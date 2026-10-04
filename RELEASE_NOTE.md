# PG SplitJSON 0.1.0 release note

**English** | [简体中文](RELEASE_NOTE.zh-CN.md) · [README](README.md) · [API reference](docs/api-reference.md)

**PostgreSQL Split JSON Storage Extension (PG SplitJSON) 0.1.0** is the initial source release for PostgreSQL 18, verified on PostgreSQL 18.6. It is licensed under [Apache License 2.0](LICENSE) (`Apache-2.0`).

PG SplitJSON separates frequently updated JSON paths into ordinary columns and stores the remaining document in a versioned cold template. Applications access a business view containing `id`, complete JSONB `doc` and optional business columns. Dedicated APIs can update existing hot fields and object/array subtrees without reading or rewriting cold.

## Main features

- Separate hot storage with missing-field and JSON null semantics. Documents without declared fields retain their original JSONB template payload.
- Single-field replacement, ordered atomic batches, deletion and exact numeric increments under a row lock. All-hot batches produce one physical UPDATE; fallback operations repack and synchronize all slots.
- Native array operations and fixed array hot paths. Declaration `["items",0,"price"]` uses an array index; `["items","0","price"]` uses an object key. Operation paths support negative indexes. Structural shifts outside a hot subtree repack the document.
- Automatic exact constant-path SELECT rewriting, direct field reads, equality ID searches and JSONB/text B-tree indexes. Original view permissions and security barriers are preserved.
- Up to 64 hot paths with 64 segments per path, plus up to 64 typed business columns. Snapshot migration from ordinary bigint/JSONB tables preserves the source.
- Cold format v2 writes with v1/v2 reads, MVCC consistency, stale ordinary view DML detection, whole-database dump/restore and paired English/Chinese documentation.

## Installation and planner loading

Requires PostgreSQL 18 server headers, PGXS, a C compiler, make and PL/pgSQL. Build and install into the selected PG18 installation:

```sh
make PG_CONFIG=/path/to/pg18/bin/pg_config
make PG_CONFIG=/path/to/pg18/bin/pg_config install
```

In the selected database, run as the extension installer:

```sql
CREATE EXTENSION pg_splitjson;
LOAD 'pg_splitjson';
SHOW splitjson.enable_query_rewrite;
```

Automatic rewriting requires the module to be loaded before planning. Administrators can configure `session_preload_libraries = 'pg_splitjson'` for application sessions. `splitjson.enable_query_rewrite` defaults to on after module load; changing it invalidates cached plans.

The installation identifier is `pg_splitjson`, the public API schema is `splitjson`, and the private storage schema is `splitjson_storage`. See [README](README.md) for examples and application grants.

## Compatibility and limitations

- This release adds an internal storage envelope and managed views. PostgreSQL still creates heap row versions; complete-document reads require reconstruction. Ordinary changed-document UPDATE repacks and does not automatically become a fast update.
- Dynamic query paths, ambiguous numeric `#>`/`#>>` segments, final `->0`/`->>0` scalar extraction and whole view-row references retain native expressions/plans. Optimization covers supported SELECT forms, with matching indexes chosen by PostgreSQL cost estimates.
- Fixed array slots identify positions, not business identities. Array wildcards and dynamic hot layouts are unsupported. Updating a whole hot array still rewrites that array, and fields in the same row share a row lock.
- View `ON CONFLICT`, RLS, partitioning, automatic logical replication reassembly and full ORM transparency are not provided. Use whole-database backup or logical export; a view-only dump omits storage dependencies.
- Migration copies data and types, not defaults, constraints, permissions, collations or later source writes. Earlier unpublished `pgjson` and 0.1.0 builds require a fresh installation and logical migration; no same-version online library overwrite is supported. Reading cold v1 does not imply an in-place extension upgrade.

Detailed contracts: [API reference](docs/api-reference.md), [array and query guide](docs/roadmap.md), [storage format](docs/storage-format.md).

## Validation and distribution

The PG18.6 suite passed semantic, concurrency, permission, real index-plan and whole-database dump/restore checks. It includes 338 native JSONB array differential cases and verifies that indexed fixed-array updates and hot-array subtree operations preserve the cold 18-byte external TOAST pointer and chunks. These results validate the tested behavior; production performance depends on the workload.

The source ZIP is `pg_splitjson-0.1.0.zip`, with an external `.zip.sha256` checksum file. Artifacts are stored under `build_output/0.1.0/`. The ZIP contains project source, installation files, license, public documentation and tests. Local build outputs, experiment reports/logs, Git metadata, agent guidance and development archives are excluded.
