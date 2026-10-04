\set ON_ERROR_STOP on
-- A preloaded hook must not claim similarly named objects without the extension.
CREATE SCHEMA splitjson;
CREATE SCHEMA splitjson_storage;
CREATE DOMAIN splitjson.cold AS jsonb;
CREATE FUNCTION splitjson.restore(splitjson.cold,jsonb[],jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT RETURN '{"state":"fromfunc"}'::jsonb;
CREATE TABLE splitjson_storage.fake (id bigint,cold splitjson.cold,hot_1 jsonb);
INSERT INTO splitjson_storage.fake VALUES (1,'{}','"fromhot"');
CREATE VIEW public.fake_view WITH (security_barrier=true) AS
SELECT id,splitjson.restore(cold,ARRAY[hot_1],'[["state"]]'::jsonb) AS doc FROM splitjson_storage.fake;
DO $$ BEGIN
    IF (SELECT doc->>'state' FROM fake_view) IS DISTINCT FROM 'fromfunc' THEN
        RAISE EXCEPTION 'planner rewrote a view without pg_splitjson installed';
    END IF;
END $$;
DROP VIEW fake_view;
DROP SCHEMA splitjson_storage CASCADE;
DROP SCHEMA splitjson CASCADE;
SELECT 'preloaded planner without extension tests passed' AS result;
