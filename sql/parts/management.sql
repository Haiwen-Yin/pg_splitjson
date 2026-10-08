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
                'collation',attcollation::regcollation::text,'generated',attgenerated,'identity',attidentity)
                ORDER BY attnum)
        FROM pg_attribute WHERE attrelid=p_table AND attnum>0 AND NOT attisdropped);

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

CREATE OR REPLACE FUNCTION splitjson._validate_mapping(p_meta splitjson._tables) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog, pg_temp
AS $$
DECLARE v oid; s oid; installer oid; hot_count integer; expected_count integer;
BEGIN
    v := to_regclass(p_meta.view_name); s := to_regclass(p_meta.storage_name);
    SELECT extowner INTO installer FROM pg_extension WHERE extname='pg_splitjson';
    IF v IS NULL OR s IS NULL OR
       NOT EXISTS(SELECT 1 FROM pg_class WHERE oid=v AND relkind='v' AND relowner=installer
                  AND reloptions @> ARRAY['security_barrier=true'] AND
                  NOT coalesce(reloptions @> ARRAY['security_invoker=true'],false)) OR
       NOT EXISTS(SELECT 1 FROM pg_class WHERE oid=s AND relkind='r' AND relowner=installer
                  AND relpersistence='p' AND NOT relrowsecurity AND NOT relforcerowsecurity
                  AND relnamespace=to_regnamespace('splitjson_storage')) THEN
        RAISE EXCEPTION 'invalid managed relation, ownership or unsupported RLS/storage layout: %',p_meta.view_name
            USING ERRCODE='55000';
    END IF;
    PERFORM splitjson.validate_paths(p_meta.paths);
    hot_count := jsonb_array_length(p_meta.paths);
    expected_count := 2+hot_count+(SELECT count(*) FROM jsonb_object_keys(p_meta.business_columns));
    IF hot_count=0 OR jsonb_array_length(p_meta.storage_definition) IS DISTINCT FROM expected_count OR
       splitjson._storage_definition(s) IS DISTINCT FROM p_meta.storage_definition OR
       splitjson._view_definition(v) IS DISTINCT FROM p_meta.view_definition OR
       NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=s AND attnum=1 AND attname='id'
                  AND atttypid='int8'::regtype AND attnotnull) OR
       NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=s AND attnum=2 AND attname='cold'
                  AND atttypid='splitjson.cold'::regtype AND attnotnull AND attstorage='e') OR
       NOT EXISTS(SELECT 1 FROM pg_index WHERE indrelid=s AND indisprimary AND indisvalid
                  AND indnkeyatts=1 AND indkey[0]=1) OR
       NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=v AND tgname='pg_splitjson_write'
                  AND tgfoid='splitjson._view_write()'::regprocedure AND tgenabled='O' AND tgtype=93) OR
       EXISTS(SELECT 1 FROM generate_series(1,hot_count) i WHERE
                  NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=s AND attname='hot_'||i
                             AND atttypid='jsonb'::regtype AND NOT attisdropped)) THEN
        RAISE EXCEPTION 'managed mapping has drifted: %; restore its layout before use',p_meta.view_name
            USING ERRCODE='55000';
    END IF;
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
        WHERE indrelid=meta.storage_name::regclass AND (NOT indisvalid OR NOT indisready);
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
    meta := splitjson._lookup(p_table,'SELECT');
    -- Use the same C ordering as create_table, not jsonb key-length ordering.
    SELECT n INTO slot FROM (SELECT key,row_number() OVER (ORDER BY key COLLATE "C")::integer n
                            FROM jsonb_each_text(meta.business_columns)) c WHERE key=p_column;
    IF slot IS NULL OR p_enabled IS NULL THEN RAISE EXCEPTION 'unknown business column or NULL flag' USING ERRCODE='22023'; END IF;
    EXECUTE format('ALTER TABLE %s ALTER COLUMN extra_%s %s NOT NULL',
                   meta.storage_name,slot,CASE WHEN p_enabled THEN 'SET' ELSE 'DROP' END);
END $$;

CREATE OR REPLACE FUNCTION splitjson.set_business_default(p_table regclass,p_column text,p_value jsonb)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE; slot integer; declaration text; literal text;
BEGIN
    meta := splitjson._lookup(p_table,'SELECT');
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
END $$;

CREATE OR REPLACE FUNCTION splitjson.add_field_check(p_table regclass,p_name text,p_path jsonb,
                                                    p_type text,p_required boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE; slot integer; condition text; parts text[];
BEGIN
    meta := splitjson._lookup(p_table,'SELECT');
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
    IF to_regclass('splitjson._tables') IS NULL THEN RETURN; END IF;
    FOR meta IN SELECT * FROM splitjson._tables LOOP PERFORM splitjson._validate_mapping(meta); END LOOP;
END $$;

CREATE OR REPLACE FUNCTION splitjson._sql_drop_guard() RETURNS event_trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog, pg_temp
AS $$
BEGIN
    IF to_regclass('splitjson._tables') IS NULL THEN RETURN; END IF;
    IF EXISTS(SELECT 1 FROM pg_event_trigger_dropped_objects() d JOIN splitjson._tables m
        ON format('%I.%I',d.schema_name,d.object_name) IN (m.view_name,m.storage_name)
        WHERE d.object_type IN ('table','view')) THEN
        RAISE EXCEPTION 'use splitjson.drop_table to remove managed relations' USING ERRCODE='55000';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION splitjson._ddl_start_guard() RETURNS event_trigger
AS 'MODULE_PATHNAME','pg_splitjson_ddl_start_guard' LANGUAGE C SECURITY DEFINER SET search_path=pg_catalog, pg_temp;
