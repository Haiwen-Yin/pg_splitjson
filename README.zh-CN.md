# PostgreSQL Split JSON Storage Extension

**PG SplitJSON · `pg_splitjson` · 0.1.0**

[English](README.md) | **简体中文** · [文档目录](docs/README.zh-CN.md) · [项目介绍](docs/introduction.zh-CN.md) · [API 参考](docs/api-reference.zh-CN.md)

本项目采用 [Apache License 2.0](LICENSE)（`Apache-2.0`）。

面向 PostgreSQL 18 的 JSON 高频更新扩展。将声明的热路径存入独立普通列，将其余内容存入可 TOAST 的 `splitjson.cold` 模板；业务通过包含 id、doc 和可选普通业务列的视图读写。**已存在的热路径及对象/数组子树通过专用 API 更新时，不读取或重写冷模板。0.1.0 同时支持固定数组热路径和 SELECT 自动查询改写。**

0.1.0 是可编译、已验证的初版实现，采用业务视图和专用更新 API。`splitjson.cold` 是新的内部封装格式，负载复用 PG JSONB；并非替换 PG 内核的 JSONB 格式或提供原生隐藏列。

安装名为 `pg_splitjson`，SQL API 为 `splitjson.*`。PG 保留 schema 的 `pg_` 前缀，因此 API 和内部 schema 分别为 `splitjson`、`splitjson_storage`。版本固定为 **0.1.0**。

## 设计背景

