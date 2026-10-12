-- Private executor and entry context are never callable by applications.
CREATE OR REPLACE FUNCTION splitjson._caller() RETURNS name
AS 'MODULE_PATHNAME','pg_splitjson_caller' LANGUAGE C STABLE;
CREATE FUNCTION splitjson._ddl_scope() RETURNS boolean
AS 'MODULE_PATHNAME','pg_splitjson_ddl_scope' LANGUAGE C STABLE;
CREATE FUNCTION splitjson._query(text,regtype[],text[],boolean) RETURNS SETOF record
AS 'MODULE_PATHNAME','pg_splitjson_query' LANGUAGE C VOLATILE;
CREATE FUNCTION splitjson.policy_field(jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT SET search_path=pg_catalog,pg_temp
AS $$ BEGIN RAISE EXCEPTION 'policy_field is a compile-time marker' USING ERRCODE='0A000'; END $$;
CREATE FUNCTION splitjson._policy_compile(regclass,regclass,jsonb,text) RETURNS text
AS 'MODULE_PATHNAME','pg_splitjson_policy_compile' LANGUAGE C STRICT;
CREATE FUNCTION splitjson._index_match(regclass,regclass,text) RETURNS boolean
AS 'MODULE_PATHNAME','pg_splitjson_index_match' LANGUAGE C STRICT;
CREATE FUNCTION splitjson._management_target(regclass) RETURNS boolean
AS 'MODULE_PATHNAME','pg_splitjson_management_target' LANGUAGE C STABLE STRICT;
CREATE FUNCTION splitjson._query_for(regclass,text,regtype[],text[],boolean) RETURNS SETOF record
AS 'MODULE_PATHNAME','pg_splitjson_query_for' LANGUAGE C VOLATILE;
CREATE FUNCTION splitjson._constant_default(oid) RETURNS boolean
AS 'MODULE_PATHNAME','pg_splitjson_constant_default' LANGUAGE C STABLE STRICT;
CREATE FUNCTION splitjson._partition_bound(regclass) RETURNS jsonb
AS 'MODULE_PATHNAME','pg_splitjson_partition_bound' LANGUAGE C STABLE STRICT;
