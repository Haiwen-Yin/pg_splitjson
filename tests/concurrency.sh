#!/usr/bin/env bash
set -Eeuo pipefail
pgbin=$1
psql_cmd=("$pgbin/psql" -X -v ON_ERROR_STOP=1)
work=$(mktemp -d /tmp/pg_splitjson-concurrency.XXXXXX)
children=()
cleanup() {
    for pid in "${children[@]}"; do wait "$pid" || true; done
    cat "$work"/*.log
    rm -rf "$work"
}
trap cleanup EXIT
wait_for_sleep() {
    local app=$1 ready
    for attempt in {1..100}; do
        ready=$("${psql_cmd[@]}" -Atc "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name='$app' AND wait_event='PgSleep')")
        if [[ "$ready" = t ]]; then return 0; fi
        sleep 0.05
    done
    printf 'Timed out waiting for %s\n' "$app" >&2
    return 1
}

PGAPPNAME=pg_splitjson-concurrency-a "${psql_cmd[@]}" >"$work/a.log" 2>&1 <<'SQL' &
BEGIN;
SELECT splitjson.set_field('concurrent_docs',1,ARRAY['left'],'10');
SELECT pg_sleep(2);
COMMIT;
SQL
a=$!; children+=("$a")
wait_for_sleep pg_splitjson-concurrency-a
"${psql_cmd[@]}" >"$work/b.log" 2>&1 <<'SQL' &
BEGIN;
SELECT splitjson.set_field('concurrent_docs',1,ARRAY['right'],'20');
COMMIT;
SQL
b=$!; children+=("$b")
wait "$a"; wait "$b"
"${psql_cmd[@]}" -c "SELECT assert_true((SELECT doc='{\"left\":10,\"right\":20,\"cold\":0}'::jsonb FROM concurrent_docs WHERE id=1), 'two hot writers retain both fields')"

PGAPPNAME=pg_splitjson-concurrency-a "${psql_cmd[@]}" >"$work/a.log" 2>&1 <<'SQL' &
BEGIN;
SELECT splitjson.set_field('concurrent_docs',1,ARRAY['left'],'30');
SELECT pg_sleep(2);
COMMIT;
SQL
a=$!; children+=("$a")
wait_for_sleep pg_splitjson-concurrency-a
"${psql_cmd[@]}" >"$work/b.log" 2>&1 <<'SQL' &
BEGIN;
SELECT splitjson.set_field('concurrent_docs',1,ARRAY['cold'],'40');
COMMIT;
SQL
b=$!; children+=("$b")
wait "$a"; wait "$b"
"${psql_cmd[@]}" -c "SELECT assert_true((SELECT doc='{\"left\":30,\"right\":20,\"cold\":40}'::jsonb FROM concurrent_docs WHERE id=1), 'hot and cold writers retain both fields')"

PGAPPNAME=pg_splitjson-snapshot "${psql_cmd[@]}" >"$work/snapshot.log" 2>&1 <<'SQL' &
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT assert_true((SELECT doc->'left'='30' FROM concurrent_docs WHERE id=1),'old MVCC snapshot before');
SELECT assert_true(splitjson.get_field('concurrent_docs',1,ARRAY['left'])='30','direct field old MVCC snapshot before');
SELECT pg_sleep(2);
SELECT assert_true((SELECT doc->'left'='30' FROM concurrent_docs WHERE id=1),'old MVCC snapshot after');
SELECT assert_true(splitjson.get_field('concurrent_docs',1,ARRAY['left'])='30','direct field old MVCC snapshot after');
SELECT assert_true((SELECT array_agg(id) FROM splitjson.find_ids('concurrent_docs',ARRAY['left'],'30') AS id)=ARRAY[1::bigint],
    'field query honors old MVCC snapshot');
COMMIT;
SQL
snapshot=$!; children+=("$snapshot")
wait_for_sleep pg_splitjson-snapshot
"${psql_cmd[@]}" -c "SELECT splitjson.set_field('concurrent_docs',1,ARRAY['left'],'50')"
wait "$snapshot"
"${psql_cmd[@]}" -c "SELECT assert_true((SELECT doc->'left'='50' FROM concurrent_docs WHERE id=1), 'new MVCC snapshot sees commit')"

PGAPPNAME=pg_splitjson-concurrency-a "${psql_cmd[@]}" >"$work/a.log" 2>&1 <<'SQL' &
BEGIN;
SELECT splitjson.set_field('concurrent_docs',1,ARRAY['left'],'60');
SELECT pg_sleep(2);
COMMIT;
SQL
a=$!; children+=("$a")
wait_for_sleep pg_splitjson-concurrency-a
"${psql_cmd[@]}" >"$work/b.log" 2>&1 <<'SQL' &
SELECT expect_error($q$UPDATE concurrent_docs SET doc=jsonb_set(doc,'{cold}','99') WHERE id=1$q$,'40001');
SQL
b=$!; children+=("$b")
wait "$a"; wait "$b"
"${psql_cmd[@]}" <<'SQL'
SELECT assert_true((SELECT doc->'left'='60' AND doc->'cold'='40' FROM concurrent_docs WHERE id=1), 'stale ordinary UPDATE cannot overwrite hot commit');
UPDATE concurrent_docs SET doc=jsonb_set(doc,'{cold}','99') WHERE id=1;
SELECT assert_true((SELECT doc->'left'='60' AND doc->'cold'='99' FROM concurrent_docs WHERE id=1), 'ordinary UPDATE retry succeeds');
SQL

PGAPPNAME=pg_splitjson-concurrency-a "${psql_cmd[@]}" >"$work/a.log" 2>&1 <<'SQL' &
BEGIN;
SELECT splitjson.set_field('concurrent_docs',1,ARRAY['left'],'70');
SELECT pg_sleep(2);
COMMIT;
SQL
a=$!; children+=("$a")
wait_for_sleep pg_splitjson-concurrency-a
"${psql_cmd[@]}" >"$work/b.log" 2>&1 <<'SQL' &
SELECT expect_error($q$DELETE FROM concurrent_docs WHERE id=1 AND doc->'left'='60'$q$,'40001');
SQL
b=$!; children+=("$b")
wait "$a"; wait "$b"
"${psql_cmd[@]}" -c "SELECT assert_true((SELECT doc->'left'='70' FROM concurrent_docs WHERE id=1), 'stale ordinary DELETE cannot remove changed row')"

"${psql_cmd[@]}" <<'SQL'
SELECT splitjson.create_table('public.atomic_docs','[["counter"],["right"]]','{"label":"text"}');
INSERT INTO atomic_docs(id,doc,label) VALUES (1,'{"counter":0,"right":0,"cold_counter":0}','before');
SQL
increment_workers=()
for worker in 1 2 3; do
    (
        for iteration in {1..100}; do
            printf '%s\n' "SELECT splitjson.increment_field('atomic_docs',1,ARRAY['counter']);"
        done
    ) | "${psql_cmd[@]}" >"$work/increment-$worker.log" 2>&1 &
    increment_workers+=("$!")
    children+=("$!")
done
for pid in "${increment_workers[@]}"; do wait "$pid"; done
"${psql_cmd[@]}" -c "SELECT assert_true((SELECT doc->'counter'='300' AND label='before' FROM atomic_docs WHERE id=1), '300 concurrent autocommit increments have no lost update')"

PGAPPNAME=pg_splitjson-concurrency-a "${psql_cmd[@]}" >"$work/a.log" 2>&1 <<'SQL' &
BEGIN;
SELECT splitjson.set_fields('atomic_docs',1,'[{"path":["counter"],"value":10},{"path":["right"],"value":20}]');
SELECT pg_sleep(2);
COMMIT;
SQL
a=$!; children+=("$a")
wait_for_sleep pg_splitjson-concurrency-a
"${psql_cmd[@]}" -c "SELECT splitjson.increment_field('atomic_docs',1,ARRAY['counter'])" >"$work/b.log" 2>&1 &
b=$!; children+=("$b")
wait "$a"; wait "$b"
"${psql_cmd[@]}" -c "SELECT assert_true((SELECT doc->'counter'='11' AND doc->'right'='20' FROM atomic_docs WHERE id=1), 'batch and increment preserve committed values')"

PGAPPNAME=pg_splitjson-concurrency-a "${psql_cmd[@]}" >"$work/a.log" 2>&1 <<'SQL' &
BEGIN;
UPDATE atomic_docs SET label='changed' WHERE id=1;
SELECT pg_sleep(2);
COMMIT;
SQL
a=$!; children+=("$a")
wait_for_sleep pg_splitjson-concurrency-a
"${psql_cmd[@]}" <<'SQL' >"$work/b.log" 2>&1 &
SELECT expect_error($q$UPDATE atomic_docs SET doc=jsonb_set(doc,'{right}','99') WHERE id=1$q$,'40001');
SQL
b=$!; children+=("$b")
wait "$a"; wait "$b"
"${psql_cmd[@]}" -c "SELECT assert_true((SELECT label='changed' AND doc->'right'='20' FROM atomic_docs WHERE id=1), 'stale JSON UPDATE cannot overwrite concurrent business column')"
printf '%s\n' 'concurrency, MVCC, atomic increments, batches and business-column conflict tests passed'

"${psql_cmd[@]}" <<'SQL'
SELECT splitjson.create_table('public.atomic_arrays','[["items",0,"n"],["hot_array"]]');
INSERT INTO atomic_arrays VALUES (1,'{"items":[{"n":0}],"hot_array":[{"n":0}],"cold":1}');
SQL
array_workers=()
for worker in 1 2 3; do
    (
        for iteration in {1..50}; do
            printf '%s\n' "SELECT splitjson.increment_field('atomic_arrays',1,ARRAY['items','0','n']);" \
                "SELECT splitjson.increment_field('atomic_arrays',1,ARRAY['hot_array','0','n']);"
        done
    ) | "${psql_cmd[@]}" >"$work/array-$worker.log" 2>&1 &
    array_workers+=("$!")
    children+=("$!")
done
for pid in "${array_workers[@]}"; do wait "$pid"; done
"${psql_cmd[@]}" -c "SELECT assert_true((SELECT doc#>'{items,0,n}'='150' AND doc#>'{hot_array,0,n}'='150' AND doc->'cold'='1' FROM atomic_arrays), 'concurrent fixed array and subtree increments have no lost updates')"
printf '%s\n' 'array concurrency tests passed'
