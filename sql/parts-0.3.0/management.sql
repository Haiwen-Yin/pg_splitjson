CREATE OR REPLACE FUNCTION splitjson._qualified_name(p_table regclass) RETURNS text
LANGUAGE sql STABLE STRICT SET search_path=pg_catalog, pg_temp
RETURN (SELECT format('%I.%I',n.nspname,c.relname) FROM pg_class c
        JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=p_table);

CREATE OR REPLACE FUNCTION splitjson._view_definition(p_table regclass) RETURNS text
LANGUAGE sql STABLE STRICT SET search_path=pg_catalog, pg_temp
RETURN pg_get_viewdef(p_table,true);

CREATE OR REPLACE FUNCTION splitjson._secure_relation(p_table regclass) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE grantee_name text;
BEGIN
    FOR grantee_name IN SELECT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee WHERE c.oid=p_table AND a.grantee<>c.relowner
    LOOP EXECUTE format('REVOKE ALL ON %s FROM %s CASCADE',p_table,grantee_name); END LOOP;
END $$;

CREATE OR REPLACE FUNCTION splitjson._storage_definition(p_table regclass) RETURNS jsonb
LANGUAGE sql STABLE STRICT SET search_path=pg_catalog, pg_temp
RETURN (SELECT jsonb_agg(jsonb_build_object('name',attname,'type',format_type(atttypid,atttypmod),
                'collation',attcollation::regcollation::text,'generated',attgenerated,'identity',attidentity,'not_null',attnotnull,'storage',attstorage)
                ORDER BY attnum)
        FROM pg_attribute WHERE attrelid=p_table AND attnum>0 AND NOT attisdropped);

UPDATE splitjson._tables SET storage_definition=splitjson._storage_definition(storage_name::regclass);

CREATE FUNCTION splitjson._replication_fingerprint(p_meta splitjson._tables) RETURNS text
LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog,pg_temp
RETURN md5('0.3.0:'||p_meta.storage_definition::text||p_meta.paths::text||p_meta.business_columns::text||p_meta.storage_mode||coalesce(p_meta.partition_spec::text,''));

-- A path segment naming an array element must be an integer when it is
-- traversed below an existing object path.  jsonb #- has a subtle edge case:
-- applying a non-integer segment to an array at the root is a no-op, while the
-- same segment after an object key raises 22P02.  Fast delete paths start at a
-- hot subtree, so inspect that subtree before using the short update.  This
-- keeps the short path cold-free while preserving native JSONB errors.
CREATE OR REPLACE FUNCTION splitjson._array_path_requires_fallback(p_value jsonb,p_path text[])
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT SET search_path=pg_catalog, pg_temp
AS $$
DECLARE cursor jsonb := p_value; i integer; segment text;
BEGIN
    FOR i IN 1..cardinality(p_path) LOOP
        segment := p_path[i];
        IF jsonb_typeof(cursor)='array' AND segment !~ '^[[:space:]]*[+-]?[0-9]+$' THEN
            RETURN true;
        END IF;
        cursor := cursor #> ARRAY[segment];
        IF cursor IS NULL THEN RETURN false; END IF;
    END LOOP;
    RETURN false;
END $$;

CREATE OR REPLACE FUNCTION splitjson._policy_definition(p_storage regclass) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp
RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('name',p.polname,'command',p.polcmd,
    'permissive',p.polpermissive,'roles',(SELECT jsonb_agg(CASE WHEN x=0 THEN 'public' ELSE pg_get_userbyid(x)::text END ORDER BY x) FROM unnest(p.polroles) x),
    'using',pg_get_expr(p.polqual,p.polrelid),'check',pg_get_expr(p.polwithcheck,p.polrelid)) ORDER BY p.polname COLLATE "C")
    FROM pg_policy p WHERE p.polrelid=p_storage),'[]'::jsonb);

