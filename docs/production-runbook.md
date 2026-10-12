# PG SplitJSON 0.3.0 production runbook

**English** | [简体中文](production-runbook.zh-CN.md) · [Documentation](README.md)

This runbook targets PostgreSQL 18.6 on Linux x86_64 and `pg_splitjson` 0.3.0. The extension is Apache 2.0 licensed, installed as `pg_splitjson`, and exposes SQL in `splitjson`. Installation, upgrade, layout migration, replication and recovery are installer operations. Keep the extension library and SQL at the exact same version on every process that can access the database.

## Preflight and installation

1. Confirm `SELECT version()` is PostgreSQL 18.6 and record `pg_config --version`, ABI, OS, architecture and the extension library path.
2. Install the same 0.3.0 library and SQL files on the primary, physical standbys, logical subscribers and restore targets. Restart sessions that loaded an older shared library.
3. Load `pg_splitjson` before planning sessions that use automatic query rewriting (`session_preload_libraries` or `LOAD`); other APIs work through the normal extension SQL entry points.
4. Create managed relations and path indexes as the extension installer. Grant only the required business view/API privileges with `splitjson.grant_access`; never grant `splitjson_storage`, `splitjson._tables` or private functions.
5. Run `SELECT splitjson.check_all(true);`, inspect `splitjson.table_stats()`, and establish a baseline for WAL, locks, vacuum and bloat.

## Security and RLS

Use `enable_rls`, `set_policy` and `drop_policy` only through their installer APIs. Policy expressions are parsed as native PostgreSQL expressions; they may use id, business columns, declared hot values and approved identity expressions. Cold/doc access, subqueries, dynamic paths and user functions are rejected. The public C entry captures the actual caller before private metadata access, so USING/WITH CHECK, `SET ROLE`, `SESSION AUTHORIZATION`, prepared plans, security barriers and MVCC remain native PostgreSQL behavior. Test every application role, including `row_security=off`, BYPASSRLS and FORCE RLS cases.

## Upgrades, backup and recovery

Upgrade the supported catalog transactionally with `ALTER EXTENSION pg_splitjson UPDATE TO '0.3.0';`, then run `check_all(true)`. The 0.1.0 → 0.2.0 → 0.3.0 path preserves old API OIDs, public row types and raw cold values. Unknown or drifted layouts are rejected. Use whole-database `pg_dump -Fc`/`pg_restore` or physical backups; `pg_dump -t` on a business view does not include private storage dependencies. After restore, PITR, physical promotion or logical takeover, call `reinitialize_table(table,'restore'|'recovery'|'takeover')` before reopening writes. This rotates the epoch and initializes the relation sequence above retained revisions without rewriting cold data. Run `check_all(true)` and compare business-view rows before traffic resumes.

## Online layout migration

`splitjson.prepare_online_migration` creates a new follower target and an owned logical slot. Run `python3 scripts/splitjson-migrate.py start --source public.events --target public.events_v2 --paths '[["state"],["items",0]]'` with the target connection environment set through libpq. The runner keeps the exported snapshot alive through copy, applies complete source transactions, stores original-layout state for unchanged TOAST, commits target rows and progress together, and acknowledges the slot afterward. `status` reports retained bytes, slot/WAL loss, source fingerprint and fence evidence; `abort` drops only the task's slot and retains source/partial target for review. On final cutover call `complete`, which establishes an ACCESS EXCLUSIVE source write fence, replays through the final LSN, compares logical rows, rotates the target epoch and leaves the fenced source retained. The application must switch traffic explicitly; the extension never renames the source view.

## Same-layout logical replication

Use `scripts/splitjson-replication.py` with a libpq `service` or passfile reference; do not put passwords in command lines, manifests or reports. `prepare` transfers a manifest and provisions a fresh private storage relation with the same physical name/layout. `start` creates an explicitly named storage publication and subscription; business views and extension catalogs are not published. `status` reports native subscription workers, relation sync state, publisher slot/WAL retention and errors. `stop`/`resume` control the native worker. `takeover` requires a source `fence_writes` barrier, a replicated private marker, the final confirmed LSN, zero active workers, exact logical-row equality and `check_all`; it then rotates the target epoch and enables local hot APIs. The source remains retained and fenced. `detach` cleans only the registered publication, subscription, slot and marker.

RLS and ACLs are deployed explicitly at the subscriber. Native apply preserves the publisher's physical revision and skips split triggers; application roles remain subject to the subscriber's local policies. DDL, path changes, indexes, policies, credentials and roles are never implicitly replicated. Same-layout PG18.6/0.3.0 is required. Cross-layout automatic reassembly, multi-primary writes and publication of business views are unsupported.

## Routine operations and rollback

Dedicated hot APIs update existing hot scalar/object/array paths without reading or assigning cold. `set_fields` writes once; `increment_field` reads and calculates under one row lock. Document replacement and structural changes take the native JSONB fallback. Monitor index validity and run `VACUUM (ANALYZE)`/`REINDEX` based on observed statistics. Keep the source relation during migration/replication retention windows. Roll back by stopping traffic, restoring the last tested backup or switching to the retained source; do not downgrade extension catalogs in place.

Native view `ON CONFLICT`, arbitrary view-DML translation, non-id partition keys, cross-major physical upgrades, cross-layout logical reassembly, multi-primary operation and general Oracle-style duality views are outside this extension.
