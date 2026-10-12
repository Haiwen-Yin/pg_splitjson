\set ON_ERROR_STOP on
CREATE FUNCTION public.cap_plan(q text) RETURNS jsonb LANGUAGE plpgsql AS $$ DECLARE p jsonb; BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON,COSTS OFF) '||q INTO p; RETURN p;
END $$;
SELECT splitjson.create_table('public.typed_docs','[["n"],["flag"],["s"],["subtree"]]');
INSERT INTO typed_docs SELECT i,jsonb_build_object('n',i,'flag',i%2=0,'s',lpad(i::text,5,'0'),
    'subtree',jsonb_build_object('a',jsonb_build_array(i,null))) FROM generate_series(1,10000) i;
INSERT INTO typed_docs VALUES(10001,'{"n":null,"flag":null,"s":null,"subtree":7}'),(10002,'{"subtree":null}');
SELECT splitjson.create_path_index('typed_docs','typed_n_idx',ARRAY['n'],'numeric');
SELECT splitjson.create_path_index('typed_docs','typed_flag_idx',ARRAY['flag'],'boolean');
SELECT splitjson.create_path_index('typed_docs','typed_s_idx',ARRAY['s'],'text','C');
SELECT storage_name AS typed_store FROM splitjson._tables WHERE view_name='public.typed_docs' \gset
ANALYZE :typed_store;
SELECT cap_ok((SELECT count(*)=11 FROM splitjson.find_ids_range('typed_docs',ARRAY['n'],'numeric','9950','9960',true,true)));
SELECT cap_ok((SELECT count(*)=10000 FROM splitjson.find_ids_range('typed_docs',ARRAY['n'],'numeric')));
SELECT cap_ok((SELECT count(*)=5000 FROM splitjson.find_ids_range('typed_docs',ARRAY['flag'],'boolean','false','true',true,false)));
SELECT cap_ok((SELECT count(*)=10 FROM splitjson.find_ids_range('typed_docs',ARRAY['s'],'text','"09950"','"09960"',true,false,'C')));
SELECT cap_fails($q$SELECT splitjson.set_field('typed_docs',1,ARRAY['n'],'"2"')$q$,'23514');
SELECT cap_fails($q$SELECT splitjson.set_field('typed_docs',1,ARRAY['flag'],'1')$q$,'23514');
SELECT cap_fails($q$SELECT splitjson.find_ids_range('typed_docs',ARRAY['n'],'numeric','"1"')$q$,'22023');
SELECT cap_plan('SELECT id FROM typed_docs WHERE (doc->>''n'')::numeric>=9950 AND (doc->>''n'')::numeric<=9960');
SELECT cap_ok(cap_plan('SELECT id FROM typed_docs WHERE (doc->>''n'')::numeric>=9950 AND (doc->>''n'')::numeric<=9960')::text LIKE '%typed_n_idx%');
SELECT cap_ok(cap_plan('SELECT id FROM typed_docs WHERE (doc->>''s'') COLLATE "C">=''09950'' AND (doc->>''s'') COLLATE "C"<''09960''')::text LIKE '%typed_s_idx%');
SELECT cap_ok(cap_plan('SELECT doc #> ''{subtree,a,0}'' FROM typed_docs WHERE id=1')::text NOT LIKE '%restore%');
CREATE TEMP TABLE suffix_on AS SELECT id,doc #> '{subtree,a,0}' j,doc #>> '{subtree,a,-1}' t,
    doc->'subtree'->0 scalar_zero, doc#>'{subtree,0}' scalar_path FROM typed_docs;
SET splitjson.enable_query_rewrite=off;
CREATE TEMP TABLE suffix_off AS SELECT id,doc #> '{subtree,a,0}' j,doc #>> '{subtree,a,-1}' t,
    doc->'subtree'->0 scalar_zero, doc#>'{subtree,0}' scalar_path FROM typed_docs;
SET splitjson.enable_query_rewrite=on;
SELECT cap_ok(NOT EXISTS((SELECT * FROM suffix_on EXCEPT SELECT * FROM suffix_off) UNION ALL (SELECT * FROM suffix_off EXCEPT SELECT * FROM suffix_on)));
-- Build and attach a real parent B-tree through the emitted individual steps.
SELECT splitjson.partition_index_ddl('cap_part','part_text_idx','["state"]','text','C') \gexec
SELECT cap_ok((SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid='splitjson_storage.part_text_idx'::regclass));
SELECT splitjson.create_partitioned_table('public.range_docs','[["n"]]','{"label":"text"}', '[{"from":null,"to":10},{"from":10,"to":20}]');
INSERT INTO range_docs VALUES(1,'{"n":1}','one'),(11,'{"n":11}','two');
SELECT splitjson.create_partition('range_docs','range_later',20,NULL);
UPDATE range_docs SET id=21,label='moved' WHERE id=1;
SELECT cap_ok((SELECT doc->'n'='1' AND label='moved' FROM range_docs WHERE id=21));
SELECT cap_ok(cap_plan('SELECT id FROM range_docs WHERE id=21')::text LIKE '%range_later%');
SELECT cap_ok(cap_plan('SELECT id FROM range_docs WHERE id=21')::text NOT LIKE '%Append%');
PREPARE generic_range(numeric) AS SELECT id FROM typed_docs WHERE (doc->>'n')::numeric >= $1;
EXECUTE generic_range(9999);
SELECT cap_ok((SELECT count(*)=2 FROM typed_docs WHERE (doc->>'n')::numeric >= 9999));
CREATE TABLE public.planning_join(id bigint);
SELECT cap_ok(cap_plan('SELECT d.id FROM typed_docs d LEFT JOIN public.planning_join u ON u.id=d.id WHERE (d.doc->>''n'')::numeric=1')::text NOT LIKE '%restore%');
SELECT cap_ok(cap_plan('SELECT id FROM cap_docs WHERE (doc->>''counter'')::numeric=1')::text NOT LIKE '%Index%');
SELECT splitjson.detach_partition('range_docs','splitjson_storage.range_later');
SELECT cap_ok((SELECT count(*)=1 FROM range_docs));
SELECT cap_ok((SELECT count(*)=1 FROM splitjson_storage.range_later));
SELECT splitjson.attach_partition('range_docs','splitjson_storage.range_later',20,NULL);
SELECT cap_ok((SELECT count(*)=2 FROM range_docs));
SELECT cap_fails($q$SELECT splitjson.create_partitioned_table('public.bad_part','[["n"]]','{}','[{"from":"0) --","to":20}]')$q$,'22023');
SELECT cap_fails($q$SELECT splitjson.create_partitioned_table('public.bad_part','[["n"]]','{}','{"strategy":"hash","modulus":2,"key":"tenant"}')$q$,'22023');
CREATE TABLE public.unrelated_guard(id integer);
CREATE FUNCTION public.unrelated_trigger() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
CREATE TRIGGER pg_splitjson_write BEFORE INSERT ON unrelated_guard FOR EACH ROW EXECUTE FUNCTION unrelated_trigger();
DROP TRIGGER pg_splitjson_write ON unrelated_guard;
SELECT cap_ok((splitjson.check_table('range_docs',true)->>'rows_checked')::int=2);
SELECT 'typed indexes, suffix rewrite and native partition planning passed';
