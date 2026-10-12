#!/usr/bin/env bash
# Only a fresh installation and PGDATA are mutated; usable locally and in CI.
set -Eeuo pipefail
source_root=$(cd "$(dirname "$0")/.." && pwd)
pg_source=${1:-/usr/local/pgsql-18.6}
profile=${PG_SPLITJSON_LAB_PROFILE:-full}
[[ "$profile" =~ ^(full|security-gate|wal-gate|capabilities|online|replication)$ ]]
lab=${PG_SPLITJSON_LAB_ROOT:-$(mktemp -d /tmp/pg_splitjson-lab.XXXXXX)}
if [[ $(id -u) = 0 ]]; then
    run_as=${PG_SPLITJSON_RUN_AS:-pgsql}
else
    run_as=$(id -un)
fi
run_pg() {
    if [[ $(id -u) = 0 ]]; then runuser -u "$run_as" -- "$@"; else "$@"; fi
}
port=65418
[[ "$lab" =~ ^/tmp/pg_splitjson-lab\.[a-zA-Z0-9]+$ ]]
[[ -d "$lab" && ! -L "$lab" && ! -e "$lab/data" && ! -e "$lab/pgsql" ]]
id "$run_as" >/dev/null
chmod 755 "$lab"
mkdir "$lab/pgsql" "$lab/runtime" "$lab/source" "$lab/results"
mkdir -p "$lab/recovery/archive"
cp -a "$pg_source"/. "$lab/pgsql"/
cp -a "$source_root"/. "$lab/source"/
pgbin="$lab/pgsql/bin"
[[ $("$pgbin/pg_config" --version) = 'PostgreSQL 18.'* ]]
[[ $("$pgbin/pg_config" --pkglibdir) = "$lab/pgsql/lib" ]]
[[ $("$pgbin/pg_config" --sharedir) = "$lab/pgsql/share" ]]
[[ $(readlink -f "$lab/pgsql/lib") = "$lab/pgsql/lib" ]]
[[ $(readlink -f "$lab/pgsql/share/extension") = "$lab/pgsql/share/extension" ]]
{
    date -u
    uname -srm
    "$pgbin/pg_config" --version
    printf 'Install prefix: %s\nData directory: %s\nSocket: %s\n' "$lab/pgsql" "$lab/data" "$lab/runtime/socket"
} >"$lab/results/environment.log"
make -C "$lab/source" PG_CONFIG="$pgbin/pg_config" >"$lab/results/build.log" 2>&1
make -C "$lab/source" PG_CONFIG="$pgbin/pg_config" install >>"$lab/results/build.log" 2>&1
python3 "$lab/source/scripts/generate-sql.py" --check
mkdir "$lab/data" "$lab/runtime/socket"
if [[ $(id -u) = 0 ]]; then chown -R "$run_as" "$lab/data" "$lab/runtime" "$lab/source" "$lab/recovery" "$lab/results"; fi
chmod 700 "$lab/data" "$lab/runtime" "$lab/runtime/socket"
run_pg "$pgbin/initdb" -D "$lab/data" --no-locale --encoding=UTF8 \
    --auth-local=trust --auth-host=reject >"$lab/results/initdb.log" 2>&1
# Recovery validation needs an archived WAL stream and replication senders. The
# archive is private to this fresh lab; no host cluster configuration is read.
printf '%s\n' \
    'wal_level = logical' \
    "output_plugin_libraries = 'pgoutput, test_decoding, pg_splitjson_decode'" \
    'max_wal_senders = 8' \
    'max_replication_slots = 4' \
    'archive_mode = on' \
    'archive_timeout = 5s' \
    "archive_command = 'test ! -f $lab/recovery/archive/%f && cp %p $lab/recovery/archive/%f'" \
    >>"$lab/data/postgresql.conf"
