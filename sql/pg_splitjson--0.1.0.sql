-- Copyright 2026 PG SplitJSON contributors
-- SPDX-License-Identifier: Apache-2.0

\echo Use "CREATE EXTENSION pg_splitjson" to load this file. \quit

CREATE TYPE splitjson.cold;
CREATE FUNCTION splitjson.cold_in(cstring) RETURNS splitjson.cold
AS 'MODULE_PATHNAME', 'pg_splitjson_cold_in' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson.cold_out(splitjson.cold) RETURNS cstring
AS 'MODULE_PATHNAME', 'pg_splitjson_cold_out' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE TYPE splitjson.cold (
    INPUT = splitjson.cold_in, OUTPUT = splitjson.cold_out,
    INTERNALLENGTH = variable, ALIGNMENT = double, STORAGE = external
);
CREATE FUNCTION splitjson.validate_paths(jsonb) RETURNS void
AS 'MODULE_PATHNAME', 'pg_splitjson_validate_paths' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson.pack(jsonb, jsonb) RETURNS splitjson.cold
AS 'MODULE_PATHNAME', 'pg_splitjson_pack' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson.slots(jsonb, jsonb) RETURNS jsonb[]
AS 'MODULE_PATHNAME', 'pg_splitjson_slots' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson.restore(splitjson.cold, jsonb[]) RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_splitjson_restore' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson.restore(splitjson.cold, jsonb[], jsonb) RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_splitjson_restore' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson._hot_route(jsonb, text[], jsonb[]) RETURNS integer
AS 'MODULE_PATHNAME', 'pg_splitjson_hot_route' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson._path_candidates(jsonb, text[]) RETURNS integer[]
AS 'MODULE_PATHNAME', 'pg_splitjson_path_candidates' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson.json_field(jsonb, text[]) RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog
RETURN $1 #> $2;

CREATE FUNCTION splitjson.template(splitjson.cold) RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_splitjson_template' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson.paths(splitjson.cold) RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_splitjson_paths' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson.assert_object_path(jsonb, text[]) RETURNS void
AS 'MODULE_PATHNAME', 'pg_splitjson_assert_object_path' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson.object_field(jsonb, text[]) RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_splitjson_object_field' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson.column_type(text) RETURNS text
AS 'MODULE_PATHNAME', 'pg_splitjson_column_type' LANGUAGE C STABLE STRICT PARALLEL SAFE;

CREATE SCHEMA splitjson_storage;
REVOKE ALL ON SCHEMA splitjson_storage FROM PUBLIC;
GRANT USAGE ON SCHEMA splitjson TO PUBLIC;
CREATE SEQUENCE splitjson._table_id_seq;
CREATE TABLE splitjson._tables (
    view_name text PRIMARY KEY,
    storage_name text NOT NULL UNIQUE,
    paths jsonb NOT NULL,
    business_columns jsonb NOT NULL DEFAULT '{}'
);
REVOKE ALL ON splitjson._tables, splitjson._table_id_seq FROM PUBLIC;
-- Relation names, rather than OIDs, survive pg_dump/restore.
SELECT pg_catalog.pg_extension_config_dump('splitjson._tables', '');
SELECT pg_catalog.pg_extension_config_dump('splitjson._table_id_seq', '');

CREATE FUNCTION splitjson._caller() RETURNS name
LANGUAGE sql STABLE SET search_path = pg_catalog
RETURN CASE WHEN current_setting('role') = 'none' THEN session_user::name
            ELSE current_setting('role')::name END;

CREATE FUNCTION splitjson._hot_array(p_paths jsonb) RETURNS text
LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog
RETURN (SELECT 'ARRAY[' || string_agg(format('hot_%s', n), ',') || ']::jsonb[]'
        FROM generate_series(1, jsonb_array_length(p_paths)) AS n);

CREATE FUNCTION splitjson._assignments(p_paths jsonb) RETURNS text
LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog
RETURN (SELECT string_agg(format('hot_%s=($2)[%s]', n, n), ',')
        FROM generate_series(1, jsonb_array_length(p_paths)) AS n);

