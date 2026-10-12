-- Online migration uses persistent original-layout column state and commits
-- target changes/progress together before acknowledging the source slot.
CREATE FUNCTION splitjson._capture_fingerprint(p_meta splitjson._tables) RETURNS text
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp
RETURN md5(p_meta.storage_definition::text||p_meta.paths::text||p_meta.business_columns::text||coalesce(p_meta.partition_spec::text,'')||
    p_meta.policy_definition::text||coalesce((SELECT relacl::text FROM pg_class WHERE oid=to_regclass(p_meta.view_name)),'')||
    coalesce((SELECT jsonb_agg(jsonb_build_object('name',a.attname,'acl',a.attacl,'default',pg_get_expr(d.adbin,d.adrelid)) ORDER BY a.attnum)
        FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
        WHERE a.attrelid=to_regclass(p_meta.view_name) AND a.attnum>0 AND NOT a.attisdropped)::text,'')||
    coalesce((SELECT jsonb_agg(jsonb_build_object('relation',c.oid::regclass::text,'identity',c.relreplident,
        'defaults',(SELECT jsonb_agg(jsonb_build_object('column',adnum,'default',pg_get_expr(adbin,adrelid)) ORDER BY adnum) FROM pg_attrdef WHERE adrelid=c.oid),
        'indexes',(SELECT jsonb_agg(pg_get_indexdef(indexrelid) ORDER BY indexrelid::regclass::text) FROM pg_index WHERE indrelid=c.oid),
        'constraints',(SELECT jsonb_agg(jsonb_build_object('name',conname,'definition',pg_get_constraintdef(oid,true)) ORDER BY conname) FROM pg_constraint WHERE conrelid=c.oid),
        'triggers',(SELECT jsonb_agg(jsonb_build_object('name',tgname,'enabled',tgenabled,'definition',pg_get_triggerdef(oid)) ORDER BY tgname) FROM pg_trigger WHERE tgrelid=c.oid AND NOT tgisinternal)) ORDER BY c.oid::regclass::text)
        FROM pg_class c WHERE c.oid IN (SELECT to_regclass(p_meta.storage_name) UNION ALL SELECT to_regclass(relation_name) FROM splitjson._leaves WHERE view_name=p_meta.view_name))::text,''));

CREATE FUNCTION splitjson.fence_writes(p_table regclass,p_enabled boolean DEFAULT true) RETURNS pg_lsn
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; position pg_lsn;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT');
    IF p_enabled IS NULL THEN RAISE EXCEPTION 'fence flag must not be NULL' USING ERRCODE='22023'; END IF;
    EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE',m.storage_name);
    UPDATE splitjson._tables SET write_fenced=p_enabled,fence_lsn=NULL WHERE view_name=m.view_name;
    position:=pg_current_wal_insert_lsn();
    IF p_enabled THEN UPDATE splitjson._tables SET fence_lsn=position WHERE view_name=m.view_name; END IF;
    RETURN position;
END $$;

CREATE FUNCTION splitjson.prepare_online_migration(p_source regclass,p_target text,p_paths jsonb,p_options jsonb DEFAULT '{}') RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; plan jsonb; job bigint; source_fingerprint text; slot name; target regclass;
BEGIN
    m:=splitjson._lookup(p_source,'SELECT'); PERFORM splitjson._export_access(m,false);
    IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=splitjson._caller() AND rolsuper) THEN
        RAISE EXCEPTION 'online decoding requires a trusted superuser installer' USING ERRCODE='42501'; END IF;
    IF current_setting('wal_level')<>'logical' OR current_setting('max_replication_slots')::integer<1 OR
       NOT ('pg_splitjson_decode'=ANY(string_to_array(replace(current_setting('output_plugin_libraries'),' ',''),','))) THEN
        RAISE EXCEPTION 'requires wal_level=logical, a slot and allowed pg_splitjson_decode module' USING ERRCODE='55000'; END IF;
    PERFORM splitjson._assert_idle(p_source);
    plan:=splitjson._api_migration_plan(p_source,p_target,p_paths,p_options||jsonb_build_object('mode','online'));
    target:=splitjson._api_import_manifest(plan,p_target,(p_options-'mode'-'subset'-'copy')||jsonb_build_object('paths',p_paths));
    UPDATE splitjson._tables SET follower_mode=true WHERE view_name=splitjson._qualified_name(target);
    source_fingerprint:=splitjson._capture_fingerprint(m);
    job:=nextval('splitjson._job_id_seq'); slot:=('sj_job_'||job||'_'||substr(md5(gen_random_uuid()::text),1,12))::name;
    INSERT INTO splitjson._jobs(id,source_name,target_name,state,source_epoch,target_epoch,source_fingerprint,slot_name,detail)
        SELECT job,m.view_name,splitjson._qualified_name(target),'prepare',m.layout_epoch,t.layout_epoch,source_fingerprint,slot,
            jsonb_build_object('paths',p_paths,'options',p_options,'snapshot_complete',false)
        FROM splitjson._tables t WHERE view_name=splitjson._qualified_name(target);
    RETURN job;
