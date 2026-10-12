\set ON_ERROR_STOP on
CREATE EXTENSION pageinspect;
CREATE EXTENSION pg_splitjson VERSION '0.1.0';
CREATE FUNCTION public.up_ok(p boolean) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
    IF p IS DISTINCT FROM true THEN RAISE EXCEPTION 'upgrade assertion failed'; END IF;
END $$;
CREATE FUNCTION public.up_ptr(s regclass) RETURNS bytea LANGUAGE plpgsql AS $$
DECLARE tid tid; b bigint; l integer; p bytea;
BEGIN
    EXECUTE format('SELECT ctid FROM %s WHERE id=1',s) INTO tid;
    b:=split_part(trim(both '()' from tid::text),',',1)::bigint; l:=split_part(trim(both '()' from tid::text),',',2)::integer;
    SELECT t_attrs[2] INTO p FROM heap_page_item_attrs(get_raw_page(s::text,b),s,false) WHERE lp=l;
    RETURN p;
END $$;
SELECT splitjson.create_table('public.upgrade_030_docs','[["counter"]]');
INSERT INTO upgrade_030_docs VALUES(1,jsonb_build_object('counter',1,'cold',(SELECT string_agg(md5(i::text),'') FROM generate_series(1,8192) i)));
ALTER EXTENSION pg_splitjson UPDATE TO '0.2.0';
CREATE ROLE up_030_reader;
SELECT splitjson.grant_access('upgrade_030_docs','up_030_reader','read');
CREATE TEMP TABLE up_before AS SELECT up_ptr('splitjson_storage.s_1') ptr,
    (SELECT jsonb_agg(to_jsonb(a) ORDER BY attnum) FROM pg_attribute a WHERE attrelid='upgrade_030_docs'::regclass AND attnum>0) descriptor,
    'splitjson.get_field(regclass,bigint,text[])'::regprocedure::oid helper_oid,
    'splitjson._view_write()'::regprocedure::oid trigger_oid,
    md5(cold::text) cold_digest FROM splitjson_storage.s_1;
ALTER EXTENSION pg_splitjson UPDATE TO '0.3.0';
SELECT up_ok(up_ptr('splitjson_storage.s_1')=ptr AND octet_length(ptr)=18) FROM up_before;
SELECT up_ok((SELECT jsonb_agg(to_jsonb(a) ORDER BY attnum) FROM pg_attribute a WHERE attrelid='upgrade_030_docs'::regclass AND attnum>0)=descriptor AND
    'splitjson.get_field(regclass,bigint,text[])'::regprocedure::oid=helper_oid AND
    'splitjson._view_write()'::regprocedure::oid=trigger_oid) FROM up_before;
SELECT up_ok((SELECT md5(cold::text) FROM splitjson_storage.s_1)=cold_digest) FROM up_before;
SELECT up_ok((SELECT row_revision=0 FROM splitjson_storage.s_1));
SET ROLE up_030_reader;
SELECT public.up_ok(splitjson.get_field('upgrade_030_docs',1,ARRAY['counter'])='1');
RESET ROLE;
SELECT up_ok(splitjson.increment_field('upgrade_030_docs',1,ARRAY['counter'])=2);
SELECT up_ok(up_ptr('splitjson_storage.s_1')=ptr) FROM up_before;
SELECT up_ok((SELECT row_revision>0 FROM splitjson_storage.s_1));
SELECT up_ok((splitjson.check_table('upgrade_030_docs',true)->>'layout_ok')::boolean);
CREATE TEMP TABLE up_token AS SELECT splitjson.row_revision('upgrade_030_docs',1) t;
SELECT splitjson.reinitialize_table('upgrade_030_docs','restore');
SELECT up_ok((SELECT splitjson.row_revision('upgrade_030_docs',1)<>t FROM up_token));
SELECT up_ok(up_ptr('splitjson_storage.s_1')=ptr) FROM up_before;
SELECT '0.1.0 -> 0.2.0 -> 0.3.0 preserves cold pointer, descriptor, function OIDs and grants';
