# PG SplitJSON 0.2.0 API 参考

[English](api-reference.md) | **简体中文** · [文档目录](README.zh-CN.md)

本文列出 **PostgreSQL Split JSON Storage Extension（PG SplitJSON）0.2.0** 的业务 API。安装 `pg_splitjson`，使用 `splitjson` schema。签名以[安装 SQL](../sql/pg_splitjson--0.2.0.sql)为依据。

## 通用约定

- `p_table` 指向受管**业务视图**，不是内部存储表。建议使用限定 schema 的关系名，由 PG 解析为 `regclass`。
- 每个受管视图提供 `id bigint`、`doc jsonb` 和可选业务列。id 唯一，id/doc 不允许 SQL NULL；文档可以是任意 JSONB 值，包括 JSON null。
- 声明 1–64 个唯一且不重叠的路径，每条 1–64 段。字符串是字面对象键，非负 int32 整数是固定数组下标，例如 `[["items",0,"price"],["state"]]`。数字字符串仍表示对象键。操作路径是一维且无 NULL 段的 `text[]`，例如 `ARRAY['items','0','price']`；批量路径是字符串数组。
- 操作路径沿用原生 JSONB 对象/数组语义，包括负下标和原生错误。声明下标为非负且要求实际数组，缺失或容器类型不匹配的路径不拆出。热子树外的结构变化通过重新拆分同步全部热槽。
- 缺失与 JSON null 不同：热槽的 SQL NULL 表示缺失，`'null'::jsonb` 表示存在的值。业务 API 参数不允许 SQL NULL。
- 布尔更新结果表示目标行是否存在。`true` 不意味着内容改变或使用快速路径，`false` 表示未找到目标行。查询遇到缺失 ID 时返回空集或 SQL NULL，具体如下。
- `p_create_missing` 默认为 true，沿用原生 `jsonb_set`，不会创建缺失的中间对象。False 阻止创建缺失的末端键，原生标量/路径错误仍然适用。

## 函数签名

以下声明用于参考，不是 SQL 安装脚本。

```sql
splitjson.create_table(
    p_name text, p_paths jsonb, p_columns jsonb DEFAULT '{}'
) RETURNS regclass

splitjson.set_field(
    p_table regclass, p_id bigint, p_path text[], p_value jsonb,
    p_create_missing boolean DEFAULT true
) RETURNS boolean

splitjson.set_fields(
    p_table regclass, p_id bigint, p_updates jsonb,
    p_create_missing boolean DEFAULT true
) RETURNS boolean

splitjson.increment_field(
    p_table regclass, p_id bigint, p_path text[], p_delta numeric DEFAULT 1
) RETURNS numeric

splitjson.delete_field(
    p_table regclass, p_id bigint, p_path text[]
) RETURNS boolean

splitjson.drop_table(p_table regclass) RETURNS void

splitjson.migrate_table(
    p_source regclass, p_target text, p_paths jsonb,
    p_doc_column name DEFAULT 'doc', p_id_column name DEFAULT 'id'
) RETURNS regclass

splitjson.get_field(
    p_table regclass, p_id bigint, p_path text[]
) RETURNS jsonb

splitjson.find_ids(
    p_table regclass, p_path text[], p_value jsonb
) RETURNS SETOF bigint

splitjson.explain_find_ids(
    p_table regclass, p_path text[], p_value jsonb
) RETURNS SETOF text

splitjson.create_path_index(
    p_table regclass, p_name text, p_path text[]
) RETURNS regclass

splitjson.grant_access(
    p_table regclass, p_role regrole, p_mode text
) RETURNS void

splitjson.check_table(
    p_table regclass, p_check_data boolean DEFAULT false
) RETURNS jsonb

splitjson.check_all(
    p_check_data boolean DEFAULT false
) RETURNS SETOF jsonb

splitjson.table_stats(p_table regclass) RETURNS jsonb
splitjson.rename_table(p_table regclass, p_name text) RETURNS regclass
splitjson.set_business_not_null(p_table regclass, p_column text,
                                p_enabled boolean DEFAULT true) RETURNS void
splitjson.set_business_default(p_table regclass, p_column text,
                               p_value jsonb) RETURNS void
splitjson.add_field_check(p_table regclass, p_name text, p_path jsonb,
                          p_type text, p_required boolean DEFAULT false) RETURNS void
splitjson.index_ddl(p_table regclass, p_name text, p_path jsonb,
                    p_kind text DEFAULT 'jsonb', p_unique boolean DEFAULT false) RETURNS text

splitjson.create_path_index(
    p_table regclass, p_name text, p_path text[], p_kind text
) RETURNS regclass

splitjson.create_path_index(
    p_table regclass, p_name text, p_path jsonb, p_kind text DEFAULT 'jsonb'
) RETURNS regclass
```

