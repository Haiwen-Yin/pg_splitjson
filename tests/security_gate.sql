-- PG18.6 identity/ACL separation gate. Only the isolated lab installs this
-- diagnostic function. Runtime 0.2.0 management rejects RLS, so its guards are
-- disabled here; 0.3.0 must replace this setup with managed policy APIs.
\set ON_ERROR_STOP on
CREATE EXTENSION pg_splitjson VERSION '0.2.0';
SELECT splitjson.create_table('public.gate_docs','[["state"]]', '{"tenant":"name"}');
INSERT INTO gate_docs VALUES (1,'{"state":1,"payload":"a"}','gate_a'),
                             (2,'{"state":2,"payload":"b"}','gate_b');
CREATE ROLE gate_a;
CREATE ROLE gate_b;
CREATE ROLE gate_bypass BYPASSRLS;
GRANT CREATE ON SCHEMA public TO gate_a;
SELECT splitjson.grant_access('gate_docs','gate_a','write');
SELECT splitjson.grant_access('gate_docs','gate_b','write');
SELECT splitjson.grant_access('gate_docs','gate_bypass','write');
SELECT splitjson.storage_relation('gate_docs')::oid AS storage \gset
ALTER EVENT TRIGGER splitjson_ddl_start DISABLE;
ALTER EVENT TRIGGER splitjson_ddl_end DISABLE;
ALTER EVENT TRIGGER splitjson_sql_drop DISABLE;
ALTER VIEW gate_docs SET (security_invoker=true);
ALTER TABLE splitjson_storage.s_1 ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_policy ON splitjson_storage.s_1
    USING (extra_1=current_user::name) WITH CHECK (extra_1=current_user::name);
CREATE TABLE gate_native (id bigint PRIMARY KEY,tenant name);
INSERT INTO gate_native VALUES (1,'gate_a'),(2,'gate_b');
ALTER TABLE gate_native ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_policy ON gate_native USING (tenant=current_user::name)
    WITH CHECK (tenant=current_user::name);
