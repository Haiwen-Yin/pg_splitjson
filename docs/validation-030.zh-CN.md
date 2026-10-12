# PG SplitJSON 0.3.0 验证报告

[English](validation-030.md) | **简体中文** · [OpenSpec 任务](../openspec/changes/prepare-extension-capabilities-030/tasks.md)

0.3.0 已完成 PostgreSQL 18.6、Linux x86_64 的实施门禁。以下每项数据库实验都通过 `scripts/test-remote.sh` 在 `root@10.10.10.131` 执行。运行器把 `/usr/local/pgsql-18.6` 复制到全新的 `/tmp/pg_splitjson-lab.*` 前缀，创建私有 PGDATA 与 socket，并且只停止这些集群。没有连接或修改任何现有 PostgreSQL 实例。

| 门禁 | Lab | 结果 | 证据 |
| --- | --- | --- | --- |
| 完整旧回归、升级、RLS、规划器、可移植性、TOAST、备份恢复、恢复和负载套件 | `n0UxNd` | 通过 | `validation/pg-splitjson-0.3.0-final/full.log` |
| 在线快照/WAL 迁移 | `mF8tkk` | 通过 | `validation/pg-splitjson-0.3.0-final/online_030.log` |
| 同布局原生逻辑 publication/subscription | `kRnekV` | 通过 | `validation/pg-splitjson-0.3.0-final/replication_030.log` |
| 最终 API 变更后的能力与可移植性断言 | `Akc56X`（规划断言修正前）及最终完整运行 `n0UxNd` | 最终运行通过 | `validation/pg-splitjson-0.3.0-final/full.log` |

最终完整运行报告 `All checks passed.`，包括冻结回归、0.1.0 → 0.2.0 → 0.3.0 升级、RLS 身份与 `COPY`、原生 HASH/RANGE 路由、numeric/boolean/text 类型索引、真实规划器输出、数组后缀改写、批量一次写入与增量并发、cold TOAST 原始指针/分块复用、JSONL 导出导入、pg_dump/pg_restore、即时崩溃恢复、命名恢复点 PITR、流复制备库提升和工作负载基准。最终在线运行器还验证了快照复制、并发插入/更新/删除/回滚、id 移动、unchanged 外部 TOAST、提交前及提交后确认前的真实子进程故障、临时 PostgreSQL 即时崩溃、WAL 槽丢失、最终写屏障和 abort。最终复制实验使用两个全新 PGDATA，验证初始同步、冷热/数组/类型化列混合事务、RLS 过滤、follower 写入拒绝、暂停/恢复、apply worker 重启、分区根发布、跨分区 id 移动、最终屏障标记和接管。

最终 lab 保留的基准原样输出如下：`case=split_cold_read samples=4252 p50_us=503978 p95_us=948592 p99_us=988377 wal_bytes=33229800 tps = 532.744291`；这只是特定负载结果，不是产品承诺。完整原始日志仍在被忽略的 lab 目录，不是发行物。本目录的精简证据不含凭据、数据库文件、dump 或 JSONL 数据。

最终打包门禁还执行了 `python3 scripts/generate-sql.py --check`、`git diff --check`、Python AST 语法检查、严格 OpenSpec 校验和显式源码文件审计。0.2.0 压缩包及历史 SHA-256 保持不变。此版本只在已测试的 PG18.6/Linux x86_64 目标上声明支持；其他 PostgreSQL minor 和架构需要单独验证。
