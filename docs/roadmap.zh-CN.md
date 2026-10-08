# 0.2.0 数组与自动查询改写

[English](roadmap.md) | **简体中文** · [文档目录](README.zh-CN.md)

**PG SplitJSON 0.2.0 已实现数组操作、固定数组热槽和精确路径 SELECT 自动改写。** 本文替代之前的实施计划。通用 duality view 不属于项目范围。

## 选择数组更新单元

| 布局 | 声明 | 快速操作 | 成本与边界 |
| --- | --- | --- | --- |
| 整个数组作为热值 | `[["items"]]` | 更新/删除/增量 items 内部路径，包括负下标 | 重写热数组，保留 cold；同一行锁 |
| 固定数组叶子作为热槽 | `[["items",0,"price"]]` | 更新已存在 items[0].price | 仅重写叶子；热子树外的位置位移重新拆分全部热槽 |
| 非热数组 | 无匹配热路径 | 原生对象/数组操作 | 还原、修改、重新拆分 |

声明用字符串表示对象键、非负整数表示数组下标。`["items",0,"price"]` 要求 items 为数组；`["items","0","price"]` 要求 items 为含键 0 的对象。根数组可用 `[[0,"price"]]` 声明。下标从零开始，须为整数且不超过 2147483647；0 与 0.0 等价，不能重复声明。路径不重叠，限制仍为 64 个槽、每条 64 段。

操作沿用 `text[]` 路径或 set_fields 中的字符串数组，遵循原生 JSONB 遍历："0" 在对象上是键、在数组上是下标。负操作下标相对当前长度定位，不作为注册槽。越界插入、缺失中间节点、标量无操作和错误均沿用原生行为。

```sql
SELECT splitjson.create_table('public.array_events',
    '[["items",0,"price"],["tags"],["state"]]');
INSERT INTO public.array_events VALUES
    (1,'{"items":[{"price":10},{"price":20}],"tags":["a","b"],"state":"new"}');
SELECT splitjson.increment_field('public.array_events',1,ARRAY['items','0','price'],0.5);
SELECT splitjson.set_fields('public.array_events',1,
    '[{"path":["items","0","price"],"value":12},{"path":["tags","-1"],"value":"c"}]');
-- 两个操作只更新热列，合并一次写入，不读取或赋值 cold。
SELECT splitjson.delete_field('public.array_events',1,ARRAY['items','0']);
-- 剩余元素成为位置 0，重新拆分时提取其 price（20）。
SELECT splitjson.get_field('public.array_events',1,ARRAY['items','0','price']);
```

删除整个注册槽、热子树外的数组插入/删除/重排、父替换、首次创建缺失热槽，均还原并重新拆分全部热槽。普通视图 UPDATE 可用 jsonb_insert 表达插入；文档变化的普通 DML 重新拆分。批量按顺序执行且只写一次；任一操作需回退时，从原文档重放完整批量。失败则整批回滚。

固定槽标识**位置**，不标识业务元素身份。动态通配 `items[*].price`、动态槽数量和自动数组到子表映射不支持，各元素仍共享一把行锁。cold v2 写入类型化声明，同时保持 v1 可读；见[存储格式](storage-format.zh-CN.md)。

## 规划前加载

C 规划器模块必须在查询规划前加载。测试会话由安装者执行 LOAD；应用会话可由管理员设置 `session_preload_libraries = 'pg_splitjson'`。实验脚本只在临时实例设置 session preload。仅安装扩展或依赖函数首次执行，不保证第一次查询获得改写。

```sql
LOAD 'pg_splitjson';
SHOW splitjson.enable_query_rewrite; -- 模块加载后默认 on
SET splitjson.enable_query_rewrite=off;
SET splitjson.enable_query_rewrite=on;
```

开关使缓存计划失效。模块保留前一个 planner hook，在当前数据库中解析限定函数/类型标识，扩展不存在时安全委托普通规划器。不通过 SPI 查询元数据，也不保留可能陈旧的槽缓存。

## 支持的查询形式与索引

