# PG SplitJSON 0.3.0 support matrix

**English** | [简体中文](support-matrix.zh-CN.md) · [Documentation](README.md)

Release support matrix for PostgreSQL 18.6/Linux x86_64. See [validation-030](validation-030.md) for the final isolated lab evidence.

| Area | Supported / verified | Boundary |
| --- | --- | --- |
| PostgreSQL | 18.6, PGXS build and isolated regression verified | Other major/minor versions are not claimed |
| OS / CPU | Linux x86_64, 64-bit, GCC 8.5 lab evidence | Other platforms require their own build and validation |
| Physical HA | Crash recovery, WAL archive PITR, streaming replay and standby promotion | Same PostgreSQL minor/ABI and extension files required |
| Logical backup | Whole-database `pg_dump -Fc`/`pg_restore` verified; JSONL snapshot export/import verified | View-only `pg_dump -t` omits private storage dependencies |
| JSON values | Objects, arrays, scalars, JSON null; missing differs from JSON null | SQL NULL documents/IDs rejected |
| Hot paths | Nested object paths and fixed nonnegative array indexes, up to 64 paths × 64 segments | No overlap, wildcards or arbitrary dynamic slots |
| Updates | Dedicated single, batch, delete, increment, row-token conditional write, upsert, JSON Patch and Merge Patch APIs | No JSONB page-in-place update; structural fallback repacks |
| Queries | Direct reads, equality/range helpers, JSONB/text/typed B-trees, suffix extraction and exact SELECT rewrite | Dynamic paths, unsafe casts/collations and arbitrary query forms retain native plans |
| Security | Native caller-aware storage RLS lifecycle, COPY, role grants, security barriers and private ACL checks | Policy expressions are deliberately restricted; installer owns policy DDL |
| Relations | Business views over private heap or id-only HASH/RANGE parents; typed business columns; per-leaf indexes | No other partition keys, subpartitioning or view `ON CONFLICT` |
| Online migration | Snapshot/WAL runner, unchanged-TOAST reconstruction, atomic progress, crash/resume, WAL-loss detection, final fence and abort | Application traffic switch remains explicit; source is retained/fenced |
| Logical replication | Same-layout PG18.6/0.3.0 native storage publication/subscription, worker status, pause/resume and verified takeover | No cross-layout reassembly, implicit DDL/ACL/policy copy or multi-primary |
| API integration | Dedicated API contract with production runbook and paired docs | Full ORM transparency and general Oracle-style duality views are out of scope |

All performance numbers are workload-specific evidence. Validate latency, WAL, lock waits, index cost, vacuum and bloat on the target workload.
