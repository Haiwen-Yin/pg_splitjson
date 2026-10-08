\set ON_ERROR_STOP on
SELECT assert_true((SELECT extversion='0.2.0' FROM pg_extension WHERE extname='pg_splitjson'),'official extension identity 0.2.0');
SELECT assert_true((SELECT obj_description(oid,'pg_extension')='PostgreSQL Split JSON Storage Extension' FROM pg_extension WHERE extname='pg_splitjson'),'full English name');

SELECT splitjson.create_table('public.batch_docs','[["x"],["y"],["obj"]]');
INSERT INTO batch_docs VALUES (1,'{"x":1,"y":null,"obj":{"child":0},"cold":9,"array":[1,2]}'),(2,'{}');
CREATE TEMP TABLE batch_audit (operation text);
CREATE FUNCTION public.audit_batch_write() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
    INSERT INTO pg_temp.batch_audit VALUES (TG_OP); RETURN NEW;
END $$;
DO $$ DECLARE store text; BEGIN
    SELECT storage_name INTO store FROM splitjson._tables WHERE view_name='public.batch_docs';
    EXECUTE format('CREATE TRIGGER audit_batch AFTER UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION public.audit_batch_write()',store);
END $$;
SELECT assert_true(splitjson.set_fields('batch_docs',1,
    '[{"path":["x"],"value":2},{"path":["y"],"value":false},{"path":["x"],"value":3},{"path":["obj"],"value":[1,null]}]'),'hot batch succeeds');
SELECT assert_true((SELECT count(*)=1 FROM batch_audit),'hot batch performs one physical UPDATE');
SELECT assert_true((SELECT doc->'x'='3' AND doc->'y'='false' AND doc->'obj'='[1,null]' FROM batch_docs WHERE id=1),'duplicate hot path last value wins');
TRUNCATE batch_audit;
SELECT splitjson.set_fields('batch_docs',1,
    '[{"path":["obj"],"value":{"child":5}},{"path":["obj","child"],"value":6},{"path":["cold"],"value":10},{"path":["x"],"value":4}]');
