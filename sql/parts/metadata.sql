
ALTER TABLE splitjson._tables ADD COLUMN view_definition text;
ALTER TABLE splitjson._tables ADD COLUMN storage_definition jsonb;

CREATE FUNCTION splitjson.cold_send(splitjson.cold) RETURNS bytea
AS 'MODULE_PATHNAME','pg_splitjson_cold_send' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION splitjson.cold_recv(internal) RETURNS splitjson.cold
AS 'MODULE_PATHNAME','pg_splitjson_cold_recv' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
ALTER TYPE splitjson.cold SET (SEND=splitjson.cold_send,RECEIVE=splitjson.cold_recv);
