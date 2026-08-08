# 指针空间文档

## 用户文档

- [用户指南](USER_GUIDE.md)
- [隐私说明](PRIVACY.md)
- [支持与反馈](SUPPORT.md)
- [版本记录](../CHANGELOG.md)

## 当前开发基线

- [当前状态与交接](CURRENT_STATUS.md)
- [5.2 计划与验收](plans/PLAN_5.2.md)
- [5.2 发布说明](releases/RELEASE_NOTES_5.2.md)
- [5.2 性能说明](performance/PERFORMANCE_5.2.md)
- [5.1 计划与验收](plans/PLAN_5.1.md)
- [5.1 发布说明](releases/RELEASE_NOTES_5.1.md)
- [5.1 性能说明](performance/PERFORMANCE_5.1.md)
- [5.0 计划与验收](plans/PLAN_5.0.md)
- [5.0 发布说明](releases/RELEASE_NOTES_5.0.md)
- [5.0 维护说明](maintenance/MAINTENANCE_5.0.md)
- [5.0 性能说明](performance/PERFORMANCE_5.0.md)

## 历史版本档案

历史资料按用途保留，供回归和安全追溯：

- `plans/`：版本范围、验收标准和决策记录。
- `releases/`：用户可见变化与安装说明。
- `maintenance/`：模块职责和修改边界。
- `performance/`：可重复性能基线。
- `technical/`：早期架构与技术说明。

历史品牌“空间文件夹”保留在旧版本文档中，不做追溯性改写。

## 发布物规则

- 当前正式 App 和 ZIP 位于 `Release/<版本>/`，该目录不进入 Git。
- 开发候选名称必须包含“开发版”或“候选版”。
- 冻结版本不得被后续开发覆盖。
- 对外下载和长期分发以 GitHub Releases 为准。
