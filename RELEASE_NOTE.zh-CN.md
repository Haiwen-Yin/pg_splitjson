# PG SplitJSON 0.1.0 发布说明

[English](RELEASE_NOTE.md) | **简体中文** · [README](README.zh-CN.md) · [API 参考](docs/api-reference.zh-CN.md)

**PostgreSQL Split JSON Storage Extension（PG SplitJSON）0.1.0** 是面向 PostgreSQL 18 的首个源码发布版本，已在 PostgreSQL 18.6 验证，采用 [Apache License 2.0](LICENSE)（`Apache-2.0`）。

PG SplitJSON 将高频更新的 JSON 路径存入普通独立列，其余文档存入版本化冷模板。应用通过包含 id、完整 JSONB doc 和可选业务列的视图访问；专用 API 更新已存在热字段及对象/数组子树时，可以不读取或重写 cold。

## 主要功能

- 独立热存储，区分字段缺失和 JSON null。文档不含声明字段时，保留原 JSONB 模板负载。
- 单字段替换、顺序原子批量、删除和行锁内精确 numeric 增量。全热批量只生成一次物理 UPDATE；回退操作重新拆分并同步全部热槽。
- 原生数组操作及固定数组热路径。声明 `["items",0,"price"]` 使用数组下标，`["items","0","price"]` 使用对象键；操作路径支持负下标。热子树外的结构位移重新拆分文档。
- 精确常量路径 SELECT 自动改写、字段直接读取、等值 ID 搜索及 JSONB/文本 B-tree 索引，保留原视图权限和安全屏障。
- 最多 64 个热路径、每条 64 段，以及最多 64 个类型化业务列。普通 bigint/JSONB 表快照迁移保留源表。
- cold 格式 v2 写入及 v1/v2 读取、MVCC 一致性、过期普通视图 DML 冲突检测、整库备份恢复和成对中英文文档。

## 安装与规划器加载

需要 PostgreSQL 18 server headers、PGXS、C 编译器、make 和 PL/pgSQL。编译并安装到选定 PG18 安装目录：

```sh
make PG_CONFIG=/path/to/pg18/bin/pg_config
make PG_CONFIG=/path/to/pg18/bin/pg_config install
```

在选定数据库中由扩展安装者执行：

```sql
CREATE EXTENSION pg_splitjson;
LOAD 'pg_splitjson';
SHOW splitjson.enable_query_rewrite;
```

自动改写要求规划前加载模块。管理员可为应用会话配置 `session_preload_libraries = 'pg_splitjson'`。模块加载后 `splitjson.enable_query_rewrite` 默认 on，改变时使缓存计划失效。

安装标识为 pg_splitjson，公共 API schema 为 splitjson，内部存储 schema 为 splitjson_storage。示例及应用授权见 [README](README.zh-CN.md)。

## 兼容性与限制

- 本版本提供内部存储封装和受管视图。PG 仍生成 heap 行版本，完整文档读取需要重组；文档变化的普通 UPDATE 重新拆分，不自动转为快速更新。
- 动态查询路径、含歧义数字段的 `#>`/`#>>`、末端 `->0`/`->>0` 标量提取及完整视图行引用保留原生表达式/计划。优化覆盖支持的 SELECT 形式，匹配索引仍由 PG 按成本选择。
- 固定数组槽标识位置，不标识业务元素身份。不支持数组通配及动态热布局。更新整个热数组仍需重写该数组，同一行的各字段共享行锁。
- 未提供视图 ON CONFLICT、RLS、分区、自动逻辑复制重组或完全 ORM 透明兼容。使用整库备份或逻辑导出；仅导出视图会缺少存储依赖。
- 迁移复制数据和类型，不复制默认值、约束、权限、排序规则或后续源表写入。更早未发布 pgjson 及 0.1.0 构建需新安装和逻辑迁移，不支持同版本在线覆盖库。cold v1 可读不等于扩展原地升级。

详细约定：[API 参考](docs/api-reference.zh-CN.md)、[数组与查询指南](docs/roadmap.zh-CN.md)、[存储格式](docs/storage-format.zh-CN.md)。

## 验证与分发

PG18.6 测试通过语义、并发、权限、真实索引计划及整库备份恢复检查。包括 338 组原生 JSONB 数组对照，并验证带索引固定数组更新和热数组子树操作保持 cold 的 18 字节 external TOAST 指针及分块。这些结果验证已测试行为，生产性能取决于实际负载。

源码 ZIP 为 `pg_splitjson-0.1.0.zip`，校验文件为包外的 `.zip.sha256`。产物存放在 `build_output/0.1.0/`。ZIP 包含项目源码、安装文件、许可证、公共文档和测试，不含本地构建产物、实验报告/日志、Git 元数据、代理指引及开发归档。