started=false
subscriber_started=false
cleanup() {
    local task_status=$?
    if [[ "$subscriber_started" = true && -f "$lab/subscriber-data/postmaster.pid" ]]; then
        run_pg "$pgbin/pg_ctl" -D "$lab/subscriber-data" -m fast -t 30 -w stop >"$lab/results/subscriber-shutdown.log" 2>&1 || task_status=1
    fi
    if [[ "$started" = true && -f "$lab/data/postmaster.pid" ]]; then
        if ! run_pg "$pgbin/pg_ctl" -D "$lab/data" -m fast -t 30 -w stop \
            >"$lab/results/shutdown.log" 2>&1; then
            printf 'Failed to stop the lab; see %s/results/shutdown.log\n' "$lab" >&2
            task_status=1
        fi
    fi
    printf 'Lab retained at %s\n' "$lab"
    trap - EXIT
    exit "$task_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
started=true
run_pg "$pgbin/pg_ctl" -D "$lab/data" \
    -l "$lab/runtime/server.log" -o "-k $lab/runtime/socket -p $port -c listen_addresses='' -c session_preload_libraries=pg_splitjson" -w start \
    >"$lab/results/startup.log" 2>&1
export PGHOST="$lab/runtime/socket" PGPORT="$port" PGUSER="$run_as" PGDATABASE=postgres
run_as_env=(PG_SPLITJSON_RUN_AS="$run_as" PG_SPLITJSON_LAB_ROOT="$lab" PG_SPLITJSON_LAB_BIN="$pgbin" PG_SPLITJSON_LAB_DATA="$lab/data")
if [[ "$profile" = replication || "$profile" = full ]]; then
    mkdir "$lab/subscriber-data" "$lab/runtime/subscriber-socket"
    if [[ $(id -u) = 0 ]]; then chown -R "$run_as" "$lab/subscriber-data" "$lab/runtime/subscriber-socket"; fi
    chmod 700 "$lab/subscriber-data" "$lab/runtime/subscriber-socket"
    run_pg "$pgbin/initdb" -D "$lab/subscriber-data" --no-locale --encoding=UTF8 --auth-local=trust --auth-host=reject >"$lab/results/subscriber-initdb.log" 2>&1
    subscriber_started=true
    run_pg "$pgbin/pg_ctl" -D "$lab/subscriber-data" -l "$lab/runtime/subscriber.log" \
        -o "-k $lab/runtime/subscriber-socket -p 65421 -c listen_addresses='' -c session_preload_libraries=pg_splitjson -c wal_retrieve_retry_interval=100ms" -w start >"$lab/results/subscriber-startup.log" 2>&1
    printf 'Subscriber data directory: %s\nSubscriber socket: %s\n' "$lab/subscriber-data" "$lab/runtime/subscriber-socket" >>"$lab/results/environment.log"
fi
if [[ "$profile" = replication ]]; then
    run_pg env "${run_as_env[@]}" PG_SPLITJSON_LIBPQ="$lab/pgsql/lib/libpq.so" python3 "$lab/source/tests/replication_030.py" >"$lab/results/replication_030.log" 2>&1
    printf '%s\n' 'Native logical replication checks passed.'
    exit 0
fi
if [[ "$profile" = online ]]; then
    run_pg env "${run_as_env[@]}" PG_SPLITJSON_LIBPQ="$lab/pgsql/lib/libpq.so" python3 "$lab/source/tests/online_030.py" >"$lab/results/online_030.log" 2>&1
    printf '%s\n' 'Online migration checks passed.'
    exit 0
fi
if [[ "$profile" = capabilities ]]; then
    run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/capabilities_030.sql" >"$lab/results/capabilities_030.log" 2>&1
    run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/planning_030.sql" >"$lab/results/planning_030.log" 2>&1
    run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/portability_030.sql" >"$lab/results/portability_030.log" 2>&1
    run_pg env "${run_as_env[@]}" PGDATABASE=postgres PG_SPLITJSON_LIBPQ="$lab/pgsql/lib/libpq.so" python3 "$lab/source/scripts/splitjson-portability.py" export --relation public.portable_docs --output "$lab/results/portable.jsonl" --copy defaults,checks,collation >"$lab/results/portability_export.log" 2>&1
    run_pg env "${run_as_env[@]}" PGDATABASE=postgres PG_SPLITJSON_LIBPQ="$lab/pgsql/lib/libpq.so" python3 "$lab/source/scripts/splitjson-portability.py" import --target public.cli_copy --input "$lab/results/portable.jsonl" --options '{"ignore_manual":true}' >"$lab/results/portability_import.log" 2>&1
    run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -c "SELECT cap_ok((SELECT count(*)=2 FROM cli_copy));" >"$lab/results/portability_cli.log" 2>&1
    run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/lifecycle_030.sql" >"$lab/results/lifecycle_030.log" 2>&1
    run_pg env "${run_as_env[@]}" "$pgbin/createdb" upgrade_030
    run_pg env "${run_as_env[@]}" PGDATABASE=upgrade_030 "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/upgrade_030.sql" >"$lab/results/upgrade_030.log" 2>&1
    printf '%s\n' '0.3.0 capability checks passed.'
    exit 0
fi
if [[ "$profile" = security-gate ]]; then
    run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/security_gate.sql" >"$lab/results/security_gate.log" 2>&1
    printf '%s\n' 'Security gate passed.'
    exit 0
fi
if [[ "$profile" = wal-gate ]]; then
    run_pg env "${run_as_env[@]}" PG_SPLITJSON_LIBPQ="$lab/pgsql/lib/libpq.so" python3 "$lab/source/tests/wal_gate.py" >"$lab/results/wal_gate.log" 2>&1
    printf '%s\n' 'WAL gate passed.'
    exit 0
fi
run_pg env "${run_as_env[@]}" make -C "$lab/source" PG_CONFIG="$pgbin/pg_config" installcheck >"$lab/results/installcheck.log" 2>&1
run_pg env "${run_as_env[@]}" "$pgbin/createdb" capabilities_030
run_pg env "${run_as_env[@]}" PGDATABASE=capabilities_030 "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/capabilities_030.sql" >"$lab/results/capabilities_030.log" 2>&1
run_pg env "${run_as_env[@]}" PGDATABASE=capabilities_030 "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/planning_030.sql" >"$lab/results/planning_030.log" 2>&1
run_pg env "${run_as_env[@]}" PGDATABASE=capabilities_030 "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/portability_030.sql" >"$lab/results/portability_030.log" 2>&1
run_pg env "${run_as_env[@]}" PGDATABASE=capabilities_030 PG_SPLITJSON_LIBPQ="$lab/pgsql/lib/libpq.so" python3 "$lab/source/scripts/splitjson-portability.py" export --relation public.portable_docs --output "$lab/results/portable.jsonl" --copy defaults,checks,collation >"$lab/results/portability_export.log" 2>&1
run_pg env "${run_as_env[@]}" PGDATABASE=capabilities_030 PG_SPLITJSON_LIBPQ="$lab/pgsql/lib/libpq.so" python3 "$lab/source/scripts/splitjson-portability.py" import --target public.cli_copy --input "$lab/results/portable.jsonl" --options '{"ignore_manual":true}' >"$lab/results/portability_import.log" 2>&1
run_pg env "${run_as_env[@]}" PGDATABASE=capabilities_030 "$pgbin/psql" -X -v ON_ERROR_STOP=1 -c "SELECT cap_ok((SELECT count(*)=2 FROM cli_copy));" >"$lab/results/portability_cli.log" 2>&1
run_pg env "${run_as_env[@]}" PGDATABASE=capabilities_030 "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/lifecycle_030.sql" >"$lab/results/lifecycle_030.log" 2>&1
run_pg env "${run_as_env[@]}" "$pgbin/createdb" upgrade_030
run_pg env "${run_as_env[@]}" PGDATABASE=upgrade_030 "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/upgrade_030.sql" >"$lab/results/upgrade_030.log" 2>&1
run_pg env "${run_as_env[@]}" "$pgbin/createdb" upgrade_test
run_pg env "${run_as_env[@]}" PGDATABASE=upgrade_test "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/upgrade.sql" >"$lab/results/upgrade.log" 2>&1
run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/planner_lifecycle.sql" >"$lab/results/planner_lifecycle.log" 2>&1
run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/semantic.sql" >"$lab/results/semantic.log" 2>&1
run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/features.sql" >"$lab/results/features.log" 2>&1
run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/arrays_rewrite.sql" >"$lab/results/arrays_rewrite.log" 2>&1
(cd "$lab/runtime"; run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/production_features.sql") >"$lab/results/production_features.log" 2>&1
run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/randomized.sql" >"$lab/results/randomized.log" 2>&1
run_pg env "${run_as_env[@]}" "$lab/source/tests/concurrency.sh" "$pgbin" >"$lab/results/concurrency.log" 2>&1
run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/physical.sql" >"$lab/results/physical.log" 2>&1
run_pg env "${run_as_env[@]}" "$pgbin/pg_dump" -Fc -f "$lab/results/backup.dump" postgres
run_pg env "${run_as_env[@]}" "$pgbin/createdb" restored
run_pg env "${run_as_env[@]}" PGOPTIONS='-c session_replication_role=replica' "$pgbin/pg_restore" --exit-on-error -d restored "$lab/results/backup.dump" >"$lab/results/restore.log" 2>&1
run_pg env "${run_as_env[@]}" PGDATABASE=restored "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/restore.sql" >>"$lab/results/restore.log" 2>&1
run_pg env "${run_as_env[@]}" "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/benchmark.sql" >"$lab/results/benchmark.log" 2>&1
run_pg env "${run_as_env[@]}" "$lab/source/tests/production_benchmark.sh" "$pgbin" >"$lab/results/production-benchmark.log" 2>&1
run_pg env "${run_as_env[@]}" "$lab/source/tests/recovery.sh" "$pgbin" "$lab" "$lab/data" "$lab/runtime/socket" "$port" >"$lab/results/recovery.log" 2>&1
printf '%s\n' 'All checks passed.'
