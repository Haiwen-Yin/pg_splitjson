# PG SplitJSON 0.1.0 API reference

**English** | [简体中文](api-reference.zh-CN.md) · [Documentation](README.md)

These are the business APIs of **PostgreSQL Split JSON Storage Extension (PG SplitJSON) 0.1.0**. Install `pg_splitjson`; use the `splitjson` schema. Signatures follow [the installation SQL](../sql/pg_splitjson--0.1.0.sql).

## Shared conventions

- `p_table` identifies a managed **business view**, not its private table. Use a schema-qualified relation name; PostgreSQL resolves it as `regclass`.
- Every managed view exposes `id bigint`, `doc jsonb` and optional business columns. id is unique; id/doc cannot be SQL NULL. The document can be any JSONB value, including JSON null.
- Declare 1–64 unique, nonoverlapping paths of 1–64 segments. Strings are literal object keys; nonnegative int32 integers are fixed array indexes: `[["items",0,"price"],["state"]]`. Numeric strings remain object keys. Operation paths are one-dimensional `text[]` without NULL segments, for example `ARRAY['items','0','price']`; batch paths are arrays of strings.
- Operation paths follow native JSONB object/array semantics, including negative indexes and native errors. Declared indexes are nonnegative and require real arrays. Missing paths or container-type mismatches are not extracted. Structural changes outside a hot subtree synchronize all slots by repacking.
- Missing and JSON null differ: SQL NULL in a hot slot means missing; `'null'::jsonb` is a present value. Business API arguments cannot be SQL NULL.
- Boolean update results indicate row existence. `true` does not imply a changed value or a fast update; `false` means no matching row. Queries return no rows or SQL NULL for an absent ID as described below.
- `p_create_missing` defaults to true and follows native `jsonb_set`. It does not create missing intermediate objects. False prevents creation of a missing final key; native scalar/path errors still apply.

## Signatures

The declarations below are a reference, not a SQL installation script.

```sql
splitjson.create_table(
    p_name text, p_paths jsonb, p_columns jsonb DEFAULT '{}'
) RETURNS regclass

splitjson.set_field(
    p_table regclass, p_id bigint, p_path text[], p_value jsonb,
    p_create_missing boolean DEFAULT true
) RETURNS boolean

splitjson.set_fields(
    p_table regclass, p_id bigint, p_updates jsonb,
    p_create_missing boolean DEFAULT true
) RETURNS boolean

splitjson.increment_field(
    p_table regclass, p_id bigint, p_path text[], p_delta numeric DEFAULT 1
) RETURNS numeric

splitjson.delete_field(
    p_table regclass, p_id bigint, p_path text[]
) RETURNS boolean

splitjson.drop_table(p_table regclass) RETURNS void

splitjson.migrate_table(
    p_source regclass, p_target text, p_paths jsonb,
    p_doc_column name DEFAULT 'doc', p_id_column name DEFAULT 'id'
) RETURNS regclass

splitjson.get_field(
    p_table regclass, p_id bigint, p_path text[]
) RETURNS jsonb

splitjson.find_ids(
    p_table regclass, p_path text[], p_value jsonb
) RETURNS SETOF bigint

splitjson.explain_find_ids(
    p_table regclass, p_path text[], p_value jsonb
) RETURNS SETOF text

splitjson.create_path_index(
    p_table regclass, p_name text, p_path text[]
) RETURNS regclass

splitjson.create_path_index(
    p_table regclass, p_name text, p_path text[], p_kind text
) RETURNS regclass

splitjson.create_path_index(
    p_table regclass, p_name text, p_path jsonb, p_kind text DEFAULT 'jsonb'
) RETURNS regclass
```

## Creation and migration

### create_table

Creates a business view, private heap table, write trigger and metadata mapping; returns the view's `regclass`. Run as the extension installer. `p_name` must include an existing schema and a new relation name, such as `public.events`. PostgreSQL quoted identifiers are accepted; identifiers must fit PostgreSQL's 63-byte limit.

`p_paths` declares the hot layout. `p_columns` defaults to `{}` and maps up to 64 business column names to SQL type strings. id/doc and empty names are prohibited. Typmods, arrays and schema-qualified domains retain native types. No extra defaults or NOT NULL constraints are added. The view lists id/doc first, then business columns in column-name order using the C collation; use explicit column lists in INSERT.

### migrate_table

Copies an ordinary source table into a **new** managed view in one transaction. `p_source` must have distinct bigint and JSONB columns named by `p_id_column` and `p_doc_column`. `p_target` is schema-qualified; `p_paths` declares its hot layout. The result is the new view's `regclass`. Run as the installer with source SELECT permission.

The copy preserves IDs, documents, extra column data, types and typmods. The source stays unchanged; invalid data, including duplicate IDs or SQL NULL documents, rolls back the target creation and copy. Extra columns follow the same count/name/type rules as `create_table`.

Defaults, constraints, indexes, triggers, column collations and permissions are not copied. Later source writes are not synchronized. This is a snapshot migration, so arrange a write pause or synchronization and verify the copy before switching applications. Custom source column names become id/doc in the target.

### drop_table

