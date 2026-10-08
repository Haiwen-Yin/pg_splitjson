\set ON_ERROR_STOP on
SELECT splitjson.create_table('public.production_dml','[["n"],["state"]]','{"tenant":"bigint"}');
SELECT splitjson.set_business_default('production_dml','tenant','42');
SELECT splitjson.set_business_not_null('production_dml','tenant');
SELECT splitjson.add_field_check('production_dml','n_type','["n"]','number',true);
WITH inserted AS (INSERT INTO production_dml(id,doc) VALUES(1,'{"n":1,"state":"new"}'),
    (2,'{"n":2,"state":"ready"}') RETURNING id,doc,tenant)
SELECT assert_true(count(*)=2 AND bool_and(tenant=42),'multi-row INSERT RETURNING and view defaults') FROM inserted;
WITH updated AS (UPDATE production_dml SET doc=jsonb_set(doc,'{state}','"changed"') RETURNING *)
SELECT assert_true(count(*)=2 AND bool_and(doc->>'state'='changed'),'multi-row UPDATE RETURNING') FROM updated;
COPY production_dml(id,doc) FROM STDIN;
3	{"n":3,"state":"copied"}
4	{"n":4,"state":"copied"}
\.
SELECT assert_true((SELECT count(*)=4 AND min(tenant)=42 FROM production_dml),'COPY FROM view with defaults');
WITH removed AS (DELETE FROM production_dml WHERE id IN (3,4) RETURNING id)
SELECT assert_true(count(*)=2,'multi-row DELETE RETURNING') FROM removed;
SELECT splitjson.index_ddl('production_dml','production_state_concurrent','["state"]','text') \gexec
SELECT assert_true((SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid='splitjson_storage.production_state_concurrent'::regclass),
    'actual concurrent index build completed');
SELECT splitjson.check_table('production_dml',true);
CREATE TEMP TABLE cold_wire(value splitjson.cold);
INSERT INTO cold_wire SELECT splitjson.pack(jsonb_build_object('n',i,'body',repeat(md5(i::text),128)),
    '[["n"]]') FROM generate_series(1,32) i;
CREATE TEMP TABLE cold_wire_before AS SELECT value::text AS wire FROM cold_wire;
\copy cold_wire TO 'cold-wire.bin' WITH (FORMAT binary)
TRUNCATE cold_wire;
\copy cold_wire FROM 'cold-wire.bin' WITH (FORMAT binary)
SELECT assert_true(NOT EXISTS((SELECT value::text FROM cold_wire EXCEPT SELECT wire FROM cold_wire_before)
    UNION ALL (SELECT wire FROM cold_wire_before EXCEPT SELECT value::text FROM cold_wire)), 'validated portable cold binary COPY round trip');
-- Similar projections not registered by the extension must retain native errors.
CREATE TABLE splitjson_storage.unmanaged(id bigint,cold splitjson.cold,hot_1 jsonb);
INSERT INTO splitjson_storage.unmanaged VALUES(1,splitjson.pack('{"state":1}','[["state"]]'),NULL);
CREATE VIEW public.unmanaged_projection WITH (security_barrier=true) AS
SELECT id,splitjson.restore(cold,ARRAY[hot_1],'[["state"]]'::jsonb) AS doc FROM splitjson_storage.unmanaged;
SELECT expect_error($q$SELECT doc->>'state' FROM unmanaged_projection$q$,'XX001');
DROP VIEW unmanaged_projection;
DROP TABLE splitjson_storage.unmanaged;
SELECT splitjson.rename_table('production_dml','public.production_renamed');
SELECT splitjson.check_table('production_renamed',true);
SELECT splitjson.drop_table('production_renamed');
SELECT 'production DML, binary protocol, concurrent index and planner registration tests passed' AS result;
