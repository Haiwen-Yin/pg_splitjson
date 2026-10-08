#!/usr/bin/env bash
# Recovery checks run only against the temporary cluster created by lab.sh.
# They deliberately use separate PGDATA/socket/ports for every secondary.
set -Eeuo pipefail

pgbin=$1
lab=$2
primary_data=$3
primary_socket=$4
primary_port=$5
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

root="$lab/recovery"
archive="$root/archive"
standby_data="$root/standby-data"
standby_socket="$root/standby-socket"
standby_port=65419
pitr_base="$root/pitr-base"
pitr_data="$root/pitr-data"
pitr_socket="$root/pitr-socket"
pitr_port=65420
db=recovery_test
mkdir -p "$root" "$archive" "$standby_socket" "$pitr_socket"
chmod 700 "$root" "$archive" "$standby_socket" "$pitr_socket"
if [[ $(id -u) = 0 ]]; then chown -R "$run_as" "$root"; fi

primary_psql() {
    if [[ $(id -u) = 0 ]]; then
        runuser -u "$run_as" -- env PGHOST="$primary_socket" PGPORT="$primary_port" \
            PGUSER="$run_as" PGDATABASE="$db" "$pgbin/psql" -X -v ON_ERROR_STOP=1 "$@"
    else
        PGHOST="$primary_socket" PGPORT="$primary_port" PGUSER="$run_as" PGDATABASE="$db" \
            "$pgbin/psql" -X -v ON_ERROR_STOP=1 "$@"
    fi
}
postgres_psql() {
    if [[ $(id -u) = 0 ]]; then
        runuser -u "$run_as" -- env PGHOST="$primary_socket" PGPORT="$primary_port" \
            PGUSER="$run_as" PGDATABASE=postgres "$pgbin/psql" -X -v ON_ERROR_STOP=1 "$@"
    else
        PGHOST="$primary_socket" PGPORT="$primary_port" PGUSER="$run_as" PGDATABASE=postgres \
            "$pgbin/psql" -X -v ON_ERROR_STOP=1 "$@"
    fi
}
secondary_psql() {
    local socket=$1 port=$2 database=$3
    shift 3
    if [[ $(id -u) = 0 ]]; then
        runuser -u "$run_as" -- env PGHOST="$socket" PGPORT="$port" \
            PGUSER="$run_as" PGDATABASE="$database" "$pgbin/psql" -X -v ON_ERROR_STOP=1 "$@"
    else
        PGHOST="$socket" PGPORT="$port" PGUSER="$run_as" PGDATABASE="$database" \
            "$pgbin/psql" -X -v ON_ERROR_STOP=1 "$@"
    fi
}
wait_query() {
    local socket=$1 port=$2 database=$3 sql=$4 expected=$5
    local value
    for _ in {1..120}; do
        value=$(secondary_psql "$socket" "$port" "$database" -Atc "$sql" 2>/dev/null || true)
        if [[ "$value" = "$expected" ]]; then return 0; fi
        sleep 0.25
    done
    printf 'timed out waiting for %s on %s\n' "$expected" "$socket" >&2
    return 1
}
stop_cluster() {
    local data=$1 log=$2
    if [[ -f "$data/postmaster.pid" ]]; then
        run_pg "$pgbin/pg_ctl" -D "$data" -m fast -t 30 -w stop >"$log" 2>&1 || true
    fi
}
cleanup() {
    local status=$?
    stop_cluster "$pitr_data" "$root/pitr-stop.log"
    stop_cluster "$standby_data" "$root/standby-stop.log"
    # If promotion stopped the primary, leave the lab in its original state so
    # lab.sh can perform its normal final cleanup.
    if [[ ! -f "$primary_data/postmaster.pid" ]]; then
        if [[ $(id -u) = 0 ]]; then chown -R "$run_as" "$primary_data"; fi
        run_pg "$pgbin/pg_ctl" -D "$primary_data" \
            -l "$root/primary-restart.log" -o "-k $primary_socket -p $primary_port -c listen_addresses=''" -w start \
            >/dev/null 2>&1 || status=1
    fi
    exit "$status"
}
trap cleanup EXIT

