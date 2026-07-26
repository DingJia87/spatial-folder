# 文档索引

项目根目录只保留日常开发必须首先看到的文件；版本资料统一放在本目录，避免发布记录与源码入口混杂。

## 分类

- `CURRENT_STATUS.md`：当前版本、工作分支、已完成事项、待办与新任务接续规则；新任务应首先阅读。
- `plans/`：各版本目标、范围与验收记录。
- `releases/`：面向使用者的版本变化与安装说明。
- `maintenance/`：模块职责、修改边界与维护建议。
- `performance/`：可重复执行的性能基线与结果。
- `technical/`：早期版本的技术说明。

## 当前 4.2 文档

- `plans/PLAN_4.2.md`：标签同步、文件夹着色、状态安全和正式验收范围。
- `releases/RELEASE_NOTES_4.2.md`：4.2用户可见变化、安装位置和资源说明。
- `maintenance/MAINTENANCE_4.2.md`：标签监听、最新状态写入和原色菜单图标不变量。
- `performance/PERFORMANCE_4.2.md`：目录扫描、日志与标签核对性能基线。

## 4.1 文档

- `plans/PLAN_4.1.md`：全局快捷键、菜单栏入口和主窗口单实例的范围与验收。
- `releases/RELEASE_NOTES_4.1.md`：4.1 使用方式、冲突提示和安装位置。
- `maintenance/MAINTENANCE_4.1.md`：热键注册、显隐控制和权限边界。
- `performance/PERFORMANCE_4.1.md`：4.1 正式冻结时的扫描与日志性能复验。

## 4.0 文档

- `plans/PLAN_4.0.md`：一键收纳桌面的范围、安全边界和验收记录。
- `releases/RELEASE_NOTES_4.0.md`：4.0 用户可见变化、安装位置和使用方式。
- `maintenance/MAINTENANCE_4.0.md`：桌面来源筛选、批量事务和单点堆叠不变量。

## 3.0 文档

- `plans/PLAN_3.0.md`：工具栏收敛、壁纸权限修复和正式验收范围。
- `releases/RELEASE_NOTES_3.0.md`：3.0 用户可见变化、兼容边界和安装位置。
- `maintenance/MAINTENANCE_3.0.md`：布局锁定与外观设置的权限边界及工具栏状态规则。
- `performance/PERFORMANCE_3.0.md`：3.0 正式冻结时的扫描和日志性能复验。

## 2.6 文档

- `plans/PLAN_2.6.md`：标签筛选与隐藏选择安全修复的范围、规则和验收证据。
- `releases/RELEASE_NOTES_2.6.md`：2.6 用户可见变化和升级边界。
- `maintenance/MAINTENANCE_2.6.md`：Finder 标签编码、筛选组合及选择安全不变量。
- `performance/PERFORMANCE_2.6.md`：保留 Finder 颜色编号后的扫描性能基线。

## 2.7 开发记录

- `plans/PLAN_2.7.md`：顶部工具栏收敛、状态保留和开发候选验证记录；成果已并入 3.0。

## 历史源码保全

2026-07-17 清理旧工作目录前，已将两份未提交但具有独有内容的工作状态保存为本仓库归档分支：

- `codex/archive-v1.1-worktree`，归档提交 `a74556e`。
- `codex/archive-v2.1-worktree`，归档提交 `e757ea3`。

这些分支仅用于追溯，不应作为新功能开发基线。当前功能开发继续以最新正式版本分支为基础。

## 本地发布物

`Release/4.2.0/` 保留当前正式 App 和压缩包，`Release/4.1.0/` 保留上一正式基线及4.2验收前候选；开发候选名称必须标明状态。旧版只保留 ZIP，集中放在 `Release/archive/<版本>/`。整个 `Release/` 是本地构建产物，不进入 Git；对外下载与长期分发以 GitHub Releases 为准。
