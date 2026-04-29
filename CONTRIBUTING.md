# 贡献指南

感谢关注 StreamBox。本项目接受 Issue、PR 和讨论，请阅读以下流程后参与。

## 提交 Bug / 功能建议

请通过 [Issues](https://github.com/huangj17/StreamBox-APP/issues) 提交，并选择对应模板填写。空白 Issue 已禁用，模板能帮助维护者快速理解和定位问题。

## 提交 Pull Request

### 流程

1. **较大改动先开 Issue 讨论** — 避免重复劳动或方向偏差。Bug 修复或小改动可直接 PR
2. Fork 仓库，从 `main` 创建分支：`git checkout -b feat/your-feature` 或 `fix/your-bug`
3. 完成开发并自测（至少在你目标平台上能跑通）
4. 提交 PR 到 `main`，描述清楚改动内容和动机

### 分支保护

`main` 已开启保护：禁止直接 push、禁止 force push、PR 需至少 1 个 approval、未解决的评论需先回复才能合并。

### Commit 规范

使用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)：

| 前缀     | 用途                              |
| -------- | --------------------------------- |
| `feat:`  | 新功能                            |
| `fix:`   | Bug 修复                          |
| `docs:`  | 文档改动                          |
| `refactor:` | 不改变行为的重构              |
| `perf:`  | 性能优化                          |
| `test:`  | 测试相关                          |
| `chore:` | 构建配置、依赖升级等杂项          |
| `ci:`    | CI / Workflow 改动                |

例：`feat(player): support external subtitle loading`

### 代码风格

- **Dart** — 遵循 `analysis_options.yaml` 中的 lint 规则，PR 前跑 `dart format .` 和 `flutter analyze`
- **Kotlin** — 遵循 [Kotlin Coding Conventions](https://kotlinlang.org/docs/coding-conventions.html)
- 不引入未经讨论的新依赖（影响包体积或维护成本）

### PR 描述

至少说清楚：

- **改了什么** — 涉及的功能或文件范围
- **为什么改** — 关联的 Issue 编号或场景
- **怎么测的** — 用了什么平台、复现步骤

## 行为准则

保持友善与尊重。技术讨论对事不对人，不接受人身攻击或歧视性言论。

## 许可

提交贡献即视为同意以本项目 [MIT License](LICENSE) 授权你的代码。
