# PG SplitJSON documentation

**English** | [简体中文](README.zh-CN.md) · [Project home](../README.md)

Documentation for **PostgreSQL Split JSON Storage Extension (PG SplitJSON) 0.2.0**, targeting PostgreSQL 18 and verified on 18.6. Install `pg_splitjson`; call APIs in `splitjson`. New cold writes use format 2; formats 1 and 2 are readable, independent of the extension version.

| Document | English | 简体中文 |
| --- | --- | --- |
| Overview, installation and quick start | [README](../README.md) | [使用说明](../README.zh-CN.md) |
| 0.2.0 features, installation and compatibility | [Release note](../RELEASE_NOTE.md) | [发布说明](../RELEASE_NOTE.zh-CN.md) |
| Short and full project introductions | [Introduction](introduction.md) | [项目介绍](introduction.zh-CN.md) |
| Design background, workloads and operations | [Design and selection](design-rationale.md) | [设计与场景指南](design-rationale.zh-CN.md) |
| Implemented arrays and query rewriting | [Arrays and queries](roadmap.md) | [数组与查询](roadmap.zh-CN.md) |
| API signatures, semantics and examples | [API reference](api-reference.md) | [API 参考](api-reference.zh-CN.md) |
| Internal cold format and placeholders | [Storage format](storage-format.md) | [存储格式](storage-format.zh-CN.md) |
| Correctness, isolation and benchmark evidence | [Validation](validation.md) | [验证报告](validation.zh-CN.md) |
| Version history and prototype migration | [Changelog](../CHANGELOG.md) | [更新记录](../CHANGELOG.zh-CN.md) |
| Production deployment and recovery | [Runbook](production-runbook.md) | [生产运行手册](production-runbook.zh-CN.md) |
| Tested platforms and exclusions | [Support matrix](support-matrix.md) | [支持矩阵](support-matrix.zh-CN.md) |

Start with the README to install and try the extension. Use the design guide to choose a storage model and hot paths, the API reference for integration details, the introduction for project descriptions, and the storage/validation documents for implementation and evidence.

## Documentation maintenance

- Update the English `*.md` and Simplified Chinese `*.zh-CN.md` files together in the same change. Keep the same structure and link each page to its counterpart.
- Keep product names, versions, API signatures/defaults, executable examples, limits, error codes and validation numbers equivalent. SQL comments and explanatory prose may be translated; example data and operations should match.
- Treat [the installation SQL](../sql/pg_splitjson--0.2.0.sql) as the API declaration source and [raw validation logs](validation/pg-splitjson-0.2.0/) as the evidence source. Do not turn a measured workload into a general performance promise.
- Check relative links, paired examples and `git diff --check` before committing. Documentation-only changes do not need a new PostgreSQL experiment; implementation changes follow [AGENTS.md](../AGENTS.md).
- Use Chinese for OpenSpec planning artifacts and keep their structural headings in English. Documentation-only changes may use `skip_specs: true`; behavior/API changes require corresponding specs and validation.

## Historical material

The [original prototype report](validation-prototype.md) and [prototype logs](validation/pg18.6/) retain their original language and `pgjson` identity. [OpenSpec specs and archives](../openspec/) retain their Chinese planning language. These records are historical evidence; the paired documents above describe the current 0.2.0 implementation.
