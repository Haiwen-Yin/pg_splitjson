# PG SplitJSON 文档目录

[English](README.md) | **简体中文** · [项目首页](../README.zh-CN.md)

本文档适用于 **PostgreSQL Split JSON Storage Extension（PG SplitJSON）0.1.0**，目标为 PostgreSQL 18，已在 18.6 验证。安装名为 `pg_splitjson`，API schema 为 `splitjson`。新 cold 写入使用格式 2，格式 1 和 2 均可读，与扩展版本独立编号。

| 文档 | English | 简体中文 |
| --- | --- | --- |
| 概览、安装和快速使用 | [README](../README.md) | [使用说明](../README.zh-CN.md) |
| 短介绍和完整项目介绍 | [Introduction](introduction.md) | [项目介绍](introduction.zh-CN.md) |
| 设计背景、场景与运维 | [Design and selection](design-rationale.md) | [设计与场景指南](design-rationale.zh-CN.md) |
| 已实现数组与查询改写 | [Arrays and queries](roadmap.md) | [数组与查询](roadmap.zh-CN.md) |
| API 签名、语义和示例 | [API reference](api-reference.md) | [API 参考](api-reference.zh-CN.md) |
| 内部冷格式和占位符 | [Storage format](storage-format.md) | [存储格式](storage-format.zh-CN.md) |
| 版本记录与原型迁移 | [Changelog](../CHANGELOG.md) | [更新记录](../CHANGELOG.zh-CN.md) |

安装和体验从 README 开始。存储模型与热路径选择查阅设计指南，集成细节查阅 API 参考，对外描述使用项目介绍，实现细节与证据查阅存储格式和验证报告。
