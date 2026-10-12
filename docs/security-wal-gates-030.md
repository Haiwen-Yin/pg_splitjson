# PG SplitJSON 0.3.0 technical gates

**English** | [简体中文](security-wal-gates-030.zh-CN.md) · [Development plan](development-plan-030.md)

This historical technical-gate record documents the caller-identity and WAL experiments that preceded the 0.3.0 acceptance run. The final release combines these gates with the capability, migration and replication evidence in [validation-030](validation-030.md). The official 0.1.0 and 0.2.0 installation scripts and the 0.2.0 archive remain unchanged.

## Caller identity and private ACL

The business view keeps its security barrier and uses `security_invoker=true`. Native rewrite builds policy qualifications and write checks with the effective caller. A planner hook authorizes only the private permission record reached through the registered, installer-owned canonical view. It preserves policy qualifications, write checks and role-dependent plan invalidation. Direct storage/metadata reads and forged views remain denied.

C API entry captures `GetUserId()` before elevation. For a generated internal statement, schema resolution temporarily uses the installer. The `post_parse_analyze_hook` switches to the caller before native RLS rewrite. The planner authorizes only that statement's registered storage permission record. `SPI_prepare_cursor(..., CURSOR_OPT_GENERIC_PLAN)` and `SPI_plan_get_cached_plan()` finish planning before the capability is removed. Execution runs as the caller, with no capability available to nested queries in user expressions. Identity/capability restoration uses `PG_TRY`/`PG_CATCH`.

The diagnostic gate covers SELECT USING, UPDATE/INSERT WITH CHECK, view DML, COPY, effective application SECURITY DEFINER identity, SET ROLE, SESSION AUTHORIZATION, prepared queries, policy invalidation, restrictive policies, `row_security=off`, BYPASSRLS/FORCE RLS, excluded-row expression errors and a nested-policy attempt to read private storage. Its diagnostic C functions are created only by the lab SQL; they are not installed business APIs. The managed policy compiler and caller-aware production data entries are now installed and covered by the final RLS/COPY assertions.

## Exported snapshot and WAL states

The optional `pg_splitjson_decode` output module uses protocol 1. A replication connection creates a slot with `SNAPSHOT 'export'`; a second connection imports that snapshot before backfill. The exporter stays open until the snapshot has been imported and scanned. Writes between import and scan are absent from the snapshot and present in committed WAL. Replay respects begin/commit boundaries; aborted transactions produce no applied changes.

Column states are explicit: SQL NULL is `null`; unchanged external TOAST is `{"unchanged":true}`; a full value carries `{"text":...,"type":...}`. Replay retains snapshot state for unchanged attributes, merges full/null values, tracks old/new id, and restores the logical JSON from the old layout. The experiment reconstructs the exact storage rows and complete documents after hot/cold updates, deletion, insertion, id movement, SQL NULL/JSON null and rollback. It replays 7 commit boundaries and excludes unrelated table rows. The resumable runner, atomic progress, slot-loss handling and final fence are covered by the online migration lab.

PG18.6 requires the output module in `output_plugin_libraries`, as well as `wal_level=logical` and slot/WAL capacity. The experiment configures these only in its fresh lab. Production tools will check prerequisites and report missing settings; they must not modify an existing cluster's configuration.

## Reproduce and evidence

```sh
scripts/test-remote.sh root@10.10.10.131 /usr/local/pgsql-18.6 security-gate
scripts/test-remote.sh root@10.10.10.131 /usr/local/pgsql-18.6 wal-gate
```

Successful private installations were `/tmp/pg_splitjson-lab.UCBVrl` and `/tmp/pg_splitjson-lab.oHRJXj`. Each copied the toolchain, used its own PGDATA/socket and stopped its own cluster. [Saved logs](validation/pg-splitjson-0.3.0-gates/) include environment, assertions and shutdown evidence. All database experiments used the authorized remote wrapper; no local PostgreSQL build/start or existing-instance operation was performed.
