# PG SplitJSON 0.3.0 发布说明

[English](RELEASE_NOTE.md) | **简体中文** · [README](README.zh-CN.md) · [API 参考](docs/api-reference.zh-CN.md)

**PostgreSQL Split JSON Storage Extension（PG SplitJSON）0.3.0** 已完成已测试 PostgreSQL 18.6/Linux x86_64 的源码发行门禁。项目采用 [Apache License 2.0](LICENSE)（`Apache-2.0`），安装名为 `pg_splitjson`，SQL 位于 `splitjson`。

0.3.0 保留 0.2.0 的冷热视图契约，新增调用者感知 RLS、仅按 id 的 HASH/RANGE 存储、版本代际、条件写入、原生 upsert、RFC 6902 Patch、RFC 7396 Merge Patch、类型索引/范围、快照可移植工具、在线 WAL 布局迁移和带屏障接管的同布局原生逻辑复制。原始 0.1.0/0.2.0 SQL、历史证据和 0.2.0 压缩包继续保留。

## 验证

最终 PG18.6 lab 通过冻结回归/升级、RLS 与 COPY、规划/索引/数组、批量一次写入与 TOAST、备份恢复、崩溃/PITR/物理提升和工作负载测试。独立在线 lab 通过原子快照/WAL 重放、unchanged-TOAST 重建、真实进程/PG 崩溃恢复、槽丢失检测、最终屏障和 abort。双 PGDATA lab 通过原生 publication/subscription、RLS/ACL 分离、worker 暂停/恢复/重启、分区根复制和验证接管。证据汇总见[validation-030](docs/validation-030.zh-CN.md)。

## 边界

源码包目标为 PostgreSQL 18.6/Linux x86_64；其他 minor 和架构需要单独验证。原生视图 `ON CONFLICT`、任意视图 DML 透明翻译、跨布局自动逻辑重组、多主复制、非 id 分区键和 Oracle 风格通用 duality view 不属于范围。通用 duality view 不作为未来里程碑。对业务视图执行 `pg_dump -t` 不会包含私有存储依赖。

发行包由 `scripts/package-release.py` 生成到 `build_output/0.3.0/`，只包含显式源码、SQL、脚本、测试和成对公共文档，不含 Git、本地 lab、数据库、dump、二进制或 JSONL 导出。本次不创建 tag 或上传 GitHub。