CREATE FUNCTION splitjson._lookup(p_table regclass, p_privilege text)
RETURNS splitjson._tables LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE meta splitjson._tables%ROWTYPE;
BEGIN
    IF p_table IS NULL THEN RAISE EXCEPTION 'table must not be NULL' USING ERRCODE='22023'; END IF;
    SELECT * INTO meta FROM splitjson._tables WHERE to_regclass(view_name)=p_table;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'relation is not a pg_splitjson managed view' USING ERRCODE='22023';
    END IF;
    IF NOT has_column_privilege(splitjson._caller(),p_table,'doc',p_privilege) OR
       (p_privilege='SELECT' AND NOT has_column_privilege(splitjson._caller(),p_table,'id','SELECT')) THEN
        RAISE EXCEPTION 'permission denied for JSON %',lower(p_privilege) USING ERRCODE='42501';
    END IF;
    RETURN meta;
END $$;
REVOKE ALL ON FUNCTION splitjson._lookup(regclass,text) FROM PUBLIC;

CREATE FUNCTION splitjson._slot(p_paths jsonb,p_path text[]) RETURNS integer
LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog
RETURN (SELECT ord::integer FROM jsonb_array_elements(p_paths) WITH ORDINALITY AS p(path,ord)
        WHERE path=to_jsonb(p_path));

CREATE FUNCTION splitjson._save(p_storage text, p_id bigint, p_doc jsonb, p_paths jsonb)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE affected bigint;
BEGIN
    IF p_doc IS NULL THEN
        RAISE EXCEPTION 'doc must not be SQL NULL; JSON null is allowed' USING ERRCODE = '23502';
    END IF;
    EXECUTE format('UPDATE %s SET cold=$1,%s WHERE id=$3',
                   p_storage, splitjson._assignments(p_paths))
        USING splitjson.pack(p_doc, p_paths), splitjson.slots(p_doc, p_paths), p_id;
    GET DIAGNOSTICS affected = ROW_COUNT;
    RETURN affected = 1;
END $$;
REVOKE ALL ON FUNCTION splitjson._save(text,bigint,jsonb,jsonb) FROM PUBLIC;

CREATE FUNCTION splitjson._view_write() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE
    meta splitjson._tables%ROWTYPE;
    hot_columns text;
    hot_params text;
    n integer;
    current_row jsonb;
    affected bigint;
    column_name text;
    column_type text;
    extra_columns text := '';
    extra_values text := '';
    extra_assignments text := '';
BEGIN
    SELECT * INTO STRICT meta FROM splitjson._tables WHERE to_regclass(view_name) = TG_RELID;
    n := 0;
    FOR column_name,column_type IN SELECT key,value FROM jsonb_each_text(meta.business_columns) ORDER BY key COLLATE "C" LOOP
        n := n+1;
        extra_columns := extra_columns || format(',extra_%s',n);
        extra_values := extra_values || format(',($4::%s).%I',meta.view_name,column_name);
        extra_assignments := extra_assignments || format(',extra_%s=($5::%s).%I',n,meta.view_name,column_name);
    END LOOP;
    IF TG_OP <> 'INSERT' THEN
        EXECUTE format('SELECT to_jsonb(ROW(id,splitjson.restore(cold,%s)%s)::%s) FROM %s WHERE id=$1 FOR UPDATE',
                       splitjson._hot_array(meta.paths),extra_columns,meta.view_name,meta.storage_name)
            INTO current_row USING OLD.id;
        GET DIAGNOSTICS affected = ROW_COUNT;
        IF affected = 0 THEN RETURN NULL; END IF;
        -- An INSTEAD OF trigger cannot re-evaluate the original UPDATE/DELETE
        -- expression like the heap executor's EvalPlanQual. Require a retry.
        IF current_row IS DISTINCT FROM to_jsonb(OLD) THEN
            RAISE EXCEPTION 'concurrent row modification; retry the statement or transaction'
                USING ERRCODE = '40001';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        EXECUTE format('DELETE FROM %s WHERE id=$1', meta.storage_name) USING OLD.id;
        RETURN OLD;
    END IF;
    IF NEW.id IS NULL OR NEW.doc IS NULL THEN
        RAISE EXCEPTION 'id and doc must not be SQL NULL' USING ERRCODE = '23502';
    END IF;
    IF TG_OP = 'INSERT' THEN
        FOR n IN 1..jsonb_array_length(meta.paths) LOOP
            hot_columns := concat_ws(',', hot_columns, format('hot_%s', n));
            hot_params := concat_ws(',', hot_params, format('($3)[%s]', n));
        END LOOP;
        EXECUTE format('INSERT INTO %s (id,cold,%s%s) VALUES ($1,$2,%s%s)',
                       meta.storage_name,hot_columns,extra_columns,hot_params,extra_values)
            USING NEW.id,splitjson.pack(NEW.doc,meta.paths),splitjson.slots(NEW.doc,meta.paths),NEW;
    ELSE
        IF NEW.doc IS NOT DISTINCT FROM OLD.doc THEN
            EXECUTE format('UPDATE %s SET id=$4%s WHERE id=$3',meta.storage_name,extra_assignments)
                USING NULL::splitjson.cold,NULL::jsonb[],OLD.id,NEW.id,NEW;
        ELSE
            EXECUTE format('UPDATE %s SET id=$4,cold=$1,%s%s WHERE id=$3',
                           meta.storage_name,splitjson._assignments(meta.paths),extra_assignments)
                USING splitjson.pack(NEW.doc,meta.paths),splitjson.slots(NEW.doc,meta.paths),OLD.id,NEW.id,NEW;
        END IF;
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION splitjson._view_write() FROM PUBLIC;

