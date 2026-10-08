# PG SplitJSON 项目介绍

[English](introduction.md) | **简体中文** · [文档目录](README.zh-CN.md)

## 统一项目身份

| 项目 | 值 |
| --- | --- |
| 完整英文名称 | PostgreSQL Split JSON Storage Extension |
| 简称 | PG SplitJSON |
| 中文说明名称 | PostgreSQL JSON 分离存储扩展 |
| 扩展标识 | `pg_splitjson` |
| 扩展版本 | `0.2.0` |
| 许可证 | [Apache License 2.0](../LICENSE)（`Apache-2.0`） |
| 目标 / 已验证 PostgreSQL | 18 / 18.6 |
| 公共 API schema | `splitjson` |
| 内部存储 schema | `splitjson_storage` |
| 内部 cold 格式版本 | 新写入 `2`；读取 `1`/`2` |

首次介绍使用完整英文名称，并附简称 **PG SplitJSON**。安装命令使用 `pg_splitjson`，SQL 示例使用 `splitjson.*`。中文说明名称对应同一个产品，不是另一个扩展标识。

## 简短介绍

**PostgreSQL Split JSON Storage Extension（PG SplitJSON）** 是面向 PostgreSQL 18 的 JSON 高频字段更新扩展。它将声明的热路径分离到普通独立列，其余内容保存为版本化冷模板。业务视图提供完整 JSONB 文档，专用 API 可更新已存在热字段而无需重写冷模板。

## 完整介绍

大型 JSONB 文档通常只有少数字段频繁变化，例如计数器、状态和进度。为这些变化反复重建文档，可能产生大量 TOAST 和 WAL 写入。PG SplitJSON 允许建表时声明常用更新对象或固定数组路径，将其值从文档其余部分独立存储。

内部 heap 表保存版本化 JSONB 模板、已存在热路径上的 null 占位符以及独立 JSONB 热列。未出现的声明字段继续保持缺失。业务视图还原完整 `doc`，对外提供 `id` 和可选类型化业务列，使应用常规读取无需接触内部布局。

更新 API 提供单字段替换、按顺序执行的原子批量更新，以及在行锁内完成的精确 numeric 增量。已存在的精确热字段及热对象/数组子路径只修改对应热列；非热更新、首次创建和热子树外的结构变化则还原并重新拆分，在同一事务内同步全部热槽。

PG SplitJSON 还提供普通 bigint/JSONB 表的快照数据迁移、热字段直接读取、等值搜索，以及热列上的可选原生 B-tree 查询索引。实现沿用 PostgreSQL 的 heap、MVCC、WAL 和 TOAST 机制，无需修改 PostgreSQL 内核。

## 设计背景

尹海文的[高频 JSON 更新文章](https://blog.csdn.net/yhw1809/article/details/164757146)强调将常变字段与半静态属性拆开，以及把 JSON 作为关系存储之上的访问层。PG SplitJSON 将这一思想落实到 PostgreSQL 单行内声明的路径：热值只保存一份，冷模板记录占位符，通用 duality view 不属于项目范围。

[设计与场景指南](design-rationale.zh-CN.md)将这一思路对应到商品/SKU、订单、背包和物流场景，并解释路径选择、查询/索引成本和 vacuum 观察。复用冷值改善写入行为，MVCC 和同一行的锁竞争仍然存在。

## 0.2.0 能力

| 方向 | 能力 |
| --- | --- |
| 更新 | 单字段更新、一次写入的批量更新、原子 numeric 增量 |
| 业务表 | id/doc 视图、最多 64 个类型化业务列、快照数据迁移 |
| 数组 | 原生数组操作、热子树和 typed 固定位置槽 |
| 查询 | 直接读取、JSONB 等值搜索、JSONB/文本索引和精确路径 SELECT 自动改写 |
| 正确性 | 区分缺失与 JSON null、行锁、视图旧值冲突检测、权限检查 |
| 验证 | PostgreSQL 18.6 语义、并发、索引计划、冷 TOAST 复用和整库备份恢复 |

## 适用边界与证据

0.2.0 采用受管视图和专用 API，提供内部封装格式，不替换 PostgreSQL 的 JSONB 存储格式。PG 仍会创建新行版本；主要优化是复用大型不变冷值的 TOAST 存储。完整文档读取需要重组，规划前加载模块后，支持的常量热路径 SELECT 提取可自动使用热列和匹配索引。本版本增加正式 0.1.0 升级、最小权限授权、映射检查、DDL 控制、运维辅助函数和恢复流程。

路径支持多级对象和固定数组下标，操作路径遵循包括负下标的原生数组语义。数字文本提取路径和涉及标量的末端 ->0 保留原生表达式。不支持动态通配。迁移复制数据与列类型，保留源表，不复制约束、默认值、权限或后续源表写入。尚未提供动态热路径变更、视图 `ON CONFLICT`、RLS、分区和自动逻辑复制重组。

独立 PG18.6 实验中，对约 256 KiB 文档执行 300 次更新，原生 JSONB 和 PG SplitJSON 的 WAL 分别为 **86,795,752 和 64,144 字节**，耗时分别为 **671.824 和 82.799 ms**。这些是特定载荷的测试结果，不是生产吞吐保证；实验条件、原始证据和测量限制见[验证报告](validation.zh-CN.md)。

安装和示例见 [README](../README.zh-CN.md)，精确行为约定见 [API 参考](api-reference.zh-CN.md)。
