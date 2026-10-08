#!/usr/bin/env bash
# Bounded workload evidence for a fresh lab. Numbers are workload-specific.
set -Eeuo pipefail

pgbin=$1
duration=${PG_SPLITJSON_BENCH_SECONDS:-8}
clients=${PG_SPLITJSON_BENCH_CLIENTS:-4}
scale=${PG_SPLITJSON_BENCH_SCALE:-200}
db=splitjson_benchmark
work=$(mktemp -d /tmp/pg_splitjson-benchmark.XXXXXX)
run_as=${PG_SPLITJSON_RUN_AS:-$(id -un)}
if [[ $(id -u) = 0 ]]; then
    run_pg() {
        runuser -u "$run_as" -- env \
            PGHOST="${PGHOST-}" PGPORT="${PGPORT-}" PGUSER="$run_as" PGDATABASE="${PGDATABASE-}" \
            "$@"
    }
else
    run_pg() { "$@"; }
fi
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

psql_cmd() {
    if [[ $(id -u) = 0 ]]; then
        runuser -u "$run_as" -- env PGHOST="${PGHOST:?}" PGPORT="${PGPORT:?}" \
            PGUSER="$run_as" PGDATABASE="$db" "$pgbin/psql" -X -v ON_ERROR_STOP=1 "$@"
    else
        PGDATABASE="$db" "$pgbin/psql" -X -v ON_ERROR_STOP=1 "$@"
    fi
}
postgres_cmd() {
    if [[ $(id -u) = 0 ]]; then
        runuser -u "$run_as" -- env PGHOST="${PGHOST:?}" PGPORT="${PGPORT:?}" \
            PGUSER="$run_as" PGDATABASE=postgres "$pgbin/psql" -X -v ON_ERROR_STOP=1 "$@"
    else
        PGDATABASE=postgres "$pgbin/psql" -X -v ON_ERROR_STOP=1 "$@"
    fi
}

postgres_cmd -c "DROP DATABASE IF EXISTS $db" >/dev/null
postgres_cmd -c "CREATE DATABASE $db" >/dev/null
psql_cmd <<SQL
CREATE EXTENSION pg_splitjson;
SELECT splitjson.create_table('public.split_load','[["state"],["counter"],["items",0,"price"]]');
CREATE TABLE public.native_load (id bigint PRIMARY KEY, doc jsonb NOT NULL) WITH (fillfactor=70);
ALTER TABLE public.native_load ALTER COLUMN doc SET STORAGE EXTERNAL;
INSERT INTO public.native_load
SELECT g, jsonb_build_object('state',CASE WHEN g % 2=0 THEN 'ready' ELSE 'new' END,
    'counter',0,'items',jsonb_build_array(jsonb_build_object('price',g)),
    'cold_key','cold-value','payload',repeat(md5(g::text),512))
FROM generate_series(1,$scale) AS g;
INSERT INTO public.split_load SELECT * FROM public.native_load;
SELECT splitjson.create_path_index('public.split_load','split_load_state_idx',ARRAY['state'],'text');
ANALYZE public.native_load;
ANALYZE splitjson_storage.s_1;
SQL

cat >"$work/split_hot_same.sql" <<'SQL'
SELECT splitjson.increment_field('public.split_load',1,ARRAY['counter']);
SQL
cat >"$work/native_hot_same.sql" <<'SQL'
UPDATE public.native_load SET doc=jsonb_set(doc,'{counter}',to_jsonb((doc->>'counter')::integer+1),false) WHERE id=1;
SQL
cat >"$work/split_hot_diff.sql" <<'SQL'
\set id random(1,200)
SELECT splitjson.increment_field('public.split_load',:id,ARRAY['counter']);
SQL
cat >"$work/native_hot_diff.sql" <<'SQL'
\set id random(1,200)
UPDATE public.native_load SET doc=jsonb_set(doc,'{counter}',to_jsonb((doc->>'counter')::integer+1),false) WHERE id=:id;
SQL
cat >"$work/split_indexed_read.sql" <<'SQL'
SELECT count(*) FROM public.split_load WHERE id IN
    (SELECT splitjson.find_ids('public.split_load',ARRAY['state'],'"ready"'));
