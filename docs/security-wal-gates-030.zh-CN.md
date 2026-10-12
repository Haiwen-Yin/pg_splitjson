# PG SplitJSON 0.3.0 技术门禁

[English](security-wal-gates-030.md) | **简体中文** · [开发计划](development-plan-030.zh-CN.md)

本文是历史技术门禁记录，保存 0.3.0 验收前完成的调用者身份与 WAL 实验。最终发行版还结合了[验证报告](validation-030.zh-CN.md)中的能力、迁移和复制证据。正式 0.1.0、0.2.0 安装脚本和 0.2.0 源码包保持不变。

## 调用者身份与私有 ACL

业务视图保留安全屏障并使用 `security_invoker=true`。原生 rewrite 按实际有效调用者生成策略条件与写入检查。planner hook 仅为通过登记、安装者拥有的标准业务视图到达的私有权限记录提供访问身份，保留策略条件、写入检查及角色相关计划失效。直接读取存储/元数据以及伪造视图仍被拒绝。

C API 入口在提权前捕获 `GetUserId()`。对于生成的内部语句，schema 解析暂用安装者身份；`post_parse_analyze_hook` 在原生 RLS rewrite 前切回调用者；planner 仅授权该语句所对应的登记存储权限记录。`SPI_prepare_cursor(..., CURSOR_OPT_GENERIC_PLAN)` 和 `SPI_plan_get_cached_plan()` 在移除能力上下文前完成计划生成。执行时使用调用者身份，用户表达式中的嵌套查询无法使用这一能力。身份/能力上下文通过 `PG_TRY`/`PG_CATCH` 恢复。

诊断门禁覆盖 SELECT USING、UPDATE/INSERT WITH CHECK、视图 DML、COPY、应用 SECURITY DEFINER 的实际有效身份、SET ROLE、SESSION AUTHORIZATION、预备查询、策略失效、restrictive 策略、`row_security=off`、BYPASSRLS/FORCE RLS、被排除行的表达式错误，以及策略嵌套读取私有存储的攻击尝试。诊断 C 函数只由实验 SQL 创建，不属于安装的业务 API。受管策略编译和调用者感知的正式数据入口已安装，并由最终 RLS/COPY 断言覆盖。

## 导出快照与 WAL 状态

可选 `pg_splitjson_decode` 输出模块使用协议 1。复制连接通过 `SNAPSHOT 'export'` 创建槽，第二个连接在回填前导入该快照；导出连接保持打开，直至快照导入并扫描完成。导入后、扫描前发生的写入不进入快照，但进入已提交 WAL。重放遵循 begin/commit 边界，回滚事务不产生已应用变化。

列状态明确区分：SQL NULL 为 `null`；未变化的外部 TOAST 为 `{"unchanged":true}`；完整值包含 `{"text":...,"type":...}`。重放对未变化属性保留快照状态，合并完整值/null，追踪旧/新 id，再从旧布局恢复逻辑 JSON。实验在热/冷更新、删除、插入、id 移动、SQL NULL/JSON null 和回滚后准确重建存储行与完整文档，重放 7 个提交边界，并排除无关表行。它还不是可恢复的迁移 runner。

PG18.6 除 `wal_level=logical`、复制槽/WAL 容量外，还要求 `output_plugin_libraries` 包含输出模块。实验只修改全新 lab 的配置。生产工具会检查前置条件并报告缺失设置，不能修改现有集群配置。

## 复现与证据

```sh
scripts/test-remote.sh root@10.10.10.131 /usr/local/pgsql-18.6 security-gate
scripts/test-remote.sh root@10.10.10.131 /usr/local/pgsql-18.6 wal-gate
```

成功的私有安装为 `/tmp/pg_splitjson-lab.UCBVrl` 和 `/tmp/pg_splitjson-lab.oHRJXj`。它们分别复制工具链，使用自己的 PGDATA/socket，并停止自己的集群。[保存日志](validation/pg-splitjson-0.3.0-gates/)包含环境、断言与停止证据。所有数据库实验均经授权远程脚本运行，没有在本机构建/启动 PostgreSQL，也没有操作现有实例。
