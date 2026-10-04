# PG SplitJSON documentation

**English** | [简体中文](README.zh-CN.md) · [Project home](../README.md)

Documentation for **PostgreSQL Split JSON Storage Extension (PG SplitJSON) 0.1.0**, targeting PostgreSQL 18 and verified on 18.6. Install `pg_splitjson`; call APIs in `splitjson`. New cold writes use format 2; formats 1 and 2 are readable, independent of the extension version.

| Document | English | 简体中文 |
| --- | --- | --- |
| Overview, installation and quick start | [README](../README.md) | [使用说明](../README.zh-CN.md) |
| Short and full project introductions | [Introduction](introduction.md) | [项目介绍](introduction.zh-CN.md) |
| Design background, workloads and operations | [Design and selection](design-rationale.md) | [设计与场景指南](design-rationale.zh-CN.md) |
| Implemented arrays and query rewriting | [Arrays and queries](roadmap.md) | [数组与查询](roadmap.zh-CN.md) |
| API signatures, semantics and examples | [API reference](api-reference.md) | [API 参考](api-reference.zh-CN.md) |
| Internal cold format and placeholders | [Storage format](storage-format.md) | [存储格式](storage-format.zh-CN.md) |
| Version history and prototype migration | [Changelog](../CHANGELOG.md) | [更新记录](../CHANGELOG.zh-CN.md) |

Start with the README to install and try the extension. Use the design guide to choose a storage model and hot paths, the API reference for integration details, the introduction for project descriptions, and the storage/validation documents for implementation and evidence.
