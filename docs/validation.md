# PG SplitJSON 0.2.0 validation report

**English** | [简体中文](validation.zh-CN.md) · [Documentation](README.md)

The production-hardening suite passed on **PostgreSQL 18.6**, Linux x86_64, in a fresh isolated lab copied from `/usr/local/pgsql-18.6` on 10.10.10.131. The lab used a unique `/tmp/pg_splitjson-lab.*` prefix, private socket, `listen_addresses=''`, and a new PGDATA; no existing PostgreSQL instance was connected to or changed. Raw logs are in [validation/pg-splitjson-0.2.0/](validation/pg-splitjson-0.2.0/).

## Release and correctness

| Check | Result |
| --- | --- |
| Build | PGXS compile and install completed without warnings |
| Regression | `make installcheck`: 1/1 production test passed |
| Upgrade | Official 0.1.0 to 0.2.0 passed; cold pointer/chunks preserved |
| Differential | 5,000 seeded JSONB operations passed |
| Arrays | Native set/delete behavior, fixed slots and structural repacking passed |
| Concurrency | Object, fixed-array and subtree increments completed without loss |
| Permissions/DDL | View-only roles, private storage, protected DDL and controlled rename/drop passed |
| Physical storage | Indexed hot updates and hot subtrees reused unchanged cold TOAST pointer/chunks |
| Backup | Whole-database dump/restore retained APIs, typed columns and permissions |

Evidence: `installcheck.log`, `upgrade.log`, `randomized.log`, `production_features.log`, `concurrency.log`, `physical.log`, and `restore.log`.

## Recovery

The same fresh cluster passed immediate crash recovery, named restore-point PITR, streaming standby replay and promotion. Committed hot/cold values and business rows survived; the uncommitted row was absent after crash recovery; PITR stopped before the post-target row; the promoted standby accepted a hot update. Evidence: [recovery.log](validation/pg-splitjson-0.2.0/recovery.log).

Physical recovery is only supported with the same PostgreSQL minor/ABI and extension files. Across PostgreSQL major versions use logical export/import. Run `splitjson.check_all(true)` after every restore or promotion before returning traffic.

## Bounded workload measurements

The production harness used 200 rows, approximately 256 KiB cold payloads, four pgbench clients, eight seconds per case, and one text B-tree on `state`. These values are evidence for this setup, not a general benchmark or SLA.

| Case | Reported TPS | WAL bytes |
| --- | ---: | ---: |
| Split hot same row | 1,019.998 | 9,147,136 |
| Native JSONB same row | 350.398 | 68,009,496 |
| Split hot different rows | 1,603.677 | 16,327,648 |
| Native JSONB different rows | 952.378 | 280,014,456 |
| Split indexed read | 2,546.868 | 25,411,592 |
| Native indexed read | 1,772.560 | 90,761,832 |
| Split cold read | 1,077.577 | 18,249,096 |
| Native cold read | 2,032.366 | 32,521,056 |
| Split mixed | 1,014.271 | 17,873,592 |
| Native mixed | 898.724 | 137,084,872 |
| Split structural fallback | 705.785 | 109,081,720 |
| Native structural update | 1,468.066 | 219,244,992 |

The split hot arm reduced WAL for this same-row case by about 86.5%. Cold reads and structural updates can favor native JSONB. The run ended with `VACUUM (ANALYZE)`, `REINDEX`, `check_all(true)`, and table statistics showing zero dead tuples after maintenance; these are observations of a short run, not long-term bloat evidence.

## Limits and reproduction

Only the dedicated APIs promise the fast path. Regular changed-document view DML repacks; same-row writers still serialize; indexed hot columns may prevent HOT. RLS, partitioned managed relations, view `ON CONFLICT`, automatic logical replication reassembly and general duality views are excluded. See the [support matrix](support-matrix.md) and [production runbook](production-runbook.md).

Reproduce with `./scripts/test-remote.sh root@10.10.10.131 /usr/local/pgsql-18.6`. The script copies the toolchain and stops only its own temporary cluster.
