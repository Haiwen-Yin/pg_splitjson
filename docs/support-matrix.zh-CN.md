# PG SplitJSON 0.3.0 支持矩阵

[English](support-matrix.md) | **简体中文** · [文档目录](README.zh-CN.md)

面向 PostgreSQL 18.6/Linux x86_64 的发行支持矩阵。最终隔离实验见[validation-030](validation-030.zh-CN.md)。

| 领域 | 已支持 / 已验证 | 边界 |
| --- | --- | --- |
| PostgreSQL | 18.6，PGXS 构建和独立回归已验证 | 不声明支持其他大版本/minor |
| 操作系统 / CPU | Linux x86_64、64 位、GCC 8.5 实验 | 其他平台需自行构建和验证 |
| 物理 HA | 崩溃恢复、WAL 归档 PITR、流复制回放和备库提升 | 要求相同 PostgreSQL minor/ABI 与扩展文件 |
| 逻辑备份 | 整库 `pg_dump -Fc`/`pg_restore` 和 JSONL 快照导入导出已验证 | 只导出视图的 `pg_dump -t` 不含私有存储依赖 |
| JSON 值 | 对象、数组、标量、JSON null；缺失与 JSON null 区分 | SQL NULL 文档/ID 拒绝 |
| 热路径 | 多级对象路径和固定非负数组下标，最多 64 路径 × 每路 64 段 | 不支持重叠、通配或任意动态槽 |
| 更新 | 专用单字段、批量、删除、增量、行令牌条件写入、upsert、JSON Patch、Merge Patch API | 不提供 JSONB 页内原地更新；结构变化回退重新拆分 |
| 查询 | 直接读取、等值/范围辅助、JSONB/text/typed B-tree、后缀提取和精确 SELECT 改写 | 动态路径、危险 cast/collation 和任意查询保留原生计划 |
| 安全 | 调用者感知的存储 RLS 生命周期、COPY、角色授权、安全屏障和私有 ACL 已验证 | 策略表达式受限，策略 DDL 由安装者执行 |
| 关系 | 业务视图对应私有 heap 或仅按 id 的 HASH/RANGE 父表，支持类型化业务列和逐叶索引 | 不支持其他分区键、子分区或视图 `ON CONFLICT` |
| 在线迁移 | 快照/WAL 运行器、unchanged-TOAST 重建、进度原子提交、崩溃/恢复、WAL 丢失检测、最终屏障和 abort | 应用流量切换由用户执行；源保留并 fenced |
| 逻辑复制 | 同布局 PG18.6/0.3.0 原生存储 publication/subscription、worker 状态、暂停/恢复和验证接管 | 不做跨布局重组、隐式 DDL/ACL/策略复制或多主 |
| API 集成 | 专用 API 契约、生产手册和成对文档 | 不提供完全 ORM 透明和通用 Oracle 风格 duality view |

所有性能数字都是特定负载证据。生产负载应自行验证延迟、WAL、锁等待、索引成本、vacuum 和膨胀。