SQL
cat >"$work/native_indexed_read.sql" <<'SQL'
SELECT count(*) FROM public.native_load WHERE doc->>'state'='ready';
SQL
cat >"$work/split_cold_read.sql" <<'SQL'
SELECT count(*) FROM public.split_load WHERE doc->>'cold_key'='cold-value';
SQL
cat >"$work/native_cold_read.sql" <<'SQL'
SELECT count(*) FROM public.native_load WHERE doc->>'cold_key'='cold-value';
SQL
cat >"$work/split_mixed.sql" <<'SQL'
\set id random(1,200)
SELECT splitjson.increment_field('public.split_load',:id,ARRAY['counter']);
SELECT count(*) FROM public.split_load WHERE id IN
    (SELECT splitjson.find_ids('public.split_load',ARRAY['state'],'"ready"'));
SQL
cat >"$work/native_mixed.sql" <<'SQL'
\set id random(1,200)
UPDATE public.native_load SET doc=jsonb_set(doc,'{counter}',to_jsonb((doc->>'counter')::integer+1),false) WHERE id=:id;
SELECT count(*) FROM public.native_load WHERE doc->>'state'='ready';
SQL
cat >"$work/split_structural.sql" <<'SQL'
\set id random(1,200)
SELECT splitjson.set_field('public.split_load',:id,ARRAY['cold_key'],'"changed"');
SQL
cat >"$work/native_structural.sql" <<'SQL'
\set id random(1,200)
UPDATE public.native_load SET doc=jsonb_set(doc,'{cold_key}','"changed"',false) WHERE id=:id;
SQL

run_case() {
    local name=$1 file=$2
    local start_lsn end_lsn
    start_lsn=$(psql_cmd -Atc 'SELECT pg_current_wal_insert_lsn()')
    rm -f "$work"/pgbench_log.*
    (cd "$work" && run_pg "$pgbin/pgbench" -n -M prepared -c "$clients" -j "$clients" -T "$duration" \
        -f "$file" -l --sampling-rate=1 -P 2 -h "${PGHOST:?}" -p "${PGPORT:?}" "$db") \
        >"$work/$name.out" 2>&1
    end_lsn=$(psql_cmd -Atc 'SELECT pg_current_wal_insert_lsn()')
    wal_bytes=$(psql_cmd -Atc "SELECT pg_wal_lsn_diff('$end_lsn','$start_lsn')")
    python3 - "$name" "$work" "$wal_bytes" <<'PY'
import pathlib, sys, subprocess
name, root, wal_bytes = sys.argv[1:]
values=[]
for path in pathlib.Path(root).glob('pgbench_log.*'):
    for line in path.read_text(errors='replace').splitlines():
        fields=line.split()
        if fields:
            try:
                value=float(fields[-1])
            except ValueError:
                continue
            if value >= 0:
                values.append(value)
values.sort()
def pct(p):
    if not values:
        return 'nan'
    return f'{values[min(len(values)-1, int((len(values)-1)*p))]:.0f}'
out=pathlib.Path(root, name+'.out').read_text(errors='replace')
tps='unknown'
for line in out.splitlines():
    if 'tps =' in line:
        tps=line.strip()
        break
print(f'case={name} samples={len(values)} p50_us={pct(.50)} p95_us={pct(.95)} p99_us={pct(.99)} wal_bytes={wal_bytes} {tps}')
PY
}

export PGHOST=${PGHOST:?PGHOST must be set by lab.sh} PGPORT=${PGPORT:?PGPORT must be set by lab.sh} PGUSER="$run_as"
for pair in \
    split_hot_same:$work/split_hot_same.sql native_hot_same:$work/native_hot_same.sql \
    split_hot_diff:$work/split_hot_diff.sql native_hot_diff:$work/native_hot_diff.sql \
    split_indexed_read:$work/split_indexed_read.sql native_indexed_read:$work/native_indexed_read.sql \
    split_cold_read:$work/split_cold_read.sql native_cold_read:$work/native_cold_read.sql \
    split_mixed:$work/split_mixed.sql native_mixed:$work/native_mixed.sql \
    split_structural:$work/split_structural.sql native_structural:$work/native_structural.sql; do
    IFS=: read -r name file <<<"$pair"
    run_case "$name" "$file"
done

psql_cmd <<'SQL'
VACUUM (ANALYZE) public.native_load;
VACUUM (ANALYZE) splitjson_storage.s_1;
REINDEX TABLE splitjson_storage.s_1;
SELECT splitjson.check_all(true);
SELECT splitjson.table_stats('public.split_load');
SQL
printf '%s\n' 'maintenance: VACUUM (ANALYZE), REINDEX and full check_all completed'
