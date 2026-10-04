# PG SplitJSON storage format

**English** | [简体中文](storage-format.zh-CN.md) · [Documentation](README.md)

Extension version: **0.1.0**. New writes use internal `cold` format version **2**; versions **1 and 2** are readable. These are independently numbered.

`splitjson.cold` is a PostgreSQL varlena type that supports external TOAST storage. It targets PG18; direct physical-file reuse across major versions is not guaranteed. Use text I/O and pg_dump to migrate between environments.

| Order | Content | Length |
| --- | --- | --- |
| 1 | PostgreSQL varlena total-length header | 4 bytes |
| 2 | magic `0x50474a53` | uint32 |
| 3 | version `2` (legacy `1` accepted) | uint32 |
| 4 | paths_len (including embedded JSONB header) | uint32 |
| 5 | template_len (including embedded JSONB header) | uint32 |
| 6 | Header alignment padding | To `MAXALIGN(20)` |
| 7 | Hot-path list as JSONB | paths_len |
| 8 | Path payload alignment padding | To MAXALIGN(paths_len) |
| 9 | Cold template as JSONB | template_len |

Total size is `MAXALIGN(20) + MAXALIGN(paths_len) + template_len`. The header is 24 bytes on the verified x86_64 PG18 installation. Embedded JSONB retains PostgreSQL encoding, key deduplication and numeric semantics.

For paths `[["user","status"],["counter"]]` and document `{"user":{"status":"new"},"counter":null,"body":"cold"}`:

```text
cold.template = {"user":{"status":null},"counter":null,"body":"cold"}
hot_1         = '"new"'::jsonb
hot_2         = 'null'::jsonb
```

If the document is `{"body":"cold"}`, the template preserves that JSONB payload exactly, and hot_1/hot_2 are SQL NULL. No keys or placeholders are added. String segments require objects; numeric segments require real arrays. Container-type mismatches, absent keys and out-of-range indexes are missing. Placeholders inside arrays do not change length or order.

Placeholder interpretation uses the declared paths and their presence in the template. Ordinary null values at undeclared paths are never placeholders. Restoration checks that each present template path has a non-SQL-NULL hot value, each missing path has SQL NULL, and the hot value count equals the path count. Nonoverlapping paths allow sequential substitution without disrupting other fields.

The text representation is:

```json
{"version":2,"paths":[["user","status"],["counter"]],"template":{"user":{"status":null},"counter":null,"body":"cold"}}
```

Input validates the version, paths and placeholders; output supports text round trips. This describes a cold template, not a complete business JSON document. Restore the complete value with `splitjson.restore(cold,jsonb[])`. Version 0.1.0 has no binary send/receive functions. Do not treat the internal format as jsonb or modify it manually.

Version 2 extends path interpretation: strings remain object keys, while nonnegative integral int32 numbers address real array containers. For `[["items",0,"price"]]` and `{"items":[{"price":10},{"price":20}]}`, the template is `{"items":[{"price":null},{"price":20}]}` and hot_1 is `10`. Numeric string `"0"` still means an object key. Version 1 accepts strings only and preserves its original object-only interpretation; text output retains the stored version rather than silently upgrading it.

Generated views use `restore(cold,hot[],constant_paths)`, which checks that the visible mapping matches the cold paths. New pack writes version 2 even for object-only declarations. Earlier unpublished extension builds also used 0.1.0: readability of v1 does not constitute a same-version online extension upgrade. Use a fresh installation and logical migration.

Updates use the ordinary heap: cold and hot_N belong to the same row and commit atomically in the same transaction. Existing hot field/subtree updates assign only hot_N; PostgreSQL TOAST reuses the unchanged cold external pointer. MVCC, WAL and recovery mechanisms remain in effect.