Removes the managed view, private table and mapping in a transaction. Requires view ownership or the owner's role privileges. It does not use CASCADE: resolve dependent objects first. Use this API rather than directly dropping or renaming managed objects.

## Updates

### set_field

Locks the row and replaces one object/array-path value. An existing exact hot path or descendant inside a hot object/array updates only its hot column, without reading or assigning cold. Missing hot slots, nonhot paths, parent replacement and structural position changes outside a hot subtree restore the document, apply native `jsonb_set`, and repack all hot values. Scalar hot ancestors use this fallback to retain native behavior. Returns a boolean for row existence. Requires UPDATE on the view's doc column.

### set_fields

Applies an ordered, atomic array of 1–64 operations. Each object must contain **exactly** `path` (a JSON array of string keys) and `value` (any JSON value). Repeated paths use the last value; ancestor/descendant changes are evaluated in order.

If every operation targets an existing hot field or hot object/array descendant, only hot columns are read and one physical UPDATE is issued. Otherwise the document is restored once, operations are applied in order, and one repack/write follows. Any failure rolls back the entire batch. Returns a boolean for row existence. Requires doc UPDATE.

### increment_field

Reads and adds `p_delta` to an existing JSON number under the same row lock. It uses exact PostgreSQL numeric arithmetic, supports negative/fractional deltas, and defaults to 1. An existing exact hot path or hot object/array descendant updates only its hot column; other paths repack the document. Other hot values and business columns are preserved.

Returns the new numeric value, or SQL NULL for a missing row. A missing field, JSON null, a nonnumeric target or a nonfinite delta raises `22023`. It does not initialize missing counters. Requires doc UPDATE.

### delete_field

Locks the row and applies native JSONB path deletion. A descendant inside an existing hot object/array changes only its hot column. Deleting an entire hot slot or a structure outside a hot subtree restores and repacks all fields, removing placeholders and synchronizing shifted positions. Native missing/type/path behavior applies. Returns a boolean for row existence. Requires doc UPDATE, not the view's row DELETE privilege.

## Reads and query indexes

### get_field

Returns a JSONB field value. Existing exact hot paths or hot object/array descendants read hot values; other paths read the restored document. A missing row or path returns SQL NULL; present JSON null returns JSONB null. Requires SELECT on both id/doc. As a STABLE function, it honors the statement's MVCC snapshot.

### find_ids

Returns IDs whose field equals `p_value` using native JSONB equality. Exact hot paths filter the hot column directly and can use a B-tree index; other paths filter the restored document. A JSON null search excludes missing fields. No match returns an empty set, and result order is unspecified. Requires id/doc SELECT and honors the statement's MVCC snapshot.

Numeric operation paths can access undeclared object/array shapes; rows with no present candidate slot use a native document fallback. Add an outer ORDER BY if order matters. Automatic ordinary SELECT rewriting is described below.

### create_path_index

Creates a native, nonunique B-tree on an already registered hot slot; returns the index's `regclass`. The original three-argument `text[]` overload uses JSONB. Four-argument overloads select `p_kind = 'jsonb'` or `'text'`; text indexes use `(hot_N #>> '{}'::text[])`. A typed JSONB path distinguishes indexes from object keys and defaults to JSONB. A `text[]` path must identify exactly one registered slot; use the typed overload when ambiguous. `p_name` is one PostgreSQL identifier, not a schema-qualified name, and the index resides in `splitjson_storage`. Run as the installer.

Hot updates maintain the index. This can prevent HOT updates and add WAL, while still allowing cold TOAST reuse. PostgreSQL chooses an index or sequential scan based on cost; index creation does not guarantee an index scan for every workload.

### explain_find_ids

Returns `EXPLAIN (COSTS OFF)` lines for the same internal query used by `find_ids`. Run as the installer; it is not an application read API and does not execute EXPLAIN ANALYZE.

### Automatic SELECT rewriting

Load `pg_splitjson` before planning, using installer `LOAD 'pg_splitjson'` or administrator-configured session preload. `splitjson.enable_query_rewrite` defaults to on and invalidates cached plans when changed. Exact constant object extraction paths and typed array chains can use hot projections; builtin WHERE equality against constants/prepared values can use matching JSONB/text indexes. Original view permissions, ownership and security barriers remain in place.

Dynamic paths, numeric text segments in `#>`/`#>>`, final `->0`/`->>0` scalar semantics, whole view-row references and unsupported projections retain native expressions. Automatic rewriting applies to SELECT, not fast-path translation of ordinary UPDATE. See [the array and query guide](roadmap.md) for examples, loading and limits.

## Complete example

In a test database with `pg_splitjson` installed, run as the installer. Relation names below are independent of the README examples. The permission snippet assumes `app_role` already exists.

