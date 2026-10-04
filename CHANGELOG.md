# PG SplitJSON changelog

**English** | [简体中文](CHANGELOG.zh-CN.md) · [Documentation](docs/README.md)

## 0.1.0

The initial unpublished version is named PostgreSQL Split JSON Storage Extension, with installation identifier `pg_splitjson` and API schema `splitjson`.

- Versioned cold templates and separate hot columns, with a business view hiding the internal layout.
- Licensed under Apache License 2.0 (`Apache-2.0`).
- Single-field and batch updates, atomic numeric increments, and cold TOAST reuse for hot updates.
- Up to 64 typed business columns, with native value transfer for typmods, arrays and domains.
- Snapshot data migration from ordinary bigint/JSONB tables, preserving the source and rolling back on failure.
- Hot-path B-tree query indexes, field reads and equality ID searches, plus installer-only plan inspection.
- Whole-row view concurrency detection, role permissions, MVCC snapshots and whole-database backup/restore.
- Fully isolated PG18.6 validation of semantics, concurrency, physical TOAST reuse, index planning and WAL.
- Paired English and Simplified Chinese documentation, project introductions and API references with shared naming and examples.
- Article-informed design and workload guidance covering storage choices, hot-path selection, query/index trade-offs and physical-table monitoring.
- Native array operations and hot object/array subtree routing; typed fixed array hot slots with synchronized structural repacking.
- Cold format v2 writes with v1 reads, plus JSONB/text and typed-path index overloads.
- Automatic exact-path SELECT rewriting with planner preload, an enable switch, preserved permissions/barriers and prepared-plan invalidation.
- Array differential, concurrency, indexed cold TOAST reuse and dump/restore tests; paired current capability and validation documentation.

The early `pgjson` prototype and previous unpublished builds used the same version number. Migration requires a fresh installation and logical data transfer; no online library overwrite, in-place system catalog rename or same-version upgrade script is provided.
