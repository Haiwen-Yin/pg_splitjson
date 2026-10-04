# PG SplitJSON 存储格式

[English](storage-format.md) | **简体中文** · [文档目录](README.zh-CN.md)

适用扩展版本：**0.1.0**。新写入使用内部 `cold` 格式版本 **2**，版本 **1 和 2** 均可读；两者独立编号。

`splitjson.cold` 是 PostgreSQL varlena 类型，允许 external TOAST。目标 PG18，不保证跨主版本直接复用物理文件；跨环境迁移通过文本 I/O 和 pg_dump。

| 顺序 | 内容 | 长度 |
| --- | --- | --- |
| 1 | PG varlena 总长度头 | 4 字节 |
| 2 | magic `0x50474a53` | uint32 |
| 3 | version `2`（接受旧 `1`） | uint32 |
| 4 | paths_len（含内嵌 JSONB 头） | uint32 |
| 5 | template_len（含内嵌 JSONB 头） | uint32 |
| 6 | 头部对齐填充 | 到 `MAXALIGN(20)` |
| 7 | 热路径列表 JSONB | paths_len |
| 8 | 路径负载对齐填充 | 到 MAXALIGN(paths_len) |
| 9 | 冷模板 JSONB | template_len |

总大小为 `MAXALIGN(20) + MAXALIGN(paths_len) + template_len`。在验证的 x86_64 PG18 上头部为 24 字节。内嵌 JSONB 保持 PG 的编码、键去重和数值语义。

例：路径 `[["user","status"],["counter"]]`，原文档 `{"user":{"status":"new"},"counter":null,"body":"cold"}`：

```text
cold.template = {"user":{"status":null},"counter":null,"body":"cold"}
hot_1         = '"new"'::jsonb
hot_2         = 'null'::jsonb
```

若原文档为 `{"body":"cold"}`，模板完全保留此 JSONB 负载，hot_1、hot_2 均为 SQL NULL。没有额外添加键或占位符。字符串段要求对象，数字段要求实际数组。容器类型不匹配、键缺失及越界下标均视为不存在。数组中的占位符不改变长度或顺序。

占位符依赖声明路径及模板中的路径存在性解释；不将任何未声明的普通 null 当作占位符。还原时验证：模板路径存在必须有非 SQL NULL 热值，缺失则必须为 SQL NULL，热值数量必须等于路径数。内部路径非重叠，保证依次替换不破坏其他字段。

文本格式为：

```json
{"version":2,"paths":[["user","status"],["counter"]],"template":{"user":{"status":null},"counter":null,"body":"cold"}}
```

输入校验版本、路径和占位符，输出可往返；它描述冷模板，不是完整业务 JSON。完整业务值需 `splitjson.restore(cold,jsonb[])`。初版不提供 binary send/receive，勿将内部格式当作 jsonb 或自行修改。

版本 2 扩展路径解释：字符串仍为对象键，非负 int32 整数定位实际数组。路径 `[["items",0,"price"]]` 和文档 `{"items":[{"price":10},{"price":20}]}` 得到模板 `{"items":[{"price":null},{"price":20}]}`，hot_1 为 `10`。数字字符串 "0" 仍为对象键。版本 1 只接受字符串并保留原有仅对象解释；文本输出保留存储版本，不隐式升级。

生成视图使用 `restore(cold,hot[],constant_paths)` 核对可见映射与 cold 路径。新的 pack 即使只有对象声明也写入版本 2。更早未发布扩展构建同样使用 0.1.0：v1 可读不等于同版本在线升级。使用新安装及逻辑迁移。

实际更新走普通 heap：cold 和 hot_N 属于同一行，同一事务原子提交。已存在热字段/子树更新只对 hot_N 赋值，PG 的 TOAST 机制复用未改动 cold 的 external 指针，未绕过 MVCC、WAL 或恢复机制。
