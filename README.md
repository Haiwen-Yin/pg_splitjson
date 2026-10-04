# PostgreSQL Split JSON Storage Extension

**PG SplitJSON · `pg_splitjson` · 0.1.0**

**English** | [简体中文](README.zh-CN.md) · [Documentation](docs/README.md) · [Project introduction](docs/introduction.md) · [API reference](docs/api-reference.md) · [Release note](RELEASE_NOTE.md)

Licensed under the [Apache License 2.0](LICENSE) (`Apache-2.0`).

A PostgreSQL 18 extension for frequent JSON field updates. Declared hot paths are stored in separate ordinary columns; the remaining content is stored in a TOASTable `splitjson.cold` template. Applications read and write a view containing `id`, `doc` and optional business columns. **Dedicated APIs update existing hot fields and object/array subtrees without reading or rewriting the cold template. Version 0.1.0 also supports fixed array hot paths and automatic SELECT query rewriting.**

Version 0.1.0 is an initial implementation with a buildable, tested business view and dedicated update APIs. `splitjson.cold` is a new internal envelope that reuses PostgreSQL JSONB payloads. It does not replace the core JSONB format or add native hidden columns.

The installation name is `pg_splitjson`; SQL APIs use `splitjson.*`. PostgreSQL reserves the `pg_` schema prefix, so the public and private schemas are `splitjson` and `splitjson_storage`. The extension version is **0.1.0**.

## Design background

Yin Haiwen's article [“JSON改一个字段，凭什么要重写整篇？”](https://blog.csdn.net/yhw1809/article/details/164757146) describes stock, prices, order state and other frequent updates whose small logical changes can generate substantial physical work. Its suggestion to extract frequently updated fields into ordinary columns informs the extension's hot/cold layout. JSON remains the business interface while the update unit becomes a separate column.

Choose paths using update frequency, field presence, value size and read patterns. Reusing cold TOAST reduces one part of the cost; row versions, locking, index maintenance and vacuum remain. See the [design and workload guide](docs/design-rationale.md) for storage-model comparisons, application scenarios, a product example and operational metrics.

## Quick start

Run as the extension installer in a test database where the extension files have been installed:

```sql
CREATE EXTENSION pg_splitjson;

-- Declare storage paths using key arrays to avoid ambiguity in dotted names.
SELECT splitjson.create_table('public.events',
    '[["stats","count"],["state"]]'::jsonb);

INSERT INTO public.events VALUES
    (1, '{"stats":{"count":1},"state":"new","payload":{"large":"cold"}}'),
    (2, '{"payload":"no hot fields"}');

-- An existing exact hot field: update only its separate column.
SELECT splitjson.set_field('public.events', 1,
    ARRAY['stats','count'], '2'::jsonb);

-- An atomic batch of existing exact hot fields produces one UPDATE.
SELECT splitjson.set_fields('public.events', 1,
    '[{"path":["stats","count"],"value":3},{"path":["state"],"value":"ready"}]');

-- Calculate under the row lock to avoid lost counter increments.
SELECT splitjson.increment_field('public.events', 1, ARRAY['stats','count'], 0.5);

-- A cold field: restore, apply native jsonb_set, and repack all hot fields.
SELECT splitjson.set_field('public.events', 1,
    ARRAY['payload','large'], '"changed"'::jsonb);

SELECT * FROM public.events; -- Only id and the complete doc.

-- Creating a missing field falls back; subsequent writes can use the fast path.
SELECT splitjson.set_field('public.events', 2, ARRAY['state'], 'null'::jsonb);
SELECT splitjson.set_field('public.events', 2, ARRAY['state'], '"ready"'::jsonb);
SELECT splitjson.delete_field('public.events', 2, ARRAY['state']);

-- Ordinary SQL DML is supported; whole-document updates repack the document.
UPDATE public.events SET doc = jsonb_set(doc, '{state}', '"done"') WHERE id = 1;
DELETE FROM public.events WHERE id = 2;
```

