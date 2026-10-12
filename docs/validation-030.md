# PG SplitJSON 0.3.0 validation report

**English** | [简体中文](validation-030.zh-CN.md) · [OpenSpec tasks](../openspec/changes/prepare-extension-capabilities-030/tasks.md)

0.3.0 has completed its implementation gates for PostgreSQL 18.6 on Linux x86_64. Every database experiment below used `scripts/test-remote.sh` against `root@10.10.10.131`. The runner copied `/usr/local/pgsql-18.6` into a fresh `/tmp/pg_splitjson-lab.*` prefix, created private PGDATA and sockets, and stopped only those clusters. No existing PostgreSQL instance was connected to or changed.

| Gate | Lab | Result | Evidence |
| --- | --- | --- | --- |
| Full legacy, upgrade, RLS, planner, portability, TOAST, dump/restore, recovery and workload suite | `n0UxNd` | passed | `validation/pg-splitjson-0.3.0-final/full.log` |
| Online snapshot/WAL migration | `mF8tkk` | passed | `validation/pg-splitjson-0.3.0-final/online_030.log` |
| Same-layout native logical publication/subscription | `kRnekV` | passed | `validation/pg-splitjson-0.3.0-final/replication_030.log` |
| Capability and portability assertion suite after final API changes | `Akc56X` (before planner assertion correction) and final full run `n0UxNd` | passed in final run | `validation/pg-splitjson-0.3.0-final/full.log` |

The final full run reported `All checks passed.` It includes the frozen regression test, 0.1.0 → 0.2.0 → 0.3.0 upgrade, RLS identity and `COPY`, native HASH/RANGE routing, typed numeric/boolean/text indexes, real planner output, array suffix rewriting, one-write batch and increment concurrency, raw cold TOAST pointer/chunk reuse, JSONL export/import, pg_dump/pg_restore, immediate crash recovery, named-point PITR, streaming standby promotion, and workload benchmarks. The final online runner additionally exercised snapshot copy, concurrent insert/update/delete/rollback, id moves, unchanged external TOAST, real child-process failure before commit and after commit-before-ack, an actual temporary PostgreSQL immediate crash, WAL-slot loss, final writer fencing and abort. The final replication lab used two new PGDATA instances and exercised initial sync, mixed hot/cold/array/typed-column transactions, RLS filtering, follower write denial, pause/resume, apply-worker restart, partition-root publication, cross-partition id moves, final fence markers and takeover.

Selected workload output is retained exactly as measured in the final lab. For example, the production benchmark reported `case=split_cold_read samples=4252 p50_us=503978 p95_us=948592 p99_us=988377 wal_bytes=33229800 tps = 532.744291`; this is a workload-specific result, not a product guarantee. Full raw logs remain in the ignored lab directory and are not release artifacts. The compact evidence files in this directory contain no credentials, database files, dumps or JSONL data.

The final package gate also ran `python3 scripts/generate-sql.py --check`, `git diff --check`, Python AST syntax checks, strict OpenSpec validation and the explicit-source package file audit. The 0.2.0 archive and its historical SHA-256 remain unchanged. 0.3.0 is supported only on the tested PG18.6/Linux x86_64 target in this release; other PostgreSQL minors and architectures require separate validation.
