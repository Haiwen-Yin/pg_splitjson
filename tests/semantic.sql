\set ON_ERROR_STOP on
CREATE EXTENSION pg_splitjson;
CREATE FUNCTION public.assert_true(ok boolean, message text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'assertion failed: %', message; END IF;
END $$;
CREATE FUNCTION public.expect_error(statement text, state text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    BEGIN EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = state THEN RETURN; END IF;
        RAISE EXCEPTION 'unexpected SQLSTATE %, expected %, error %', SQLSTATE, state, SQLERRM;
    END;
    RAISE EXCEPTION 'expected error % for %', state, statement;
END $$;

SELECT splitjson.create_table('public.docs', '[["counter"],["user","status"],["list"],["a.b"],[""]]');
INSERT INTO docs VALUES
    (1,'{"counter":1,"user":{"status":"new","name":"张三"},"list":[1,null,{}],"a.b":false,"":{},"cold":"unchanged"}'),
    (2,'{"cold":"no hot fields","user":{}}'),
    (3,'{"counter":null,"user":null}'),
    (4,'null'), (5,'[1,2,3]'), (6,'42');
SELECT assert_true((SELECT array_agg(column_name::text ORDER BY ordinal_position) FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='docs') = ARRAY['id','doc'], 'only id and doc visible');
SELECT assert_true((SELECT doc FROM docs WHERE id=1) =
    '{"counter":1,"user":{"status":"new","name":"张三"},"list":[1,null,{}],"a.b":false,"":{},"cold":"unchanged"}', 'round trip all JSON types');
SELECT assert_true((SELECT doc FROM docs WHERE id=2) = '{"cold":"no hot fields","user":{}}', 'absent fields not created');
SELECT assert_true((SELECT hot_1 IS NOT NULL AND hot_1='null'::jsonb FROM splitjson_storage.s_1 WHERE id=3), 'JSON null is present');
SELECT assert_true((SELECT splitjson.template(cold) FROM splitjson_storage.s_1 WHERE id=2) =
                   (SELECT doc FROM docs WHERE id=2), 'no hot fields: unchanged JSONB payload');
SELECT assert_true((SELECT doc FROM docs WHERE id=4) = 'null'::jsonb, 'scalar null');
SELECT assert_true((SELECT doc FROM docs WHERE id=5) = '[1,2,3]'::jsonb, 'root array');
SELECT assert_true((SELECT doc FROM docs WHERE id=6) = '42'::jsonb, 'root number');
SELECT assert_true((SELECT splitjson.restore(cold::text::splitjson.cold,ARRAY[hot_1,hot_2,hot_3,hot_4,hot_5]) FROM splitjson_storage.s_1 WHERE id=1)
                   = (SELECT doc FROM docs WHERE id=1), 'cold text IO round trip');

CREATE TEMP TABLE before_cold AS SELECT id,cold::text AS cold FROM splitjson_storage.s_1;
SELECT assert_true(splitjson.set_field('docs',1,ARRAY['counter'],'2'), 'hot update found row');
SELECT assert_true(splitjson.set_field('docs',1,ARRAY['user','status'],'"ready"'), 'nested hot update');
SELECT assert_true(splitjson.set_field('docs',1,ARRAY['list'],'["x",{"n":2}]'), 'array hot value');
SELECT assert_true(splitjson.set_field('docs',1,ARRAY['a.b'],'true'), 'literal dot key');
SELECT assert_true(splitjson.set_field('docs',1,ARRAY[''],'[]'), 'empty key');
SELECT assert_true((SELECT cold::text FROM splitjson_storage.s_1 WHERE id=1) =
                   (SELECT cold FROM before_cold WHERE id=1), 'hot updates preserve cold content');
SELECT assert_true((SELECT doc#>'{user,status}' FROM docs WHERE id=1) = '"ready"', 'nested hot visible');
SELECT assert_true(splitjson.set_field('docs',3,ARRAY['counter'],'7'), 'JSON null fast update');
SELECT assert_true((SELECT cold::text FROM splitjson_storage.s_1 WHERE id=3) =
                   (SELECT cold FROM before_cold WHERE id=3), 'JSON null uses fast path');
SELECT assert_true(NOT splitjson.set_field('docs',999,ARRAY['counter'],'1'), 'missing row returns false');
SELECT assert_true(NOT splitjson.delete_field('docs',999,ARRAY['counter']), 'missing delete returns false');

SELECT splitjson.set_field('docs',1,ARRAY['cold'],'"modified"');
SELECT assert_true((SELECT doc#>'{user,status}'='"ready"' AND doc->'counter'='2' AND doc->'cold'='"modified"' FROM docs WHERE id=1), 'cold update retains hot values');
SELECT splitjson.set_field('docs',2,ARRAY['counter'],'3',false);
SELECT assert_true((SELECT NOT doc ? 'counter' FROM docs WHERE id=2), 'create_missing=false keeps absent');
SELECT splitjson.set_field('docs',2,ARRAY['counter'],'3');
SELECT assert_true((SELECT doc->'counter'='3' FROM docs WHERE id=2), 'first create synchronized');
SELECT splitjson.set_field('docs',2,ARRAY['missing','child'],'1');
SELECT assert_true((SELECT NOT doc ? 'missing' FROM docs WHERE id=2), 'native jsonb_set does not create intermediate objects');
SELECT splitjson.set_field('docs',1,ARRAY['user'],'{"status":null,"name":"李四"}');
SELECT assert_true((SELECT doc#>'{user,status}'='null' AND doc#>'{user,name}'='"李四"' FROM docs WHERE id=1), 'parent replacement synchronizes hot null');
SELECT splitjson.set_field('docs',1,ARRAY['user'],'{"name":"王五"}');
SELECT assert_true((SELECT hot_2 IS NULL FROM splitjson_storage.s_1 WHERE id=1), 'parent replacement drops hot child');
SELECT splitjson.set_field('docs',1,ARRAY['list'],'{"nested":1}');
SELECT splitjson.set_field('docs',1,ARRAY['list','nested'],'2');
SELECT assert_true((SELECT doc#>'{list,nested}'='2' FROM docs WHERE id=1), 'child of hot object synchronized');
SELECT splitjson.delete_field('docs',1,ARRAY['counter']);
SELECT assert_true((SELECT NOT doc ? 'counter' FROM docs WHERE id=1), 'deletion removes placeholder');
SELECT splitjson.set_field('docs',1,ARRAY['counter'],'99');
SELECT assert_true((SELECT hot_1='99' FROM splitjson_storage.s_1 WHERE id=1), 'recreate after deletion');
UPDATE docs SET doc='{"counter":100,"user":{"status":"replace"},"new":true}' WHERE id=1;
SELECT assert_true((SELECT hot_1='100' AND hot_2='"replace"' AND hot_3 IS NULL FROM splitjson_storage.s_1 WHERE id=1), 'whole document synchronization');
UPDATE docs SET doc=jsonb_set(doc,'{user,name}','"sql"') WHERE id=1;
SELECT assert_true((SELECT doc#>'{user,name}'='"sql"' AND doc->'counter'='100' FROM docs WHERE id=1), 'ordinary jsonb UPDATE');
BEGIN;
SELECT splitjson.set_field('docs',1,ARRAY['counter'],'999');
SELECT splitjson.set_field('docs',1,ARRAY['new'],'false');
ROLLBACK;
SELECT assert_true((SELECT doc->'counter'='100' AND doc->'new'='true' FROM docs WHERE id=1), 'rollback both hot and cold');
UPDATE docs SET id=10 WHERE id=6;
DELETE FROM docs WHERE id=10;
SELECT assert_true(NOT EXISTS(SELECT 1 FROM docs WHERE id IN (6,10)), 'id update and delete');

SELECT expect_error($q$SELECT splitjson.create_table('public.bad','[["a"],["a","b"]]')$q$,'22023');
SELECT assert_true(to_regclass('public.bad') IS NULL, 'invalid DDL leaves no view');
SELECT expect_error($q$SELECT splitjson.validate_paths('[["a"],["a"]]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.validate_paths('[[]]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.validate_paths('[[null]]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.validate_paths('{}')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.validate_paths((SELECT jsonb_agg(jsonb_build_array(i::text)) FROM generate_series(1,65) AS i))$q$,'22023');
SELECT expect_error($q$SELECT splitjson.validate_paths(jsonb_build_array((SELECT jsonb_agg(i::text) FROM generate_series(1,65) AS i)))$q$,'22023');
SELECT expect_error($q$SELECT splitjson.set_field('docs',1,'{}','1')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.set_field('docs',1,ARRAY['x',NULL],'1')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.set_field('docs',1,ARRAY['x'],NULL)$q$,'22023');
SELECT splitjson.set_field('docs',1,ARRAY['array'],'[1,2]');
SELECT splitjson.set_field('docs',1,ARRAY['array','0'],'3');
SELECT assert_true((SELECT doc->'array'='[3,2]' FROM docs WHERE id=1),'native array element set');
SELECT splitjson.delete_field('docs',1,ARRAY['array','0']);
SELECT assert_true((SELECT doc->'array'='[2]' FROM docs WHERE id=1),'native array deletion');
SELECT splitjson.set_field('docs',5,ARRAY['0'],'3');
SELECT assert_true((SELECT doc='[3,2,3]' FROM docs WHERE id=5),'root array update');
SELECT expect_error($q$SELECT splitjson.restore(splitjson.pack('{"x":1}','[["x"]]'), ARRAY[NULL::jsonb])$q$,'XX001');
SELECT expect_error($q$SELECT '{"version":3,"paths":[],"template":{}}'::splitjson.cold$q$,'22P02');
SELECT expect_error($q$SELECT '{"version":1,"paths":[["x"]],"template":{"x":1}}'::splitjson.cold$q$,'22P02');
SELECT expect_error($q$INSERT INTO docs VALUES (100,NULL)$q$,'23502');
SELECT expect_error($q$INSERT INTO docs VALUES (1,'{}')$q$,'23505');
SELECT splitjson.create_table('public.lifecycle','[["v"]]');
SELECT splitjson.drop_table('public.lifecycle');
SELECT assert_true(to_regclass('public.lifecycle') IS NULL AND NOT EXISTS(SELECT 1 FROM splitjson._tables WHERE view_name='public.lifecycle'), 'managed lifecycle cleanup');

CREATE ROLE splitjson_reader;
CREATE ROLE splitjson_writer;
GRANT EXECUTE ON FUNCTION splitjson.get_field(regclass,bigint,text[]),splitjson.find_ids(regclass,text[],jsonb)
    TO splitjson_reader,splitjson_writer;
GRANT EXECUTE ON FUNCTION splitjson.set_field(regclass,bigint,text[],jsonb,boolean),
    splitjson.set_fields(regclass,bigint,jsonb,boolean),splitjson.delete_field(regclass,bigint,text[]),
    splitjson.increment_field(regclass,bigint,text[],numeric) TO splitjson_writer;
GRANT SELECT ON docs TO splitjson_reader;
GRANT SELECT,INSERT,UPDATE,DELETE ON docs TO splitjson_writer;
SET ROLE splitjson_reader;
SELECT assert_true((SELECT doc->'counter' FROM docs WHERE id=1)='100', 'reader logical view');
SELECT expect_error($q$SELECT * FROM splitjson_storage.s_1$q$,'42501');
SELECT expect_error($q$SELECT * FROM splitjson._tables$q$,'42501');
SELECT expect_error($q$SELECT splitjson.set_field('docs',1,ARRAY['counter'],'1')$q$,'42501');
SELECT expect_error($q$SELECT splitjson.delete_field('docs',1,ARRAY['counter'])$q$,'42501');
SELECT expect_error($q$SELECT splitjson._save('splitjson_storage.s_1',1,'{}','[["x"]]')$q$,'42501');
SELECT expect_error($q$SELECT splitjson.drop_table('docs')$q$,'42501');
RESET ROLE;
SET ROLE splitjson_writer;
SELECT splitjson.set_field('docs',1,ARRAY['counter'],'101');
SELECT splitjson.set_field('docs',1,ARRAY['cold'],'"writer"');
INSERT INTO docs VALUES (100,'{"counter":1}');
UPDATE docs SET doc=jsonb_set(doc,'{counter}','2') WHERE id=100;
SELECT assert_true((SELECT doc->'counter' FROM docs WHERE id=100)='2', 'writer DML');
DELETE FROM docs WHERE id=100;
RESET ROLE;
SET SESSION AUTHORIZATION splitjson_reader;
SELECT expect_error($q$SELECT splitjson.set_field('docs',1,ARRAY['counter'],'1')$q$,'42501');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION splitjson_writer;
SELECT splitjson.set_field('docs',1,ARRAY['counter'],'102');
RESET SESSION AUTHORIZATION;
SELECT assert_true((SELECT doc->'counter' FROM docs WHERE id=1)='102', 'session authorization writer');

-- Different shapes at the same registered path must round trip as JSONB.
WITH samples AS (
    SELECT CASE i%8
        WHEN 0 THEN jsonb_build_object('hot',i,'nested',jsonb_build_object('v',NULL),'other','x')
        WHEN 1 THEN jsonb_build_object('hot',jsonb_build_array(i,NULL),'nested',jsonb_build_object('v',i))
        WHEN 2 THEN jsonb_build_object('nested',jsonb_build_object('other',i))
        WHEN 3 THEN jsonb_build_object('nested',jsonb_build_array(i))
        WHEN 4 THEN jsonb_build_object('hot',NULL,'nested',false)
        WHEN 5 THEN to_jsonb(i)
        WHEN 6 THEN 'null'::jsonb
        ELSE jsonb_build_array(i,'x') END AS doc
    FROM generate_series(1,256) AS i
)
SELECT assert_true(bool_and(doc=splitjson.restore(splitjson.pack(doc,'[["hot"],["nested","v"]]'),
    splitjson.slots(doc,'[["hot"],["nested","v"]]'))),'round trip across 256 heterogeneous documents') FROM samples;

-- Stable fixture for backup and concurrent writers.
SELECT splitjson.create_table('public.concurrent_docs','[["left"],["right"]]');
INSERT INTO concurrent_docs VALUES (1,'{"left":0,"right":0,"cold":0}');
SELECT 'semantic tests passed' AS result;