END $$;

CREATE FUNCTION splitjson.migration_status(p_job bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE j splitjson._jobs%ROWTYPE; m splitjson._tables%ROWTYPE; slot jsonb;
BEGIN
    SELECT * INTO j FROM splitjson._jobs WHERE id=p_job;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO m FROM splitjson._tables WHERE view_name=j.source_name;
    SELECT to_jsonb(s)-'catalog_xmin'-'xmin' INTO slot FROM pg_replication_slots s WHERE slot_name=j.slot_name;
    RETURN to_jsonb(j)||jsonb_build_object('slot',slot,'retained_bytes',CASE WHEN slot IS NULL THEN NULL ELSE pg_wal_lsn_diff(pg_current_wal_lsn(),(slot->>'restart_lsn')::pg_lsn) END,
        'requires_rebootstrap',j.state NOT IN ('prepare','completed','aborted') AND (slot IS NULL OR slot->>'wal_status'='lost'),
        'source_fenced',m.write_fenced,'cutover_ready',j.state='ready' AND m.write_fenced AND j.ready_lsn>=m.fence_lsn AND slot IS NOT NULL AND slot->>'wal_status'<>'lost' AND
            (slot->>'confirmed_flush_lsn')::pg_lsn>=j.ready_lsn AND j.source_fingerprint=splitjson._capture_fingerprint(m),
        'evidence_position_only',true,'fingerprint_valid',j.source_epoch=m.layout_epoch AND j.source_fingerprint=splitjson._capture_fingerprint(m));
END $$;

CREATE FUNCTION splitjson._own_slot(p_job splitjson._jobs) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp
RETURN p_job.slot_name::text ~ ('^sj_job_'||p_job.id||'_[a-f0-9]{12}$') AND
    EXISTS(SELECT 1 FROM pg_replication_slots WHERE slot_name=p_job.slot_name AND plugin='pg_splitjson_decode' AND database=current_database() AND NOT temporary);

CREATE FUNCTION splitjson.abort_migration(p_job bigint,p_reason text DEFAULT 'operator abort') RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE j splitjson._jobs%ROWTYPE;
BEGIN
    SELECT * INTO STRICT j FROM splitjson._jobs WHERE id=p_job FOR UPDATE;
    IF j.state IN ('completed','aborted') THEN RAISE EXCEPTION 'migration is terminal' USING ERRCODE='55000'; END IF;
    IF splitjson._own_slot(j) THEN PERFORM pg_drop_replication_slot(j.slot_name); END IF;
    DELETE FROM splitjson._migration_rows WHERE job_id=p_job;
    UPDATE splitjson._jobs SET state='aborted',error_state=coalesce(p_reason,'operator abort') WHERE id=p_job;
    -- Retain the target as a fenced/partial artifact. Explicit cleanup uses
    -- drop_table; the source and all unrelated slots remain untouched.
END $$;

CREATE FUNCTION splitjson.mark_migration_state(p_job bigint,p_state text,p_lsn pg_lsn DEFAULT NULL,p_detail jsonb DEFAULT '{}') RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE j splitjson._jobs%ROWTYPE; m splitjson._tables%ROWTYPE;
BEGIN
    SELECT * INTO STRICT j FROM splitjson._jobs WHERE id=p_job FOR UPDATE;
    SELECT * INTO STRICT m FROM splitjson._tables WHERE view_name=j.source_name;
    IF j.state IN ('completed','aborted') OR p_state IS NULL OR
       p_state NOT IN ('copying','catching_up','ready','failed') THEN RAISE EXCEPTION 'invalid migration transition' USING ERRCODE='55000'; END IF;
    IF p_state<>'failed' AND (j.source_epoch<>m.layout_epoch OR j.source_fingerprint<>splitjson._capture_fingerprint(m)) THEN
        RAISE EXCEPTION 'source layout/security fingerprint changed' USING ERRCODE='55000'; END IF;
    IF p_state='copying' AND (j.state<>'prepare' OR p_lsn IS NULL OR NOT splitjson._own_slot(j)) THEN
        RAISE EXCEPTION 'copying requires owned exported-snapshot slot handshake' USING ERRCODE='55000'; END IF;
    IF p_state IN ('catching_up','ready') AND (p_lsn IS NULL OR NOT splitjson._own_slot(j) OR
       NOT coalesce((p_detail->>'snapshot_complete')::boolean,(j.detail->>'snapshot_complete')::boolean,false)) THEN
        RAISE EXCEPTION 'replay requires complete snapshot state and owned slot' USING ERRCODE='55000'; END IF;
    IF p_lsn<j.confirmed_lsn THEN RAISE EXCEPTION 'migration progress cannot move backwards' USING ERRCODE='55000'; END IF;
    UPDATE splitjson._jobs SET state=p_state,start_lsn=CASE WHEN p_state='copying' THEN p_lsn ELSE start_lsn END,
        confirmed_lsn=coalesce(p_lsn,confirmed_lsn),ready_lsn=CASE WHEN p_state='ready' THEN p_lsn ELSE NULL END,
        error_state=CASE WHEN p_state='failed' THEN coalesce(p_detail->>'failure','replay failed; inspect native status') ELSE NULL END,
        detail=detail||coalesce(p_detail,'{}') WHERE id=p_job;
END $$;

CREATE FUNCTION splitjson._logical_row(p_meta splitjson._tables) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp
AS $$
DECLARE n integer:=0; key text; business text:='';
BEGIN
    FOR key IN SELECT e.key FROM jsonb_each(p_meta.business_columns) e ORDER BY e.key COLLATE "C" LOOP
        n:=n+1; business:=business||CASE WHEN n=1 THEN '' ELSE ',' END||format('%L,extra_%s::text',key,n); END LOOP;
    RETURN format('jsonb_build_object(''id'',id::text,''doc'',splitjson.restore(cold,%s),''business'',jsonb_build_object(%s))',splitjson._hot_array(p_meta.paths),business);
END $$;

CREATE FUNCTION splitjson.complete_migration(p_job bigint,p_final_lsn pg_lsn,p_writer_barrier boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE j splitjson._jobs%ROWTYPE; source splitjson._tables%ROWTYPE; target splitjson._tables%ROWTYPE; equal_rows boolean;
BEGIN
    SELECT * INTO STRICT j FROM splitjson._jobs WHERE id=p_job FOR UPDATE;
    SELECT * INTO STRICT source FROM splitjson._tables WHERE view_name=j.source_name;
    SELECT * INTO STRICT target FROM splitjson._tables WHERE view_name=j.target_name;
    IF p_writer_barrier IS DISTINCT FROM true OR p_final_lsn IS NULL OR j.state<>'ready' OR
       NOT source.write_fenced OR source.fence_lsn IS NULL OR p_final_lsn<source.fence_lsn OR
       j.ready_lsn<p_final_lsn OR NOT splitjson._own_slot(j) OR
       NOT EXISTS(SELECT 1 FROM pg_replication_slots WHERE slot_name=j.slot_name AND confirmed_flush_lsn>=p_final_lsn) THEN
        RAISE EXCEPTION 'cutover requires native fence, complete replay and acknowledged final LSN' USING ERRCODE='55000'; END IF;
    EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE',source.storage_name);
    PERFORM splitjson._api_check_table(target.view_name::regclass,true);
    EXECUTE format('SELECT NOT EXISTS ((SELECT %s FROM %s EXCEPT SELECT %s FROM %s) UNION ALL (SELECT %s FROM %s EXCEPT SELECT %s FROM %s))',
        splitjson._logical_row(source),source.storage_name,splitjson._logical_row(target),target.storage_name,
        splitjson._logical_row(target),target.storage_name,splitjson._logical_row(source),source.storage_name) INTO equal_rows;
    IF equal_rows IS DISTINCT FROM true THEN RAISE EXCEPTION 'source and target logical rows differ at fence' USING ERRCODE='55000'; END IF;
    PERFORM pg_drop_replication_slot(j.slot_name);
    UPDATE splitjson._jobs SET state='completed',confirmed_lsn=p_final_lsn,ready_lsn=p_final_lsn WHERE id=p_job;
    PERFORM splitjson._api_reinitialize_table(target.view_name::regclass,'takeover');
    UPDATE splitjson._tables SET follower_mode=false WHERE view_name=target.view_name;
    DELETE FROM splitjson._migration_rows WHERE job_id=p_job;
    RETURN jsonb_build_object('job',p_job,'state','completed','source',source.view_name,'target',target.view_name,'final_lsn',p_final_lsn,'rows_equal',true,
        'source_retained',true,'source_fenced',true,'application_cutover','manual');
END $$;

CREATE FUNCTION splitjson.prepare_replica(p_table regclass,p_target regclass,p_options jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; t splitjson._tables%ROWTYPE; fingerprint text; replica text;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); t:=splitjson._lookup(p_target,'INSERT');
    fingerprint:=splitjson._replication_fingerprint(m);
    IF fingerprint IS DISTINCT FROM splitjson._replication_fingerprint(t) OR
       m.storage_mode IS DISTINCT FROM t.storage_mode THEN RAISE EXCEPTION 'replica layout fingerprint mismatch' USING ERRCODE='55000'; END IF;
    replica:=format('sj_rep_%s',substr(md5(m.view_name||t.view_name),1,20));
    INSERT INTO splitjson._replicas(view_name,source_view,publication_name,subscription_name,state,fingerprint,detail)
        VALUES(t.view_name,m.view_name,NULL,NULL,'prepared',fingerprint,jsonb_build_object('source_storage',m.storage_name,'target_storage',t.storage_name,'options',p_options))
        ON CONFLICT(view_name) DO UPDATE SET source_view=EXCLUDED.source_view,state='prepared',fingerprint=EXCLUDED.fingerprint,detail=EXCLUDED.detail;
    UPDATE splitjson._tables SET follower_mode=true WHERE view_name=t.view_name;
    RETURN jsonb_build_object('source',m.view_name,'target',t.view_name,'fingerprint',fingerprint,'state','prepared','publication_name',replica||'_pub','subscription_name',replica||'_sub','credentials',NULL);
END $$;

-- Cross-cluster preparation consumes a source manifest produced by the
-- installer.  It creates a fresh local managed relation, then adopts the
-- source's private storage name so pgoutput can address the physical row
-- relation without exposing the business view.  No roles, credentials,
-- publication or subscription are created here.
CREATE FUNCTION splitjson.prepare_replica_manifest(p_manifest jsonb,p_target text,p_options jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE target regclass; tm splitjson._tables%ROWTYPE; old_storage text; source_storage text;
    old_revision_trigger text; new_revision_trigger text; source_fingerprint text;
BEGIN
    IF p_manifest IS NULL OR p_target IS NULL OR p_options IS NULL OR jsonb_typeof(p_options)<>'object' OR
       p_manifest->>'extension' IS DISTINCT FROM 'pg_splitjson' OR p_manifest->>'version' IS DISTINCT FROM '0.3.0' OR
       p_manifest->>'storage' IS NULL OR p_manifest->>'mode' NOT IN ('heap','hash','range') OR
       jsonb_typeof(p_manifest->'paths')<>'array' OR jsonb_typeof(p_manifest->'business_columns')<>'object' OR
       EXISTS(SELECT 1 FROM jsonb_object_keys(p_options) k WHERE k NOT IN ('role_map','ignore_manual')) THEN
        RAISE EXCEPTION 'invalid replication manifest or options' USING ERRCODE='22023'; END IF;
    IF NOT has_schema_privilege(splitjson._caller(),(parse_ident(p_target,true))[1],'CREATE') THEN
        RAISE EXCEPTION 'target business schema CREATE permission required' USING ERRCODE='42501'; END IF;
    source_storage:=p_manifest->>'storage';
    IF source_storage !~ '^splitjson_storage\.s_[0-9]+$' THEN
        RAISE EXCEPTION 'manifest storage must be a qualified private relation' USING ERRCODE='22023'; END IF;
    IF to_regclass(source_storage) IS NOT NULL THEN
        RAISE EXCEPTION 'target private storage name is already occupied' USING ERRCODE='42710'; END IF;
    target:=splitjson._api_import_manifest(p_manifest,p_target,p_options);
    SELECT * INTO STRICT tm FROM splitjson._tables WHERE view_name=splitjson._qualified_name(target);
    old_storage:=tm.storage_name;
    IF old_storage<>source_storage THEN
        old_revision_trigger:=format('pg_splitjson_revision_%s',md5(old_storage));
        new_revision_trigger:=format('pg_splitjson_revision_%s',md5(source_storage));
        EXECUTE format('ALTER TABLE %s RENAME TO %I',old_storage,(parse_ident(source_storage,true))[2]);
        EXECUTE format('ALTER TRIGGER %I ON %s RENAME TO %I',old_revision_trigger,source_storage,new_revision_trigger);
        UPDATE splitjson._tables SET storage_name=source_storage,
            view_definition=splitjson._view_definition(target::regclass),
            storage_definition=splitjson._storage_definition(source_storage::regclass)
            WHERE view_name=tm.view_name;
    END IF;
    PERFORM splitjson._api_check_table(target,true);
    SELECT * INTO STRICT tm FROM splitjson._tables WHERE view_name=splitjson._qualified_name(target);
    IF tm.storage_definition IS DISTINCT FROM p_manifest->'storage_definition' THEN
        RAISE EXCEPTION 'replica physical column/type/collation fingerprint mismatch' USING ERRCODE='55000'; END IF;
    source_fingerprint:=splitjson._replication_fingerprint(tm);
    IF source_fingerprint IS DISTINCT FROM p_manifest->>'layout_fingerprint' THEN
        RAISE EXCEPTION 'source manifest fingerprint does not match the provisioned target' USING ERRCODE='55000'; END IF;
    INSERT INTO splitjson._replicas(view_name,source_view,publication_name,subscription_name,state,fingerprint,detail)
        VALUES(splitjson._qualified_name(target),p_manifest->>'view',NULL,NULL,'prepared',source_fingerprint,
               jsonb_build_object('source_storage',source_storage,'target_storage',source_storage,'manifest',p_manifest,'options',p_options))
        ON CONFLICT(view_name) DO UPDATE SET source_view=EXCLUDED.source_view,state='prepared',fingerprint=EXCLUDED.fingerprint,detail=EXCLUDED.detail;
    UPDATE splitjson._tables SET follower_mode=true WHERE view_name=splitjson._qualified_name(target);
    RETURN jsonb_build_object('source',p_manifest->>'view','target',splitjson._qualified_name(target),'storage',source_storage,
        'fingerprint',source_fingerprint,'state','prepared','publication_name',format('sj_rep_%s_pub',substr(md5(p_manifest->>'view'||splitjson._qualified_name(target)),1,20)),
        'subscription_name',format('sj_rep_%s_sub',substr(md5(p_manifest->>'view'||splitjson._qualified_name(target)),1,20)),'credentials',NULL);
END $$;

CREATE FUNCTION splitjson.replication_status(p_table regclass) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp
RETURN (SELECT to_jsonb(r)||jsonb_build_object(
    'subscription_present',s.oid IS NOT NULL,'subscription_enabled',s.subenabled,
    'workers',(SELECT coalesce(jsonb_agg(to_jsonb(ss)), '[]') FROM pg_stat_subscription ss WHERE ss.subid=s.oid),
    'active_workers',(SELECT count(*) FROM pg_stat_subscription ss WHERE ss.subid=s.oid AND ss.pid IS NOT NULL),
    'relations',(SELECT coalesce(jsonb_agg(jsonb_build_object('relation',srrelid::regclass::text,'state',srsubstate)),'[]') FROM pg_subscription_rel WHERE srsubid=s.oid),
    'synced',s.oid IS NOT NULL AND NOT EXISTS(SELECT 1 FROM pg_subscription_rel WHERE srsubid=s.oid AND srsubstate<>'r'),
    'target_confirmed_lsn',(SELECT remote_lsn FROM pg_replication_origin_status WHERE external_id='pg_'||s.oid),
    'errors',(SELECT to_jsonb(x)-'subid'-'subname' FROM pg_stat_subscription_stats x WHERE x.subid=s.oid))
    FROM splitjson._replicas r LEFT JOIN pg_subscription s ON s.subname=r.subscription_name AND s.subdbid=(SELECT oid FROM pg_database WHERE datname=current_database())
    WHERE r.view_name=splitjson._qualified_name($1));

CREATE FUNCTION splitjson.register_replica_subscription(p_table regclass,p_subscription name,p_publication name) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; r splitjson._replicas%ROWTYPE;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT');
    SELECT * INTO STRICT r FROM splitjson._replicas WHERE view_name=m.view_name FOR UPDATE;
    IF p_subscription IS NULL OR p_publication IS NULL OR NOT EXISTS(SELECT 1 FROM pg_subscription WHERE subname=p_subscription AND subpublications=ARRAY[p_publication::text]) THEN
        RAISE EXCEPTION 'matching subscription must exist before registration' USING ERRCODE='42704'; END IF;
    IF r.state NOT IN ('prepared','stopped') THEN RAISE EXCEPTION 'replica is not in a startable state' USING ERRCODE='55000'; END IF;
    UPDATE splitjson._replicas SET subscription_name=p_subscription,publication_name=p_publication,state='running',detail=detail||jsonb_build_object('subscription_registered',true) WHERE view_name=m.view_name;
    RETURN splitjson._api_replication_status(p_table);
END $$;

CREATE FUNCTION splitjson.stop_replica(p_table regclass,p_final_lsn pg_lsn DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; r splitjson._replicas%ROWTYPE;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); SELECT * INTO STRICT r FROM splitjson._replicas WHERE view_name=m.view_name FOR UPDATE;
    IF r.subscription_name IS NULL OR NOT EXISTS(SELECT 1 FROM pg_subscription WHERE subname=r.subscription_name) THEN
        RAISE EXCEPTION 'registered subscription is missing' USING ERRCODE='55000'; END IF;
    EXECUTE format('ALTER SUBSCRIPTION %I DISABLE',r.subscription_name);
    UPDATE splitjson._replicas SET state='stopped',final_lsn=coalesce(p_final_lsn,final_lsn),detail=detail||jsonb_build_object('stopped',true) WHERE view_name=m.view_name;
    RETURN splitjson._api_replication_status(p_table);
END $$;

CREATE FUNCTION splitjson.takeover_replica(p_table regclass,p_final_lsn pg_lsn,p_writer_barrier boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE r splitjson._replicas%ROWTYPE; m splitjson._tables%ROWTYPE; status jsonb; marker text;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); SELECT * INTO STRICT r FROM splitjson._replicas WHERE view_name=m.view_name FOR UPDATE;
    status:=splitjson._api_replication_status(p_table);
    IF p_writer_barrier IS DISTINCT FROM true OR p_final_lsn IS NULL OR r.state<>'stopped' OR
       r.detail->'fence'->>'token' IS NULL OR r.detail->'fence'->>'lsn' IS DISTINCT FROM p_final_lsn::text OR
       status->>'subscription_enabled' IS DISTINCT FROM 'false' OR (status->>'active_workers')::integer<>0 OR
       status->>'synced' IS DISTINCT FROM 'true' OR (status->>'target_confirmed_lsn')::pg_lsn<p_final_lsn OR
       r.detail->>'barrier_table' !~ '^splitjson_storage[.]sj_barrier_[a-f0-9]{20}$' THEN
        RAISE EXCEPTION 'takeover requires verified source fence, synchronized marker, committed apply and stopped native workers' USING ERRCODE='55000'; END IF;
    EXECUTE format('SELECT token FROM %s WHERE id=1',r.detail->>'barrier_table') INTO marker;
    IF marker IS DISTINCT FROM r.detail->'fence'->>'token' THEN
        RAISE EXCEPTION 'replicated writer fence marker is missing' USING ERRCODE='55000'; END IF;
    PERFORM splitjson._api_check_table(p_table,true);
    PERFORM splitjson._api_reinitialize_table(p_table,'takeover');
    UPDATE splitjson._tables SET follower_mode=false WHERE view_name=m.view_name;
    UPDATE splitjson._replicas SET state='promoted',final_lsn=p_final_lsn WHERE view_name=m.view_name;
    RETURN jsonb_build_object('state','promoted','view',m.view_name,'final_lsn',p_final_lsn,'writer_barrier',true,'native_workers_stopped',true);
END $$;
