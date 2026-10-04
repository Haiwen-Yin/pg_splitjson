\set ON_ERROR_STOP on
\timing on
SELECT version();
SHOW wal_compression;
SHOW full_page_writes;
SHOW block_size;
SELECT splitjson.create_table('public.bench_split','[["counter"]]');
CREATE TABLE bench_jsonb (id bigint PRIMARY KEY,doc jsonb NOT NULL) WITH (fillfactor=70);
ALTER TABLE bench_jsonb ALTER COLUMN doc SET STORAGE EXTERNAL;
INSERT INTO bench_jsonb SELECT 1,jsonb_build_object('counter',0,
    'payload',(SELECT string_agg(md5(i::text),'') FROM generate_series(1,8192) AS i));
INSERT INTO bench_split SELECT * FROM bench_jsonb;
CREATE TEMP TABLE benchmark_results (implementation text,updates integer,wal_bytes numeric,elapsed_ms numeric);
SELECT pg_column_size(doc) AS jsonb_bytes FROM bench_jsonb;

CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS start_lsn, clock_timestamp() AS start_time \gset
DO $$ BEGIN
    FOR i IN 1..300 LOOP
        UPDATE bench_jsonb SET doc=jsonb_set(doc,'{counter}',to_jsonb(i)) WHERE id=1;
    END LOOP;
END $$;
INSERT INTO benchmark_results SELECT 'native_jsonb',300,
    pg_wal_lsn_diff(pg_current_wal_insert_lsn(),:'start_lsn'::pg_lsn),
    extract(epoch FROM clock_timestamp()-:'start_time'::timestamptz)*1000;

CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS start_lsn, clock_timestamp() AS start_time \gset
DO $$ BEGIN
    FOR i IN 1..300 LOOP
        PERFORM splitjson.set_field('bench_split',1,ARRAY['counter'],to_jsonb(i));
    END LOOP;
END $$;
INSERT INTO benchmark_results SELECT 'pg_splitjson_hot',300,
    pg_wal_lsn_diff(pg_current_wal_insert_lsn(),:'start_lsn'::pg_lsn),
    extract(epoch FROM clock_timestamp()-:'start_time'::timestamptz)*1000;

TABLE benchmark_results;
SELECT round(a.wal_bytes/b.wal_bytes,2) AS wal_reduction_factor,
       round(a.elapsed_ms/b.elapsed_ms,2) AS elapsed_ratio
FROM benchmark_results a,benchmark_results b WHERE a.implementation='native_jsonb' AND b.implementation='pg_splitjson_hot';
SELECT assert_true((SELECT doc FROM bench_jsonb WHERE id=1)=(SELECT doc FROM bench_split WHERE id=1),'benchmark final docs agree');
SELECT assert_true((SELECT wal_bytes FROM benchmark_results WHERE implementation='native_jsonb')>
                   (SELECT wal_bytes*10 FROM benchmark_results WHERE implementation='pg_splitjson_hot'),'hot updates substantially reduce WAL for large fixture');
SELECT 'benchmark passed (single-session fixture, not production capacity)' AS result;

SELECT splitjson.create_table('public.bench_array_split','[["items",0,"counter"]]');
CREATE TABLE bench_array_jsonb (id bigint PRIMARY KEY,doc jsonb NOT NULL) WITH (fillfactor=70);
ALTER TABLE bench_array_jsonb ALTER COLUMN doc SET STORAGE EXTERNAL;
INSERT INTO bench_array_jsonb SELECT 1,jsonb_build_object('items','[{"counter":0}]'::jsonb,
    'payload',(SELECT string_agg(md5(i::text),'') FROM generate_series(1,8192) i));
INSERT INTO bench_array_split SELECT * FROM bench_array_jsonb;
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS start_lsn, clock_timestamp() AS start_time \gset
DO $$ BEGIN
    FOR i IN 1..300 LOOP UPDATE bench_array_jsonb SET doc=jsonb_set(doc,'{items,0,counter}',to_jsonb(i)) WHERE id=1; END LOOP;
END $$;
INSERT INTO benchmark_results SELECT 'native_jsonb_array',300,
    pg_wal_lsn_diff(pg_current_wal_insert_lsn(),:'start_lsn'::pg_lsn),
    extract(epoch FROM clock_timestamp()-:'start_time'::timestamptz)*1000;
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS start_lsn, clock_timestamp() AS start_time \gset
DO $$ BEGIN
    FOR i IN 1..300 LOOP PERFORM splitjson.set_field('bench_array_split',1,ARRAY['items','0','counter'],to_jsonb(i)); END LOOP;
END $$;
INSERT INTO benchmark_results SELECT 'pg_splitjson_array_hot',300,
    pg_wal_lsn_diff(pg_current_wal_insert_lsn(),:'start_lsn'::pg_lsn),
    extract(epoch FROM clock_timestamp()-:'start_time'::timestamptz)*1000;
TABLE benchmark_results;
SELECT assert_true((SELECT doc FROM bench_array_jsonb)=(SELECT doc FROM bench_array_split),'array benchmark final docs agree');
SELECT assert_true((SELECT wal_bytes FROM benchmark_results WHERE implementation='native_jsonb_array')>
    (SELECT wal_bytes*10 FROM benchmark_results WHERE implementation='pg_splitjson_array_hot'),'array hot updates reduce WAL for large fixture');
SET splitjson.enable_query_rewrite=off;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT id FROM rewrite_docs WHERE doc->>'state'='s_101';
SET splitjson.enable_query_rewrite=on;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT id FROM rewrite_docs WHERE doc->>'state'='s_101';
SELECT 'array and query benchmark passed (workload-specific)' AS result;