CREATE OR REPLACE FUNCTION splitjson._validate_mapping(p_meta splitjson._tables) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp
AS $$
DECLARE v oid; s oid; installer oid; hot_count integer; expected_count integer; leaf record;
BEGIN
    v:=to_regclass(p_meta.view_name); s:=to_regclass(p_meta.storage_name);
    SELECT extowner INTO installer FROM pg_extension WHERE extname='pg_splitjson';
    IF EXISTS(SELECT 1 FROM pg_namespace n CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a
        WHERE n.nspname='splitjson_storage' AND a.grantee<>installer) OR
       EXISTS(SELECT 1 FROM pg_namespace WHERE nspname IN ('splitjson','splitjson_storage') AND nspowner<>installer) OR
       EXISTS(SELECT 1 FROM pg_namespace n CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a
        WHERE n.nspname='splitjson' AND a.grantee<>installer AND a.privilege_type='CREATE') THEN
        RAISE EXCEPTION 'private schema ownership or ACL has drifted' USING ERRCODE='55000'; END IF;
    IF v IS NULL OR s IS NULL OR
       NOT EXISTS(SELECT 1 FROM pg_class WHERE oid=v AND relkind='v' AND relowner=installer
          AND reloptions @> ARRAY['security_barrier=true'] AND
          coalesce(reloptions @> ARRAY['security_invoker=true'],false)=p_meta.rls_enabled) OR
       NOT EXISTS(SELECT 1 FROM pg_class WHERE oid=s AND relkind=CASE WHEN p_meta.storage_mode='heap' THEN 'r'::"char" ELSE 'p'::"char" END
          AND relowner=installer AND relpersistence='p' AND relnamespace=to_regnamespace('splitjson_storage')
          AND relrowsecurity=p_meta.rls_enabled AND relforcerowsecurity=p_meta.rls_force) THEN
        RAISE EXCEPTION 'invalid managed relation, ownership, RLS or storage layout: %',p_meta.view_name USING ERRCODE='55000';
    END IF;
    IF EXISTS(SELECT 1 FROM splitjson._jobs j WHERE j.source_name=p_meta.view_name AND j.state NOT IN ('completed','aborted') AND
        (j.source_epoch<>p_meta.layout_epoch OR j.source_fingerprint<>splitjson._capture_fingerprint(p_meta))) THEN
        RAISE EXCEPTION 'active migration source definition has drifted' USING ERRCODE='55000'; END IF;
    IF EXISTS(SELECT 1 FROM splitjson._replicas r WHERE r.view_name=p_meta.view_name AND r.state NOT IN ('detached','promoted') AND
       (r.fingerprint<>splitjson._replication_fingerprint(p_meta) OR (r.detail ? 'source_fingerprint' AND r.detail->>'source_fingerprint'<>splitjson._capture_fingerprint(p_meta)))) THEN
        RAISE EXCEPTION 'active replication layout/security definition has drifted' USING ERRCODE='55000'; END IF;
    PERFORM splitjson.validate_paths(p_meta.paths);
    hot_count:=jsonb_array_length(p_meta.paths);
    expected_count:=3+hot_count+(SELECT count(*) FROM jsonb_object_keys(p_meta.business_columns));
    IF hot_count=0 OR jsonb_array_length(p_meta.storage_definition) IS DISTINCT FROM expected_count OR
       (p_meta.storage_mode<>'heap' AND NOT EXISTS(SELECT 1 FROM pg_partitioned_table WHERE partrelid=s AND partnatts=1 AND partattrs[0]=1 AND
            partstrat=CASE WHEN p_meta.storage_mode='hash' THEN 'h'::"char" ELSE 'r'::"char" END)) OR
       splitjson._storage_definition(s) IS DISTINCT FROM p_meta.storage_definition OR
       splitjson._view_definition(v) IS DISTINCT FROM p_meta.view_definition OR
       NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=s AND attnum=1 AND attname='id' AND atttypid='int8'::regtype AND attnotnull) OR
       NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=s AND attnum=2 AND attname='cold' AND atttypid='splitjson.cold'::regtype AND attnotnull AND attstorage='e') OR
       NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=s AND attname='row_revision' AND atttypid='int8'::regtype AND attnotnull) OR
       NOT EXISTS(SELECT 1 FROM pg_index WHERE indrelid=s AND indisprimary AND indisvalid AND indnkeyatts=1 AND indkey[0]=1) OR
       NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=v AND tgname='pg_splitjson_write' AND tgfoid='splitjson._view_write()'::regprocedure AND tgenabled='O' AND tgtype=93) OR
       NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=s AND tgname=format('pg_splitjson_revision_%s',md5(p_meta.storage_name))
          AND tgfoid='splitjson._revision_write()'::regprocedure AND tgenabled='O' AND tgtype=23) OR
       NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=s AND tgname='pg_splitjson_fence'
          AND tgfoid='splitjson._storage_write_guard()'::regprocedure AND tgenabled='O' AND tgtype=62) OR
       EXISTS(SELECT 1 FROM generate_series(1,hot_count) i WHERE NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=s AND attname='hot_'||i AND atttypid='jsonb'::regtype AND NOT attisdropped)) OR
       EXISTS(SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE c.oid=s AND a.grantee<>installer) OR
       EXISTS(SELECT 1 FROM pg_attribute t CROSS JOIN LATERAL aclexplode(t.attacl) a WHERE t.attrelid=s AND a.grantee<>installer) OR
       splitjson._policy_definition(s) IS DISTINCT FROM p_meta.policy_definition OR
       (p_meta.revision_initialized AND NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_sequence q ON q.seqrelid=c.oid WHERE c.oid=to_regclass(p_meta.revision_sequence)
          AND c.relowner=installer AND c.relnamespace='splitjson'::regnamespace AND NOT q.seqcycle AND q.seqincrement=1 AND q.seqmin=1 AND q.seqtypid='int8'::regtype)) OR
       EXISTS(SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE c.oid=to_regclass(p_meta.revision_sequence) AND a.grantee<>installer) THEN
        RAISE EXCEPTION 'managed mapping has drifted: %; restore its layout before use',p_meta.view_name USING ERRCODE='55000';
    END IF;
    IF EXISTS(SELECT 1 FROM splitjson._slot_types t WHERE t.view_name=p_meta.view_name AND NOT EXISTS(SELECT 1 FROM pg_constraint c WHERE c.conrelid=s AND c.conname=t.guard_name AND c.convalidated AND pg_get_constraintdef(c.oid,true)=t.definition)) THEN
        RAISE EXCEPTION 'managed path type guard has drifted' USING ERRCODE='55000'; END IF;
    -- Dropping an index is allowed. Remove stale registrations in the DDL guard;
    -- live registrations must retain their canonical definition.
    IF EXISTS(SELECT 1 FROM splitjson._path_indexes i WHERE i.view_name=p_meta.view_name AND to_regclass(i.index_name) IS NOT NULL AND pg_get_indexdef(to_regclass(i.index_name)) IS DISTINCT FROM i.definition) THEN
        RAISE EXCEPTION 'managed path index has drifted' USING ERRCODE='55000'; END IF;
    FOR leaf IN SELECT l.*,c.oid,c.relowner,c.relkind,c.relrowsecurity,c.relforcerowsecurity,c.relacl,c.relnamespace FROM splitjson._leaves l
        LEFT JOIN pg_class c ON c.oid=to_regclass(l.relation_name) WHERE l.view_name=p_meta.view_name LOOP
        IF leaf.oid IS NULL OR leaf.relowner<>installer OR leaf.relkind<>'r' OR leaf.relrowsecurity OR leaf.relforcerowsecurity OR
           leaf.relnamespace<>to_regnamespace('splitjson_storage') OR
           NOT EXISTS(SELECT 1 FROM pg_inherits WHERE inhparent=s AND inhrelid=leaf.oid) OR
           splitjson._storage_definition(leaf.oid) IS DISTINCT FROM p_meta.storage_definition OR
           (SELECT pg_get_expr(relpartbound,oid) FROM pg_class WHERE oid=leaf.oid) IS DISTINCT FROM leaf.bound OR
           splitjson._partition_bound(leaf.oid) IS DISTINCT FROM leaf.bound_spec OR
           EXISTS(SELECT 1 FROM aclexplode(leaf.relacl) a WHERE a.grantee<>installer) OR
           EXISTS(SELECT 1 FROM pg_attribute t CROSS JOIN LATERAL aclexplode(t.attacl) a WHERE t.attrelid=leaf.oid AND a.grantee<>installer) OR
           NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=leaf.oid AND tgname=format('pg_splitjson_revision_%s',md5(p_meta.storage_name)) AND
                tgfoid='splitjson._revision_write()'::regprocedure AND tgenabled='O' AND tgtype=23) OR
           NOT EXISTS(SELECT 1 FROM pg_index WHERE indrelid=leaf.oid AND indisprimary AND indisvalid AND indnkeyatts=1 AND indkey[0]=1) OR
           EXISTS(SELECT 1 FROM pg_inherits WHERE inhparent=leaf.oid) OR
           EXISTS(SELECT 1 FROM pg_policy WHERE polrelid=leaf.oid) THEN
            RAISE EXCEPTION 'managed partition has drifted: %',leaf.relation_name USING ERRCODE='55000';
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM pg_inherits WHERE inhparent=s)<>(SELECT count(*) FROM splitjson._leaves WHERE view_name=p_meta.view_name) THEN
        RAISE EXCEPTION 'unregistered partition attached to %',p_meta.view_name USING ERRCODE='55000'; END IF;
