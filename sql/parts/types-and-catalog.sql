-- Copyright 2026 PG SplitJSON contributors
-- SPDX-License-Identifier: Apache-2.0

\echo Use "CREATE EXTENSION pg_splitjson" to load this file. \quit

CREATE TYPE splitjson.cold;
CREATE OR REPLACE FUNCTION splitjson.cold_in(cstring) RETURNS splitjson.cold
AS 'MODULE_PATHNAME', 'pg_splitjson_cold_in' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson.cold_out(splitjson.cold) RETURNS cstring
AS 'MODULE_PATHNAME', 'pg_splitjson_cold_out' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE TYPE splitjson.cold (
    INPUT = splitjson.cold_in, OUTPUT = splitjson.cold_out,
    INTERNALLENGTH = variable, ALIGNMENT = double, STORAGE = external
);
CREATE OR REPLACE FUNCTION splitjson.validate_paths(jsonb) RETURNS void
AS 'MODULE_PATHNAME', 'pg_splitjson_validate_paths' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson.pack(jsonb, jsonb) RETURNS splitjson.cold
AS 'MODULE_PATHNAME', 'pg_splitjson_pack' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson.slots(jsonb, jsonb) RETURNS jsonb[]
AS 'MODULE_PATHNAME', 'pg_splitjson_slots' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson.restore(splitjson.cold, jsonb[]) RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_splitjson_restore' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson.restore(splitjson.cold, jsonb[], jsonb) RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_splitjson_restore' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson._hot_route(jsonb, text[], jsonb[]) RETURNS integer
AS 'MODULE_PATHNAME', 'pg_splitjson_hot_route' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson._path_candidates(jsonb, text[]) RETURNS integer[]
AS 'MODULE_PATHNAME', 'pg_splitjson_path_candidates' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson.json_field(jsonb, text[]) RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog, pg_temp
RETURN $1 #> $2;

CREATE OR REPLACE FUNCTION splitjson.template(splitjson.cold) RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_splitjson_template' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson.paths(splitjson.cold) RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_splitjson_paths' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson.assert_object_path(jsonb, text[]) RETURNS void
AS 'MODULE_PATHNAME', 'pg_splitjson_assert_object_path' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson.object_field(jsonb, text[]) RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_splitjson_object_field' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OR REPLACE FUNCTION splitjson.column_type(text) RETURNS text
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