GRANT SELECT,INSERT,UPDATE,DELETE ON gate_native TO gate_a,gate_b,gate_bypass;
CREATE FUNCTION public.gate_api(regclass,boolean,bigint,text) RETURNS bigint
AS '$libdir/pg_splitjson','pg_splitjson_security_gate' LANGUAGE C;
GRANT EXECUTE ON FUNCTION gate_api(regclass,boolean,bigint,text) TO gate_a,gate_b,gate_bypass;
CREATE FUNCTION gate_assert(condition boolean,description text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION 'gate failed: %',description; END IF;
END $$;
CREATE FUNCTION gate_denied(sql text,expected text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE got text;
BEGIN
    BEGIN EXECUTE sql; EXCEPTION WHEN OTHERS THEN got:=SQLSTATE; END;
    IF got IS DISTINCT FROM expected THEN RAISE EXCEPTION 'expected %, got %: %',expected,got,sql; END IF;
END $$;
CREATE FUNCTION gate_write() RETURNS trigger
AS '$libdir/pg_splitjson','pg_splitjson_security_gate_trigger' LANGUAGE C;
DROP TRIGGER pg_splitjson_write ON gate_docs;
CREATE TRIGGER pg_splitjson_write INSTEAD OF INSERT OR UPDATE OR DELETE ON gate_docs
    FOR EACH ROW EXECUTE FUNCTION gate_write();
SET ROLE gate_a;
SELECT gate_assert((SELECT array_agg(id) FROM gate_docs)=ARRAY[1]::bigint[], 'view USING as A');
SELECT gate_assert((SELECT count(*) FROM gate_native)=1, 'native USING control');
SELECT gate_assert(gate_api(:storage::oid::regclass,false,1,'gate_a')=1, 'API visible');
SELECT gate_assert(gate_api(:storage::oid::regclass,false,2,'gate_a') IS NULL, 'API invisible');
SELECT gate_assert(gate_api(:storage::oid::regclass,true,1,'gate_a')=1, 'API UPDATE allowed');
SELECT gate_assert(gate_api(:storage::oid::regclass,true,2,'gate_a') IS NULL, 'API UPDATE invisible');
SELECT gate_denied('SELECT * FROM splitjson_storage.s_1','42501');
SELECT gate_denied('SELECT * FROM splitjson._tables','42501');
SELECT gate_denied('CREATE VIEW public.gate_fake AS SELECT id FROM splitjson_storage.s_1','42501');
SELECT gate_denied(format('SELECT gate_api(%s::oid::regclass,true,1,''gate_b'')',:storage),'42501');
SELECT gate_denied('UPDATE gate_native SET tenant=''gate_b'' WHERE id=1','42501');
INSERT INTO gate_docs VALUES(3,'{"state":3}','gate_a');
SELECT gate_denied('INSERT INTO gate_docs VALUES(4,''{"state":4}'',''gate_b'')','42501');
SELECT gate_denied('UPDATE gate_docs SET tenant=''gate_b'' WHERE id=3','42501');
UPDATE gate_docs SET doc='{"state":33}' WHERE id=3;
SELECT gate_assert((SELECT doc->'state' FROM gate_docs WHERE id=3)='33','view UPDATE WITH CHECK');
DELETE FROM gate_docs WHERE id=3;
COPY gate_docs(id,doc,tenant) FROM STDIN;
5	{"state":5}	gate_a
\.
DELETE FROM gate_docs WHERE id=5;
SET row_security=off;
SELECT gate_denied('SELECT * FROM gate_docs','42501');
SELECT gate_denied(format('SELECT gate_api(%s::oid::regclass,false,1,''gate_a'')',:storage),'42501');
RESET row_security;
PREPARE gate_query AS SELECT array_agg(id) FROM gate_docs;
EXECUTE gate_query;
SET ROLE gate_b;
EXECUTE gate_query;
SELECT gate_assert((SELECT array_agg(id) FROM gate_docs)=ARRAY[2]::bigint[], 'view USING as B');
SELECT gate_assert(gate_api(:storage::oid::regclass,false,1,'gate_b') IS NULL, 'API role switch');
SET splitjson.enable_query_rewrite=off;
SELECT gate_assert((SELECT count(*) FROM gate_docs)=1, 'ACL authorization independent of rewrite');
RESET splitjson.enable_query_rewrite;
RESET ROLE;
CREATE FUNCTION gate_wrapper(p_storage regclass) RETURNS bigint LANGUAGE SQL SECURITY DEFINER
SET search_path=pg_catalog,public AS $$ SELECT public.gate_api(p_storage,false,2,'gate_b') $$;
ALTER FUNCTION gate_wrapper(regclass) OWNER TO gate_b;
CREATE FUNCTION gate_excluded_error(value jsonb) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF value->>'payload'='b' THEN RAISE EXCEPTION 'excluded row' USING ERRCODE='22023'; END IF;
    RETURN true;
END $$;
CREATE FUNCTION gate_nested_private() RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN PERFORM id FROM splitjson_storage.s_1; RETURN true; END $$;
SET ROLE gate_a;
SELECT gate_assert(gate_wrapper(:storage::oid::regclass)=2,'effective application SECURITY DEFINER caller');
SELECT gate_assert((SELECT count(*) FROM gate_docs WHERE gate_excluded_error(doc))=1,
    'non-leakproof expression executes after native RLS and security barrier');
CREATE VIEW gate_outer WITH (security_invoker=true,security_barrier=true) AS SELECT * FROM gate_docs;
SELECT gate_assert((SELECT count(*) FROM gate_outer)=1,'wrapper view preserves native caller');
RESET ROLE;
SET SESSION AUTHORIZATION gate_b;
SELECT gate_assert((SELECT array_agg(id) FROM gate_docs)=ARRAY[2]::bigint[], 'SESSION AUTHORIZATION');
RESET SESSION AUTHORIZATION;
SET ROLE gate_bypass;
SELECT gate_assert((SELECT count(*) FROM gate_docs)=2,'native BYPASSRLS');
SELECT gate_assert(gate_api(:storage::oid::regclass,false,1,'gate_a')=1,'API BYPASSRLS');
RESET ROLE;
ALTER TABLE splitjson_storage.s_1 FORCE ROW LEVEL SECURITY;
SET ROLE gate_a;
SELECT gate_assert((SELECT count(*) FROM gate_docs)=1,'FORCE keeps caller policy');
SELECT gate_assert(gate_api(:storage::oid::regclass,false,1,'gate_a')=1,'identity restored after errors');
RESET ROLE;
ALTER POLICY tenant_policy ON splitjson_storage.s_1 USING (gate_nested_private());
SET ROLE gate_a;
SELECT gate_denied(format('SELECT gate_api(%s::oid::regclass,false,1,''gate_a'')',:storage),'42501');
RESET ROLE;
ALTER POLICY tenant_policy ON splitjson_storage.s_1 USING (extra_1=current_user::name);
CREATE POLICY restrictive_gate ON splitjson_storage.s_1 AS RESTRICTIVE TO gate_a USING (hot_1='1'::jsonb);
SET ROLE gate_a;
SELECT gate_assert((SELECT count(*) FROM gate_docs)=1,'restrictive policy');
RESET ROLE;
ALTER POLICY tenant_policy ON splitjson_storage.s_1 USING (false);
SET ROLE gate_a;
SELECT gate_assert((SELECT count(*) FROM gate_docs)=0,'policy DDL invalidates plans');
EXECUTE gate_query;
RESET ROLE;
SELECT 'Native SELECT/UPDATE RLS and private ACL identity gate passed' AS result;
