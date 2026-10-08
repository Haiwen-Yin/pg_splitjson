# PG SplitJSON 0.2.0 production runbook

**English** | [简体中文](production-runbook.zh-CN.md) · [Documentation](README.md)

This runbook is for PostgreSQL 18.6 and the `pg_splitjson` 0.2.0 release. Perform installation, upgrade, backup and restore work as the database/extension installer. Use a maintenance window for extension library changes and reconnect sessions after replacing files.

## Preflight

1. Confirm `SELECT version()` is PostgreSQL 18 and record the server ABI, OS, architecture, extension library path and `pg_config --version`.
2. Install the same `pg_splitjson` library and SQL files on every physical replica. Keep the PostgreSQL minor version and ABI identical across primary, standby, backup and restore targets.
3. Review declared paths, hot update ratios, cold payload size, indexes and same-row concurrency. Create a new managed relation for a changed layout.
4. Verify application roles have only the required business schema/view privileges. Do not grant `splitjson_storage` or `splitjson._tables` access.
5. Take a whole-database backup and test the restore procedure in an isolated PG18 cluster.

## New installation

Build and install with the selected PG18 `pg_config`, then run `CREATE EXTENSION pg_splitjson;` in each application database. Configure `session_preload_libraries = 'pg_splitjson'` only for sessions that need automatic SELECT rewriting, or issue `LOAD 'pg_splitjson'` before planning. Create managed views and indexes as the installer, then use `splitjson.grant_access` for application roles.

Run `SELECT splitjson.check_all(true);` after loading data and before opening traffic. Keep `splitjson.table_stats()` and PostgreSQL relation statistics in the operational dashboard.

## Upgrade from official 0.1.0

1. Confirm the source is the official 0.1.0 catalog, not an early prototype or hand-modified layout.
2. Install the 0.2.0 library and extension SQL files without stopping or modifying unrelated PostgreSQL instances.
3. Drain or reconnect application sessions that loaded the old shared library.
4. In each database run `ALTER EXTENSION pg_splitjson UPDATE TO '0.2.0';` and then `SELECT splitjson.check_all(true);`.
5. Reapply application EXECUTE grants through `splitjson.grant_access` if the role contract requires them. Validate old plans, permissions, indexes and logical row counts.

The script is transactional and refuses unknown 0.1.0 definitions. Earlier prototypes and changed layouts require a fresh install plus logical export/import or `splitjson.migrate_table`; never overwrite a loaded shared library for an online same-version upgrade.

## Backup and recovery

Use whole-database `pg_dump -Fc`/`pg_restore` or a physical backup that includes the extension files. A view-only `pg_dump -t` omits private storage dependencies. For restore into a new database, use the installer-controlled `session_replication_role=replica` procedure required by the dump order, then run `SELECT splitjson.check_all(true);` before granting traffic.

Physical streaming replication, PITR and promotion require the same PostgreSQL minor/ABI and extension files. The extension uses normal heap, WAL, MVCC and TOAST recovery; it does not provide a separate redo protocol. Across PostgreSQL major versions use logical export/import. After an incident, compare business-view rows and run `check_all(true)` before resuming writes.

## Online operations

Use only the dedicated hot APIs for the fast-update contract. A regular `UPDATE view SET doc = ...` restores and repacks the document and synchronizes hot columns. `index_ddl` returns reviewed SQL; execute `CREATE INDEX CONCURRENTLY` outside a transaction and monitor invalid indexes. Schedule `VACUUM (ANALYZE)` and `REINDEX` according to observed statistics. A changed indexed hot column can prevent HOT even when the cold TOAST value is reused.

The release does not support RLS, partitioned managed relations, view `ON CONFLICT`, automatic logical replication reassembly or general duality views. Treat these as deployment blockers and use an explicitly supported relational design instead.

## Rollback and cutover

Rollback an upgrade by restoring the tested pre-upgrade database and matching 0.1.0 library/SQL files; do not downgrade catalogs in place. For a layout migration, keep the source table unchanged, pause or synchronize writes, compare rows, grant the new view, switch traffic, and retain the source until the retention window expires.
