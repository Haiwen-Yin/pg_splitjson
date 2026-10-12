-- Logical portability: all data passes through the native caller executor.
CREATE FUNCTION splitjson._export_access(p_meta splitjson._tables,p_subset boolean) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp
AS $$
DECLARE key text; caller oid;
BEGIN
    IF p_subset IS NULL THEN RAISE EXCEPTION 'subset must not be NULL' USING ERRCODE='22023'; END IF;
    SELECT oid INTO caller FROM pg_roles WHERE rolname=splitjson._caller();
    FOR key IN SELECT jsonb_object_keys(p_meta.business_columns) LOOP
        IF NOT has_column_privilege(caller,p_meta.view_name,key,'SELECT') THEN
            RAISE EXCEPTION 'export requires SELECT on every business column' USING ERRCODE='42501'; END IF;
    END LOOP;
    IF NOT p_subset AND p_meta.rls_enabled AND NOT EXISTS(SELECT 1 FROM pg_roles WHERE oid=caller AND
        (rolsuper OR rolbypassrls OR (NOT p_meta.rls_force AND oid=(SELECT extowner FROM pg_extension WHERE extname='pg_splitjson')))) THEN
        RAISE EXCEPTION 'full export needs complete RLS authorization; choose subset explicitly' USING ERRCODE='42501'; END IF;
END $$;

