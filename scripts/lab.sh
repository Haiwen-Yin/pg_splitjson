#!/usr/bin/env bash
# Run on the PG host as root, from a source checkout. Only the fresh lab is mutated.
set -Eeuo pipefail
source_root=$(cd "$(dirname "$0")/.." && pwd)
pg_source=${1:-/usr/local/pgsql-18.6}
lab=${PG_SPLITJSON_LAB_ROOT:-$(mktemp -d /tmp/pg_splitjson-lab.XXXXXX)}
run_as=${PG_SPLITJSON_RUN_AS:-pgsql}
port=65418
[[ "$lab" =~ ^/tmp/pg_splitjson-lab\.[a-zA-Z0-9]+$ ]]
[[ -d "$lab" && ! -L "$lab" && ! -e "$lab/data" && ! -e "$lab/pgsql" ]]
[[ $(id -u) = 0 ]]
id "$run_as" >/dev/null
chmod 755 "$lab"
mkdir "$lab/pgsql" "$lab/runtime" "$lab/source" "$lab/results"
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
mkdir "$lab/data" "$lab/runtime/socket"
chown -R "$run_as" "$lab/data" "$lab/runtime"
chmod 700 "$lab/data" "$lab/runtime" "$lab/runtime/socket"
runuser -u "$run_as" -- "$pgbin/initdb" -D "$lab/data" --no-locale --encoding=UTF8 \
    --auth-local=trust --auth-host=reject >"$lab/results/initdb.log" 2>&1
started=false
cleanup() {
    local task_status=$?
    if [[ "$started" = true && -f "$lab/data/postmaster.pid" ]]; then
        if ! runuser -u "$run_as" -- "$pgbin/pg_ctl" -D "$lab/data" -m fast -t 30 -w stop \
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
runuser -u "$run_as" -- "$pgbin/pg_ctl" -D "$lab/data" \
    -l "$lab/runtime/server.log" -o "-k $lab/runtime/socket -p $port -c listen_addresses='' -c session_preload_libraries=pg_splitjson" -w start \
    >"$lab/results/startup.log" 2>&1
export PGHOST="$lab/runtime/socket" PGPORT="$port" PGUSER="$run_as" PGDATABASE=postgres
"$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/planner_lifecycle.sql" >"$lab/results/planner_lifecycle.log" 2>&1
"$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/semantic.sql" >"$lab/results/semantic.log" 2>&1
"$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/features.sql" >"$lab/results/features.log" 2>&1
"$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/arrays_rewrite.sql" >"$lab/results/arrays_rewrite.log" 2>&1
"$lab/source/tests/concurrency.sh" "$pgbin" >"$lab/results/concurrency.log" 2>&1
"$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/physical.sql" >"$lab/results/physical.log" 2>&1
"$pgbin/pg_dump" -Fc -f "$lab/results/backup.dump" postgres
"$pgbin/createdb" restored
"$pgbin/pg_restore" --exit-on-error -d restored "$lab/results/backup.dump" >"$lab/results/restore.log" 2>&1
PGDATABASE=restored "$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/restore.sql" >>"$lab/results/restore.log" 2>&1
"$pgbin/psql" -X -v ON_ERROR_STOP=1 -f "$lab/source/tests/benchmark.sql" >"$lab/results/benchmark.log" 2>&1
printf '%s\n' 'All checks passed.'