## 创建与迁移

### create_table

创建业务视图、内部 heap 表、写入触发器和元数据映射，返回业务视图的 `regclass`。由扩展安装者执行。`p_name` 必须包含已存在的 schema 和新的关系名，例如 `public.events`。支持 PG 引号标识符，标识符不得超过 PG 的 63 字节限制。

`p_paths` 声明热存储布局；`p_columns` 默认 `{}`，将最多 64 个业务列名映射到 SQL 类型字符串。禁止 id/doc 和空列名。类型参数、数组、限定 schema 的 domain 保持原生类型，不附加额外默认值或 NOT NULL。视图先列出 id/doc，再按 C 排序规则的列名顺序列出业务列；INSERT 应明确指定列名。

### migrate_table

在一个事务内将普通源表复制到**新的**受管视图。`p_source` 必须包含不同的 bigint 与 JSONB 列，由 `p_id_column` 和 `p_doc_column` 指定。`p_target` 需限定 schema，`p_paths` 声明目标热布局，返回新视图的 `regclass`。由安装者执行，并需拥有源表 SELECT 权限。

复制保留 ID、文档、额外列数据、类型和 typmod。源表保持不变；重复 ID、SQL NULL 文档等非法数据使目标创建与复制全部回滚。额外列遵循 `create_table` 的数量、名称和类型规则。

不复制默认值、约束、索引、触发器、列排序规则和权限，也不持续同步后续源表写入。此功能是快照迁移；应用切换前需安排停写或同步，并验证复制结果。自定义源列名在目标中变为 id/doc。

### drop_table

事务内删除受管视图、内部表和映射，需要拥有视图或拥有视图所有者角色的相应权限。不使用 CASCADE，需先处理依赖对象。使用该 API，不直接删除或重命名受管对象。

### 运维管理

`grant_access` 向已有角色授予 `read` 或 `write` 模式下的业务视图和最小辅助/更新函数权限，不授予内部存储权限。`check_table` 校验一个映射，可选地还原全部行；`check_all` 校验所有受管映射。`table_stats` 返回内部表的 PostgreSQL 统计和关系大小。`rename_table` 在业务 schema 内修改受管视图名称。`set_business_not_null`、`set_business_default` 和 `add_field_check` 在受管存储上应用类型化业务约束。`index_ddl` 返回可审阅的 `CREATE INDEX [CONCURRENTLY]` SQL，应在事务外执行并检查 invalid index。

## 更新

### set_field

锁定目标行并替换一个对象/数组路径的值。已存在的精确热路径及热对象/数组内部的子路径只更新对应热列，不读取或赋值 cold。缺失热槽、非热路径、父替换及热子树外的结构位移还原文档，使用原生 `jsonb_set` 并重新拆分全部热值。标量热祖先使用该回退以保持原生行为。返回行是否存在的布尔值，需要视图 doc 列 UPDATE 权限。

### set_fields

按顺序原子执行包含 1–64 个操作的数组。每个对象必须**恰好**包含 `path`（字符串键的 JSON 数组）和 `value`（任意 JSON 值）。重复路径以最后值为准，父子路径操作按顺序解释。

如果所有操作都命中已存在的热字段或热对象/数组子路径，仅读取热列并执行一次物理 UPDATE；否则还原文档一次、按顺序执行操作，再重新拆分写入一次。任意失败使整批回滚。返回行是否存在的布尔值，需要 doc UPDATE 权限。

### increment_field

在同一行锁内读取已有 JSON 数字并加上 `p_delta`。采用 PG 精确 numeric 运算，允许负数与小数，默认增量为 1。已存在的精确热路径或热对象/数组子路径只更新对应热列；其他路径重新拆分文档，其他热值与业务列保持不变。

返回新的 numeric，缺失行返回 SQL NULL。缺失字段、JSON null、非数字目标或非有限增量报 `22023`，不会初始化缺失计数器。需要 doc UPDATE 权限。

### delete_field