CREATE FUNCTION splitjson._schema_plan(p_meta splitjson._tables,p_copy jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp
AS $$
DECLARE plan jsonb:='[]'; item record; selected text; n integer; def_value jsonb; path jsonb;
BEGIN
    IF p_copy IS NULL OR jsonb_typeof(p_copy)<>'array' OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_copy) x WHERE jsonb_typeof(x)<>'string' OR x #>> '{}' NOT IN ('not_null','defaults','checks','indexes','rls','acl','collation')) THEN
        RAISE EXCEPTION 'invalid schema copy selection' USING ERRCODE='22023'; END IF;
    FOR selected IN SELECT jsonb_array_elements_text(p_copy) LOOP
        IF selected='not_null' THEN
            FOR item IN SELECT attname,attnum FROM pg_attribute WHERE attrelid=p_meta.storage_name::regclass AND attname LIKE 'extra_%' AND attnotnull LOOP
                n:=substr(item.attname,7)::integer;
                SELECT key INTO selected FROM (SELECT key,row_number() OVER(ORDER BY key COLLATE "C") i FROM jsonb_each(p_meta.business_columns)) x WHERE i=n;
                plan:=plan||jsonb_build_array(jsonb_build_object('category','not_null','status','apply','column',selected));
            END LOOP;
        ELSIF selected='defaults' THEN
            FOR item IN SELECT d.oid,a.attname,pg_get_expr(d.adbin,d.adrelid) expression,d.adbin::text node FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid=d.adrelid AND a.attnum=d.adnum WHERE d.adrelid=p_meta.storage_name::regclass AND a.attname LIKE 'extra_%' LOOP
                n:=substr(item.attname,7)::integer;
                SELECT key INTO selected FROM (SELECT key,row_number() OVER(ORDER BY key COLLATE "C") i FROM jsonb_each(p_meta.business_columns)) x WHERE i=n;
                -- Inspect native expression nodes; permit only builtin immutable
                -- constant expressions. User functions/domains are manual.
                IF splitjson._constant_default(item.oid) THEN
                    SELECT q.value INTO def_value FROM splitjson._query(format('SELECT to_jsonb(%s)',item.expression),ARRAY[]::regtype[],ARRAY[]::text[],true) q(value jsonb);
                    plan:=plan||jsonb_build_array(jsonb_build_object('category','defaults','status','apply','column',selected,'value',def_value));
                ELSE plan:=plan||jsonb_build_array(jsonb_build_object('category','defaults','status','manual','column',selected,'reason','nonconstant default; sequences and functions are not copied')); END IF;
            END LOOP;
        ELSIF selected='checks' THEN
            FOR item IN SELECT f.constraint_name,f.path,f.json_type,f.required FROM splitjson._field_checks f WHERE f.view_name=p_meta.view_name LOOP
                plan:=plan||jsonb_build_array(jsonb_build_object('category','checks','status','apply','name',item.constraint_name,'path',item.path,'type',item.json_type,'required',item.required));
            END LOOP;
            FOR item IN SELECT c.conname,c.contype FROM pg_constraint c WHERE c.conrelid=p_meta.storage_name::regclass AND contype IN ('c','f','u','x') AND
                c.conname NOT IN (SELECT f.constraint_name FROM splitjson._field_checks f WHERE f.view_name=p_meta.view_name UNION ALL SELECT t.guard_name FROM splitjson._slot_types t WHERE t.view_name=p_meta.view_name) LOOP
                plan:=plan||jsonb_build_array(jsonb_build_object('category','checks','status','manual','name',item.conname,'reason','unregistered CHECK, foreign key, unique or exclusion dependency')); END LOOP;
        ELSIF selected='indexes' THEN
            FOR item IN SELECT * FROM splitjson._path_indexes WHERE view_name=p_meta.view_name AND to_regclass(index_name) IS NOT NULL LOOP
                plan:=plan||jsonb_build_array(jsonb_build_object('category','indexes','status','apply','path',item.path,'kind',item.kind,'collation',item.collation_name)); END LOOP;
            FOR item IN SELECT indexrelid::regclass::text name FROM pg_index WHERE indrelid=p_meta.storage_name::regclass AND NOT indisprimary AND indexrelid NOT IN (SELECT to_regclass(index_name) FROM splitjson._path_indexes WHERE view_name=p_meta.view_name) LOOP
                plan:=plan||jsonb_build_array(jsonb_build_object('category','indexes','status','manual','name',item.name,'reason','unregistered index expression')); END LOOP;
        ELSIF selected='rls' THEN
            plan:=plan||jsonb_build_array(jsonb_build_object('category','rls','status','apply','enabled',p_meta.rls_enabled,'force',p_meta.rls_force,
                'policies',coalesce((SELECT jsonb_agg(to_jsonb(p)-'view_name') FROM splitjson._policies p WHERE view_name=p_meta.view_name),'[]')));
        ELSIF selected='acl' THEN
            FOR item IN SELECT a.grantee,bool_or(a.privilege_type IN ('INSERT','UPDATE','DELETE')) writable,
                array_agg(DISTINCT a.privilege_type ORDER BY a.privilege_type) privileges,bool_or(a.is_grantable) grantable
                FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
                WHERE c.oid=p_meta.view_name::regclass AND a.grantee<>c.relowner GROUP BY a.grantee LOOP
                IF item.grantee=0 OR item.grantable OR item.privileges NOT IN (ARRAY['SELECT'],ARRAY['DELETE','INSERT','SELECT','UPDATE']) THEN
                    plan:=plan||jsonb_build_array(jsonb_build_object('category','acl','status','manual','reason','PUBLIC, partial/special privileges or grant options require an exact manual ACL deployment'));
                ELSE
                    plan:=plan||jsonb_build_array(jsonb_build_object('category','acl','status','apply','role',pg_get_userbyid(item.grantee),'mode',CASE WHEN item.writable THEN 'write' ELSE 'read' END));
                END IF;
            END LOOP;
            IF EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=p_meta.view_name::regclass AND attacl IS NOT NULL) THEN
                plan:=plan||jsonb_build_array(jsonb_build_object('category','acl','status','manual','reason','column ACL requires explicit review')); END IF;
        ELSIF selected='collation' THEN
            FOR item IN SELECT a.attname,a.attcollation::regcollation::text coll FROM pg_attribute a JOIN pg_type t ON t.oid=a.atttypid
                WHERE a.attrelid=p_meta.storage_name::regclass AND a.attname LIKE 'extra_%' AND a.attcollation<>t.typcollation LOOP
                n:=substr(item.attname,7)::integer;
                SELECT key INTO selected FROM (SELECT key,row_number() OVER(ORDER BY key COLLATE "C") i FROM jsonb_each(p_meta.business_columns)) x WHERE i=n;
                plan:=plan||jsonb_build_array(jsonb_build_object('category','collation','status','apply','column',selected,'collation',item.coll)); END LOOP;
        END IF;
    END LOOP;
    IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=p_meta.storage_name::regclass AND NOT tgisinternal AND tgfoid NOT IN ('splitjson._revision_write()'::regprocedure,'splitjson._storage_write_guard()'::regprocedure)) THEN
        plan:=plan||jsonb_build_array(jsonb_build_object('category','triggers','status','manual','reason','user triggers are never copied')); END IF;
    RETURN plan;
