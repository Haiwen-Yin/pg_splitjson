# PG SplitJSON 0.2.0 生产运行手册

[English](production-runbook.md) | **简体中文** · [文档目录](README.zh-CN.md)

本手册适用于 PostgreSQL 18.6 与 `pg_splitjson` 0.2.0。安装、升级、备份和恢复由数据库/扩展安装者执行。更换库文件应安排维护窗口，并在更换后重新连接会话。

## 前置检查

1. 确认 `SELECT version()` 为 PostgreSQL 18，并记录服务器 ABI、操作系统、架构、扩展库路径和 `pg_config --version`。
2. 在所有物理备库安装相同的 `pg_splitjson` 库和 SQL 文件。主库、备库、备份和恢复目标保持相同 PostgreSQL minor 版本和 ABI。
3. 评估声明路径、热更新比例、cold 负载大小、索引和同一行并发。布局变化应创建新的受管关系。
4. 确认应用角色只拥有所需业务 schema/视图权限，不授予 `splitjson_storage` 或 `splitjson._tables` 权限。
5. 生成整库备份，并在独立 PG18 集群演练恢复流程。

## 新安装

使用目标 PG18 的 `pg_config` 编译并安装，然后在每个业务数据库执行 `CREATE EXTENSION pg_splitjson;`。只有需要 SELECT 自动改写的会话配置 `session_preload_libraries = 'pg_splitjson'`，或在规划前执行 `LOAD 'pg_splitjson'`。由安装者创建受管视图和索引，再使用 `splitjson.grant_access` 授予应用角色权限。

装载数据后、开放流量前执行 `SELECT splitjson.check_all(true);`。将 `splitjson.table_stats()` 和 PostgreSQL 关系统计加入运维监控。

## 从正式 0.1.0 升级

1. 确认来源为正式 0.1.0 目录，而不是早期原型或手工改动的布局。
2. 安装 0.2.0 库和扩展 SQL 文件，不停止或修改无关的 PostgreSQL 实例。
3. 让加载旧共享库的应用会话排空或重新连接。
4. 在每个数据库执行 `ALTER EXTENSION pg_splitjson UPDATE TO '0.2.0';`，再执行 `SELECT splitjson.check_all(true);`。
5. 按应用权限契约通过 `splitjson.grant_access` 补发 EXECUTE 授权，验证旧计划、权限、索引和逻辑行数。

升级脚本在事务内运行并拒绝未知 0.1.0 定义。早期原型和改动布局必须新安装并逻辑导出/导入或使用 `splitjson.migrate_table`；不得在线覆盖已加载的共享库。

## 备份与恢复

使用整库 `pg_dump -Fc`/`pg_restore`，或包含扩展文件的物理备份。只导出视图的 `pg_dump -t` 不包含内部存储依赖。恢复到新库时，按 dump 顺序使用安装者控制的 `session_replication_role=replica` 流程，再执行 `SELECT splitjson.check_all(true);`，确认后再开放流量。

物理流复制、PITR 和提升要求相同 PostgreSQL minor/ABI 及扩展文件。扩展使用普通 heap、WAL、MVCC 和 TOAST 恢复，不提供独立 redo 协议。跨 PostgreSQL 大版本使用逻辑导出/导入。故障后比对业务视图并执行 `check_all(true)`，再恢复写入。

## 在线运维

快速更新契约只使用专用热 API。普通 `UPDATE view SET doc = ...` 会还原并重新拆分文档、同步热列。`index_ddl` 返回可审阅 SQL；在事务外执行 `CREATE INDEX CONCURRENTLY` 并监控 invalid index。按统计信息安排 `VACUUM (ANALYZE)` 与 `REINDEX`。变化的热索引列可能阻止 HOT，即使 cold TOAST 值被复用。

本版不支持 RLS、分区受管关系、视图 `ON CONFLICT`、自动逻辑复制重组或通用 duality view。将这些作为部署阻塞项，改用明确支持的关系设计。

## 回滚与切换

升级回滚应恢复经过测试的升级前数据库以及匹配的 0.1.0 库和 SQL 文件，不要原地降级目录。布局迁移保持源表不变，暂停或同步写入，比对行数据，授予新视图权限，切换流量，并在保留窗口结束前保留源表。