规划器识别生成的无过滤、单存储表、安全屏障视图投影，通过内部投影映射**精确常量注册提取路径**，保持公开输出列、原权限记录和视图所有者。不增加私有表授权、不移除屏障、不更改 leakproof 标记。

| 表达式 | 改写 / 索引行为 |
| --- | --- |
| `doc->'state'`、`doc#>'{state}'` | 热 JSONB 值；JSONB B-tree 支持等值 |
| `doc->>'state'`、`doc#>>'{state}'` | `hot_N #>> '{}'`；匹配文本表达式 B-tree |
| `doc->'items'->0->>'price'` | 带类型的链匹配 `["items",0,"price"]`；文本 B-tree |
| `doc#>>'{items,0,price}'` | 原生回退：数字文本既可能是数组下标，也可能是对象键 |
| 末端 `doc->0` / `doc->>0` | 原生回退：这两个操作符也能提取标量 |
| row_to_json(d) 等完整视图行引用 | 保留原生计划，维持公开复合行类型 |
| 动态路径、负提取下标、不支持的投影 | 保留原生表达式 |

常量 jsonb_extract_path / jsonb_extract_path_text 采用相同路径规则。比较值可为常量或预备语句参数。WHERE 内建 JSONB/文本等值可向标准视图加入等价内部条件，同时保留外层条件以维持外连接 NULL 语义。其他谓词、连接、类型转换与排序规则保留自身操作符，仅支持的提取子表达式变化；不承诺范围/连接/转换的专门索引下推。复杂或过滤视图可保留原生计划。

```sql
SELECT splitjson.create_path_index('public.array_events','array_state_json_idx',ARRAY['state']);
SELECT splitjson.create_path_index('public.array_events','array_state_text_idx',ARRAY['state'],'text');
SELECT splitjson.create_path_index('public.array_events','array_price_text_idx',
    '["items",0,"price"]'::jsonb,'text');
EXPLAIN SELECT id FROM public.array_events WHERE doc->>'state'='new';
EXPLAIN SELECT id FROM public.array_events WHERE doc->'items'->0->>'price'='20';
PREPARE array_state(text) AS SELECT id FROM public.array_events WHERE doc->>'state'=$1;
EXECUTE array_state('new');
DEALLOCATE array_state;
```

小表使用顺序扫描是合理结果。选择性 10,000 行测试验证真实 JSONB、文本和 typed 数组索引扫描。文本提取不等于 JSONB 字符串比较：数字 1 和字符串 "1" 均提取为文本 1，JSON null 变为 SQL NULL，对象/数组使用原生 JSON 序列化。非默认排序规则可能无法匹配默认文本索引。索引维护可能阻止 HOT，但仍允许 cold TOAST 复用。

get_field 与 find_ids 不依赖 planner hook。数字搜索路径在 typed 候选槽均缺失的行上保留文档回退，使未声明的形状仍可查询。回退可能增加扫描；需要透明数组索引查询时使用带类型的操作符链。

## 验证与后续

[验证报告](validation.zh-CN.md)覆盖 338 组原生数组对照、固定位置位移、标量与混合形状回退、批量单写、并发增量、真实计划、generic PREPARE、GUC/索引失效、外连接、仅视图权限、cold 指针/分块复用和备份恢复。测试见 [arrays_rewrite.sql](../tests/arrays_rewrite.sql)、[physical.sql](../tests/physical.sql)、[concurrency.sh](../tests/concurrency.sh)及 [restore.sql](../tests/restore.sql)。

更早未发布构建也沿用 0.1.0 版本号。迁移应使用新安装及逻辑导出/导入；正式 0.1.0 到 0.2.0 脚本只接受规范目录。不覆盖已加载的库，也不要为改动布局假设可升级。当前行为由 [OpenSpec](../openspec/specs/) 规定。

0.2.0 增加生产生命周期与运维管理能力，见 [API 参考](api-reference.zh-CN.md)和[生产运行手册](production-runbook.zh-CN.md)。通用 duality view 不在项目范围。
