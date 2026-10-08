\set ON_ERROR_STOP on
SELECT assert_true((SELECT extversion='0.2.0' FROM pg_extension WHERE extname='pg_splitjson'),'release version 0.2.0');
SELECT assert_true(splitjson.restore('{"version":1,"paths":[["x"]],"template":{"x":null}}'::splitjson.cold,ARRAY['5'::jsonb])='{"x":5}','legacy cold v1 read');
SELECT assert_true(splitjson.pack('{"x":1}','[["x"]]')::text::jsonb->'version'='2','new cold format v2');
SELECT assert_true(splitjson.pack('{"a":[{"v":1},null]}','[["a",0,"v"]]')::text::splitjson.cold::text=splitjson.pack('{"a":[{"v":1},null]}','[["a",0,"v"]]')::text,'cold v2 typed round trip');
SELECT expect_error($q$SELECT splitjson.validate_paths('[["a",-1]]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.validate_paths('[["a",1.5]]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.validate_paths('[["a",2147483648]]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.validate_paths('[["a",0],["a",0.0]]')$q$,'22023');
SELECT expect_error($q$SELECT splitjson.validate_paths('[["a"],["a",0,"b"]]')$q$,'22023');

SELECT splitjson.create_table('public.array_differential','[["a",0,"v"],["a","0","v"],["hot"]]');
DO $$
DECLARE original jsonb; path text[]; path_json jsonb; expected jsonb; native_code text; actual_code text; mode integer; cases integer:=0;
BEGIN
    FOR original IN SELECT value FROM jsonb_array_elements('[{},null,5,[],[1,2],{"a":[]},{"a":[{"v":1},{"v":2}]},{"a":{"0":{"v":3}}},{"a":[null]},{"hot":[{"v":1},[2,3],null]},{"hot":1},{"hot":null},{"hot":{"0":{"v":4}}}]') LOOP
        FOR path_json IN SELECT value FROM jsonb_array_elements('[["a","0","v"],["a","-1","v"],["a","00","v"],["a","1"],["a","99"],["a","bad"],["hot","0","v"],["hot","1","-1"],["hot","-1"],["hot","bad"],["hot"],["0"],["-1"]]') LOOP
            path := ARRAY(SELECT jsonb_array_elements_text(path_json));
            FOR mode IN 1..2 LOOP
                DELETE FROM array_differential;
                INSERT INTO array_differential VALUES (1,original);
                native_code:=NULL; actual_code:=NULL;
                BEGIN
                    IF mode=1 THEN expected:=jsonb_set(original,path,'9');
                    ELSE expected:=original #- path; END IF;
                EXCEPTION WHEN OTHERS THEN native_code:=SQLSTATE; END;
                BEGIN
                    IF mode=1 THEN PERFORM splitjson.set_field('array_differential',1,path,'9');
                    ELSE PERFORM splitjson.delete_field('array_differential',1,path); END IF;
                EXCEPTION WHEN OTHERS THEN actual_code:=SQLSTATE; END;
                PERFORM assert_true(native_code IS NOT DISTINCT FROM actual_code,'array native error equivalence '||original::text||' '||path_json::text);
                IF native_code IS NULL THEN
                    PERFORM assert_true((SELECT doc=expected FROM array_differential),'array native result equivalence '||original::text||' '||path_json::text);
                ELSE
                    PERFORM assert_true((SELECT doc=original FROM array_differential),'array failed update rollback');
                END IF;
                cases:=cases+1;
            END LOOP;
        END LOOP;
    END LOOP;
    RAISE NOTICE 'array native differential cases: %',cases;
END $$;

SELECT splitjson.create_table('public.array_slots','[["items",0,"price"],["items",1,"qty"],["items","0","price"],["state"]]');
INSERT INTO array_slots VALUES
 (1,'{"items":[{"price":10,"qty":1},{"price":20,"qty":2}],"state":null,"body":"cold"}'),
 (2,'{"items":{"0":{"price":30}},"state":"object"}'),
 (3,'{"items":[],"state":"empty"}'),
 (4,'{"items":[null],"state":"null"}');
SELECT assert_true(splitjson.get_field('array_slots',1,ARRAY['items','0','price'])='10','typed array getter');
SELECT assert_true(splitjson.get_field('array_slots',2,ARRAY['items','0','price'])='30','numeric object key getter');
SELECT assert_true((SELECT array_agg(id ORDER BY id) FROM splitjson.find_ids('array_slots',ARRAY['items','0','price'],'30') id)=ARRAY[2::bigint],'mixed shape exact search');
SELECT splitjson.set_field('array_slots',1,ARRAY['items','00','price'],'11');
SELECT splitjson.set_field('array_slots',2,ARRAY['items','0','price'],'31');
SELECT assert_true((SELECT doc#>'{items,0,price}'='11' FROM array_slots WHERE id=1),'canonical index aliases');
SELECT assert_true((SELECT doc#>'{items,0,price}'='31' FROM array_slots WHERE id=2),'key vs index updates');
SELECT splitjson.increment_field('array_slots',1,ARRAY['items','0','price'],0.5);
SELECT splitjson.set_fields('array_slots',1,'[{"path":["items","0","price"],"value":12},{"path":["items","1","qty"],"value":4}]');
CREATE TEMP TABLE array_before AS SELECT doc FROM array_slots WHERE id=1;
SELECT splitjson.delete_field('array_slots',1,ARRAY['items','0']);
SELECT assert_true((SELECT doc FROM array_slots WHERE id=1)=(SELECT doc #- '{items,0}' FROM array_before),'deletion shifts registered slots');
SELECT assert_true(splitjson.get_field('array_slots',1,ARRAY['items','0','price'])='20','shifted price synchronized');
SELECT assert_true(splitjson.get_field('array_slots',1,ARRAY['items','1','qty']) IS NULL,'removed position absent');
SELECT splitjson.set_field('array_slots',1,ARRAY['items','-1','price'],'21');
SELECT assert_true(splitjson.get_field('array_slots',1,ARRAY['items','-1','price'])='21','negative native index');
UPDATE array_slots SET doc=jsonb_insert(doc,'{items,0}','{"price":7,"qty":8}') WHERE id=1;
SELECT assert_true(splitjson.get_field('array_slots',1,ARRAY['items','0','price'])='7','insertion repacks positions');
SELECT assert_true(splitjson.get_field('array_slots',1,ARRAY['items','1','qty'])='4','insertion preserves moved item');
SELECT splitjson.set_field('array_slots',3,ARRAY['items','99'],'{"price":1,"qty":2}');
SELECT assert_true(splitjson.get_field('array_slots',3,ARRAY['items','0','price'])='1','out of range native append');
SELECT expect_error($q$SELECT splitjson.create_path_index('array_slots','ambiguous_idx',ARRAY['items','0','price'])$q$,'22023');
SELECT splitjson.create_path_index('array_slots','array_price_idx','["items",0,"price"]'::jsonb);
SELECT splitjson.create_path_index('array_slots','object_price_idx','["items","0","price"]'::jsonb);

SELECT splitjson.create_table('public.hot_arrays','[["items"],["obj"],["count"]]');
INSERT INTO hot_arrays VALUES (1,'{"items":[{"n":1},null,[2,3]],"obj":{"x":1},"count":0,"body":"cold"}');
CREATE FUNCTION public.array_audit() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO public.array_audit_log DEFAULT VALUES; RETURN NEW; END$$;
CREATE TABLE public.array_audit_log(n integer);
SELECT storage_name AS hot_arrays_store FROM splitjson._tables WHERE view_name='public.hot_arrays' \gset
CREATE TRIGGER audit AFTER UPDATE ON :hot_arrays_store FOR EACH ROW EXECUTE FUNCTION public.array_audit();
CREATE TEMP TABLE hot_array_before AS SELECT cold::text AS cold FROM :hot_arrays_store;
SELECT splitjson.set_fields('hot_arrays',1,'[{"path":["items","0","n"],"value":2},{"path":["items","2","-1"],"value":4},{"path":["obj","x"],"value":3}]');
SELECT assert_true((SELECT count(*)=1 FROM array_audit_log),'subtree batch one physical write');
SELECT assert_true((SELECT cold::text FROM :hot_arrays_store)=(SELECT cold FROM hot_array_before),'subtree batch cold unchanged');
SELECT assert_true(splitjson.increment_field('hot_arrays',1,ARRAY['items','0','n'])=3,'array subtree increment');
SELECT splitjson.delete_field('hot_arrays',1,ARRAY['items','1']);
SELECT assert_true(splitjson.get_field('hot_arrays',1,ARRAY['items','1','-1'])='4','subtree delete and nested array');
SELECT assert_true((SELECT cold::text FROM :hot_arrays_store)=(SELECT cold FROM hot_array_before),'subtree increment/delete cold unchanged');
CREATE TEMP TABLE subtree_before AS SELECT doc FROM hot_arrays;
SELECT expect_error($q$SELECT splitjson.set_fields('hot_arrays',1,'[{"path":["count"],"value":99},{"path":["items","bad"],"value":0}]')$q$,'22P02');
SELECT assert_true((SELECT doc FROM hot_arrays)=(SELECT doc FROM subtree_before),'invalid subtree batch rollback');
-- Relative updates to scalar hot values must retain whole-document native semantics.
SELECT splitjson.set_field('hot_arrays',1,ARRAY['obj'],'1');
CREATE TEMP TABLE scalar_before AS SELECT doc FROM hot_arrays;
SELECT splitjson.set_field('hot_arrays',1,ARRAY['obj','x'],'4');
SELECT assert_true((SELECT doc FROM hot_arrays)=(SELECT jsonb_set(doc,'{obj,x}','4') FROM scalar_before),'scalar ancestor fallback matches native');

CREATE FUNCTION public.plan_lines(statement text) RETURNS SETOF text LANGUAGE plpgsql AS $$BEGIN RETURN QUERY EXECUTE 'EXPLAIN (COSTS OFF) '||statement; END$$;
SELECT splitjson.create_table('public.shape_docs','[["a",0,"v"]]');
INSERT INTO shape_docs VALUES (1,'{"a":[{"v":1}]}'),(2,'{"a":{"0":{"v":1}}}'),(3,'{}');
SELECT assert_true((SELECT array_agg(id ORDER BY id) FROM splitjson.find_ids('shape_docs',ARRAY['a','0','v'],'1') id)=ARRAY[1::bigint,2::bigint],'search includes undeclared object shape');
SET splitjson.enable_query_rewrite=off;
CREATE TEMP TABLE shape_native AS SELECT id,doc#>'{a,0,v}' AS value FROM shape_docs;
SET splitjson.enable_query_rewrite=on;
SELECT assert_true((SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM (SELECT id,doc#>'{a,0,v}' AS value FROM shape_docs) r)=(SELECT jsonb_agg(to_jsonb(n) ORDER BY id) FROM shape_native n),'ambiguous native path keeps cold object values');
SELECT splitjson.create_table('public.root_arrays','[[0]]');
INSERT INTO root_arrays VALUES (1,'[1,2]'),(2,'5'),(3,'null'),(4,'[]'),(5,'{"0":6}');
SET splitjson.enable_query_rewrite=off;
CREATE TEMP TABLE root_native AS SELECT id,doc->0 AS value,doc->>0 AS text_value FROM root_arrays;
SET splitjson.enable_query_rewrite=on;
SELECT assert_true((SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM (SELECT id,doc->0 AS value,doc->>0 AS text_value FROM root_arrays) r)=(SELECT jsonb_agg(to_jsonb(n) ORDER BY id) FROM root_native n),'final array operator zero preserves scalar semantics');
SELECT splitjson.set_field('root_arrays',1,ARRAY['-1'],'3');
SELECT assert_true((SELECT doc='[1,3]' FROM root_arrays WHERE id=1),'root negative array update');
SELECT assert_true((SELECT array_agg(id ORDER BY id) FROM splitjson.find_ids('root_arrays',ARRAY['0'],'6') id)=ARRAY[5::bigint],'root numeric path includes object keys');
SELECT splitjson.create_table('public.rewrite_docs','[["state"],["items",0,"price"]]','{"tenant":"integer"}');
INSERT INTO rewrite_docs(id,doc,tenant) SELECT n,jsonb_build_object('state','s_'||n,'items',jsonb_build_array(jsonb_build_object('price',n)),'cold',repeat(md5(n::text),64)),n%2 FROM generate_series(1,10000) n;
SELECT splitjson.create_path_index('rewrite_docs','rewrite_json_idx',ARRAY['state']);
SELECT splitjson.create_path_index('rewrite_docs','rewrite_text_idx',ARRAY['state'],'text');
SELECT splitjson.create_path_index('rewrite_docs','rewrite_array_idx','["items",0,"price"]'::jsonb,'text');
SELECT storage_name AS rewrite_store FROM splitjson._tables WHERE view_name='public.rewrite_docs' \gset
ANALYZE :rewrite_store;
SELECT * FROM plan_lines($q$SELECT id FROM rewrite_docs WHERE doc->'state'='"s_101"'::jsonb$q$);
SELECT assert_true((SELECT bool_or(plan_lines LIKE '%rewrite_json_idx%') FROM plan_lines($q$SELECT id FROM rewrite_docs WHERE doc->'state'='"s_101"'::jsonb$q$)),'native JSONB predicate uses hot index');
SELECT * FROM plan_lines($q$SELECT id FROM rewrite_docs WHERE doc->>'state'='s_101'$q$);
SELECT assert_true((SELECT bool_or(plan_lines LIKE '%rewrite_text_idx%') FROM plan_lines($q$SELECT id FROM rewrite_docs WHERE doc->>'state'='s_101'$q$)),'native text predicate uses expression index');
SELECT assert_true((SELECT bool_or(plan_lines LIKE '%rewrite_array_idx%') FROM plan_lines($q$SELECT id FROM rewrite_docs WHERE doc->'items'->0->>'price'='101'$q$)),'typed array chain uses hot index');
SELECT assert_true((SELECT bool_and(plan_lines NOT LIKE '%rewrite_array_idx%') FROM plan_lines($q$SELECT id FROM rewrite_docs WHERE doc#>>'{items,0,price}'='101'$q$)),'runtime key/index path safely falls back');
SELECT assert_true((SELECT array_agg(id) FROM rewrite_docs r WHERE r.doc#>'{state}'='"s_101"')=ARRAY[101::bigint],'alias and native path results');
SELECT assert_true((SELECT to_jsonb(d)=jsonb_build_object('id',id,'doc',doc,'tenant',tenant) FROM rewrite_docs d WHERE doc->>'state'='s_101'),'whole-row composite keeps public columns');
SELECT assert_true((SELECT (SELECT to_jsonb(d))=jsonb_build_object('id',id,'doc',doc,'tenant',tenant) FROM rewrite_docs d WHERE doc->>'state'='s_101'),'correlated whole-row reference stays native');
SELECT assert_true((SELECT bool_and(plan_lines NOT LIKE '%rewrite_text_idx%') FROM plan_lines($q$SELECT row_to_json(d) FROM rewrite_docs d WHERE doc->>'state'='s_101'$q$)),'whole-row extraction retains native plan');
SELECT assert_true((SELECT doc->'items'->'0'->'price' FROM rewrite_docs WHERE id=101) IS NULL,'string object operator does not become array index');
SET plan_cache_mode=force_generic_plan;
PREPARE rewritten(text) AS SELECT id FROM rewrite_docs WHERE doc->>'state'=$1;
SELECT assert_true((SELECT bool_or(plan_lines LIKE '%rewrite_text_idx%') FROM plan_lines($q$EXECUTE rewritten('s_101')$q$)),'generic prepared index plan');
EXECUTE rewritten('s_101');
SET splitjson.enable_query_rewrite=off;
SELECT assert_true((SELECT bool_and(plan_lines NOT LIKE '%rewrite_text_idx%') FROM plan_lines($q$EXECUTE rewritten('s_101')$q$)),'disable invalidates prepared plan');
EXECUTE rewritten('s_101');
SET splitjson.enable_query_rewrite=on;
EXECUTE rewritten('s_101');
DROP INDEX splitjson_storage.rewrite_text_idx;
EXECUTE rewritten('s_101');
SELECT splitjson.create_path_index('rewrite_docs','rewrite_text_idx',ARRAY['state'],'text');
EXECUTE rewritten('s_101');
DEALLOCATE rewritten;
RESET plan_cache_mode;

SELECT splitjson.create_table('public.rewrite_values','[["v"]]');
INSERT INTO rewrite_values VALUES (1,'{"v":1}'),(2,'{"v":"1"}'),(3,'{"v":null}'),(4,'{}'),(5,'{"v":{"x":1}}'),(6,'{"v":[1,2]}');
SET splitjson.enable_query_rewrite=off;
CREATE TEMP TABLE native_text AS SELECT id,doc->>'v' AS v FROM rewrite_values;
SET splitjson.enable_query_rewrite=on;
SELECT assert_true((SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM (SELECT id,doc->>'v' AS v FROM rewrite_values) r)=(SELECT jsonb_agg(to_jsonb(n) ORDER BY id) FROM native_text n),'all text/null/complex value extraction semantics');
SELECT assert_true((SELECT array_agg(id ORDER BY id) FROM rewrite_values WHERE doc->>'v'='1')=ARRAY[1::bigint,2::bigint],'number and string both match native text');
SELECT assert_true((SELECT array_agg(id ORDER BY id) FROM rewrite_values WHERE doc->>'v' IS NULL)=ARRAY[3::bigint,4::bigint],'text null/missing preserved');
SELECT assert_true((SELECT count(*) FROM (VALUES (101),(20001)) ids(id) LEFT JOIN rewrite_docs d ON d.id=ids.id WHERE d.doc->>'state'='s_101')=1,'outer join null extension and predicate');
SET splitjson.enable_query_rewrite=off;
CREATE TEMP TABLE join_native AS SELECT ids.id,doc->>'state' AS state FROM (VALUES (101),(20001)) ids(id) LEFT JOIN rewrite_docs d ON d.id=ids.id;
SET splitjson.enable_query_rewrite=on;
SELECT assert_true((SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM (SELECT ids.id,doc->>'state' AS state FROM (VALUES (101),(20001)) ids(id) LEFT JOIN rewrite_docs d ON d.id=ids.id) r)=(SELECT jsonb_agg(to_jsonb(n) ORDER BY id) FROM join_native n),'outer join projected NULL values unchanged');
CREATE VIEW public.filtered_rewrite WITH (security_barrier=true) AS SELECT * FROM rewrite_docs WHERE tenant=0;
SELECT assert_true((SELECT count(*) FROM filtered_rewrite WHERE doc->>'state'='s_101')=0,'wrapper security barrier keeps row filter');
SELECT assert_true((SELECT count(*) FROM rewrite_docs WHERE (doc->>'state')::text COLLATE "C"='s_101')=1,'explicit collation semantics');
SELECT assert_true((SELECT array_agg(id) FROM rewrite_docs WHERE (doc->'items'->0->>'price')::integer=101)=ARRAY[101::bigint],'numeric cast keeps result semantics');
SET plan_cache_mode=force_generic_plan;
PREPARE dynamic_path(text[]) AS SELECT id FROM rewrite_docs WHERE doc#>>$1='s_101';
SELECT assert_true((SELECT bool_and(plan_lines NOT LIKE '%rewrite_text_idx%') FROM plan_lines($q$EXECUTE dynamic_path('{state}')$q$)),'dynamic generic path retains native plan');
EXECUTE dynamic_path('{state}');
DEALLOCATE dynamic_path;
RESET plan_cache_mode;
GRANT SELECT ON rewrite_docs,rewrite_values,array_slots TO splitjson_reader;
SET ROLE splitjson_reader;
SELECT assert_true((SELECT array_agg(id) FROM rewrite_docs WHERE doc->>'state'='s_101')=ARRAY[101::bigint],'view-only role transparent query');
SELECT expect_error($q$SELECT * FROM splitjson._tables$q$,'42501');
SELECT expect_error(format('SELECT * FROM %s', :'rewrite_store'),'42501');
RESET ROLE;
CREATE ROLE rewrite_id_only;
GRANT SELECT(id) ON rewrite_docs TO rewrite_id_only;
SET ROLE rewrite_id_only;
SELECT expect_error($q$SELECT id FROM rewrite_docs WHERE doc->>'state'='s_101'$q$,'42501');
RESET ROLE;
SELECT 'array and automatic rewrite tests passed' AS result;