## Update semantics

| Operation | Path or condition | Behavior |
| --- | --- | --- |
| `set_field` | Existing exact hot path | Row lock; update only hot_N; reuse the cold TOAST pointer |
| `set_field` | Hot field was missing | Apply native JSONB update and repack |
| `set_field` | Existing hot object/array descendant | Update only the hot subtree |
| `set_field` | Cold path or hot-path ancestor | Restore, update, and synchronize all separate columns |
| `delete_field` | Existing hot object/array descendant | Update only the hot subtree |
| `delete_field` | Whole hot slot or structure outside a hot subtree | Native deletion and repack all slots |
| `set_fields` | All operations within existing hot paths/subtrees | Interpret in order; merge into one UPDATE; reuse cold |
| `set_fields` | Mixed hot/cold, new fields or structural changes | Restore once, apply in order, and repack in one write |
| `increment_field` | Existing JSON number | Exact numeric addition under the row lock; hot path reuses cold |
| `UPDATE view SET doc=...` | Logical document changed | Repack the document |
| `UPDATE view SET business_column=...` | doc unchanged | Update ordinary columns; reuse cold |
| INSERT | All declared paths missing | Preserve the original JSONB template payload without adding fields |

The optional fifth `set_field` argument, `create_missing`, defaults to `true`. It follows PostgreSQL `jsonb_set`: missing intermediate objects are not created. Boolean update results indicate whether the row was found, not whether its value changed or the fast path was used.

`set_fields` accepts 1–64 operations containing exactly `path` and `value`, applied in array order. The last value wins for repeated paths; ancestor/descendant operations are evaluated in order. Any error rolls back the entire batch. Its fourth argument, `create_missing`, defaults to true; the result indicates row existence.

The fourth `increment_field` argument is a finite numeric delta, defaulting to 1. Negative and fractional deltas are supported, and the new numeric value is returned. A missing row returns SQL NULL. A missing field, JSON null, a nonnumeric target or a NaN/Infinity delta raises `22023`; counters are not implicitly created.

`id` and the business document cannot be SQL NULL. Documents may be JSON null, scalars, arrays or objects. SQL NULL in a hot column means missing; `'null'::jsonb` means a present JSON null. Business APIs reject SQL NULL arguments. Hot values may be scalars, objects, arrays or JSON null. Declare 1–64 nonoverlapping paths, each at most 64 levels deep. Keys may contain dots, quotes, digits or empty strings. Declared strings address object keys; nonnegative integers address fixed array indexes: `["items",0,"price"]` differs from `["items","0","price"]`. Operation `text[]` paths follow native object/array semantics, including negative indexes. Missing slots, parent replacement and position shifts outside a hot subtree repack all slots. A declared container-type mismatch means missing.

Both fast and fallback updates lock the row. Dedicated updates to different fields in the same row serialize and retain both changes. Ordinary view UPDATE/DELETE raises `40001` when the old document or a business column was concurrently changed; retry the statement or transaction. Handle other PostgreSQL isolation errors normally. Use `increment_field` for counters: reading a value in the application and then calling `set_field` can still lose increments.

## Business columns and migration

The third `create_table` argument maps business column names to SQL type declarations, with at most 64 columns. Typmods, arrays and schema-qualified domains are supported. Values retain their native types; no additional NOT NULL constraints or defaults are added. Column names cannot be id/doc.

```sql
SELECT splitjson.create_table('public.orders',
    '[["stats","count"],["state"]]',
    '{"tenant_id":"bigint","note":"text","amount":"numeric(18,4)","created_at":"timestamptz"}');

INSERT INTO public.orders(id,doc,tenant_id,note,amount,created_at)
VALUES (1,'{"stats":{"count":0},"state":"new"}',100,'first',12.3456,now());
UPDATE public.orders SET note='changed',amount=20.1234 WHERE id=1;
SELECT splitjson.increment_field('public.orders',1,ARRAY['stats','count']);
SELECT * FROM public.orders; -- Business columns are visible; cold/hot/extra are hidden.

-- A separate migration example: copy an ordinary table into a new managed view.
CREATE TABLE public.old_orders (id bigint PRIMARY KEY, doc jsonb NOT NULL, tenant_id bigint);
INSERT INTO public.old_orders VALUES (1, '{"state":"new","stats":{"count":0}}', 100);
SELECT splitjson.migrate_table('public.old_orders','public.new_orders',
    '[["stats","count"],["state"]]');
```

