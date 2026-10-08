# PG SplitJSON 0.2.0 发布说明

[English](RELEASE_NOTE.md) | **简体中文** · [README](README.zh-CN.md) · [API 参考](docs/api-reference.zh-CN.md)

**PostgreSQL Split JSON Storage Extension（PG SplitJSON）0.2.0** 是面向 PostgreSQL 18 的生产硬化版本，已在 Linux x86_64 的 PostgreSQL 18.6 上验证，采用 [Apache License 2.0](LICENSE)（`Apache-2.0`）。

PG SplitJSON 将声明的高频更新 JSON 路径放入内部普通列，其余文档保存为可 TOAST 的版本化 cold 模板。业务视图提供 `id`、完整 JSONB `doc` 和可选类型化业务列；专用 API 更新已有热路径时无需读取或赋值 cold 模板。

## 0.2.0 新增内容

- 正式的 0.1.0 到 0.2.0 扩展升级，以及拒绝未知历史构建的前置检查。现有 cold v1/v2 值、热索引、数据和视图权限继续可用。
- 最小权限默认值：内部及管理函数不向 PUBLIC 开放 EXECUTE；`splitjson.grant_access` 只向指定角色授予所需视图及读写 API。
- 映射漂移检查、数据库级 DDL 保护、受控重命名/删除、业务列默认值和约束、表统计、可审阅索引 DDL，以及 `check_table`/`check_all` 一致性检查。
- 已验证的 cold 二进制发送/接收、规划器注册检查、栈/中断边界和基于文本封装的二进制 COPY 往返。
- 可复现的 installcheck、随机差分、升级、权限/DDL、并发、TOAST、备份恢复、崩溃恢复、PITR、流复制和提升测试。
- 有界生产风格负载脚本，以及普通 PG18、cassert 和 sanitizer 编译 CI 任务。

## 兼容性与运行契约

- 当前实测支持范围为 Linux x86_64 上的 PostgreSQL 18.6。物理备份、流复制和 PITR 要求相同 PostgreSQL minor/ABI，以及目标实例安装的 `pg_splitjson` 库和 SQL 文件。跨 PostgreSQL 大版本请使用逻辑导出/导入或 `splitjson.migrate_table`。
- 快速更新契约只适用于命中已有热路径的 `set_field`、`set_fields`、`delete_field` 和 `increment_field` 专用调用。普通视图文档 DML 会还原并重新拆分文档，同步热列，但不保证快速路径。
- 实现保留 MVCC、WAL、行锁和 PostgreSQL TOAST 语义。变化的热索引列可能阻止 HOT；未变化的大 cold 值仍可复用 external TOAST 指针。
- RLS、分区受管视图/表、视图 `ON CONFLICT`、自动逻辑复制重组和完全透明的 ORM 更新不在本版范围。通用 Oracle 风格 duality view 不在项目范围。
- 迁移是复制到新受管关系的一次快照，不复制源表默认值、约束、索引、触发器、权限、排序规则或后续写入。应用授权前应安排切换并比对结果。
- 在新库 `pg_restore` 必须使用文档规定的安装者控制 `session_replication_role=replica` 流程，恢复后执行 `splitjson.check_all(true)`。原地升级不得覆盖已加载的共享库。

## 安装与升级

使用目标 PG18 的 `pg_config` 编译：

```sh
make PG_CONFIG=/path/to/pg18/bin/pg_config
make PG_CONFIG=/path/to/pg18/bin/pg_config install
```

新数据库执行 `CREATE EXTENSION pg_splitjson;`。正式 0.1.0 安装应先安装 0.2.0 库和 SQL 文件、重新连接会话，再执行：

```sql
ALTER EXTENSION pg_splitjson UPDATE TO '0.2.0';
SELECT splitjson.check_all(true);
```

升级在事务内完成，并拒绝无法识别的历史 0.1.0 目录。更早原型或已改动布局请使用逻辑迁移。

## 验证证据

完整独立 PG18.6 实验通过了 installcheck、升级、5000 组有种子 JSONB 差分操作、权限和 DDL、并发增量、cold TOAST 指针/分块复用、备份恢复、立即崩溃恢复、命名恢复点 PITR、流复制回放及备库提升。原始证据位于 [docs/validation/pg-splitjson-0.2.0/](docs/validation/pg-splitjson-0.2.0/)，报告解释每项测量的边界。

在四客户端、八秒的有界负载中，拆分热更新组产生 9,147,136 字节 WAL，原生 JSONB 组为 68,009,496 字节；该次运行报告的 TPS 分别为 1,019.998 和 350.398。这些数字是特定负载的实测证据，不是吞吐或 SLA 承诺。冷读和结构更新可能更适合原生 JSONB，同一行并发写入仍会竞争行锁。

## 源码包

可复现源码包为 `build_output/0.2.0/pg_splitjson-0.2.0.zip`，包外校验文件为 `build_output/0.2.0/pg_splitjson-0.2.0.zip.sha256`。包内包含源码、安装/升级 SQL、测试和成对公共文档，排除 Git 元数据、本地实验、数据库目录、dump、编译对象、OpenSpec 历史、代理指引和文章工作材料。

部署前请阅读 [API 参考](docs/api-reference.zh-CN.md)、[生产运行手册](docs/production-runbook.zh-CN.md)、[支持矩阵](docs/support-matrix.zh-CN.md)和 [0.2.0 验证报告](docs/validation.zh-CN.md)。