CREATE FUNCTION splitjson.create_table(p_name text, p_paths jsonb, p_columns jsonb DEFAULT '{}') RETURNS regclass
LANGUAGE plpgsql SET search_path = pg_catalog
AS $$
DECLARE
    parts text[];
    logical_name text;
    storage_name text;
    columns text := '';
    n integer;
    column_name text;
    declared_type jsonb;
    normalized_type text;
    normalized_columns jsonb := '{}';
    extra_select text := '';
BEGIN
    IF p_name IS NULL OR p_paths IS NULL OR p_columns IS NULL THEN
        RAISE EXCEPTION 'table name and paths must not be NULL' USING ERRCODE = '22023';
    END IF;
    PERFORM splitjson.validate_paths(p_paths);
    IF jsonb_array_length(p_paths) = 0 THEN
        RAISE EXCEPTION 'declare at least one hot path' USING ERRCODE = '22023';
    END IF;
    parts := parse_ident(p_name, true);
    IF cardinality(parts) <> 2 THEN
        RAISE EXCEPTION 'use a schema-qualified name, for example public.docs' USING ERRCODE = '22023';
    END IF;
    -- Avoid PostgreSQL identifier truncation creating ambiguous metadata names.
    IF octet_length(parts[1]) > 63 OR octet_length(parts[2]) > 63 THEN
        RAISE EXCEPTION 'schema and relation names must fit PostgreSQL identifiers' USING ERRCODE = '22023';
    END IF;
    logical_name := format('%I.%I', parts[1], parts[2]);
    IF jsonb_typeof(p_columns)<>'object' OR (SELECT count(*) FROM jsonb_object_keys(p_columns))>64 THEN
        RAISE EXCEPTION 'business columns must be an object with at most 64 entries' USING ERRCODE='22023';
    END IF;
    n := 0;
    FOR column_name,declared_type IN SELECT key,value FROM jsonb_each(p_columns) ORDER BY key COLLATE "C" LOOP
        IF column_name IN ('id','doc') OR column_name='' OR octet_length(column_name)>63 OR jsonb_typeof(declared_type)<>'string' THEN
            RAISE EXCEPTION 'invalid business column name or type declaration' USING ERRCODE='22023';
        END IF;
        normalized_type := splitjson.column_type(declared_type #>> '{}');
        normalized_columns := normalized_columns || jsonb_build_object(column_name,normalized_type);
        n := n+1;
        columns := columns || format(',extra_%s %s',n,normalized_type);
        extra_select := extra_select || format(',extra_%s AS %I',n,column_name);
    END LOOP;
    storage_name := format('splitjson_storage.s_%s', nextval('splitjson._table_id_seq'));
    FOR n IN 1..jsonb_array_length(p_paths) LOOP
        columns := columns || format(',hot_%s jsonb', n);
    END LOOP;
    EXECUTE format('CREATE TABLE %s (id bigint PRIMARY KEY,cold splitjson.cold NOT NULL%s) WITH (fillfactor=70)',
                   storage_name, columns);
    EXECUTE format('ALTER TABLE %s ALTER COLUMN cold SET STORAGE EXTERNAL', storage_name);
    EXECUTE format('CREATE VIEW %s WITH (security_barrier=true) AS '
                   'SELECT id,splitjson.restore(cold,%s,%L::jsonb) AS doc%s FROM %s',
                   logical_name,splitjson._hot_array(p_paths),p_paths::text,extra_select,storage_name);
    INSERT INTO splitjson._tables VALUES (logical_name,storage_name,p_paths,normalized_columns);
    EXECUTE format('CREATE TRIGGER pg_splitjson_write INSTEAD OF INSERT OR UPDATE OR DELETE ON %s '
                   'FOR EACH ROW EXECUTE FUNCTION splitjson._view_write()', logical_name);
    RETURN logical_name::regclass;
END $$;

-- Fast path: the SELECT and UPDATE below mention only id and hot_N, never cold.
CREATE FUNCTION splitjson.set_field(p_table regclass,p_id bigint,p_path text[],p_value jsonb,
                                      p_create_missing boolean DEFAULT true)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog
AS $$
BEGIN
    IF p_table IS NULL OR p_id IS NULL OR p_path IS NULL OR p_value IS NULL OR p_create_missing IS NULL THEN
        RAISE EXCEPTION 'arguments must not be NULL; use JSON null' USING ERRCODE='22023';
    END IF;
    PERFORM splitjson.assert_object_path('{}',p_path);
    p_path := ARRAY(SELECT unnest(p_path));
    RETURN splitjson.set_fields(p_table,p_id,jsonb_build_array(jsonb_build_object('path',to_jsonb(p_path),'value',p_value)),p_create_missing);
END $$;

CREATE FUNCTION splitjson.delete_field(p_table regclass,p_id bigint,p_path text[])
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog
AS $$
DECLARE meta splitjson._tables%ROWTYPE; hot jsonb[]; slot integer; relative text[]; doc jsonb; affected bigint;
BEGIN
    IF p_id IS NULL OR p_path IS NULL THEN RAISE EXCEPTION 'arguments must not be NULL' USING ERRCODE='22023'; END IF;
    PERFORM splitjson.assert_object_path('{}',p_path);
    p_path := ARRAY(SELECT unnest(p_path));
    meta := splitjson._lookup(p_table,'UPDATE');
    EXECUTE format('SELECT %s FROM %s WHERE id=$1 FOR UPDATE',splitjson._hot_array(meta.paths),meta.storage_name)
        INTO hot USING p_id;
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected=0 THEN RETURN false; END IF;
    slot := splitjson._hot_route(meta.paths,p_path,hot);
    IF slot IS NOT NULL AND jsonb_array_length(meta.paths->(slot-1))<cardinality(p_path) THEN
        relative := p_path[jsonb_array_length(meta.paths->(slot-1))+1:cardinality(p_path)];
        EXECUTE format('UPDATE %s SET hot_%s=$1 WHERE id=$2',meta.storage_name,slot) USING hot[slot] #- relative,p_id;
        RETURN true;
    END IF;
    EXECUTE format('SELECT splitjson.restore(cold,%s) FROM %s WHERE id=$1',splitjson._hot_array(meta.paths),meta.storage_name)
        INTO doc USING p_id;
    RETURN splitjson._save(meta.storage_name,p_id,doc #- p_path,meta.paths);
END $$;

CREATE FUNCTION splitjson.drop_table(p_table regclass) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE meta splitjson._tables%ROWTYPE; owner_oid oid; caller_oid oid;
BEGIN
    IF p_table IS NULL THEN RAISE EXCEPTION 'table must not be NULL' USING ERRCODE = '22023'; END IF;
    SELECT * INTO meta FROM splitjson._tables WHERE to_regclass(view_name) = p_table;
    IF NOT FOUND THEN RAISE EXCEPTION 'relation is not a pg_splitjson managed view' USING ERRCODE = '22023'; END IF;
    SELECT relowner INTO owner_oid FROM pg_class WHERE oid = p_table;
    SELECT oid INTO caller_oid FROM pg_roles WHERE rolname = splitjson._caller();
    IF NOT pg_has_role(caller_oid, owner_oid, 'USAGE') THEN
        RAISE EXCEPTION 'must own the managed view to drop it' USING ERRCODE = '42501';
    END IF;
    -- No CASCADE: dependencies must be handled explicitly by the owner.
    EXECUTE format('DROP VIEW %s', meta.view_name);
    EXECUTE format('DROP TABLE %s', meta.storage_name);
    DELETE FROM splitjson._tables WHERE view_name = meta.view_name;
END $$;

CREATE FUNCTION splitjson.set_fields(p_table regclass,p_id bigint,p_updates jsonb,
                                     p_create_missing boolean DEFAULT true)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog
AS $$
DECLARE
    meta splitjson._tables%ROWTYPE;
    operation jsonb;
    path text[];
    relative text[];
    hot jsonb[];
    touched integer[] := '{}';
    slot integer;
    depth integer;
    all_hot boolean := true;
    affected bigint;
    assignments text;
    doc jsonb;
BEGIN
    IF p_id IS NULL OR p_updates IS NULL OR p_create_missing IS NULL OR jsonb_typeof(p_updates)<>'array' THEN
        RAISE EXCEPTION 'updates must be an array; arguments must not be NULL' USING ERRCODE='22023';
    END IF;
    IF jsonb_array_length(p_updates) NOT BETWEEN 1 AND 64 THEN
        RAISE EXCEPTION 'a batch must contain between 1 and 64 operations' USING ERRCODE='22023';
    END IF;
    FOR operation IN SELECT value FROM jsonb_array_elements(p_updates) LOOP
        IF jsonb_typeof(operation)<>'object' THEN
            RAISE EXCEPTION 'each operation must contain exactly path and value' USING ERRCODE='22023';
        END IF;
        IF (SELECT count(*) FROM jsonb_object_keys(operation))<>2 OR NOT operation ? 'path' OR NOT operation ? 'value' THEN
            RAISE EXCEPTION 'each operation must contain exactly path and value' USING ERRCODE='22023';
        END IF;
        IF jsonb_typeof(operation->'path')<>'array' OR
           EXISTS(SELECT 1 FROM jsonb_array_elements(operation->'path') e WHERE jsonb_typeof(e)<>'string') THEN
            RAISE EXCEPTION 'operation path must be an array of string segments' USING ERRCODE='22023';
        END IF;
        path := ARRAY(SELECT jsonb_array_elements_text(operation->'path'));
        PERFORM splitjson.assert_object_path('{}',path);
    END LOOP;
    meta := splitjson._lookup(p_table,'UPDATE');
    EXECUTE format('SELECT %s FROM %s WHERE id=$1 FOR UPDATE',splitjson._hot_array(meta.paths),meta.storage_name)
        INTO hot USING p_id;
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected=0 THEN RETURN false; END IF;
    FOR operation IN SELECT value FROM jsonb_array_elements(p_updates) LOOP
        path := ARRAY(SELECT jsonb_array_elements_text(operation->'path'));
        slot := splitjson._hot_route(meta.paths,path,hot);
        IF slot IS NULL THEN all_hot := false; EXIT; END IF;
        depth := jsonb_array_length(meta.paths->(slot-1));
        relative := path[depth+1:cardinality(path)];
        IF cardinality(relative)=0 THEN hot[slot] := operation->'value';
        ELSE hot[slot] := jsonb_set(hot[slot],relative,operation->'value',p_create_missing); END IF;
        touched := array_append(touched,slot);
    END LOOP;
    IF all_hot THEN
        SELECT string_agg(format('hot_%s=($1)[%s]',n,n),',' ORDER BY n) INTO assignments
            FROM (SELECT DISTINCT unnest(touched) AS n) t;
        EXECUTE format('UPDATE %s SET %s WHERE id=$2',meta.storage_name,assignments) USING hot,p_id;
        RETURN true;
    END IF;
    EXECUTE format('SELECT splitjson.restore(cold,%s) FROM %s WHERE id=$1',splitjson._hot_array(meta.paths),meta.storage_name)
        INTO doc USING p_id;
    FOR operation IN SELECT value FROM jsonb_array_elements(p_updates) LOOP
        path := ARRAY(SELECT jsonb_array_elements_text(operation->'path'));
        doc := jsonb_set(doc,path,operation->'value',p_create_missing);
    END LOOP;
    RETURN splitjson._save(meta.storage_name,p_id,doc,meta.paths);
END $$;

CREATE FUNCTION splitjson.increment_field(p_table regclass,p_id bigint,p_path text[],p_delta numeric DEFAULT 1)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog
AS $$
DECLARE meta splitjson._tables%ROWTYPE; hot jsonb[]; slot integer; relative text[]; value jsonb; doc jsonb; result numeric; affected bigint;
BEGIN
    IF p_id IS NULL OR p_path IS NULL OR p_delta IS NULL OR p_delta::text IN ('NaN','Infinity','-Infinity') THEN
        RAISE EXCEPTION 'arguments must not be NULL and delta must be finite' USING ERRCODE='22023';
    END IF;
    PERFORM splitjson.assert_object_path('{}',p_path);
    p_path := ARRAY(SELECT unnest(p_path));
    meta := splitjson._lookup(p_table,'UPDATE');
    EXECUTE format('SELECT %s FROM %s WHERE id=$1 FOR UPDATE',splitjson._hot_array(meta.paths),meta.storage_name)
        INTO hot USING p_id;
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected=0 THEN RETURN NULL; END IF;
    slot := splitjson._hot_route(meta.paths,p_path,hot);
    IF slot IS NOT NULL THEN
        relative := p_path[jsonb_array_length(meta.paths->(slot-1))+1:cardinality(p_path)];
        value := hot[slot] #> relative;
    ELSE
        EXECUTE format('SELECT splitjson.restore(cold,%s) FROM %s WHERE id=$1',splitjson._hot_array(meta.paths),meta.storage_name)
            INTO doc USING p_id;
        value := doc #> p_path;
    END IF;
    IF value IS NULL OR jsonb_typeof(value)<>'number' THEN
        RAISE EXCEPTION 'increment target must be an existing JSON number' USING ERRCODE='22023';
    END IF;
    result := value::text::numeric+p_delta;
    IF slot IS NOT NULL THEN
        IF cardinality(relative)=0 THEN value := to_jsonb(result);
        ELSE value := jsonb_set(hot[slot],relative,to_jsonb(result),false); END IF;
        EXECUTE format('UPDATE %s SET hot_%s=$1 WHERE id=$2',meta.storage_name,slot) USING value,p_id;
    ELSE
        PERFORM splitjson._save(meta.storage_name,p_id,jsonb_set(doc,p_path,to_jsonb(result),false),meta.paths);
    END IF;
    RETURN result;
END $$;

CREATE FUNCTION splitjson.migrate_table(p_source regclass,p_target text,p_paths jsonb,
                                           p_doc_column name DEFAULT 'doc',p_id_column name DEFAULT 'id')
RETURNS regclass LANGUAGE plpgsql SET search_path=pg_catalog
AS $$
DECLARE
    columns jsonb;
    target regclass;
    names text := '';
    column_name text;
    declaration text;
BEGIN
    IF p_source IS NULL OR p_doc_column IS NULL OR p_id_column IS NULL OR p_doc_column=p_id_column OR
       NOT EXISTS(SELECT 1 FROM pg_class WHERE oid=p_source AND relkind='r') THEN
        RAISE EXCEPTION 'source must be an ordinary table with distinct id/doc columns' USING ERRCODE='22023';
    END IF;
    -- Hold source DDL stable for the complete snapshot copy.
    EXECUTE format('LOCK TABLE %s IN ACCESS SHARE MODE',p_source);
    IF NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=p_source AND attname=p_id_column
                  AND NOT attisdropped AND atttypid='int8'::regtype) OR
       NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=p_source AND attname=p_doc_column
                  AND NOT attisdropped AND atttypid='jsonb'::regtype) THEN
        RAISE EXCEPTION 'source id must be bigint and document must be jsonb' USING ERRCODE='22023';
    END IF;
    SELECT coalesce(jsonb_object_agg(attname,format_type(atttypid,atttypmod)),'{}') INTO columns
        FROM pg_attribute WHERE attrelid=p_source AND attnum>0 AND NOT attisdropped
        AND attname NOT IN (p_id_column,p_doc_column);
    FOR column_name,declaration IN SELECT key,value FROM jsonb_each_text(columns) ORDER BY key COLLATE "C" LOOP
        names := names || format(',%I',column_name);
    END LOOP;
    target := splitjson.create_table(p_target,p_paths,columns);
    EXECUTE format('INSERT INTO %s (id,doc%s) SELECT %I,%I%s FROM %s',
                   target,names,p_id_column,p_doc_column,names,p_source);
    RETURN target;