锁定行并执行原生 JSONB 路径删除。已存在热对象/数组内部的子路径只更新热列；删除整个热槽或热子树外的结构则还原并重新拆分，删除占位符并同步位移位置。缺失、类型和路径行为沿用原生规则。返回行是否存在的布尔值，需要 doc UPDATE 权限，而不是视图整行 DELETE 权限。

## 读取与查询索引

### get_field

返回 JSONB 字段值。已存在的精确热路径及热对象/数组子路径读取热值；其他路径读取还原的文档。缺失行或字段返回 SQL NULL；存在的 JSON null 返回 JSONB null。需要同时拥有 id/doc SELECT 权限。该函数为 STABLE，遵循语句的 MVCC 快照。

### find_ids

按原生 JSONB 等值语义返回字段与 `p_value` 相等的 ID。精确热路径直接过滤热列，可使用 B-tree；其他路径过滤还原后的文档。查询 JSON null 时排除缺失字段。无匹配时返回空集，结果顺序无保证。需要 id/doc SELECT 权限，遵循语句的 MVCC 快照。

数字操作路径可能访问未声明拆出的对象/数组形状；没有现存候选热槽的行使用原生文档回退。有顺序需求时在外层增加 ORDER BY；普通 SELECT 自动改写见下文。

### create_path_index

为已注册热槽创建原生非唯一 B-tree，返回索引的 `regclass`。原三参数 `text[]` 重载使用 JSONB；四参数重载通过 `p_kind = 'jsonb'` 或 `'text'` 选择，文本索引表达式为 `(hot_N #>> '{}'::text[])`。typed JSONB 路径区分下标与对象键，默认 JSONB。`text[]` 必须唯一确定一个注册槽，存在歧义时使用 typed 重载。`p_name` 是单个 PG 标识符，不是 schema 限定名称；索引位于 `splitjson_storage`。由安装者执行。

热更新同步维护索引，可能阻止 HOT 更新并增加 WAL，但仍可复用冷 TOAST。PG 按成本选择索引或顺序扫描，创建索引不保证所有载荷都使用索引扫描。

### explain_find_ids

返回 `find_ids` 同一内部查询的 `EXPLAIN (COSTS OFF)` 文本行。由安装者执行，不是业务读取 API，也不执行 EXPLAIN ANALYZE。

### SELECT 自动改写

规划前加载 pg_splitjson，由安装者执行 `LOAD 'pg_splitjson'` 或由管理员设置 session preload。`splitjson.enable_query_rewrite` 默认 on，改变时使缓存计划失效。精确常量对象提取路径和 typed 数组链可使用热投影；WHERE 内建等值与常量/预备值比较可使用匹配 JSONB/文本索引。保留原视图权限、所有者和安全屏障。

动态路径、`#>`/`#>>` 中的数字文本段、末端 `->0`/`->>0` 的标量语义、完整视图行引用及不支持的投影保留原表达式。自动改写适用于 SELECT，不把普通 UPDATE 自动转为快速更新。示例、加载方式和限制见[数组与查询指南](roadmap.zh-CN.md)。

## 完整示例

在已安装 `pg_splitjson` 的测试数据库中由安装者执行，下列关系名与 README 示例独立。授权片段假设 `app_role` 已存在。

```sql
SELECT splitjson.create_table('public.api_events',
    '[["stats","count"],["state"]]', '{"tenant_id":"bigint"}');

INSERT INTO public.api_events(id, doc, tenant_id) VALUES
    (1, '{"stats":{"count":0},"state":"new","items":[1,2]}', 100),
    (2, '{"body":"cold"}', 200);

SELECT splitjson.set_field('public.api_events', 1, ARRAY['state'], '"ready"');
SELECT splitjson.set_fields('public.api_events', 1,
    '[{"path":["stats","count"],"value":10},{"path":["state"],"value":"done"}]');
SELECT splitjson.increment_field('public.api_events', 1, ARRAY['stats','count'], 0.5);
-- 返回 10.5。

SELECT splitjson.set_field('public.api_events', 1, ARRAY['items'], '[3,4]');
SELECT splitjson.set_field('public.api_events', 2, ARRAY['state'], 'null');
SELECT splitjson.get_field('public.api_events', 2, ARRAY['state']); -- JSONB null。
SELECT splitjson.delete_field('public.api_events', 2, ARRAY['state']);
SELECT splitjson.get_field('public.api_events', 2, ARRAY['state']) IS NULL; -- true。

SELECT splitjson.create_path_index('public.api_events', 'api_events_state_idx', ARRAY['state']);
SELECT * FROM splitjson.find_ids('public.api_events', ARRAY['state'], '"done"') ORDER BY 1;
SELECT * FROM splitjson.explain_find_ids('public.api_events', ARRAY['state'], '"done"');

UPDATE public.api_events SET tenant_id = 101 WHERE id = 1;
SELECT * FROM public.api_events ORDER BY id;

CREATE TABLE public.api_source (key bigint PRIMARY KEY, body jsonb NOT NULL, label text);
INSERT INTO public.api_source VALUES (1, '{"count":5}', 'source');
SELECT splitjson.migrate_table('public.api_source', 'public.api_copy',
    '[["count"]]', 'body', 'key');
SELECT * FROM public.api_copy;
SELECT * FROM public.api_source; -- 源表未修改。

GRANT USAGE ON SCHEMA public, splitjson TO app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.api_events TO app_role;

-- 检查结果后清理。
SELECT splitjson.drop_table('public.api_copy');
SELECT splitjson.drop_table('public.api_events');
DROP TABLE public.api_source;
```

