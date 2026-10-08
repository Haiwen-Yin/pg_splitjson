\set ON_ERROR_STOP on
CREATE EXTENSION pg_splitjson VERSION '0.1.0';
LOAD 'pg_splitjson';
SELECT splitjson.create_table('public.upgrade_docs','[["n"],["items",0,"n"]]','{"label":"text"}');
INSERT INTO upgrade_docs(id,doc,label) SELECT 1,jsonb_build_object('n',1,'items','[{"n":2}]'::jsonb,
    'cold',(SELECT string_agg(md5(i::text),'') FROM generate_series(1,8192) i)),'original';
SELECT splitjson.create_path_index('upgrade_docs','upgrade_n_idx',ARRAY['n']);
CREATE TEMP TABLE before_upgrade AS SELECT s.*,cold::text AS wire FROM splitjson_storage.s_1 s;
CREATE TEMP TABLE before_chunks(chunk_id oid,chunk_seq integer,chunk_data bytea);
-- Obtain actual chunks without assuming relation OIDs.
DO $$ DECLARE toast_table regclass; BEGIN
    SELECT reltoastrelid::regclass INTO toast_table FROM pg_class WHERE oid='splitjson_storage.s_1'::regclass;
    EXECUTE format('INSERT INTO before_chunks SELECT chunk_id,chunk_seq,chunk_data FROM %s',toast_table);
END$$;
ALTER EXTENSION pg_splitjson UPDATE TO '0.2.0';
DO $$ DECLARE toast_table regclass; matches boolean; BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname='pg_splitjson')<>'0.2.0' OR
       (SELECT cold::text FROM splitjson_storage.s_1)<>
       (SELECT wire FROM before_upgrade) THEN RAISE EXCEPTION 'upgrade changed cold'; END IF;
    SELECT reltoastrelid::regclass INTO toast_table FROM pg_class WHERE oid='splitjson_storage.s_1'::regclass;
    EXECUTE format('SELECT NOT EXISTS((SELECT * FROM before_chunks EXCEPT SELECT chunk_id,chunk_seq,chunk_data FROM %s) '
                   'UNION ALL (SELECT chunk_id,chunk_seq,chunk_data FROM %s EXCEPT SELECT * FROM before_chunks))',toast_table,toast_table)
        INTO matches;
    IF NOT matches THEN RAISE EXCEPTION 'upgrade rewrote TOAST'; END IF;
    IF splitjson.increment_field('upgrade_docs',1,ARRAY['items','0','n'])<>3 THEN RAISE EXCEPTION 'upgraded API failed'; END IF;
    IF (splitjson.check_table('upgrade_docs',true)->>'rows_checked')::integer<>1 THEN RAISE EXCEPTION 'upgraded check failed'; END IF;
END$$;
SELECT 'official 0.1.0 -> 0.2.0 upgrade passed; cold and chunks preserved' AS result;
