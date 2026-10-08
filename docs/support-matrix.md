# PG SplitJSON 0.2.0 support matrix

**English** | [简体中文](support-matrix.zh-CN.md) · [Documentation](README.md)

| Area | Supported / verified | Boundary |
| --- | --- | --- |
| PostgreSQL | 18.6, PGXS build and isolated regression verified | Other major versions are not claimed; use logical migration across majors |
| OS / CPU | Linux x86_64, 64-bit, GCC 8.5 lab evidence | Other platforms require their own build and validation |
| Physical HA | Crash recovery, WAL archive PITR, streaming replay and standby promotion verified | Same PostgreSQL minor/ABI and extension files required |
| Logical backup | Whole-database `pg_dump -Fc`/`pg_restore` verified | View-only `pg_dump -t` omits storage dependencies |
| JSON values | Objects, arrays, scalars, JSON null; missing differs from JSON null | SQL NULL documents/IDs rejected |
| Hot paths | Nested object paths and fixed nonnegative array indexes, up to 64 paths × 64 segments | No overlap, wildcards or dynamic layout changes |
| Updates | Dedicated single, batch, delete and numeric increment APIs; native fallback for structural changes | Ordinary changed-document DML repacks; no partial JSONB page update |
| Queries | Direct reads, equality helpers, JSONB/text B-trees and tested exact SELECT rewrite | Dynamic paths, unsupported casts/collations and arbitrary query forms retain native plans |
| Security | View security barrier, role grants and internal storage isolation | RLS is not supported for managed relations |
| Relations | Business views over private ordinary heap tables; typed business columns | Partitioned managed relations and view `ON CONFLICT` are unsupported |
| Replication | Physical replication and promotion tested | Automatic logical replication reassembly is not provided |
| API integration | Explicit dedicated API contract | Full ORM transparency and general Oracle-style duality views are out of scope |

All performance numbers are workload-specific evidence. Validate latency, WAL, lock waits, index cost, vacuum and bloat on the target workload before production approval.