END $$;

CREATE FUNCTION splitjson.export_manifest(p_table regclass,p_subset boolean,p_copy jsonb DEFAULT '[]') RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._export_access(m,p_subset);
    PERFORM q.id FROM splitjson._query(format('SELECT id FROM %s LIMIT 0',m.storage_name),ARRAY[]::regtype[],ARRAY[]::text[],true) q(id bigint);
    RETURN jsonb_build_object('format',2,'extension','pg_splitjson','version','0.3.0','view',m.view_name,'storage',m.storage_name,
        'epoch',m.layout_epoch,'generation',m.layout_generation,'mode',m.storage_mode,'partition_spec',m.partition_spec,
        'paths',m.paths,'business_columns',m.business_columns,'storage_definition',m.storage_definition,'subset',p_subset,
        'schema_plan',splitjson._schema_plan(m,p_copy),'credentials',NULL);
END $$;
CREATE FUNCTION splitjson.export_manifest(p_table regclass) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp
RETURN splitjson._api_export_manifest(p_table,false,'[]');

CREATE FUNCTION splitjson.export_rows(p_table regclass,p_subset boolean) RETURNS SETOF jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; n integer:=0; expression text:=''; key text;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._export_access(m,p_subset);
    FOR key IN SELECT e.key FROM jsonb_each(m.business_columns) e ORDER BY e.key COLLATE "C" LOOP
        n:=n+1; expression:=expression||CASE WHEN n=1 THEN '' ELSE ',' END||format('%L,extra_%s::text',key,n); END LOOP;
    RETURN QUERY SELECT q.value FROM splitjson._query(format('SELECT jsonb_build_object(''id'',id::text,''doc'',splitjson.restore(cold,%s),''business'',jsonb_build_object(%s)) FROM %s ORDER BY id',
        splitjson._hot_array(m.paths),expression,m.storage_name),ARRAY[]::regtype[],ARRAY[]::text[],true) q(value jsonb);
END $$;
CREATE FUNCTION splitjson.export_rows(p_table regclass) RETURNS SETOF jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$ SELECT * FROM splitjson._api_export_rows(p_table,false); $$;