`migrate_table(source,target,paths,doc_column DEFAULT 'doc',id_column DEFAULT 'id')` performs a snapshot copy of an ordinary table within a transaction and leaves the source unchanged. The identifier must be bigint and the document jsonb. Extra column data, types and typmods are copied. The last two arguments allow custom source column names. Invalid data rolls back both target DDL and the copy.

Migration does not copy defaults, NOT NULL constraints, indexes, foreign keys, triggers, column collations or permissions, and does not track later source writes. Before switching applications, arrange a write pause or synchronization, compare the data, and grant target permissions as needed. The source table is not automatically converted into a view.

## Hot field reads and query indexes

```sql
-- The installer creates a B-tree on a registered hot path.
SELECT splitjson.create_path_index('public.orders','orders_state_idx',ARRAY['state']);

-- Existing hot paths/subtrees read hot values; other paths restore the document.
SELECT splitjson.get_field('public.orders',1,ARRAY['state']);

-- Filter the hot column by JSONB equality; PostgreSQL can use the B-tree.
SELECT id,tenant_id,note FROM public.orders
WHERE id IN (SELECT splitjson.find_ids('public.orders',ARRAY['state'],'"new"'));

-- The installer can inspect the internal plan used by find_ids.
SELECT * FROM splitjson.explain_find_ids('public.orders',ARRAY['state'],'"new"');
```

`get_field` and `find_ids` honor statement/MVCC snapshots and require SELECT on the view's id/doc columns. Missing fields return SQL NULL; JSON null returns JSONB null. Reads follow native object/array paths, including negative indexes. Numeric paths search undeclared shapes through a document fallback when no candidate hot slot is present. `find_ids` returns bigint IDs without an ordering guarantee. Nonhot paths filter the restored logical document.

Query indexes support JSONB equality or native root text extraction. A missing SQL NULL does not match JSON null. Hot updates maintain the index, which may prevent HOT updates; cold TOAST can still be reused. PostgreSQL chooses indexes based on cost.

Load the module before planning to enable automatic SELECT rewriting. For a test session, run `LOAD` as the installer; administrators can configure `session_preload_libraries = 'pg_splitjson'` for application sessions. Installation and preload configuration apply to your chosen instance; the lab script configures only its temporary instance.

```sql
LOAD 'pg_splitjson';
SELECT splitjson.create_path_index('public.orders','orders_state_text_idx',ARRAY['state'],'text');
EXPLAIN SELECT id FROM public.orders WHERE doc->>'state'='new';
SET splitjson.enable_query_rewrite=off; -- Also invalidates cached plans.
SET splitjson.enable_query_rewrite=on;
```

Exact constant object extraction paths and typed array chains can map to hot columns. Dynamic paths, ambiguous numeric `#>`/`#>>` segments, a final `->0`/`->>0` and whole view-row references retain native behavior. Parameter comparison values are supported. View permissions and security barriers are preserved. See the [array and query guide](docs/roadmap.md).

## Internal storage and permissions

```text
Business view:                 id | complete doc(JSONB) | business columns
                                     restored on reads
Private splitjson_storage.s_N: id | cold(splitjson.cold) | hot_N(JSONB) | extra_N(native type)
                                    null placeholders    hot values     business mapping
```

Cold values contain a format version and the path list. Null placeholders are interpreted only at declared hot paths; there is no special JSON object that can collide with user data. When no fields match, the original JSONB payload is preserved with version/path envelope overhead. See the [storage format](docs/storage-format.md).

