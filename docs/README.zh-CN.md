# PG SplitJSON 文档目录

[English](README.md) | **简体中文** · [项目首页](../README.zh-CN.md)

本文档适用于 **PostgreSQL Split JSON Storage Extension（PG SplitJSON）0.2.0**，目标为 PostgreSQL 18，已在 18.6 验证。安装名为 `pg_splitjson`，API schema 为 `splitjson`。新 cold 写入使用格式 2，格式 1 和 2 均可读，与扩展版本独立编号。

| 文档 | English | 简体中文 |
| --- | --- | --- |
| 概览、安装和快速使用 | [README](../README.md) | [使用说明](../README.zh-CN.md) |
| 0.2.0 功能、安装与兼容性 | [Release note](../RELEASE_NOTE.md) | [发布说明](../RELEASE_NOTE.zh-CN.md) |
| 短介绍和完整项目介绍 | [Introduction](introduction.md) | [项目介绍](introduction.zh-CN.md) |
| 设计背景、场景与运维 | [Design and selection](design-rationale.md) | [设计与场景指南](design-rationale.zh-CN.md) |
| 已实现数组与查询改写 | [Arrays and queries](roadmap.md) | [数组与查询](roadmap.zh-CN.md) |
| API 签名、语义和示例 | [API reference](api-reference.md) | [API 参考](api-reference.zh-CN.md) |
| 内部冷格式和占位符 | [Storage format](storage-format.md) | [存储格式](storage-format.zh-CN.md) |
| 正确性、隔离和性能证据 | [Validation](validation.md) | [验证报告](validation.zh-CN.md) |
| 版本记录与原型迁移 | [Changelog](../CHANGELOG.md) | [更新记录](../CHANGELOG.zh-CN.md) |
| 生产部署与恢复 | [Runbook](production-runbook.md) | [生产运行手册](production-runbook.zh-CN.md) |
| 已测平台与排除项 | [Support matrix](support-matrix.md) | [支持矩阵](support-matrix.zh-CN.md) |

安装和体验从 README 开始。存储模型与热路径选择查阅设计指南，集成细节查阅 API 参考，对外描述使用项目介绍，实现细节与证据查阅存储格式和验证报告。

## 文档维护

- 同一变更同时更新英文 `*.md` 和简体中文 `*.zh-CN.md`，保持相同结构，每页链接到另一种语言版本。
- 产品名、版本、API 签名与默认值、可执行示例、限制、错误码和验证数字保持一致。SQL 注释和解释文字可以翻译，示例数据和操作应相同。
- 以[安装 SQL](../sql/pg_splitjson--0.2.0.sql)为 API 声明依据，以[原始验证日志](validation/pg-splitjson-0.2.0/)为证据来源。不把特定载荷的测试数字描述为通用性能承诺。
- 提交前检查相对链接、成对示例及 `git diff --check`。纯文档变更无需重新执行 PG 实验；实现变更遵循 [AGENTS.md](../AGENTS.md)。
- OpenSpec 规划材料使用中文，结构标题保留英文。纯文档变更可使用 `skip_specs: true`；行为/API 变更需要对应规范和验证。

## 历史材料

[原型验证报告](validation-prototype.md)和[原型日志](validation/pg18.6/)保留原始语言及 `pgjson` 身份。[OpenSpec 规范与归档](../openspec/)保留中文规划语言。这些是历史证据；上方成对文档描述当前 0.2.0 实现。
