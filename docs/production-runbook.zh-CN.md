# PG SplitJSON 0.3.0 生产运行手册

[English](production-runbook.md) | **简体中文** · [文档目录](README.zh-CN.md)

本手册面向 Linux x86_64 上的 PostgreSQL 18.6 与 `pg_splitjson` 0.3.0。扩展采用 Apache 2.0，安装名为 `pg_splitjson`，SQL 位于 `splitjson`。安装、升级、布局迁移、复制和恢复均由安装者执行。所有访问数据库的进程必须使用完全相同版本的扩展库和 SQL。

## 前置检查与安装

1. 确认 `SELECT version()` 为 PostgreSQL 18.6，并记录 `pg_config --version`、ABI、操作系统、架构和扩展库路径。
2. 在主库、物理备库、逻辑订阅端和恢复目标安装相同的 0.3.0 库与 SQL。重新连接加载过旧共享库的会话。
3. 使用自动查询改写的会话在规划前加载 `pg_splitjson`（`session_preload_libraries` 或 `LOAD`）；其他 API 使用正常扩展 SQL 入口。
4. 以安装者创建受管关系和路径索引。用 `splitjson.grant_access` 只授予所需业务视图/API 权限，绝不授予 `splitjson_storage`、`splitjson._tables` 或私有函数。
5. 执行 `SELECT splitjson.check_all(true);`，检查 `splitjson.table_stats()`，并建立 WAL、锁、vacuum 和膨胀基线。

## 安全与 RLS

只通过安装者 API 使用 `enable_rls`、`set_policy` 和 `drop_policy`。策略表达式由原生 PostgreSQL 解析，只能使用 id、业务列、声明的热值和批准的身份表达式；cold/doc、子查询、动态路径和用户函数会被拒绝。公开 C 入口在访问私有元数据前捕获真实调用者，因此 USING/WITH CHECK、`SET ROLE`、`SESSION AUTHORIZATION`、预备计划、安全屏障和 MVCC 保持 PostgreSQL 原生行为。应为每个应用角色测试，包括 `row_security=off`、BYPASSRLS 和 FORCE RLS。

## 升级、备份与恢复

用 `ALTER EXTENSION pg_splitjson UPDATE TO '0.3.0';` 事务升级支持的目录，然后执行 `check_all(true)`。0.1.0 → 0.2.0 → 0.3.0 路径保留旧 API OID、公开行类型和原始 cold 值；未知或漂移布局会被拒绝。使用整库 `pg_dump -Fc`/`pg_restore` 或物理备份；对业务视图执行 `pg_dump -t` 不会包含私有存储依赖。恢复、PITR、物理提升或逻辑接管后，在重新开放写入前调用 `reinitialize_table(table,'restore'|'recovery'|'takeover')`，它只提升代际并在保留版本之上初始化序列，不重写 cold。重新开放流量前执行 `check_all(true)` 并比较业务视图行。

## 在线布局迁移

`splitjson.prepare_online_migration` 创建新的 follower 目标和专属逻辑槽。将 libpq 环境配置为目标连接，运行 `python3 scripts/splitjson-migrate.py start --source public.events --target public.events_v2 --paths '[["state"],["items",0]]'`。运行器在回填期间保持导出快照，按完整源事务应用，保存 unchanged TOAST 的原布局状态，把目标行与进度一起提交，随后确认槽。`status` 报告保留字节数、槽/WAL 丢失、源指纹和屏障证据；`abort` 只删除任务自己的槽并保留源/部分目标供检查。最终切换用 `complete` 建立源 ACCESS EXCLUSIVE 写屏障，追平最终 LSN、比较逻辑行、轮换目标代际并保留已加屏障的源。应用必须显式切换流量，扩展不会重命名源视图。

## 同布局逻辑复制

使用 `scripts/splitjson-replication.py`，通过 libpq `service` 或 passfile 引用连接；不要把密码放入命令行、清单或报告。`prepare` 传递清单并以相同物理名称/布局创建新的私有存储关系。`start` 创建显式命名的存储 publication/subscription；不发布业务视图和扩展目录。`status` 报告原生订阅 worker、关系同步、发布端槽/WAL 保留和错误。`stop`/`resume` 控制原生 worker。`takeover` 要求源 `fence_writes` 屏障、复制到订阅端的私有标记、最终确认 LSN、零活跃 worker、逻辑行完全相等以及 `check_all`，随后轮换目标代际并启用本地热 API。源仍保留并保持 fenced。`detach` 只清理登记的 publication、subscription、槽和标记。

RLS 和 ACL 在订阅端显式部署。原生 apply 保留源物理 revision 并跳过拆分触发器；应用角色仍受订阅端本地策略约束。DDL、路径变化、索引、策略、凭据和角色不会隐式复制。要求同为 PG18.6/0.3.0。跨布局自动重组、多主写入和发布业务视图均不支持。

## 日常操作与回滚

专用热 API 更新现有标量/对象/数组热路径时不读取或赋值 cold。`set_fields` 只写一次；`increment_field` 在同一行锁内读取并计算。文档替换和结构变化走原生 JSONB 回退。根据统计信息监控索引有效性并执行 `VACUUM (ANALYZE)`/`REINDEX`。迁移/复制保留窗口内保留源关系。回滚时停止流量，恢复最近验证过的备份或切换到保留源；不要原地降级扩展目录。

原生视图 `ON CONFLICT`、任意视图 DML 翻译、非 id 分区键、跨大版本物理升级、跨布局逻辑重组、多主操作和通用 Oracle 风格 duality view 不属于本扩展。