## 事务、权限与错误

专用更新持有行锁至事务结束，同一行的修改串行执行。读改写计数器使用 `increment_field`，应用先读取再调用 `set_field` 可能丢失增量。普通视图 UPDATE/DELETE 在行锁内检查包括业务列的完整旧行；行已经改变时报 `40001`，应用按自身事务策略重试，并按常规处理其他原生 PG 并发错误。

普通 INSERT/UPDATE/DELETE 检查视图权限。更新函数检查有效调用角色的 doc UPDATE，包括 SET ROLE 和 SESSION AUTHORIZATION；读取函数检查 id/doc SELECT。应用仅获得视图和公共 API schema 权限，内部表及元数据不开放。这些检查与普通 schema USAGE、函数 EXECUTE 权限同时适用。DDL、迁移、索引创建和计划检查由安装者执行，删除需要所有权。

| SQLSTATE | 常见原因 |
| --- | --- |
| `22023` | 非法参数/路径、重叠声明、非法批量或增量目标 |
| `22P02` | 原生数组操作使用非整数下标 |
| `23502` | 视图 DML 或迁移中的 id/文档为 SQL NULL |
| `23505` | 视图 DML 或迁移中的重复 id |
| `42501` | 视图权限或所有权不足 |
| `40001` | 普通视图 UPDATE/DELETE 的旧值冲突，或原生序列化失败 |

此表不是完整错误列表；非法 SQL/JSON、无法解析的关系、非法类型或运算限制仍可能触发 PG 原生错误。

## 内部格式函数

这些函数用于检查和格式实验，不是应用绕过 API 修改存储的入口。以下划线 `_` 开头的函数属于内部实现，类型输入/输出由 PG 自动调用。封装约定见[存储格式](storage-format.zh-CN.md)。

| 函数 | 结果 / 用途 |
| --- | --- |
| `splitjson.validate_paths(jsonb)` | void；检查路径结构与重叠，允许空列表，与 create_table 不同 |
| `splitjson.pack(jsonb, jsonb)` | splitjson.cold；文档 + 路径 → 冷模板封装 |
| `splitjson.slots(jsonb, jsonb)` | jsonb[]；按声明顺序提取热值，SQL NULL 元素表示缺失 |
| `splitjson.restore(splitjson.cold, jsonb[])` | jsonb；还原完整文档并验证热槽数量/存在性 |
| `splitjson.restore(splitjson.cold, jsonb[], jsonb)` | jsonb；额外核对声明路径与 cold，生成视图使用此重载 |
| `splitjson.json_field(jsonb, text[])` | jsonb；对象/数组的原生 `#>` 提取 |
| `splitjson.template(splitjson.cold)` | jsonb；检查冷模板 |
| `splitjson.paths(splitjson.cold)` | jsonb；检查声明路径 |
| `splitjson.assert_object_path(jsonb, text[])` | void；保留旧名称，仅检查路径结构，不检查文档或断言字段存在 |
| `splitjson.object_field(jsonb, text[])` | jsonb；仅遍历对象，缺失或穿过数组返回 SQL NULL |
| `splitjson.column_type(text)` | text；规范化 SQL 类型声明，保留 typmod，拒绝伪类型 |

这些 C 函数为 STRICT，任意 SQL NULL 参数会直接返回 SQL NULL 而不调用函数体，与业务 API 显式拒绝 SQL NULL 不同。不要把 `template` 当作完整文档，也不要独立修改内部 cold/hot 列。
