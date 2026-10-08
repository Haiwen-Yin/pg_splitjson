# PG SplitJSON 0.2.0 release note

**English** | [简体中文](RELEASE_NOTE.zh-CN.md) · [README](README.md) · [API reference](docs/api-reference.md)

**PostgreSQL Split JSON Storage Extension (PG SplitJSON) 0.2.0** is the production-hardening release for PostgreSQL 18. It was verified on PostgreSQL 18.6 on Linux x86_64 and is licensed under [Apache License 2.0](LICENSE) (`Apache-2.0`).

PG SplitJSON separates declared frequently updated JSON paths into ordinary private columns and stores the remaining document in a versioned TOASTable cold template. A business view exposes `id`, complete JSONB `doc`, and optional typed business columns. Dedicated APIs can update existing hot paths without reading or assigning the cold template.

## What is new in 0.2.0

- A real 0.1.0 to 0.2.0 extension upgrade with preflight rejection of unknown historical builds. Existing cold v1/v2 values, hot indexes, data and view privileges remain usable.
- Least-privilege defaults: internal and management functions are not PUBLIC-executable; `splitjson.grant_access` grants a chosen role only the view and read/write APIs it needs.
- Mapping drift checks, database-level DDL protection, controlled rename/drop, business-column defaults and constraints, table statistics, index DDL review, and `check_table`/`check_all` consistency checks.
- Validated cold binary send/receive, planner-registration checks, stack/interruption bounds, and portable text-backed binary COPY round trips.
- Reproducible installcheck, randomized differential, upgrade, permissions/DDL, concurrency, TOAST, dump/restore, crash recovery, PITR, streaming standby and promotion tests.
- A bounded production-style workload harness and CI jobs for a normal PG18 build, cassert build and sanitizer compile.

## Compatibility and operating contract

- The tested support target is PostgreSQL 18.6 on Linux x86_64. Physical backup, streaming replication and PITR require the same PostgreSQL minor/ABI and the installed `pg_splitjson` library and SQL files. Move between PostgreSQL major versions with logical export/import or `splitjson.migrate_table`.
- The fast-update contract applies to dedicated `set_field`, `set_fields`, `delete_field` and `increment_field` calls that hit existing hot paths. Ordinary changed-document view DML restores and repacks the document; it synchronizes hot columns but is not a fast-path guarantee.
- The implementation preserves MVCC, WAL, row locks and PostgreSQL TOAST. A changed indexed hot column can prevent HOT; unchanged large cold values can still reuse their external TOAST pointer.
- RLS, partitioned managed views/tables, view `ON CONFLICT`, automatic logical-replication reassembly, and fully transparent ORM updates are outside this release. General Oracle-style duality views are outside project scope.
- Migration is a snapshot copy into a new managed relation. It does not copy source defaults, constraints, indexes, triggers, permissions, collations or later writes. Arrange a cutover and compare the result before granting application access.
- A `pg_restore` into a new database must use the documented installer-controlled `session_replication_role=replica` restore flow, then run `splitjson.check_all(true)`. Do not overwrite a loaded shared library during an in-place upgrade.

## Installation and upgrade

Build against the selected PG18 `pg_config`:

```sh
make PG_CONFIG=/path/to/pg18/bin/pg_config
make PG_CONFIG=/path/to/pg18/bin/pg_config install
```

For a new database, run `CREATE EXTENSION pg_splitjson;`. For an official 0.1.0 installation, install the 0.2.0 library and SQL files, reconnect sessions, and run:

```sql
ALTER EXTENSION pg_splitjson UPDATE TO '0.2.0';
SELECT splitjson.check_all(true);
```

The upgrade is transactional and refuses an unrecognized historical 0.1.0 catalog. Use logical migration for earlier prototypes or altered layouts.

## Validation evidence

The complete isolated PG18.6 run passed installcheck, upgrade, 5000 seeded JSONB differential operations, permission and DDL checks, concurrent increments, physical cold TOAST pointer/chunk reuse, dump/restore, immediate crash recovery, named-restore-point PITR, streaming replay and standby promotion. The raw evidence is under [docs/validation/pg-splitjson-0.2.0/](docs/validation/pg-splitjson-0.2.0/); the report explains the limits of each measurement.

In the bounded four-client, eight-second workload, the split hot update arm produced 9,147,136 WAL bytes versus 68,009,496 for the native JSONB arm; split hot updates reached 1,019.998 versus 350.398 reported TPS for that run. These values are workload-specific evidence, not a throughput or SLA promise. Cold reads and structural updates can favor native JSONB, and concurrent writers still contend on the same row.

## Source archive

The reproducible source archive is `build_output/0.2.0/pg_splitjson-0.2.0.zip` with the external checksum `build_output/0.2.0/pg_splitjson-0.2.0.zip.sha256`. It contains the source, installation/upgrade SQL, tests and paired public documentation. It excludes Git metadata, local labs, database files, dumps, compiled objects, OpenSpec history, agent instructions and article working material.

See the [API reference](docs/api-reference.md), [production runbook](docs/production-runbook.md), [support matrix](docs/support-matrix.md) and [0.2.0 validation report](docs/validation.md) before deployment.
