# Arrays and automatic query rewriting in 0.2.0

**English** | [简体中文](roadmap.zh-CN.md) · [Documentation](README.md)

**PG SplitJSON 0.2.0 implements array operations, fixed array hot slots and automatic exact-path SELECT rewriting.** This page replaces the earlier implementation plan. General duality views are outside the project's scope.

## Choose the array update unit

| Layout | Declaration | Fast operation | Cost and boundary |
| --- | --- | --- | --- |
| Whole array as one hot value | `[["items"]]` | Update/delete/increment inside `items`, including negative indexes | Rewrites the hot array, preserves cold; same-row lock |
| Fixed array leaf as a hot slot | `[["items",0,"price"]]` | Update existing `items[0].price` | Rewrites only the leaf; position shifts outside the hot subtree repack all slots |
| Nonhot array | No matching hot path | Native object/array operations | Restore, modify and repack |

Declarations use strings for object keys and nonnegative integers for array indexes. `["items",0,"price"]` requires an array at `items`; `["items","0","price"]` requires an object with key `0`. Root arrays can use declarations such as `[[0,"price"]]`. Indexes are zero-based, integral and at most 2147483647; equivalent numerics such as 0 and 0.0 cannot be declared twice. Paths remain nonoverlapping and bounded at 64 slots/64 segments.

Operations retain `text[]` paths, or string arrays in `set_fields`. They follow native JSONB traversal: `"0"` is a key at an object and an index at an array. Negative operation indexes address positions relative to length; they are not registered slots. Native out-of-range insertion, missing intermediates, scalar no-ops and errors apply.

```sql
SELECT splitjson.create_table('public.array_events',
    '[["items",0,"price"],["tags"],["state"]]');
INSERT INTO public.array_events VALUES
    (1,'{"items":[{"price":10},{"price":20}],"tags":["a","b"],"state":"new"}');
SELECT splitjson.increment_field('public.array_events',1,ARRAY['items','0','price'],0.5);
SELECT splitjson.set_fields('public.array_events',1,
    '[{"path":["items","0","price"],"value":12},{"path":["tags","-1"],"value":"c"}]');
-- Both operations update hot columns in one write, without reading/assigning cold.
SELECT splitjson.delete_field('public.array_events',1,ARRAY['items','0']);
-- Remaining element becomes position 0; its price (20) is extracted on repack.
SELECT splitjson.get_field('public.array_events',1,ARRAY['items','0','price']);
```

Deleting an entire registered slot, inserting/deleting/reordering array positions outside a hot subtree, replacing a parent, or creating a missing hot slot restores and repacks all slots. Ordinary view UPDATE with `jsonb_insert` can express insertions; ordinary changed-document DML repacks. A batch executes operations in order and writes once; any fallback replays the complete batch from the original document. Failures roll back the batch.

Fixed slots identify **positions**, not business identities. Dynamic wildcards such as `items[*].price`, dynamic slot counts and automatic array-to-child-table mapping are unsupported. Independent elements still share a row lock. Cold v2 writes typed declarations while v1 remains readable; see [storage format](storage-format.md).

## Load before planning

The C planner module must be loaded before the query is planned. Run `LOAD` as the installer for a test session, or have an administrator set `session_preload_libraries = 'pg_splitjson'` for application sessions. The lab script uses session preload only in its temporary instance. Merely installing the extension or relying on a function's first execution does not ensure rewriting of the first query.

```sql
LOAD 'pg_splitjson';
SHOW splitjson.enable_query_rewrite; -- on by default after module load
SET splitjson.enable_query_rewrite=off;
SET splitjson.enable_query_rewrite=on;
```

The switch invalidates cached plans. The module preserves the previous planner hook, resolves qualified function/type identities in the current database and safely delegates when the extension is absent. No metadata SPI query or stale slot cache is used.

## Supported query forms and indexes

The planner recognizes generated, unfiltered, single-storage-table security-barrier view projections. It maps **exact constant registered extraction paths** through internal projections, preserving public output columns, original permission records and view ownership. It does not grant private-table privileges, remove barriers or change leakproof flags.

| Expression | Rewrite / index behavior |
| --- | --- |
| `doc->'state'`, `doc#>'{state}'` | Hot JSONB value; JSONB B-tree for equality |
| `doc->>'state'`, `doc#>>'{state}'` | `hot_N #>> '{}'`; matching text expression B-tree |
| `doc->'items'->0->>'price'` | Typed chain matches `["items",0,"price"]`; text B-tree |
| `doc#>>'{items,0,price}'` | Native fallback: numeric text can address arrays or object keys |
| Final `doc->0` / `doc->>0` | Native fallback: these operators also extract scalars |
| Whole view-row references such as `row_to_json(d)` | Retain native plan to preserve the public composite row type |
| Dynamic paths, negative extraction indexes, unsupported projections | Retain native expression |

Constant `jsonb_extract_path` / `jsonb_extract_path_text` forms follow the same path rules. Comparison values may be constants or prepared parameters. For builtin JSONB/text equality in WHERE, the canonical view can receive an equivalent internal condition while retaining the outer condition for outer-join NULL semantics. Other predicates, joins, casts and collations retain their operators; only supported extraction subexpressions change. Specialized range/join/cast index pushdown is not promised. More complex or filtered views can retain native plans.

```sql
SELECT splitjson.create_path_index('public.array_events','array_state_json_idx',ARRAY['state']);
SELECT splitjson.create_path_index('public.array_events','array_state_text_idx',ARRAY['state'],'text');
SELECT splitjson.create_path_index('public.array_events','array_price_text_idx',
    '["items",0,"price"]'::jsonb,'text');
EXPLAIN SELECT id FROM public.array_events WHERE doc->>'state'='new';
EXPLAIN SELECT id FROM public.array_events WHERE doc->'items'->0->>'price'='20';
PREPARE array_state(text) AS SELECT id FROM public.array_events WHERE doc->>'state'=$1;
EXECUTE array_state('new');
DEALLOCATE array_state;
```

A small table can legitimately use a sequential scan. The selective 10,000-row tests verify real JSONB, text and typed array index scans. Text extraction is not JSONB string equality: number 1 and string "1" both extract as text `1`, JSON null becomes SQL NULL, and objects/arrays use native JSON serialization. Nondefault collations may not match the default text index. Index maintenance can prevent HOT while still reusing cold TOAST.

`get_field` and `find_ids` work without the planner hook. Numeric search paths include a document fallback for rows whose typed candidate slots are all missing, so undeclared shapes remain searchable. Such a fallback may add a scan; use typed operator chains for a transparent array-index query.

## Verification and remaining work

[Validation](validation.md) covers 338 native array differential cases, fixed-position shifts, scalar and mixed-shape fallbacks, one-write batches, concurrent increments, real plans, generic PREPARE, GUC/index invalidation, outer joins, view-only permissions, cold pointer/chunk reuse and dump/restore. Tests are in [arrays_rewrite.sql](../tests/arrays_rewrite.sql), [physical.sql](../tests/physical.sql), [concurrency.sh](../tests/concurrency.sh) and [restore.sql](../tests/restore.sql).

Earlier unpublished builds also used the 0.1.0 version number. Use a fresh installation and logical export/import for migration; the official 0.1.0 to 0.2.0 script accepts only the formal catalog shape. Do not overwrite a loaded library or assume an upgrade for altered layouts. Current behavior is specified in [OpenSpec](../openspec/specs/).

Version 0.2.0 adds the production lifecycle and management functions documented in the [API reference](api-reference.md) and [production runbook](production-runbook.md). General duality views are excluded.
