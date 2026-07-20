# 文档索引

项目根目录只保留日常开发必须首先看到的文件；版本资料统一放在本目录，避免发布记录与源码入口混杂。

## 分类

- `CURRENT_STATUS.md`：当前版本、工作分支、已完成事项、待办与新任务接续规则；新任务应首先阅读。
- `plans/`：各版本目标、范围与验收记录。
- `releases/`：面向使用者的版本变化与安装说明。
- `maintenance/`：模块职责、修改边界与维护建议。
- `performance/`：可重复执行的性能基线与结果。
- `technical/`：早期版本的技术说明。

## 当前 2.6 文档

- `plans/PLAN_2.6.md`：标签筛选与隐藏选择安全修复的范围、规则和验收证据。
- `releases/RELEASE_NOTES_2.6.md`：2.6 用户可见变化和升级边界。
- `maintenance/MAINTENANCE_2.6.md`：Finder 标签编码、筛选组合及选择安全不变量。
- `performance/PERFORMANCE_2.6.md`：保留 Finder 颜色编号后的扫描性能基线。

## 历史源码保全

2026-07-17 清理旧工作目录前，已将两份未提交但具有独有内容的工作状态保存为本仓库归档分支：

- `codex/archive-v1.1-worktree`，归档提交 `a74556e`。
- `codex/archive-v2.1-worktree`，归档提交 `e757ea3`。

这些分支仅用于追溯，不应作为新功能开发基线。当前功能开发继续以最新正式版本分支为基础。

## 本地发布物

`Release/2.6.0/` 保留当前可运行 App 和压缩包；用户可见的开发候选以后也统一放入 `Release/<版本>/` 并在名称中标明状态。旧版只保留 ZIP，集中放在 `Release/archive/<版本>/`。整个 `Release/` 是本地构建产物，不进入 Git；对外下载与长期分发以 GitHub Releases 为准。