尹海文的文章[《JSON改一个字段，凭什么要重写整篇？》](https://blog.csdn.net/yhw1809/article/details/164757146)以库存、价格、订单状态等高频更新为例，指出小逻辑变化可能产生大量物理操作。其中把常变字段拆到普通列的建议，与本扩展的冷热布局相对应：JSON 保留为业务接口，字段更新单元变为独立列。

选择路径应结合更新频率、字段存在比例、值大小和读取模式。复用冷 TOAST 减少部分成本，行版本、锁、索引维护和 vacuum 仍然存在。存储模型比较、业务场景、商品示例和运维指标见[设计与场景指南](docs/design-rationale.zh-CN.md)。

## 快速使用

在安装扩展的测试数据库中，以扩展安装者建表：

```sql
CREATE EXTENSION pg_splitjson;

-- 建表时声明“存储索引”路径：使用键数组，避免点分字符串歧义。
SELECT splitjson.create_table('public.events',
    '[["stats","count"],["state"]]'::jsonb);

INSERT INTO public.events VALUES
    (1, '{"stats":{"count":1},"state":"new","payload":{"large":"cold"}}'),
    (2, '{"payload":"no hot fields"}');

-- 精确且已存在的热字段：只修改独立列。
SELECT splitjson.set_field('public.events', 1,
    ARRAY['stats','count'], '2'::jsonb);

-- 原子批量更新：全部命中已存在热字段时只生成一次 UPDATE。
SELECT splitjson.set_fields('public.events', 1,
    '[{"path":["stats","count"],"value":3},{"path":["state"],"value":"ready"}]');

-- 在行锁内增加当前数值，避免先读后写丢失计数。
SELECT splitjson.increment_field('public.events', 1, ARRAY['stats','count'], 0.5);

-- 非热字段：还原 -> 原生 jsonb_set -> 重新拆分，同步所有热字段。
SELECT splitjson.set_field('public.events', 1,
    ARRAY['payload','large'], '"changed"'::jsonb);

SELECT * FROM public.events; -- 只有 id 和完整 doc

-- 缺失字段首次创建走回退，之后可使用快速路径。
SELECT splitjson.set_field('public.events', 2, ARRAY['state'], 'null'::jsonb);
SELECT splitjson.set_field('public.events', 2, ARRAY['state'], '"ready"'::jsonb);
SELECT splitjson.delete_field('public.events', 2, ARRAY['state']);

-- 普通 SQL DML 可用，整文档更新会重新拆分。
UPDATE public.events SET doc = jsonb_set(doc, '{state}', '"done"') WHERE id = 1;
DELETE FROM public.events WHERE id = 2;
```

## 更新语义

| 操作 | 路径 | 实际行为 |
| --- | --- | --- |
| `set_field` | 精确热路径，字段已存在 | 行锁 + 仅 UPDATE hot_N，复用 cold TOAST 指针 |
| `set_field` | 热字段原来缺失 | 原生 JSONB 更新并重新拆分 |
| `set_field` | 已存在热对象/数组的子路径 | 仅更新热子树 |
| `set_field` | 非热路径或热字段父路径 | 还原文档、更新、同步全部独立列 |
| `delete_field` | 已存在热对象/数组的子路径 | 仅更新热子树 |
| `delete_field` | 整个热槽或热子树外的结构变化 | 原生删除并同步重新拆分全部热槽 |
| `set_fields` | 全部位于已存在热路径/子树 | 顺序解释、合并为一次 UPDATE，复用 cold |
| `set_fields` | 混合热/冷、新增或结构变化 | 一次还原、按顺序修改、一次重新拆分写入 |
| `increment_field` | 现存 JSON 数字 | 在行锁内精确 numeric 加法；热路径复用 cold |
| `UPDATE view SET doc=...` | 逻辑文档发生变化 | 全量重新拆分 |
| `UPDATE view SET 业务列=...` | doc 未改变 | 仅修改普通列，复用 cold |
| INSERT | 所有声明路径均缺失 | JSONB 模板负载保持原值，不添加字段 |

`set_field` 的可选第五个参数 `create_missing` 默认为 `true`，与 PG `jsonb_set` 一致：不创建缺失的中间对象。更新函数返回是否找到目标行；返回 `true` 不意味着内容一定改变，也不表示使用了快速路径。

`set_fields` 接受 1–64 个且只含 `path`、`value` 的操作，按数组顺序执行。重复路径最后值生效，父子操作按顺序解释；任意操作失败整批回滚。第四参数 `create_missing` 默认为 true，返回值表示是否找到目标行。

`increment_field` 的第四参数为有限 numeric 增量，默认 1，允许负数和小数，返回新 numeric。缺失行返回 SQL NULL；缺失字段、JSON null、非数字或 NaN/Infinity 增量报 `22023`，不会隐式创建计数器。

业务文档和 id 不允许 SQL NULL；文档可以是 JSON null、标量、数组或对象。热列的 SQL NULL 表示字段缺失，`'null'::jsonb` 表示已存在的 JSON null。业务 API 拒绝 SQL NULL 参数。热值可以是标量、对象、数组或 JSON null。允许 1–64 个非重叠路径，每条最多 64 层；键可以含点、引号、数字、空字符串。声明中的字符串段表示对象键，非负整数段表示固定数组下标：`["items",0,"price"]` 与 `["items","0","price"]` 不同。操作 `text[]` 路径沿用原生对象/数组语义，包括负下标。缺失热槽、父替换及热子树外的位置位移会重新拆分全部热槽。声明容器类型不匹配视为缺失。

精确热路径和回退路径均使用行锁，因此同一行不同字段的专用更新可串行提交并保留双方修改。普通视图 UPDATE/DELETE 在发现旧文档或普通业务列已被并发修改时返回 `40001`，应用应重试语句或事务。PG 的其他隔离级别错误也按常规处理。计数器使用 `increment_field`；应用自行先读再调用 set_field 的方式仍可能丢失增量。

## 普通业务列和数据迁移

建表时第三参数为业务列名到 SQL 类型声明的映射，最多 64 列。支持类型参数、数组和限定名称的 domain；保留类型化值，额外列不默认附加 NOT NULL 或默认值。名称不能为 id/doc。

```sql
SELECT splitjson.create_table('public.orders',
    '[["stats","count"],["state"]]',
    '{"tenant_id":"bigint","note":"text","amount":"numeric(18,4)","created_at":"timestamptz"}');

INSERT INTO public.orders(id,doc,tenant_id,note,amount,created_at)
VALUES (1,'{"stats":{"count":0},"state":"new"}',100,'first',12.3456,now());
UPDATE public.orders SET note='changed',amount=20.1234 WHERE id=1;
SELECT splitjson.increment_field('public.orders',1,ARRAY['stats','count']);
SELECT * FROM public.orders; -- 业务列可见，内部 cold/hot/extra 列隐藏

-- 独立的迁移示例：创建普通源表，复制到新的受管视图。
CREATE TABLE public.old_orders (id bigint PRIMARY KEY, doc jsonb NOT NULL, tenant_id bigint);
INSERT INTO public.old_orders VALUES (1, '{"state":"new","stats":{"count":0}}', 100);
SELECT splitjson.migrate_table('public.old_orders','public.new_orders',
    '[["stats","count"],["state"]]');
```

`migrate_table(source,target,paths,doc_column DEFAULT 'doc',id_column DEFAULT 'id')` 对普通表做一次事务内快照复制，源表保持不变。标识须为 bigint，文档须为 jsonb；复制额外列的数据、类型和 typmod。自定义源列名可通过最后两个参数指定。无效数据使新目标 DDL 和复制一起回滚。

迁移不复制默认值、NOT NULL、索引、外键、触发器、列排序规则或权限，也不追踪复制后源表的变化。应用切换前需安排停写或同步、比对结果，并按业务要求设置新表权限。这是数据迁移入口，原表不会自动变成视图。

## 热字段读取和查询索引

```sql
-- 由安装者创建热路径 B-tree；路径必须已注册。
SELECT splitjson.create_path_index('public.orders','orders_state_idx',ARRAY['state']);

-- 已存在热路径/子树读取热值；其他路径重组后读取。
SELECT splitjson.get_field('public.orders',1,ARRAY['state']);

-- 直接在热列上进行 JSONB 等值过滤，规划器可使用 B-tree。
SELECT id,tenant_id,note FROM public.orders
WHERE id IN (SELECT splitjson.find_ids('public.orders',ARRAY['state'],'"new"'));

-- 安装者可检查与 find_ids 相同的内部查询计划。
SELECT * FROM splitjson.explain_find_ids('public.orders',ARRAY['state'],'"new"');
```

`get_field` 和 `find_ids` 使用语句/MVCC 快照，并检查业务视图 id/doc 的 SELECT 权限。字段缺失返回 SQL NULL，JSON null 返回 JSONB null。读取采用原生对象/数组路径，包括负下标。数字路径在候选热槽均缺失时回退到文档，查询未声明拆出的另一种形状。`find_ids` 返回无顺序承诺的 bigint 集合，非热路径使用逻辑文档过滤。

查询索引支持 JSONB 等值或原生根文本提取；SQL NULL 缺失不会匹配 JSON null。热值更新同步维护索引，可能阻止 HOT，冷 TOAST 仍可复用。PG 按成本选择索引。

规划前加载模块即可启用 SELECT 自动改写。测试会话可由安装者执行 LOAD；管理员可为应用会话配置 `session_preload_libraries = 'pg_splitjson'`。安装和预加载配置应用于自行选择的实例；实验脚本只配置自身临时实例。

```sql
LOAD 'pg_splitjson';
SELECT splitjson.create_path_index('public.orders','orders_state_text_idx',ARRAY['state'],'text');
EXPLAIN SELECT id FROM public.orders WHERE doc->>'state'='new';
SET splitjson.enable_query_rewrite=off; -- 同时使缓存计划失效。
SET splitjson.enable_query_rewrite=on;
```

精确常量对象提取路径及带类型的数组提取链可映射到热列。动态路径、含歧义数字段的 `#>`/`#>>`、末端 `->0`/`->>0` 及完整视图行引用保留原生行为。支持比较值参数，保持视图权限及安全屏障。详见[数组与查询指南](docs/roadmap.zh-CN.md)。

## 内部存储与权限

```text
业务视图:                  id | 完整 doc(JSONB) | 普通业务列
                          ↓ 读取时还原
内部表 splitjson_storage.s_N: id | cold(splitjson.cold) | hot_N(JSONB) | extra_N(原生类型)
                                  冷模板含 null 占位符   实际热值      业务列映射
```

冷值内嵌版本和路径列表，模板中的 null 占位符只解释为已声明的热路径，不依赖可与用户数据碰撞的特殊 JSON 对象。无匹配字段时保留原 JSONB 负载，但仍有版本/路径封装开销。详细布局见 [存储格式](docs/storage-format.zh-CN.md)。

初版建表由扩展安装者执行。给已存在的业务角色 `app_role` 授予**视图**权限，不授予内部 schema、表和元数据权限。下例继续使用快速使用部分创建的 `events`：

```sql
GRANT USAGE ON SCHEMA public, splitjson TO app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.events TO app_role;
```

更新入口验证调用角色的视图 `doc` UPDATE 权限，包括 SET ROLE 和 SESSION AUTHORIZATION；读取入口检查 id/doc SELECT；受管删除要求拥有视图。建表、迁移、查询索引管理和计划检查由扩展安装者执行。超级用户和扩展安装者仍可检查内部数据。

“存储索引”是热路径布局声明；`create_path_index` 创建另外的实际 B-tree 查询索引。两者分开管理。

## 编译和验证

发布产物统一存放在 `build_output/<版本>/`。0.1.0 的源码 ZIP 和 SHA-256 文件分别为 `build_output/0.1.0/pg_splitjson-0.1.0.zip`、`build_output/0.1.0/pg_splitjson-0.1.0.zip.sha256`。Git 忽略该生成目录。

依赖：PG18 server headers/PGXS、C 编译器、make，以及 PostgreSQL 自带 PL/pgSQL。完整验证还需 PG18 的 `pageinspect`（仅测试使用）。在独立 PG18 安装前缀中执行以下命令；`make install` 会写入所选安装目录：

```sh
make PG_CONFIG=/path/to/isolated/pg18/bin/pg_config
make PG_CONFIG=/path/to/isolated/pg18/bin/pg_config install
```

在专用测试主机上以 root 执行完整验证，使用已有非 root OS 用户及要复制的 PG18 安装：

```sh
PG_SPLITJSON_RUN_AS=postgres bash scripts/lab.sh /path/to/pg18
```

脚本创建全新临时安装、PGDATA 和私有 socket，只停止自身实验实例。指定 PG18 安装仅作为只读复制来源。

测试包括 256 个不同形状文档往返、批量单次写入、原子增量、普通业务列、迁移回滚、权限、并发和快照、索引计划、TOAST 指针及分块复用，以及 `pg_dump/pg_restore` 后全部新增 API。可使用包内测试脚本复现这些检查。

## 备份和边界

整库 `pg_dump -Fc` / `pg_restore` 已验证。元数据使用限定关系名保存映射，配置表及命名序列通过 extension config dump 导出，不依赖原数据库 OID。逻辑迁移可通过 `SELECT * FROM view` 写入普通 JSONB/业务列表。

第一版固定标识/文档名称为 id/doc，支持额外业务列，不支持动态修改热路径。禁止直接修改内部表、直接 DROP/RENAME 受管视图或存储表；删除用 `splitjson.drop_table`：

```sql
-- 在不再需要示例数据时执行；同时删除视图、内部表和映射。
SELECT splitjson.drop_table('public.events');
```

视图的 `ON CONFLICT`、RLS、分区、自动逻辑复制重组和 ORM 完全透明兼容尚未提供。仅导出某个业务视图的 `pg_dump -t` 不包含它的完整存储依赖，应使用整库备份或逻辑导出。

PG MVCC 仍生成新 heap tuple；小的内联模板仍随行版本复制。热值自身很大时仍可能产生自己的 TOAST 更新。优化目标是避免重写不变的大冷值；完整 JSON 读取需要重组，普通 UPDATE 也不承诺快速更新。

本项目早期未发布原型名称为 `pgjson`。新名称仍为 0.1.0，未提供旧原型或更早未发布 0.1.0 构建的原地升级。不要覆盖已加载的库来在线升级相同版本，应逻辑迁移到新安装；原型数据通过逻辑导出写入新建的 splitjson 受管视图，或用 migrate_table 接入普通 JSONB 表。历史日志保留旧名。

需求、决策和实施记录由 OpenSpec 管理。[数组与查询指南](docs/roadmap.zh-CN.md)说明 0.1.0 已实现的行为与边界。通用 duality view 不属于项目范围。后续可继续评估约束/默认值和动态布局迁移。