CREATE FUNCTION splitjson.migration_plan(p_source regclass,p_target text,p_paths jsonb,p_options jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; mode text; subset boolean;
BEGIN
    IF p_target IS NULL OR p_paths IS NULL OR p_options IS NULL OR jsonb_typeof(p_options)<>'object' OR
        EXISTS(SELECT 1 FROM jsonb_object_keys(p_options) k WHERE k NOT IN ('mode','subset','copy','ignore_manual','role_map','partition_spec')) THEN
        RAISE EXCEPTION 'invalid migration arguments/options' USING ERRCODE='22023'; END IF;
    m:=splitjson._lookup(p_source,'SELECT'); PERFORM splitjson.validate_paths(p_paths);
    mode:=coalesce(p_options->>'mode','snapshot'); subset:=coalesce((p_options->>'subset')::boolean,false);
    IF mode NOT IN ('snapshot','online') THEN RAISE EXCEPTION 'unknown migration mode' USING ERRCODE='22023'; END IF;
    PERFORM splitjson._export_access(m,subset);
    IF mode='online' AND subset THEN RAISE EXCEPTION 'online migration requires full authorization' USING ERRCODE='42501'; END IF;
    RETURN splitjson._api_export_manifest(p_source,subset,coalesce(p_options->'copy','[]'))||
        jsonb_build_object('migration_mode',mode,'target',p_target,'target_paths',p_paths,'source_unchanged',true,'snapshot_only',mode='snapshot');
END $$;

CREATE FUNCTION splitjson.import_manifest(p_manifest jsonb,p_target text,p_options jsonb DEFAULT '{}') RETURNS regclass
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE target regclass; item jsonb; policy jsonb; mapped name[]; source_role text; n integer:=0; kind text; idx text;
BEGIN
    IF p_manifest IS NULL OR p_manifest->>'format' IS DISTINCT FROM '2' OR p_manifest->>'extension' IS DISTINCT FROM 'pg_splitjson' OR p_manifest->>'version' IS DISTINCT FROM '0.3.0' OR
       jsonb_typeof(p_manifest->'business_columns')<>'object' OR jsonb_typeof(p_manifest->'paths')<>'array' OR
       jsonb_typeof(p_manifest->'schema_plan')<>'array' OR p_manifest->>'mode' NOT IN ('heap','hash','range') OR p_target IS NULL OR
       p_options IS NULL OR jsonb_typeof(p_options)<>'object' OR
       EXISTS(SELECT 1 FROM jsonb_object_keys(p_options) k WHERE k NOT IN ('ignore_manual','role_map','paths','partition_spec')) THEN
        RAISE EXCEPTION 'invalid import manifest/options' USING ERRCODE='22023'; END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_manifest->'schema_plan') e WHERE e->>'status'<>'apply') AND
       NOT coalesce((p_options->>'ignore_manual')::boolean,false) THEN
        RAISE EXCEPTION 'schema plan contains manual/rejected dependencies; review explicitly' USING ERRCODE='0A000'; END IF;
    IF p_manifest->>'mode'='heap' AND NOT p_options ? 'partition_spec' THEN
        target:=splitjson._api_create_table(p_target,coalesce(p_options->'paths',p_manifest->'paths'),p_manifest->'business_columns');
    ELSE target:=splitjson._api_create_partitioned_table(p_target,coalesce(p_options->'paths',p_manifest->'paths'),p_manifest->'business_columns',coalesce(p_options->'partition_spec',p_manifest->'partition_spec')); END IF;
    FOR item IN SELECT value FROM jsonb_array_elements(p_manifest->'schema_plan') LOOP
        IF item->>'status'<>'apply' THEN CONTINUE; END IF;
        kind:=item->>'category';
        IF kind='not_null' THEN PERFORM splitjson._api_set_business_not_null(target,item->>'column',true);
        ELSIF kind='defaults' THEN PERFORM splitjson._api_set_business_default(target,item->>'column',item->'value');
        ELSIF kind='checks' THEN PERFORM splitjson._api_add_field_check(target,item->>'name',item->'path',item->>'type',(item->>'required')::boolean);
        ELSIF kind='indexes' THEN n:=n+1; idx:='sj_import_'||target::oid||'_'||n;
            PERFORM splitjson._api_create_path_index(target,idx,item->'path',item->>'kind',(item->>'collation')::name);
        ELSIF kind='collation' THEN target:=splitjson._api_set_business_collation(target,item->>'column',(item->>'collation')::name);
        ELSIF kind='rls' THEN
            FOR policy IN SELECT value FROM jsonb_array_elements(item->'policies') LOOP
                mapped:='{}';
                FOR source_role IN SELECT jsonb_array_elements_text(policy->'roles') LOOP
                    IF lower(source_role)='public' THEN mapped:=array_append(mapped,'public');
                    ELSIF p_options->'role_map' ? source_role THEN mapped:=array_append(mapped,(p_options->'role_map'->>source_role)::name);
                    ELSE RAISE EXCEPTION 'explicit existing role mapping required' USING ERRCODE='42704'; END IF;
                END LOOP;
                PERFORM splitjson._api_set_policy(target,policy->>'policy_name',policy->>'command',mapped,policy->>'using_expression',policy->>'check_expression',(policy->>'restrictive')::boolean);
            END LOOP;
            PERFORM splitjson._api_enable_rls(target,(item->>'enabled')::boolean,(item->>'force')::boolean);
        ELSIF kind='acl' THEN
            source_role:=item->>'role';
            IF NOT p_options->'role_map' ? source_role THEN RAISE EXCEPTION 'explicit ACL role mapping required' USING ERRCODE='42704'; END IF;
            PERFORM splitjson._api_grant_access(target,(p_options->'role_map'->>source_role)::regrole,item->>'mode');
        ELSE RAISE EXCEPTION 'unsupported declarative schema item' USING ERRCODE='0A000'; END IF;
    END LOOP;
    RETURN target;
END $$;