The extension installer creates managed tables. Grant permissions on the **view** to an existing application role `app_role`; do not grant access to the private schema, storage tables or metadata. This example continues using `events` from the quick start:

```sql
GRANT USAGE ON SCHEMA public, splitjson TO app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.events TO app_role;
```

Update APIs check the effective caller's view `doc` UPDATE privilege, including SET ROLE and SESSION AUTHORIZATION. Read APIs check SELECT on id/doc; managed deletion requires ownership of the view. Table creation, migration, query index management and plan inspection are installer operations. Superusers and the installer can inspect internal data.

A “storage index” means the hot-path layout declaration. `create_path_index` creates a separate, actual B-tree query index. They are managed separately.

## Build and validation

Release artifacts are stored in `build_output/<version>/`. For 0.1.0, the source ZIP and its SHA-256 file are `build_output/0.1.0/pg_splitjson-0.1.0.zip` and `build_output/0.1.0/pg_splitjson-0.1.0.zip.sha256`. Git ignores this generated output directory.

Requirements: PG18 server headers/PGXS, a C compiler, make, and PostgreSQL's PL/pgSQL. Full validation also needs PG18 `pageinspect` for tests. Use an isolated PG18 installation prefix for these commands; `make install` writes to the selected installation:

```sh
make PG_CONFIG=/path/to/isolated/pg18/bin/pg_config
make PG_CONFIG=/path/to/isolated/pg18/bin/pg_config install
```

Run the full suite as root on a dedicated test host with an existing non-root OS account and a PG18 installation to copy:

```sh
PG_SPLITJSON_RUN_AS=postgres bash scripts/lab.sh /path/to/pg18
```

The runner creates a fresh temporary installation, PGDATA and private socket, and stops only its own lab. The selected PG18 installation is a read-only copy source.

Validation covers 256 document shapes, one-write batches, atomic increments, business columns, migration rollback, permissions, concurrency and snapshots, index plans, TOAST pointer/chunk reuse, and all new APIs after `pg_dump/pg_restore`. See the included test scripts to reproduce the checks.

## Backup and limitations

Whole-database `pg_dump -Fc` / `pg_restore` has been verified. Metadata records qualified relation names; extension configuration tables and the naming sequence are dumped without depending on original database OIDs. For logical migration, copy `SELECT * FROM view` into ordinary JSONB/business columns.

Version 0.1.0 uses fixed id/doc names and supports additional business columns. Hot paths cannot be changed dynamically. Do not modify internal tables or directly DROP/RENAME managed views or storage tables. Use `splitjson.drop_table`:

```sql
-- Run when the example data is no longer needed; remove view, storage and metadata.
SELECT splitjson.drop_table('public.events');
```

View `ON CONFLICT`, RLS, partitioning, automatic logical replication reassembly and full ORM transparency are not provided. A `pg_dump -t` of only a business view does not include all storage dependencies; use a whole-database backup or logical export.

PostgreSQL MVCC still creates a new heap tuple. Small inline templates are copied with each row version, and large hot values may generate their own TOAST writes. The optimization avoids rewriting a large unchanged cold value; reading a complete JSON document requires reassembly, and ordinary UPDATE does not guarantee a fast update.

The early unpublished prototype was named `pgjson`. The renamed extension remains at 0.1.0 and has no in-place upgrade from that prototype or earlier unpublished 0.1.0 builds. Do not overwrite a loaded library for an online same-version upgrade; logically migrate into a fresh installation. Logically export prototype data into newly created SplitJSON views, or use `migrate_table` for an ordinary JSONB table. Historical logs retain the old name.

OpenSpec records requirements, decisions and implementation work. The [arrays and query guide](docs/roadmap.md) describes implemented 0.1.0 behavior and remaining boundaries. General duality views are outside the project's scope. Further work may evaluate constraints/defaults and dynamic layout migration.