```sql
SELECT splitjson.create_table('public.api_events',
    '[["stats","count"],["state"]]', '{"tenant_id":"bigint"}');

INSERT INTO public.api_events(id, doc, tenant_id) VALUES
    (1, '{"stats":{"count":0},"state":"new","items":[1,2]}', 100),
    (2, '{"body":"cold"}', 200);

SELECT splitjson.set_field('public.api_events', 1, ARRAY['state'], '"ready"');
SELECT splitjson.set_fields('public.api_events', 1,
    '[{"path":["stats","count"],"value":10},{"path":["state"],"value":"done"}]');
SELECT splitjson.increment_field('public.api_events', 1, ARRAY['stats','count'], 0.5);
-- Returns 10.5.

SELECT splitjson.set_field('public.api_events', 1, ARRAY['items'], '[3,4]');
SELECT splitjson.set_field('public.api_events', 2, ARRAY['state'], 'null');
SELECT splitjson.get_field('public.api_events', 2, ARRAY['state']); -- JSONB null.
SELECT splitjson.delete_field('public.api_events', 2, ARRAY['state']);
SELECT splitjson.get_field('public.api_events', 2, ARRAY['state']) IS NULL; -- true.

SELECT splitjson.create_path_index('public.api_events', 'api_events_state_idx', ARRAY['state']);
SELECT * FROM splitjson.find_ids('public.api_events', ARRAY['state'], '"done"') ORDER BY 1;
SELECT * FROM splitjson.explain_find_ids('public.api_events', ARRAY['state'], '"done"');

UPDATE public.api_events SET tenant_id = 101 WHERE id = 1;
SELECT * FROM public.api_events ORDER BY id;

CREATE TABLE public.api_source (key bigint PRIMARY KEY, body jsonb NOT NULL, label text);
INSERT INTO public.api_source VALUES (1, '{"count":5}', 'source');
SELECT splitjson.migrate_table('public.api_source', 'public.api_copy',
    '[["count"]]', 'body', 'key');
SELECT * FROM public.api_copy;
SELECT * FROM public.api_source; -- Source unchanged.

GRANT USAGE ON SCHEMA public, splitjson TO app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.api_events TO app_role;

-- Cleanup after reviewing the results.
SELECT splitjson.drop_table('public.api_copy');
SELECT splitjson.drop_table('public.api_events');
DROP TABLE public.api_source;
```

## Transactions, permissions and errors

Dedicated updates lock the row until transaction end and serialize changes within the same row. Use `increment_field` for read/modify/write counters; application-side reads followed by `set_field` can lose increments. Ordinary view UPDATE/DELETE checks the complete old row under a lock, including business columns. If the row has changed, it raises `40001`; retry according to the application's transaction policy and handle other native PostgreSQL concurrency errors normally.

Ordinary INSERT/UPDATE/DELETE checks view permissions. The update functions check doc UPDATE for the effective caller, including SET ROLE and SESSION AUTHORIZATION. Read helpers check SELECT on both id/doc. Grant application access on the view and public API schema, keeping private tables and metadata inaccessible. These checks coexist with normal schema USAGE and function EXECUTE permissions. DDL, migration, index creation and plan inspection are installer operations; drop requires ownership.

| SQLSTATE | Common cause |
| --- | --- |
| `22023` | Invalid arguments/paths, overlapping declarations, invalid batches or increment targets |
| `22P02` | Native array operation uses a noninteger index |
| `23502` | SQL NULL id/document in view DML or migration |
| `23505` | Duplicate id in view DML or migration |
| `42501` | Insufficient view permissions or ownership |
| `40001` | Stale ordinary view UPDATE/DELETE, or a native serialization failure |

This table is not an exhaustive error list. PostgreSQL may raise native errors for malformed SQL/JSON, unresolved relations, invalid types or arithmetic limits.

## Internal format functions

These are available for inspection and format experiments, not application shortcuts for modifying storage. Functions beginning with `_` are implementation helpers. Type input/output functions are used automatically by PostgreSQL. See the [storage format](storage-format.md) for the envelope contract.

| Function | Result / purpose |
| --- | --- |
| `splitjson.validate_paths(jsonb)` | void; validate path structure and overlap; allows an empty list, unlike create_table |
| `splitjson.pack(jsonb, jsonb)` | splitjson.cold; document + paths → cold template envelope |
| `splitjson.slots(jsonb, jsonb)` | jsonb[]; extract hot values in declared order; SQL NULL elements mean missing |
| `splitjson.restore(splitjson.cold, jsonb[])` | jsonb; restore a complete document and verify slot count/presence |
| `splitjson.restore(splitjson.cold, jsonb[], jsonb)` | jsonb; also validate declared paths against cold; generated views use this overload |
| `splitjson.json_field(jsonb, text[])` | jsonb; native `#>` extraction for objects/arrays |
| `splitjson.template(splitjson.cold)` | jsonb; inspect the cold template |
| `splitjson.paths(splitjson.cold)` | jsonb; inspect declared paths |
| `splitjson.assert_object_path(jsonb, text[])` | void; retained name, validates path shape only; does not inspect the document or assert existence |
| `splitjson.object_field(jsonb, text[])` | jsonb; object-only extraction; missing or array traversal returns SQL NULL |
| `splitjson.column_type(text)` | text; normalize a SQL type declaration, including typmod; reject pseudo types |

These C functions are STRICT: a SQL NULL argument produces SQL NULL without calling the function. This differs from the business APIs' explicit SQL NULL rejection. Never use `template` as a complete document or update private cold/hot columns independently.