END $$;

CREATE OR REPLACE FUNCTION splitjson.storage_relation(p_table regclass) RETURNS regclass
LANGUAGE plpgsql STABLE SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE;
BEGIN
    meta := splitjson._lookup(p_table,'SELECT');
    RETURN meta.storage_name::regclass;
END $$;

CREATE OR REPLACE FUNCTION splitjson.check_table(p_table regclass,p_check_data boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE; rows_checked bigint := 0; invalid_indexes bigint;
BEGIN
    IF p_check_data IS NULL THEN RAISE EXCEPTION 'check_data must not be NULL' USING ERRCODE='22023'; END IF;
    meta := splitjson._lookup(p_table,'SELECT');
    IF p_check_data THEN
        EXECUTE format('SELECT count(splitjson.restore(cold,%s,$1)) FROM %s',
                       splitjson._hot_array(meta.paths),meta.storage_name) INTO rows_checked USING meta.paths;
    END IF;
    SELECT count(*) INTO invalid_indexes FROM pg_index
        WHERE indrelid IN (SELECT meta.storage_name::regclass UNION ALL SELECT to_regclass(relation_name) FROM splitjson._leaves WHERE view_name=meta.view_name)
        AND (NOT indisvalid OR NOT indisready);
    RETURN jsonb_build_object('view',meta.view_name,'storage',meta.storage_name,
               'layout_ok',true,'rows_checked',rows_checked,'invalid_indexes',invalid_indexes);
END $$;

CREATE OR REPLACE FUNCTION splitjson.check_all(p_check_data boolean DEFAULT false) RETURNS SETOF jsonb
LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE relation text;
BEGIN
    FOR relation IN SELECT view_name FROM splitjson._tables ORDER BY view_name LOOP
        RETURN NEXT splitjson.check_table(relation::regclass,p_check_data);
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION splitjson.table_stats(p_table regclass) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE; stats jsonb;
BEGIN
    meta := splitjson._lookup(p_table,'SELECT');
    SELECT to_jsonb(s) || jsonb_build_object('view',meta.view_name,
        'total_bytes',pg_total_relation_size(s.relid),'heap_bytes',pg_relation_size(s.relid),
        'indexes_bytes',pg_indexes_size(s.relid)) INTO stats
        FROM pg_stat_user_tables s WHERE relid=meta.storage_name::regclass;
    RETURN stats;
END $$;

CREATE OR REPLACE FUNCTION splitjson.rename_table(p_table regclass,p_name text) RETURNS regclass
LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE; parts text[]; oldparts text[]; target text;
BEGIN
    meta := splitjson._lookup(p_table,'SELECT');
    PERFORM splitjson._assert_idle(p_table);
    parts := parse_ident(p_name,true); oldparts := parse_ident(meta.view_name,true);
    IF cardinality(parts)<>2 OR parts[1]<>oldparts[1] OR octet_length(parts[2])>63 THEN
        RAISE EXCEPTION 'use a schema-qualified name in the same business schema' USING ERRCODE='22023';
    END IF;
    target := format('%I.%I',parts[1],parts[2]);
    IF to_regclass(target) IS NOT NULL THEN RAISE EXCEPTION 'target already exists' USING ERRCODE='42P07'; END IF;
    UPDATE splitjson._tables SET view_name=target WHERE view_name=meta.view_name;
    EXECUTE format('ALTER VIEW %s RENAME TO %I',meta.view_name,parts[2]);
    RETURN target::regclass;
END $$;

CREATE OR REPLACE FUNCTION splitjson.set_business_not_null(p_table regclass,p_column text,p_enabled boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE; slot integer;
BEGIN
    meta := splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    -- Use the same C ordering as create_table, not jsonb key-length ordering.
    SELECT n INTO slot FROM (SELECT key,row_number() OVER (ORDER BY key COLLATE "C")::integer n
                            FROM jsonb_each_text(meta.business_columns)) c WHERE key=p_column;
    IF slot IS NULL OR p_enabled IS NULL THEN RAISE EXCEPTION 'unknown business column or NULL flag' USING ERRCODE='22023'; END IF;
    EXECUTE format('ALTER TABLE %s ALTER COLUMN extra_%s %s NOT NULL',
                   meta.storage_name,slot,CASE WHEN p_enabled THEN 'SET' ELSE 'DROP' END);
    UPDATE splitjson._tables SET storage_definition=splitjson._storage_definition(meta.storage_name::regclass),view_definition=splitjson._view_definition(meta.view_name::regclass)
        WHERE view_name=meta.view_name;
END $$;

CREATE OR REPLACE FUNCTION splitjson.set_business_default(p_table regclass,p_column text,p_value jsonb)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE; slot integer; declaration text; literal text;
BEGIN
    meta := splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    SELECT n,value INTO slot,declaration FROM (SELECT key,value,
        row_number() OVER (ORDER BY key COLLATE "C")::integer n FROM jsonb_each_text(meta.business_columns)) c
        WHERE key=p_column;
    IF slot IS NULL THEN RAISE EXCEPTION 'unknown business column' USING ERRCODE='22023'; END IF;
    IF p_value IS NULL THEN
        EXECUTE format('ALTER TABLE %s ALTER COLUMN extra_%s DROP DEFAULT',meta.storage_name,slot);
        EXECUTE format('ALTER VIEW %s ALTER COLUMN %I DROP DEFAULT',meta.view_name,p_column);
    ELSE
        EXECUTE format('SELECT ((jsonb_populate_record(NULL::%s,$1)).%I)::text',meta.view_name,p_column)
            INTO literal USING jsonb_build_object(p_column,p_value);
        EXECUTE format('ALTER TABLE %s ALTER COLUMN extra_%s SET DEFAULT %L::%s',meta.storage_name,slot,literal,declaration);
        EXECUTE format('ALTER VIEW %s ALTER COLUMN %I SET DEFAULT %L::%s',meta.view_name,p_column,literal,declaration);
    END IF;
    UPDATE splitjson._tables SET storage_definition=splitjson._storage_definition(meta.storage_name::regclass),view_definition=splitjson._view_definition(meta.view_name::regclass)
        WHERE view_name=meta.view_name;
END $$;

CREATE OR REPLACE FUNCTION splitjson.add_field_check(p_table regclass,p_name text,p_path jsonb,
                                                    p_type text,p_required boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE; slot integer; condition text; parts text[];
BEGIN
    meta := splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    PERFORM splitjson.validate_paths(jsonb_build_array(p_path));
    parts := parse_ident(p_name,true);
    IF p_type IS NULL OR p_required IS NULL OR cardinality(parts)<>1 OR octet_length(parts[1])>63 OR
       p_type NOT IN ('object','array','string','number','boolean','null') THEN
        RAISE EXCEPTION 'invalid check name or JSON type' USING ERRCODE='22023';
    END IF;
    SELECT ord::integer INTO slot FROM jsonb_array_elements(meta.paths) WITH ORDINALITY p(path,ord) WHERE path=p_path;
    IF slot IS NULL THEN RAISE EXCEPTION 'check path must be a registered hot slot' USING ERRCODE='22023'; END IF;
    condition := format('jsonb_typeof(hot_%s)=%L',slot,p_type);
    IF p_required THEN condition := format('hot_%s IS NOT NULL AND (%s)',slot,condition); END IF;
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%s)',meta.storage_name,parts[1],condition);
    INSERT INTO splitjson._field_checks VALUES(meta.view_name,parts[1],p_path,p_type,p_required);
END $$;

CREATE OR REPLACE FUNCTION splitjson.index_ddl(p_table regclass,p_name text,p_path jsonb,
                                             p_kind text DEFAULT 'jsonb',p_unique boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE; slot integer; parts text[]; expression text;
BEGIN
    meta := splitjson._lookup(p_table,'SELECT');
    PERFORM splitjson.validate_paths(jsonb_build_array(p_path));
    parts := parse_ident(p_name,true);
    IF p_kind IS NULL OR p_unique IS NULL OR cardinality(parts)<>1 OR octet_length(parts[1])>63 OR
       p_kind NOT IN ('jsonb','text') THEN RAISE EXCEPTION 'invalid index declaration' USING ERRCODE='22023'; END IF;
    SELECT ord::integer INTO slot FROM jsonb_array_elements(meta.paths) WITH ORDINALITY p(path,ord) WHERE path=p_path;
    IF slot IS NULL THEN RAISE EXCEPTION 'path must be a registered hot slot' USING ERRCODE='22023'; END IF;
    expression := format('hot_%s',slot);
    IF p_kind='text' THEN expression := format('(%s #>> %L::text[])',expression,'{}'); END IF;
    RETURN format('CREATE %sINDEX CONCURRENTLY %I ON %s USING btree (%s);',
                  CASE WHEN p_unique THEN 'UNIQUE ' ELSE '' END,parts[1],meta.storage_name,expression);
END $$;

CREATE OR REPLACE FUNCTION splitjson._ddl_end_guard() RETURNS event_trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE;
BEGIN
    IF to_regclass('splitjson._tables') IS NULL OR splitjson._ddl_scope() THEN RETURN; END IF;
    FOR meta IN SELECT * FROM splitjson._tables LOOP PERFORM splitjson._validate_mapping(meta); END LOOP;
END $$;

CREATE OR REPLACE FUNCTION splitjson._sql_drop_guard() RETURNS event_trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog, pg_temp
AS $$
BEGIN
    IF to_regclass('splitjson._tables') IS NULL OR splitjson._ddl_scope() THEN RETURN; END IF;
    IF EXISTS(SELECT 1 FROM pg_event_trigger_dropped_objects() d JOIN splitjson._tables m
        ON format('%I.%I',d.schema_name,d.object_name) IN (m.view_name,m.storage_name)
        WHERE d.object_type IN ('table','view')) THEN
        RAISE EXCEPTION 'use splitjson.drop_table to remove managed relations' USING ERRCODE='55000';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION splitjson._ddl_start_guard() RETURNS event_trigger
AS 'MODULE_PATHNAME','pg_splitjson_ddl_start_guard' LANGUAGE C SECURITY DEFINER SET search_path=pg_catalog, pg_temp;

CREATE FUNCTION splitjson.reinitialize_table(p_table regclass,p_reason text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; maximum bigint; sequence_value bigint; epoch text;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT');
    IF p_reason IS NULL OR p_reason NOT IN ('restore','recovery','import','takeover') THEN
        RAISE EXCEPTION 'reason must be restore, recovery, import or takeover' USING ERRCODE='22023'; END IF;
    EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE',m.storage_name);
    IF to_regclass(m.revision_sequence) IS NULL THEN
        EXECUTE format('CREATE SEQUENCE %s NO CYCLE',m.revision_sequence);
        PERFORM splitjson._secure_relation(m.revision_sequence::regclass);
    END IF;
    EXECUTE format('SELECT coalesce(max(row_revision),0) FROM %s',m.storage_name) INTO maximum;
    EXECUTE format('SELECT last_value FROM %s',m.revision_sequence) INTO sequence_value;
    PERFORM setval(m.revision_sequence::regclass,greatest(maximum,sequence_value,1),true);
    epoch:=splitjson._new_epoch();
    UPDATE splitjson._tables SET layout_epoch=epoch,layout_generation=layout_generation+1,revision_initialized=true WHERE view_name=m.view_name;
    RETURN epoch;
END $$;

CREATE FUNCTION splitjson.set_business_collation(p_table regclass,p_column text,p_collation name) RETURNS regclass
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; n integer; declaration text; coll regcollation; qualified text; select_columns text:=''; key text;
    view_acl jsonb; column_acl jsonb; defaults jsonb; item jsonb; target regclass;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    SELECT x.i,x.value INTO n,declaration FROM (SELECT e.key,e.value,row_number() OVER(ORDER BY e.key COLLATE "C")::integer i FROM jsonb_each_text(m.business_columns) e) x WHERE x.key=p_column;
    coll:=splitjson._collation(p_collation);
    IF n IS NULL OR coll IS NULL THEN RAISE EXCEPTION 'business column and collation required' USING ERRCODE='22023'; END IF;
    SELECT format('%I.%I',ns.nspname,c.collname) INTO qualified FROM pg_collation c JOIN pg_namespace ns ON ns.oid=c.collnamespace WHERE c.oid=coll;
    SELECT coalesce(jsonb_agg(jsonb_build_object('role',CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END,'privilege',a.privilege_type,'grantable',a.is_grantable)),'[]') INTO view_acl
        FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE c.oid=p_table AND a.grantee<>c.relowner;
    SELECT coalesce(jsonb_agg(jsonb_build_object('role',CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END,'privilege',a.privilege_type,'grantable',a.is_grantable,'column',t.attname)),'[]') INTO column_acl
        FROM pg_attribute t CROSS JOIN LATERAL aclexplode(t.attacl) a WHERE t.attrelid=p_table;
    SELECT coalesce(jsonb_agg(jsonb_build_object('column',a.attname,'expression',pg_get_expr(d.adbin,d.adrelid))),'[]') INTO defaults
        FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid=d.adrelid AND a.attnum=d.adnum WHERE d.adrelid=p_table;
    -- External view dependents cause an atomic error, never DROP CASCADE.
    EXECUTE format('DROP VIEW %s',m.view_name);
    EXECUTE format('ALTER TABLE %s ALTER COLUMN extra_%s TYPE %s COLLATE %s',m.storage_name,n,declaration,qualified);
    n:=0;
    FOR key IN SELECT e.key FROM jsonb_each(m.business_columns) e ORDER BY e.key COLLATE "C" LOOP
        n:=n+1; select_columns:=select_columns||format(',extra_%s AS %I',n,key); END LOOP;
    EXECUTE format('CREATE VIEW %s WITH (security_barrier=true,security_invoker=%s) AS SELECT id,splitjson.restore(cold,%s,%L::jsonb) AS doc%s FROM %s',m.view_name,
        CASE WHEN m.rls_enabled THEN 'true' ELSE 'false' END,splitjson._hot_array(m.paths),m.paths,select_columns,m.storage_name);
    EXECUTE format('CREATE TRIGGER pg_splitjson_write INSTEAD OF INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION splitjson._view_write()',m.view_name);
    target:=m.view_name::regclass;
    FOR item IN SELECT value FROM jsonb_array_elements(view_acl) LOOP
        EXECUTE format('GRANT %s ON %s TO %s%s',item->>'privilege',m.view_name,item->>'role',CASE WHEN (item->>'grantable')::boolean THEN ' WITH GRANT OPTION' ELSE '' END); END LOOP;
    FOR item IN SELECT value FROM jsonb_array_elements(column_acl) LOOP
        EXECUTE format('GRANT %s(%I) ON %s TO %s%s',item->>'privilege',item->>'column',m.view_name,item->>'role',CASE WHEN (item->>'grantable')::boolean THEN ' WITH GRANT OPTION' ELSE '' END); END LOOP;
    FOR item IN SELECT value FROM jsonb_array_elements(defaults) LOOP
        EXECUTE format('ALTER VIEW %s ALTER COLUMN %I SET DEFAULT %s',m.view_name,item->>'column',item->>'expression'); END LOOP;
    UPDATE splitjson._tables SET view_definition=splitjson._view_definition(target),storage_definition=splitjson._storage_definition(m.storage_name::regclass) WHERE view_name=m.view_name;
    RETURN target;
END $$;