printf '%s\n' '--- crash recovery ---'
postgres_psql -c "DROP DATABASE IF EXISTS $db" >/dev/null
postgres_psql -c "CREATE DATABASE $db" >/dev/null
primary_psql <<'SQL'
CREATE FUNCTION public.assert_true(p boolean,p_message text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN IF NOT p THEN RAISE EXCEPTION 'assertion failed: %',p_message; END IF; END $$;
CREATE EXTENSION pg_splitjson;
SELECT splitjson.create_table('public.recovery_docs','[["hot"]]');
INSERT INTO recovery_docs VALUES (1,'{"hot":{"value":1},"cold":"before"}');
SELECT splitjson.set_field('recovery_docs',1,ARRAY['hot','value'],'2');
SQL

export PGHOST="$primary_socket" PGPORT="$primary_port" PGUSER="$run_as" PGDATABASE="$db"
run_pg "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f - >"$root/crash-writer.log" 2>&1 <<'SQL' &
BEGIN;
SELECT splitjson.set_field('recovery_docs',1,ARRAY['hot','value'],'99');
INSERT INTO recovery_docs VALUES (2,'{"hot":2,"cold":"uncommitted"}');
SELECT pg_sleep(30);
COMMIT;
SQL
writer=$!
sleep 1
run_pg "$pgbin/pg_ctl" -D "$primary_data" -m immediate -t 30 -w stop >"$root/crash-stop.log" 2>&1
wait "$writer" || true
run_pg "$pgbin/pg_ctl" -D "$primary_data" -l "$root/crash-restart.log" \
    -o "-k $primary_socket -p $primary_port -c listen_addresses=''" -w start >"$root/crash-start.log" 2>&1
primary_psql <<'SQL'
SELECT assert_true((SELECT doc->'hot'->'value'='2' AND doc->'cold'='"before"' FROM recovery_docs WHERE id=1),
                   'committed state survives immediate crash recovery');
SELECT assert_true(NOT EXISTS (SELECT 1 FROM recovery_docs WHERE id=2),
                   'uncommitted row is absent after immediate crash recovery');
SQL

printf '%s\n' '--- PITR ---'
rm -rf "$pitr_base" "$pitr_data"
run_pg "$pgbin/pg_basebackup" -h "$primary_socket" -p "$primary_port" -U "$run_as" \
    -D "$pitr_base" -Fp -X stream -c fast >"$root/pitr-basebackup.log" 2>&1
primary_psql <<'SQL'
INSERT INTO recovery_docs VALUES (10,'{"hot":10,"cold":"pitr-before"}');
SELECT pg_create_restore_point('pg_splitjson_pitr') AS restore_point \gset
INSERT INTO recovery_docs VALUES (11,'{"hot":11,"cold":"pitr-after"}');
SELECT pg_switch_wal();
SELECT pg_switch_wal();
SQL
for _ in {1..120}; do
    if compgen -G "$archive/*" >/dev/null 2>&1; then break; fi
    sleep 0.25
done
if ! compgen -G "$archive/*" >/dev/null 2>&1; then
    printf 'WAL archive did not receive a segment\n' >&2
    exit 1
fi
cp -a "$pitr_base" "$pitr_data"
printf '%s\n' \
    "restore_command = 'cp $archive/%f %p'" \
    "recovery_target_name = 'pg_splitjson_pitr'" \
    "recovery_target_action = 'promote'" \
    "port = $pitr_port" \
    "unix_socket_directories = '$pitr_socket'" \
    "listen_addresses = ''" >>"$pitr_data/postgresql.auto.conf"
touch "$pitr_data/recovery.signal"
if [[ $(id -u) = 0 ]]; then chown -R "$run_as" "$pitr_data"; fi
run_pg "$pgbin/pg_ctl" -D "$pitr_data" -l "$root/pitr.log" \
    -o "-k $pitr_socket -p $pitr_port -c listen_addresses=''" -w start >"$root/pitr-start.log" 2>&1
wait_query "$pitr_socket" "$pitr_port" "$db" "SELECT pg_is_in_recovery()" f
secondary_psql "$pitr_socket" "$pitr_port" "$db" <<'SQL'
SELECT assert_true(EXISTS (SELECT 1 FROM recovery_docs WHERE id=10), 'PITR restores committed state before target');
SELECT assert_true(NOT EXISTS (SELECT 1 FROM recovery_docs WHERE id=11), 'PITR stops at named restore point');
SELECT assert_true((SELECT doc->'hot'='10' FROM recovery_docs WHERE id=10), 'PITR restores split JSON payload');
SQL
stop_cluster "$pitr_data" "$root/pitr-stop.log"

printf '%s\n' '--- streaming standby and promotion ---'
rm -rf "$standby_data"
run_pg "$pgbin/pg_basebackup" -h "$primary_socket" -p "$primary_port" -U "$run_as" \
    -D "$standby_data" -Fp -X stream -R -c fast >"$root/standby-basebackup.log" 2>&1
printf '%s\n' "port = $standby_port" "unix_socket_directories = '$standby_socket'" "listen_addresses = ''" >>"$standby_data/postgresql.auto.conf"
if [[ $(id -u) = 0 ]]; then chown -R "$run_as" "$standby_data"; fi
run_pg "$pgbin/pg_ctl" -D "$standby_data" -l "$root/standby.log" \
    -o "-k $standby_socket -p $standby_port -c listen_addresses=''" -w start >"$root/standby-start.log" 2>&1
wait_query "$standby_socket" "$standby_port" "$db" "SELECT pg_is_in_recovery()" t
primary_psql -c "INSERT INTO recovery_docs VALUES (20,'{\"hot\":20,\"cold\":\"streamed\"}')" >/dev/null
primary_psql -c "SELECT pg_switch_wal(),pg_switch_wal()" >/dev/null
wait_query "$standby_socket" "$standby_port" "$db" "SELECT count(*) FROM recovery_docs WHERE id=20" 1
run_pg "$pgbin/pg_ctl" -D "$primary_data" -m fast -t 30 -w stop >"$root/primary-before-promote.log" 2>&1
run_pg "$pgbin/pg_ctl" -D "$standby_data" promote >"$root/promote.log" 2>&1
wait_query "$standby_socket" "$standby_port" "$db" "SELECT pg_is_in_recovery()" f
secondary_psql "$standby_socket" "$standby_port" "$db" -c "SELECT splitjson.set_field('recovery_docs',20,ARRAY['hot'],'21')" >/dev/null
secondary_psql "$standby_socket" "$standby_port" "$db" -c \
    "SELECT assert_true((SELECT doc->'hot'='21' FROM recovery_docs WHERE id=20),'promoted standby accepts split JSON writes')"
stop_cluster "$standby_data" "$root/standby-promoted-stop.log"

printf '%s\n' 'recovery, PITR, streaming replay and promotion tests passed\n'