CREATE FUNCTION splitjson.import_row(p_table regclass,p_row jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; key text; n integer:=0; columns text:='id,cold'; values_sql text; business jsonb;
BEGIN
    m:=splitjson._lookup(p_table,'INSERT');
    IF p_row IS NULL OR jsonb_typeof(p_row)<>'object' OR NOT p_row ? 'id' OR NOT p_row ? 'doc' OR jsonb_typeof(p_row->'business')<>'object' THEN
        RAISE EXCEPTION 'invalid logical row' USING ERRCODE='22023'; END IF;
    business:=p_row->'business';
    IF EXISTS(SELECT 1 FROM jsonb_object_keys(business) k WHERE NOT m.business_columns ? k) OR
       EXISTS(SELECT 1 FROM jsonb_each(business) e WHERE jsonb_typeof(e.value) NOT IN ('string','null')) THEN
        RAISE EXCEPTION 'business values must use native text or SQL null' USING ERRCODE='22023'; END IF;
    values_sql:='$1,$2';
    FOR n IN 1..jsonb_array_length(m.paths) LOOP
        columns:=columns||format(',hot_%s',n); values_sql:=values_sql||format(',($3)[%s]',n); END LOOP;
    n:=0;
    FOR key IN SELECT e.key FROM jsonb_each(m.business_columns) e ORDER BY e.key COLLATE "C" LOOP
        n:=n+1; columns:=columns||format(',extra_%s',n); values_sql:=values_sql||format(',((jsonb_populate_record(NULL::%s,$4)).%I)',m.view_name,key); END LOOP;
    PERFORM q.id FROM splitjson._query_for(p_table,format('INSERT INTO %s(%s) VALUES(%s) RETURNING id',m.storage_name,columns,values_sql),
        ARRAY['bigint','splitjson.cold','jsonb[]','jsonb']::regtype[],ARRAY[p_row->>'id',splitjson.pack(p_row->'doc',m.paths)::text,splitjson.slots(p_row->'doc',m.paths)::text,business::text],false) q(id bigint);
END $$;

CREATE FUNCTION splitjson.migrate_layout(p_source regclass,p_target text,p_paths jsonb,p_options jsonb DEFAULT '{}') RETURNS regclass
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE plan jsonb; m splitjson._tables%ROWTYPE; target regclass; row_data jsonb; names text[];
BEGIN
    names:=parse_ident(p_target,true);
    IF cardinality(names)<>2 OR names[1] IN ('splitjson','splitjson_storage') OR names[1] LIKE 'pg_%' OR
       NOT has_schema_privilege(splitjson._caller(),names[1],'CREATE') THEN
        RAISE EXCEPTION 'target business schema CREATE permission required' USING ERRCODE='42501'; END IF;
    plan:=splitjson._api_migration_plan(p_source,p_target,p_paths,p_options);
    IF plan->>'migration_mode'='online' THEN RAISE EXCEPTION 'use splitjson-migrate.py for the online snapshot/LSN handshake' USING ERRCODE='0A000'; END IF;
    m:=splitjson._lookup(p_source,'SELECT');
    EXECUTE format('LOCK TABLE %s IN ACCESS SHARE MODE',m.storage_name);
    target:=splitjson._api_import_manifest(plan,p_target,(p_options-'mode'-'subset'-'copy')||jsonb_build_object('paths',p_paths));
    FOR row_data IN SELECT * FROM splitjson._api_export_rows(p_source,coalesce((p_options->>'subset')::boolean,false)) LOOP
        PERFORM splitjson._api_import_row(target,row_data);
    END LOOP;
    PERFORM splitjson._api_check_table(target,true);
    RETURN target;
END $$;

CREATE FUNCTION splitjson.replication_manifest(p_table regclass) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$ BEGIN RETURN splitjson._api_replication_manifest(p_table,'["collation"]'::jsonb); END $$;

CREATE FUNCTION splitjson.replication_manifest(p_table regclass,p_copy jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT');
    RETURN splitjson._api_export_manifest(p_table,false,p_copy)||jsonb_build_object('publication_tables',jsonb_build_array(m.storage_name),
        'publish_via_partition_root',true,'same_layout_only',true,'apply_revision','preserve_source','server_major',18,'cold_format',1,
        'publisher_systemid',(SELECT system_identifier::text FROM pg_control_system()),'layout_fingerprint',splitjson._replication_fingerprint(m));
END $$;

CREATE FUNCTION splitjson.replication_ddl(p_table regclass,p_publication text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT');
    IF p_publication IS NULL OR p_publication='' OR octet_length(p_publication)>63 THEN RAISE EXCEPTION 'invalid publication name' USING ERRCODE='22023'; END IF;
    RETURN format('CREATE PUBLICATION %I FOR TABLE %s WITH (publish_via_partition_root=true);',p_publication,m.storage_name);
END $$;