END $$;

CREATE FUNCTION splitjson.get_field(p_table regclass,p_id bigint,p_path text[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog
AS $$
DECLARE meta splitjson._tables%ROWTYPE; hot jsonb[]; slot integer; value jsonb; affected bigint;
BEGIN
    IF p_id IS NULL OR p_path IS NULL THEN RAISE EXCEPTION 'arguments must not be NULL' USING ERRCODE='22023'; END IF;
    PERFORM splitjson.assert_object_path('{}',p_path);
    p_path := ARRAY(SELECT unnest(p_path));
    meta := splitjson._lookup(p_table,'SELECT');
    EXECUTE format('SELECT %s FROM %s WHERE id=$1',splitjson._hot_array(meta.paths),meta.storage_name) INTO hot USING p_id;
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected=0 THEN RETURN NULL; END IF;
    slot := splitjson._hot_route(meta.paths,p_path,hot);
    IF slot IS NOT NULL THEN
        RETURN hot[slot] #> p_path[jsonb_array_length(meta.paths->(slot-1))+1:cardinality(p_path)];
    END IF;
    EXECUTE format('SELECT splitjson.restore(cold,%s) #> $2 FROM %s WHERE id=$1',splitjson._hot_array(meta.paths),meta.storage_name)
        INTO value USING p_id,p_path;
    RETURN value;
END $$;

CREATE FUNCTION splitjson._find_query(p_meta splitjson._tables,p_path text[]) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog
AS $$
DECLARE candidates integer[]; condition text; missing text;
BEGIN
    candidates := splitjson._path_candidates(p_meta.paths,p_path);
    IF cardinality(candidates)>0 THEN
        SELECT string_agg(format('hot_%s=$1',n),' OR ') INTO condition FROM unnest(candidates) n;
        -- Native text paths may address shapes not covered by declared typed slots.
        IF EXISTS(SELECT 1 FROM unnest(p_path) key WHERE key ~ '^[[:space:]]*[+-]?[0-9]+$') THEN
            SELECT string_agg(format('hot_%s IS NULL',n),' AND ') INTO missing FROM unnest(candidates) n;
            condition := condition || format(' OR (%s AND splitjson.restore(cold,%s) #> $2=$1)',
                                               missing,splitjson._hot_array(p_meta.paths));
        END IF;
        RETURN format('SELECT id FROM %s WHERE %s',p_meta.storage_name,condition);
    END IF;
    RETURN format('SELECT id FROM %s WHERE splitjson.restore(cold,%s) #> $2=$1',p_meta.storage_name,splitjson._hot_array(p_meta.paths));
END $$;
REVOKE ALL ON FUNCTION splitjson._find_query(splitjson._tables,text[]) FROM PUBLIC;

CREATE FUNCTION splitjson.find_ids(p_table regclass,p_path text[],p_value jsonb) RETURNS SETOF bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog
AS $$
DECLARE meta splitjson._tables%ROWTYPE;
BEGIN
    IF p_path IS NULL OR p_value IS NULL THEN RAISE EXCEPTION 'arguments must not be NULL' USING ERRCODE='22023'; END IF;
    meta := splitjson._lookup(p_table,'SELECT');
    RETURN QUERY EXECUTE splitjson._find_query(meta,p_path) USING p_value,p_path;
END $$;

-- Installer-only: the same SQL used by find_ids, planned by PostgreSQL.
CREATE FUNCTION splitjson.explain_find_ids(p_table regclass,p_path text[],p_value jsonb) RETURNS SETOF text
LANGUAGE plpgsql SET search_path=pg_catalog
AS $$
DECLARE meta splitjson._tables%ROWTYPE;
BEGIN
    IF p_path IS NULL OR p_value IS NULL THEN RAISE EXCEPTION 'arguments must not be NULL' USING ERRCODE='22023'; END IF;
    meta := splitjson._lookup(p_table,'SELECT');
    RETURN QUERY EXECUTE 'EXPLAIN (COSTS OFF) ' || splitjson._find_query(meta,p_path) USING p_value,p_path;
END $$;

CREATE FUNCTION splitjson._create_index(p_table regclass,p_name text,p_slot integer,p_kind text) RETURNS regclass
LANGUAGE plpgsql SET search_path=pg_catalog
AS $$
DECLARE meta splitjson._tables%ROWTYPE; parts text[]; qualified_name text; expression text;
BEGIN
    meta := splitjson._lookup(p_table,'SELECT');
    IF p_name IS NULL OR p_slot IS NULL OR p_slot NOT BETWEEN 1 AND jsonb_array_length(meta.paths) OR
       p_kind IS NULL OR p_kind NOT IN ('jsonb','text') THEN
        RAISE EXCEPTION 'invalid index name, slot or kind (jsonb/text)' USING ERRCODE='22023';
    END IF;
    parts := parse_ident(p_name,true);
    IF cardinality(parts)<>1 OR octet_length(parts[1])>63 THEN
        RAISE EXCEPTION 'use a single PostgreSQL index identifier' USING ERRCODE='22023';
    END IF;
    SELECT format('%I.%I',n.nspname,parts[1]) INTO qualified_name
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=meta.storage_name::regclass;
    expression := format('hot_%s',p_slot);
    IF p_kind='text' THEN expression := format('(%s #>> %L::text[])',expression,'{}'); END IF;
    EXECUTE format('CREATE INDEX %I ON %s USING btree (%s)',parts[1],meta.storage_name,expression);
    RETURN qualified_name::regclass;
END $$;
REVOKE ALL ON FUNCTION splitjson._create_index(regclass,text,integer,text) FROM PUBLIC;

CREATE FUNCTION splitjson.create_path_index(p_table regclass,p_name text,p_path text[],p_kind text) RETURNS regclass
LANGUAGE plpgsql SET search_path=pg_catalog
AS $$
DECLARE meta splitjson._tables%ROWTYPE; candidates integer[];
BEGIN
    meta := splitjson._lookup(p_table,'SELECT');
    IF p_path IS NULL THEN RAISE EXCEPTION 'path must not be NULL' USING ERRCODE='22023'; END IF;
    candidates := splitjson._path_candidates(meta.paths,p_path);
    IF cardinality(candidates)<>1 THEN
        RAISE EXCEPTION 'path must identify one registered slot; use a typed jsonb path for ambiguity' USING ERRCODE='22023';
    END IF;
    RETURN splitjson._create_index(p_table,p_name,candidates[1],p_kind);
END $$;

CREATE FUNCTION splitjson.create_path_index(p_table regclass,p_name text,p_path text[]) RETURNS regclass
LANGUAGE sql SET search_path=pg_catalog
RETURN splitjson.create_path_index(p_table,p_name,p_path,'jsonb');

CREATE FUNCTION splitjson.create_path_index(p_table regclass,p_name text,p_path jsonb,p_kind text DEFAULT 'jsonb') RETURNS regclass
LANGUAGE plpgsql SET search_path=pg_catalog
AS $$
DECLARE meta splitjson._tables%ROWTYPE; slot integer;
BEGIN
    meta := splitjson._lookup(p_table,'SELECT');
    IF p_path IS NULL THEN RAISE EXCEPTION 'path must not be NULL' USING ERRCODE='22023'; END IF;
    PERFORM splitjson.validate_paths(jsonb_build_array(p_path));
    SELECT ord::integer INTO slot FROM jsonb_array_elements(meta.paths) WITH ORDINALITY p(path,ord) WHERE path=p_path;
    IF slot IS NULL THEN RAISE EXCEPTION 'path must be registered' USING ERRCODE='22023'; END IF;
    RETURN splitjson._create_index(p_table,p_name,slot,p_kind);
END $$;

COMMENT ON EXTENSION pg_splitjson IS 'PostgreSQL Split JSON Storage Extension';
COMMENT ON FUNCTION splitjson.create_table(text,jsonb,jsonb) IS 'Installer-only DDL: create id/doc/business-column view with hidden hot columns';
COMMENT ON FUNCTION splitjson.set_fields(regclass,bigint,jsonb,boolean) IS 'Ordered atomic batch; existing exact hot paths write one row and preserve cold';
COMMENT ON FUNCTION splitjson.increment_field(regclass,bigint,text[],numeric) IS 'Atomic finite numeric increment; returns new value or NULL for a missing row';
COMMENT ON FUNCTION splitjson.migrate_table(regclass,text,jsonb,name,name) IS 'Copy source data and column types into a new managed view; source remains unchanged';
COMMENT ON FUNCTION splitjson.set_field(regclass,bigint,text[],jsonb,boolean) IS 'Update a field; existing exact hot paths preserve the cold datum';
COMMENT ON TYPE splitjson.cold IS 'Internal version 2 envelope (reads v1): paths and JSONB template; not a complete logical document';
