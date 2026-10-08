# PG SplitJSON 0.2.0 验证报告

[English](validation.md) | **简体中文** · [文档目录](README.zh-CN.md)

生产硬化测试已在 10.10.10.131 的全新独立实验中通过，环境为 **PostgreSQL 18.6**、Linux x86_64。实验从 `/usr/local/pgsql-18.6` 复制到唯一 `/tmp/pg_splitjson-lab.*` 前缀，使用私有 socket、`listen_addresses=''` 和全新 PGDATA；没有连接或修改任何现有 PostgreSQL 实例。原始日志位于 [validation/pg-splitjson-0.2.0/](validation/pg-splitjson-0.2.0/)。

## 发布与正确性

| 检查 | 结果 |
| --- | --- |
| 构建 | PGXS 编译和安装无警告完成 |
| 回归 | `make installcheck`：1/1 production 测试通过 |
| 升级 | 正式 0.1.0 到 0.2.0 通过；cold 指针/分块保留 |
| 差分 | 5000 组有种子 JSONB 操作通过 |
| 数组 | 原生 set/delete、固定槽和结构重新拆分通过 |
| 并发 | 对象、固定数组和子树增量无丢失完成 |
| 权限/DDL | 仅视图角色、内部存储、受保护 DDL 和受控重命名/删除通过 |
| 物理存储 | 带索引热更新和热子树更新复用未变化 cold TOAST 指针/分块 |
| 备份 | 整库 dump/restore 保留 API、类型化列和权限 |

证据文件：`installcheck.log`、`upgrade.log`、`randomized.log`、`production_features.log`、`concurrency.log`、`physical.log` 和 `restore.log`。

## 恢复

同一独立集群通过了立即崩溃恢复、命名恢复点 PITR、流复制备库回放和提升。已提交热/冷值及业务行保留；崩溃时未提交行消失；PITR 在目标点之前停止；提升后的备库接受热字段更新。证据见 [recovery.log](validation/pg-splitjson-0.2.0/recovery.log)。

物理恢复只支持相同 PostgreSQL minor/ABI 和扩展文件。跨 PostgreSQL 大版本使用逻辑导出/导入。每次恢复或提升后，恢复流量前执行 `splitjson.check_all(true)`。

## 有界负载实测

生产脚本使用 200 行、约 256 KiB cold 负载、四个 pgbench 客户端、每组八秒，并在 `state` 上建立一个文本 B-tree。数字只证明本配置的行为，不是通用基准或 SLA。

| 场景 | 报告 TPS | WAL 字节 |
| --- | ---: | ---: |
| 拆分热字段同一行 | 1,019.998 | 9,147,136 |
| 原生 JSONB 同一行 | 350.398 | 68,009,496 |
| 拆分热字段不同行 | 1,603.677 | 16,327,648 |
| 原生 JSONB 不同行 | 952.378 | 280,014,456 |
| 拆分索引读取 | 2,546.868 | 25,411,592 |
| 原生索引读取 | 1,772.560 | 90,761,832 |
| 拆分 cold 读取 | 1,077.577 | 18,249,096 |
| 原生 cold 读取 | 2,032.366 | 32,521,056 |
| 拆分混合 | 1,014.271 | 17,873,592 |
| 原生混合 | 898.724 | 137,084,872 |
| 拆分结构回退 | 705.785 | 109,081,720 |
| 原生结构更新 | 1,468.066 | 219,244,992 |

在该同一行场景中，拆分热更新组的 WAL 约减少 86.5%。冷读和结构更新可能更适合原生 JSONB。短测试结束时执行了 `VACUUM (ANALYZE)`、`REINDEX`、`check_all(true)`，维护后死元组为零；这只是短时观察，不代表长期膨胀结果。

## 限制与复现

只有专用 API 提供快速路径契约。普通文档 DML 会重新拆分；同一行写入仍串行；热索引列变化可能阻止 HOT。不支持 RLS、分区受管关系、视图 `ON CONFLICT`、自动逻辑复制重组和通用 duality view。详见[支持矩阵](support-matrix.zh-CN.md)和[生产运行手册](production-runbook.zh-CN.md)。

使用 `./scripts/test-remote.sh root@10.10.10.131 /usr/local/pgsql-18.6` 复现。脚本复制工具链，只停止自身临时集群。
