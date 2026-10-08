#!/usr/bin/env bash
set -Eeuo pipefail
source_root=$(cd "$(dirname "$0")/.." && pwd)
host=${1:-root@10.10.10.131}
pg_source=${2:-/usr/local/pgsql-18.6}
archive=$(mktemp /tmp/pg_splitjson-source.XXXXXX.tar.gz)
trap 'rm -f "$archive"' EXIT
lab=$(ssh -o BatchMode=yes "$host" 'mktemp -d /tmp/pg_splitjson-lab.XXXXXX')
[[ "$lab" =~ ^/tmp/pg_splitjson-lab\.[a-zA-Z0-9]+$ ]]
tar --exclude=.git --exclude=.lab --exclude=build_output --exclude='*.o' --exclude='*.so' --exclude='*.bc' \
    -czf "$archive" -C "$source_root" .
scp -q "$archive" "$host:$lab/source.tar.gz"
printf -v command 'mkdir -- %q; tar -xzf %q -C %q; PG_SPLITJSON_LAB_ROOT=%q bash %q %q' \
    "$lab/checkout" "$lab/source.tar.gz" "$lab/checkout" "$lab" "$lab/checkout/scripts/lab.sh" "$pg_source"
status=0
ssh -o BatchMode=yes "$host" "$command" || status=$?
local_results="$source_root/.lab/$(basename "$lab")"
mkdir -p "$local_results"
scp -rq "$host:$lab/results" "$local_results/" || true
scp -q "$host:$lab/runtime/server.log" "$local_results/" || true
printf 'Local logs: %s\n' "$local_results"
exit "$status"
