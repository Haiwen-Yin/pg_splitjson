# Introducing PG SplitJSON

**English** | [简体中文](introduction.zh-CN.md) · [Documentation](README.md)

## Official identity

| Item | Value |
| --- | --- |
| Full English name | PostgreSQL Split JSON Storage Extension |
| Short name | PG SplitJSON |
| Chinese description | PostgreSQL JSON 分离存储扩展 |
| Extension identifier | `pg_splitjson` |
| Extension version | `0.3.0` |
| License | [Apache License 2.0](../LICENSE) (`Apache-2.0`) |
| Target / verified PostgreSQL | 18 / 18.6 |
| Public API schema | `splitjson` |
| Private storage schema | `splitjson_storage` |
| Internal cold format version | New writes `2`; reads `1`/`2` |

Use the full English name on first mention, followed by **PG SplitJSON**. Use `pg_splitjson` in installation commands and `splitjson.*` in SQL examples. The Chinese description accompanies the same product name; it is not a separate extension identifier.

## Short introduction

**PostgreSQL Split JSON Storage Extension (PG SplitJSON)** is a PostgreSQL 18 extension for frequent JSON field updates. It separates declared hot paths into ordinary columns and stores the rest in a versioned cold template. A business view exposes complete JSONB documents, while dedicated APIs update existing hot fields without rewriting the cold template.

## Full introduction

Large JSONB documents often contain a few fields that change frequently, such as counters, state and progress. Repeatedly rebuilding the document for those changes can create substantial TOAST and WAL writes. PG SplitJSON lets a table's designer declare frequently updated object or fixed array paths and store their values separately from the rest of the document.

The private heap table holds a versioned JSONB template, null placeholders at existing hot paths, and separate JSONB hot columns. Missing declared fields remain missing. A business view reconstructs the complete `doc` and exposes `id` plus optional typed business columns, keeping the internal layout out of the application's ordinary reads.

The update APIs provide single-field replacement, ordered atomic batches and exact numeric increments under a row lock. Existing exact hot fields and hot object/array descendants change only their hot columns. Nonhot updates, first-time creation and structural changes outside a hot subtree restore and repack, synchronizing all slots in the same transaction.

PG SplitJSON also offers snapshot data migration from ordinary bigint/JSONB tables, direct hot-field reads, equality searches and optional native B-tree indexes on hot columns. The implementation uses PostgreSQL's heap, MVCC, WAL and TOAST mechanisms; it does not require a PostgreSQL core patch.

## Design background

Yin Haiwen's [article on frequent JSON updates](https://blog.csdn.net/yhw1809/article/details/164757146) emphasizes splitting hot fields from semistatic attributes and treating JSON as an access layer over relational storage. PG SplitJSON makes this practical for declared paths in one PostgreSQL row, keeping one authoritative hot value and a cold template with placeholders. General duality views are outside the project's scope.

The [design and workload guide](design-rationale.md) connects this idea to product/SKU, order, inventory and logistics scenarios, and explains path selection, query/index costs and vacuum observation. Cold reuse improves write behavior while MVCC and same-row lock contention remain.

## Capabilities in 0.3.0

| Area | Capability |
| --- | --- |
| Updates | Single-field updates, one-write batches and atomic numeric increments |
| Business tables | id/doc view, up to 64 typed business columns and snapshot migration |
| Arrays | Native array operations, hot subtrees and typed fixed-position slots |
| Queries | Direct reads, JSONB equality search, JSONB/text indexes and automatic exact-path SELECT rewriting |
| Correctness | Missing vs JSON null, row locks, stale view DML detection and permission checks |
| Validation | PostgreSQL 18.6 semantics, concurrency, index plans, cold TOAST reuse and whole-database dump/restore |

## Scope and evidence

Version 0.3.0 keeps PostgreSQL's heap, MVCC, WAL and TOAST mechanisms and adds caller-aware RLS, id-only HASH/RANGE storage, revision tokens, upsert/Patch/Merge Patch, typed indexes and range helpers, snapshot portability, online WAL migration, same-layout logical replication and recovery epoch initialization. Existing exact hot updates reuse the cold TOAST value; complete reads reconstruct the document. The [validation report](validation-030.md) records the final PG18.6 labs and workload-specific measurements.

The release supports nested object paths and fixed array indexes, native operation semantics, explicit text collation and safe exact-path query rewriting. Dynamic wildcards, cross-layout automatic logical reassembly, view `ON CONFLICT`, non-id partition keys and general duality views remain outside scope. For installation and examples, see the [README](../README.md); for exact signatures, see the [API reference](api-reference.md).