SELECT assert_true((SELECT count(*)=1 FROM batch_audit),'mixed batch performs one physical UPDATE');
SELECT assert_true((SELECT doc->'x'='4' AND doc#>'{obj,child}'='6' AND doc->'cold'='10' FROM batch_docs WHERE id=1),'ordered mixed batch synchronized');
SELECT splitjson.set_fields('batch_docs',2,'[{"path":["x"],"value":1},{"path":["missing","child"],"value":2}]',false);
SELECT assert_true((SELECT doc='{}' FROM batch_docs WHERE id=2),'batch create_missing false');
SELECT splitjson.set_fields('batch_docs',2,'[{"path":["x"],"value":1},{"path":["y"],"value":null}]');
SELECT assert_true((SELECT doc='{"x":1,"y":null}' FROM batch_docs WHERE id=2),'batch first create and JSON null');
CREATE TEMP TABLE batch_before AS SELECT * FROM batch_docs;
SELECT expect_error($q$SELECT splitjson.set_fields('batch_docs',1,'[{"path":["x"],"value":100},{"path":["array","bad"],"value":7}]')$q$,'22P02');
SELECT assert_true((SELECT doc FROM batch_docs WHERE id=1)=(SELECT doc FROM batch_before WHERE id=1),'invalid later batch operation leaves no partial change');
SELECT expect_error($q$SELECT splitjson.set_fields('batch_docs',1,'[]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.set_fields('batch_docs',1,'{}')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.set_fields('batch_docs',1,'[null]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.set_fields('batch_docs',1,'[{"path":["x"]}]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.set_fields('batch_docs',1,'[{"path":["x"],"value":1,"extra":1}]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.set_fields('batch_docs',1,'[{"path":[null],"value":1}]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.set_fields('batch_docs',1,(SELECT jsonb_agg(jsonb_build_object('path',ARRAY['x'],'value',i)) FROM generate_series(1,65) AS i))$q$,'22023');
SELECT assert_true(NOT splitjson.set_fields('batch_docs',999,'[{"path":["x"],"value":1}]'),'missing batch row');

SELECT assert_true(splitjson.increment_field('batch_docs',1,ARRAY['x'],0.125)=4.125,'decimal hot increment');
SELECT assert_true(splitjson.increment_field('batch_docs',1,ARRAY['x'],-0.025)=4.1,'negative decimal increment');
SELECT assert_true(splitjson.increment_field('batch_docs',1,ARRAY['cold'],1)=11,'non-hot increment');
SELECT splitjson.set_field('batch_docs',1,ARRAY['x'],'9007199254740993.123456789');
SELECT assert_true(splitjson.increment_field('batch_docs',1,ARRAY['x'],0.000000001)=9007199254740993.123456790,'numeric precision exceeds double');
SELECT assert_true(splitjson.increment_field('batch_docs',999,ARRAY['x']) IS NULL,'missing increment row');
SELECT expect_error($q$SELECT splitjson.increment_field('batch_docs',1,ARRAY['missing'])$q$,'22023');
SELECT expect_error($q$SELECT splitjson.increment_field('batch_docs',1,ARRAY['y'])$q$,'22023');
SELECT expect_error($q$SELECT splitjson.increment_field('batch_docs',2,ARRAY['y'])$q$,'22023');
SELECT expect_error($q$SELECT splitjson.increment_field('batch_docs',1,ARRAY['x'],'NaN')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.increment_field('batch_docs',1,ARRAY['x'],'Infinity')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.increment_field('batch_docs',1,ARRAY['array','bad'])$q$,'22023');
CREATE TEMP TABLE increment_before AS SELECT * FROM batch_docs;
BEGIN;
SELECT splitjson.increment_field('batch_docs',1,ARRAY['x'],1);
SELECT splitjson.set_fields('batch_docs',1,'[{"path":["cold"],"value":0},{"path":["y"],"value":true}]');
ROLLBACK;
SELECT assert_true((SELECT doc FROM batch_docs WHERE id=1)=(SELECT doc FROM increment_before WHERE id=1),'batch and increment rollback');
DO $$ DECLARE store text; BEGIN
    SELECT storage_name INTO store FROM splitjson._tables WHERE view_name='public.batch_docs';
    EXECUTE format('DROP TRIGGER audit_batch ON %s',store);
END $$;
DROP FUNCTION audit_batch_write();

SELECT splitjson.create_table('public.business_docs','[["count"]]',
    '{"account_id":"uuid","label":"varchar(12)","amount":"numeric(12,3)","created_at":"timestamp with time zone","bytes":"bytea","tags":"integer[]","odd name":"text"}');
INSERT INTO business_docs(id,doc,account_id,label,amount,created_at,bytes,tags,"odd name") VALUES
    (1,'{"count":1,"cold":1}','00112233-4455-6677-8899-aabbccddeeff','客户A',12.345,'2026-10-04 12:34:56.123456+08','\x00ff10',ARRAY[1,NULL,3],'quoted');
SELECT assert_true((SELECT amount=12.345 AND bytes='\x00ff10'::bytea AND tags=ARRAY[1,NULL,3]
                    AND created_at='2026-10-04 12:34:56.123456+08'::timestamptz AND "odd name"='quoted' FROM business_docs WHERE id=1),'typed business INSERT preserves values');
SELECT assert_true((SELECT format_type(atttypid,atttypmod)='numeric(12,3)' FROM pg_attribute WHERE attrelid='business_docs'::regclass AND attname='amount'),'numeric typmod preserved');
SELECT assert_true((SELECT format_type(atttypid,atttypmod)='character varying(12)' FROM pg_attribute WHERE attrelid='business_docs'::regclass AND attname='label'),'varchar typmod preserved');
CREATE TEMP TABLE business_before AS SELECT id,to_jsonb(b)-'doc' AS extras FROM business_docs b;
SELECT splitjson.set_fields('business_docs',1,'[{"path":["count"],"value":2},{"path":["cold"],"value":2}]');
SELECT splitjson.increment_field('business_docs',1,ARRAY['count']);
SELECT assert_true((SELECT to_jsonb(b)-'doc' FROM business_docs b WHERE id=1)=(SELECT extras FROM business_before WHERE id=1),'JSON APIs leave business columns intact');
UPDATE business_docs SET label='客户B',amount=99.999,tags=ARRAY[2,4],"odd name"='updated' WHERE id=1;
SELECT assert_true((SELECT label='客户B' AND amount=99.999 AND doc->'count'='3' FROM business_docs WHERE id=1),'business UPDATE preserves JSON');
SELECT expect_error($q$UPDATE business_docs SET label='this label is too long' WHERE id=1$q$,'22001');
SELECT expect_error($q$SELECT splitjson.create_table('public.bad_columns','[["x"]]','{"id":"integer"}')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.create_table('public.bad_columns','[["x"]]','{"doc":"text"}')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.create_table('public.bad_columns','[["x"]]','{"x":"record"}')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.create_table('public.bad_columns','[["x"]]','{"x":"integer); DROP TABLE public.docs; --"}')$q$,'42601');
SELECT assert_true(to_regclass('public.bad_columns') IS NULL AND to_regclass('public.docs') IS NOT NULL,'invalid declarations do not execute SQL or leave objects');
CREATE DOMAIN public.positive_money AS numeric(20,4) CHECK(VALUE>0);
SELECT splitjson.create_table('public.domain_docs','[["x"]]','{"money":"public.positive_money"}');
INSERT INTO domain_docs(id,doc,money) VALUES (1,'{"x":1}',123.4567);
SELECT assert_true((SELECT money=123.4567 FROM domain_docs WHERE id=1),'qualified domain business value');
SELECT expect_error($q$INSERT INTO domain_docs(id,doc,money) VALUES (2,'{}',-1)$q$,'23514');

CREATE TABLE public.migration_source(id bigint PRIMARY KEY,doc jsonb,label varchar(8),amount numeric(12,3),tags int[]);
INSERT INTO migration_source VALUES (1,'{"count":10,"cold":"a"}','one',1.234,ARRAY[1,2]),(2,'{"cold":"b"}',NULL,9.876,NULL);
CREATE TEMP TABLE source_before AS TABLE migration_source;
SELECT splitjson.migrate_table('migration_source','public.migrated_docs','[["count"]]');
SELECT assert_true((SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM migration_source s)=
                   (SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM migrated_docs s),'migration copies logical rows and business values');
SELECT splitjson.increment_field('migrated_docs',1,ARRAY['count']);
SELECT assert_true((SELECT doc->'count'='11' AND amount=1.234 AND label='one' FROM migrated_docs WHERE id=1),'migrated hot update preserves extras');
SELECT assert_true((SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM migration_source s)=
                   (SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM source_before s),'migration and target updates leave source unchanged');
CREATE TABLE invalid_source(id bigint,doc jsonb);
INSERT INTO invalid_source VALUES (1,NULL);
SELECT expect_error($q$SELECT splitjson.migrate_table('invalid_source','public.failed_migration','[["x"]]')$q$,'23502');
SELECT assert_true(to_regclass('public.failed_migration') IS NULL AND NOT EXISTS(SELECT 1 FROM splitjson._tables WHERE view_name='public.failed_migration'),'migration failure rolls back target DDL');
TRUNCATE invalid_source;
INSERT INTO invalid_source VALUES (1,'{}'),(1,'{}');
SELECT expect_error($q$SELECT splitjson.migrate_table('invalid_source','public.failed_migration','[["x"]]')$q$,'23505');
SELECT assert_true(to_regclass('public.failed_migration') IS NULL AND (SELECT count(*)=2 FROM invalid_source),'duplicate IDs rollback without altering source');
CREATE TABLE named_source(key bigint,body jsonb,note text);
INSERT INTO named_source VALUES (7,'{"x":1}','custom names');
SELECT splitjson.migrate_table('named_source','public.named_docs','[["x"]]','body','key');
SELECT assert_true((SELECT id=7 AND doc='{"x":1}' AND note='custom names' FROM named_docs),'custom source identifier and document names');

SELECT splitjson.create_table('public.query_docs','[["state"],["hot_null"],["count"]]','{"tenant":"integer"}');
INSERT INTO query_docs(id,doc,tenant) SELECT i,
    jsonb_build_object('state','s_'||i,'count',i,'other',i%11,'array',ARRAY[i])||
    CASE WHEN i%7=0 THEN '{"hot_null":null}'::jsonb ELSE '{}'::jsonb END,i%3
    FROM generate_series(1,10000) AS i;
SELECT splitjson.create_path_index('query_docs','query_state_idx',ARRAY['state']);
DO $$ DECLARE store text; BEGIN
    SELECT storage_name INTO store FROM splitjson._tables WHERE view_name='public.query_docs';
    EXECUTE format('ANALYZE %s',store);
END $$;
SELECT assert_true(splitjson.get_field('query_docs',10,ARRAY['state'])='"s_10"','direct hot field read');
SELECT assert_true(splitjson.get_field('query_docs',10,ARRAY['other'])='10','cold field read');
SELECT assert_true(splitjson.get_field('query_docs',7,ARRAY['hot_null'])='null','JSON null read');
SELECT assert_true(splitjson.get_field('query_docs',8,ARRAY['hot_null']) IS NULL,'absent hot read');
SELECT assert_true(splitjson.get_field('query_docs',10001,ARRAY['state']) IS NULL,'missing row read');
SELECT assert_true(splitjson.get_field('query_docs',10,ARRAY['array','0'])='10','native array field read');
SELECT assert_true((SELECT array_agg(id) FROM splitjson.find_ids('query_docs',ARRAY['state'],'"s_101"') AS id)=ARRAY[101::bigint],'indexed equality IDs');
SELECT assert_true((SELECT array_agg(id ORDER BY id) FROM splitjson.find_ids('query_docs',ARRAY['other'],'0') AS id)=
                   (SELECT array_agg(id ORDER BY id) FROM query_docs WHERE doc->'other'='0'),'non-hot equality fallback');
SELECT assert_true((SELECT count(*) FROM splitjson.find_ids('query_docs',ARRAY['hot_null'],'null'))=1428,'null equality excludes missing');
SELECT assert_true((SELECT bool_or(plan LIKE '%Index%Scan%' AND plan LIKE '%query_state_idx%')
                    FROM splitjson.explain_find_ids('query_docs',ARRAY['state'],'"s_101"') AS plan),'actual planner uses hot B-tree index');
SELECT * FROM splitjson.explain_find_ids('query_docs',ARRAY['state'],'"s_101"');
SELECT splitjson.set_field('query_docs',101,ARRAY['state'],'"changed"');
SELECT assert_true(NOT EXISTS(SELECT 1 FROM splitjson.find_ids('query_docs',ARRAY['state'],'"s_101"')) AND
                   (SELECT array_agg(id) FROM splitjson.find_ids('query_docs',ARRAY['state'],'"changed"') AS id)=ARRAY[101::bigint],'query index follows hot update');
SELECT assert_true((SELECT tenant=2 FROM query_docs WHERE id=101),'query hot updates preserve business field');
SELECT expect_error($q$SELECT splitjson.create_path_index('query_docs','invalid_idx',ARRAY['other'])$q$,'22023');

GRANT SELECT ON batch_docs,business_docs,query_docs TO splitjson_reader;
GRANT SELECT,UPDATE ON batch_docs,business_docs TO splitjson_writer;
SET ROLE splitjson_reader;
SELECT assert_true(splitjson.get_field('query_docs',101,ARRAY['state'])='"changed"','view reader can directly read hot field');
SELECT assert_true((SELECT array_agg(id) FROM splitjson.find_ids('query_docs',ARRAY['state'],'"changed"') AS id)=ARRAY[101::bigint],'view reader can query hot index');
SELECT expect_error($q$SELECT splitjson.create_path_index('query_docs','denied_idx',ARRAY['state'])$q$,'42501');
SELECT expect_error($q$SELECT * FROM splitjson.explain_find_ids('query_docs',ARRAY['state'],'"changed"')$q$,'42501');
SELECT expect_error($q$SELECT splitjson.set_fields('batch_docs',1,'[{"path":["x"],"value":1}]')$q$,'42501');
SELECT expect_error($q$SELECT splitjson.increment_field('batch_docs',1,ARRAY['x'])$q$,'42501');
RESET ROLE;
SET ROLE splitjson_writer;
SELECT splitjson.set_fields('business_docs',1,'[{"path":["count"],"value":4}]');
SELECT splitjson.increment_field('business_docs',1,ARRAY['count']);
RESET ROLE;
CREATE ROLE splitjson_noaccess;
SET ROLE splitjson_noaccess;
SELECT expect_error($q$SELECT splitjson.get_field('query_docs',1,ARRAY['state'])$q$,'42501');
SELECT expect_error($q$SELECT * FROM splitjson.find_ids('query_docs',ARRAY['state'],'"s_1"')$q$,'42501');
RESET ROLE;
SELECT assert_true((SELECT label='客户B' AND amount=99.999 AND doc->'count'='5' FROM business_docs WHERE id=1),'writer APIs preserve typed business values');
SELECT 'new update, business table and query tests passed' AS result;
