\set ON_ERROR_STOP on
CREATE EXTENSION pageinspect;
CREATE FUNCTION public.toast_state(p_table regclass) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE toast_table regclass; state jsonb;
BEGIN
    SELECT reltoastrelid::regclass INTO toast_table FROM pg_class WHERE oid=p_table;
    EXECUTE format('SELECT jsonb_build_object(''chunks'',count(*),''ids'',array_agg(DISTINCT chunk_id),'
                   '''bytes'',sum(octet_length(chunk_data)),''digest'',md5(string_agg(encode(chunk_data,''hex''),'''' ORDER BY chunk_id,chunk_seq))) FROM %s', toast_table)
        INTO state;
    RETURN state;
END $$;
CREATE FUNCTION public.cold_pointer(p_table regclass,p_id bigint) RETURNS bytea LANGUAGE plpgsql AS $$
DECLARE tuple_id text; block_num bigint; item_num integer; pointer bytea;
BEGIN
    EXECUTE format('SELECT ctid::text FROM %s WHERE id=$1',p_table) INTO tuple_id USING p_id;
    block_num := split_part(trim(both '()' from tuple_id),',',1)::bigint;
    item_num := split_part(trim(both '()' from tuple_id),',',2)::integer;
    SELECT t_attrs[2] INTO pointer FROM heap_page_item_attrs(get_raw_page(p_table::text,block_num),p_table,false) WHERE lp=item_num;
    RETURN pointer;
END $$;

SELECT splitjson.create_table('public.physical_docs','[["counter"],["nested","state"]]','{"label":"text"}');
INSERT INTO physical_docs(id,doc,label) SELECT 1,jsonb_build_object('counter',0,'nested',jsonb_build_object('state','new'),
    'payload',(SELECT string_agg(md5(i::text),'') FROM generate_series(1,8192) AS i)),'before';
SELECT storage_name AS physical_store FROM splitjson._tables WHERE view_name='public.physical_docs' \gset
CREATE TEMP TABLE physical_before AS SELECT toast_state(:'physical_store'::regclass) AS toast,
    cold_pointer(:'physical_store'::regclass,1) AS pointer;
SELECT assert_true(octet_length(pointer)=18 AND (toast->>'chunks')::bigint>100,'large external TOAST pointer fixture') FROM physical_before;
DO $$ BEGIN
    FOR i IN 1..100 LOOP
        PERFORM splitjson.set_field('physical_docs',1,ARRAY['counter'],to_jsonb(i));
        PERFORM splitjson.set_field('physical_docs',1,ARRAY['nested','state'],to_jsonb('ready'::text));
    END LOOP;
END $$;
SELECT assert_true(toast_state(:'physical_store'::regclass)=toast,'fast updates preserve all TOAST ids/chunks/bytes/digest') FROM physical_before;
SELECT assert_true(cold_pointer(:'physical_store'::regclass,1)=pointer,'fast updates preserve raw external TOAST pointer') FROM physical_before;
SELECT assert_true((SELECT doc->'counter'='100' AND doc#>'{nested,state}'='"ready"' FROM physical_docs WHERE id=1),'fast updates visible');
SELECT splitjson.set_fields('physical_docs',1,
    '[{"path":["counter"],"value":101},{"path":["nested","state"],"value":"batch"}]');
SELECT assert_true(cold_pointer(:'physical_store'::regclass,1)=pointer AND toast_state(:'physical_store'::regclass)=toast,
    'batch preserves raw cold pointer and chunks') FROM physical_before;
SELECT assert_true(splitjson.increment_field('physical_docs',1,ARRAY['counter'],0.5)=101.5,'physical hot increment result');
SELECT assert_true(cold_pointer(:'physical_store'::regclass,1)=pointer,'numeric increment preserves raw cold pointer') FROM physical_before;
SELECT splitjson.create_path_index('physical_docs','physical_counter_idx',ARRAY['counter']);
SELECT splitjson.increment_field('physical_docs',1,ARRAY['counter'],0.5);
SELECT assert_true(cold_pointer(:'physical_store'::regclass,1)=pointer AND toast_state(:'physical_store'::regclass)=toast,
    'indexed hot update preserves cold pointer and TOAST chunks') FROM physical_before;
SELECT assert_true((SELECT array_agg(id) FROM splitjson.find_ids('physical_docs',ARRAY['counter'],'102') AS id)=ARRAY[1::bigint],
    'indexed hot update is searchable');
UPDATE physical_docs SET label='changed' WHERE id=1;
SELECT assert_true(cold_pointer(:'physical_store'::regclass,1)=pointer AND toast_state(:'physical_store'::regclass)=toast,
    'business-column-only UPDATE preserves cold pointer and chunks') FROM physical_before;
SELECT splitjson.set_field('physical_docs',1,ARRAY['cold_extra'],'true');
SELECT assert_true(cold_pointer(:'physical_store'::regclass,1)<>pointer,'fallback replaces cold external pointer') FROM physical_before;
SELECT assert_true((SELECT doc->'counter'='102' AND doc->'cold_extra'='true' FROM physical_docs WHERE id=1),'fallback preserves hot values');

SELECT splitjson.create_table('public.physical_arrays','[["items",0,"n"],["hot_array"]]');
INSERT INTO physical_arrays SELECT 1,jsonb_build_object('items','[{"n":0},{"n":1}]'::jsonb,
    'hot_array','[{"n":0},null,[1,2]]'::jsonb,
    'body',(SELECT string_agg(md5(i::text),'') FROM generate_series(1,8192) i));
SELECT storage_name AS physical_array_store FROM splitjson._tables WHERE view_name='public.physical_arrays' \gset
SELECT splitjson.create_path_index('physical_arrays','physical_array_n_idx','["items",0,"n"]'::jsonb);
CREATE TEMP TABLE physical_array_before AS SELECT toast_state(:'physical_array_store'::regclass) AS toast,
    cold_pointer(:'physical_array_store'::regclass,1) AS pointer;
SELECT assert_true(octet_length(pointer)=18,'array external cold pointer fixture') FROM physical_array_before;
DO $$ BEGIN
    FOR i IN 1..100 LOOP
        PERFORM splitjson.increment_field('physical_arrays',1,ARRAY['items','0','n']);
        PERFORM splitjson.set_fields('physical_arrays',1,
            '[{"path":["hot_array","0","n"],"value":7},{"path":["hot_array","2","-1"],"value":8}]');
    END LOOP;
END $$;
SELECT splitjson.delete_field('physical_arrays',1,ARRAY['hot_array','1']);
SELECT assert_true(cold_pointer(:'physical_array_store'::regclass,1)=pointer AND
    toast_state(:'physical_array_store'::regclass)=toast,'indexed array leaf and hot array subtree reuse cold pointer/chunks') FROM physical_array_before;
SELECT assert_true((SELECT doc#>'{items,0,n}'='100' AND doc#>'{hot_array,1,-1}'='8' FROM physical_arrays),'array physical logical values');
SELECT splitjson.delete_field('physical_arrays',1,ARRAY['items','0']);
SELECT assert_true(cold_pointer(:'physical_array_store'::regclass,1)<>pointer,'array position shift repacks cold pointer') FROM physical_array_before;
SELECT assert_true(splitjson.get_field('physical_arrays',1,ARRAY['items','0','n'])='1','array shift updates indexed slot');
SELECT 'physical TOAST tests passed' AS result;
