# 空间文件夹 2.5 代码维护手册

本文是 2.5 的架构和数据安全说明。产品的长期不变量是：画布展示真实文件夹的直接子项，空间位置是独立元数据，文件系统永远是事实来源。

## 1. 不可破坏的边界

1. 只枚举用户选定文件夹的第一级项目。
2. 画布图标直接对应真实 URL，不得为展示而创建替代链接或副本。
3. 画布内拖动只修改坐标，不移动真实文件。
4. 删除必须调用 `FileManager.trashItem`，且先写 `pending` 操作记录。
5. 外部新项目不能重排已有坐标；主画布无位置时进入待放置区。
6. 异常恢复不得依赖推测执行真实文件修改；证据不足时必须人工核对或仅存档日志。

## 2. 2.5 模块边界

| 模块 | 责任 | 不应承担 |
|---|---|---|
| `FolderCanvasModel` | `@MainActor` 可观察状态和 UI 流程编排 | 坐标算法、日志文件格式、生产路径短 I/O |
| `CanvasLayoutEngine` | 初始排列、新项目空位、投放点落位、网格吸附和边界 | 读写文件、修改 SwiftUI 状态 |
| `OperationJournalStore` | actor 串行追加、事件重放、迁移、压缩和损坏归档 | 执行真实文件操作 |
| `FolderAccessRepository` | actor 执行冲突查询、唯一名规划、属性读取和短方案准备 | 维护画布位置或操作历史 |
| `FileOperationCoordinator` | actor 串行执行真实文件步骤、回调逐步结果、失败回滚 | 决定用户交互、坐标或按钮文案 |
| `RecoveryAnalyzer` | actor 只读检查异常记录的磁盘证据 | 移动、覆盖、删除或自动“修复”文件 |
| `CanvasLayoutStore` | 布局原子保存、备份、恢复、导入导出 | 修改真实文件 |
| `FolderScanService` | 后台读取直接子项的轻量元数据 | 递归扫描、预加载全部 Finder 图标 |

`FolderCanvasModel` 仍较大，但 2.5 后它应是“编排者”而不是算法或磁盘实现者。新增职责时，如果能以值类型输入/输出表达，应优先放入独立类型或 actor。

## 3. 增量操作日志

目录：`~/Library/Application Support/SpatialFolder/Operations`。每张画布使用三类文件：

- `<canvasKey>.snapshot.json`：最近一次原子快照。
- `<canvasKey>.journal.jsonl`：从快照之后的 upsert/replaceAll 事件。
- `<canvasKey>.2.4.json`：首次迁移后保留的 2.4 旧记录。

读取顺序是：迁移旧 JSON → 读快照 → 按行重放 JSONL → 限制最大记录数。达到事件阈值后，先原子写新快照，成功后再截断 JSONL。不得把顺序改为“先删日志、再写快照”。

真实文件操作的安全顺序：

1. 主模型创建 `pending` 记录。
2. `await persistOperationRecordNow`，确认日志落盘。
3. coordinator 执行一个真实文件步骤。
4. 每步成功后立即追加动作并等待日志。
5. 全部完成后改为 `applied`；失败后记录回滚结果。

批量操作不得只在最后写一次。

## 4. 恢复向导规则

`RecoveryAnalyzer` 只分析 `pending/undoing/redoing/unavailable` 记录。它产生证据和建议，不修改磁盘。

- `relocate`：仅目标存在支持已完成；仅原位置存在支持已回滚。
- `materialize`：目标存在支持已完成；只有目标不存在且记录的撤销废纸篓路径存在才支持已回滚。
- `discard`：原位置不存在且记录的废纸篓项存在支持已完成。
- `tags`：当前标签必须与 before 或 after 规范化值完全一致。
- 批量“已完成”还必须覆盖全部 `itemNames`；只完成 1/3 不能建议整批完成。
- 存在冲突位移 `displacements` 时一律人工核对。

用户按“确认已完成/已回滚”时只修正日志状态。“仅存档记录”也不修改文件。

## 5. 投放点落位

`CanvasFileDropDelegate` 读取 `DropInfo.location`，使用当前显示缩放比转换为逻辑画布坐标，并与整批 URL 一起传入 `importFiles` 。

真实复制/移动成功后，`CanvasLayoutEngine.placeImportedItems` 才为实际生成的目标路径分配位置。算法先稳定排序候选网格，跳过已占用区域，且不修改原 `positions`。操作失败时必须丢弃待定投放点。

## 6. 并发与 I/O 规则

- `FolderCanvasModel` 只在主 actor 更新 `@Published` 状态。
- 日志、文件规划/属性、实际文件操作、扫描和恢复分析由各自 actor 隔离。
- 打开空间时，操作快照/日志在 `OperationJournalStore` actor 后台加载；加载完成前暂停真实文件和布局写入，避免新操作被迟到的历史快照覆盖。
- 生产模式 `fileOperationsAsynchronously == true`。模型中保留的同步文件分支仅供 2.4 遗留确定性测试使用，不得从 App 启动路径关闭异步模式。
- 开始新事务、关闭画布或打包最终状态前，必须等待已排队的日志任务。
- 不要用大范围 `@unchecked Sendable` 消除 Swift 6 警告。

## 7. 测试和性能

日常验证：

```zsh
./scripts/run_standard_tests.zsh
./scripts/run_self_tests.zsh
./scripts/run_performance_baseline.zsh
SDKROOT="$(./scripts/select_macos_sdk.zsh)" swift build -c release --disable-sandbox -Xswiftc -warnings-as-errors
```

- 标准测试：8 项，面向 CI 和关键架构。
- 完整自测：63 项，覆盖数据迁移、断电尾部修复、操作回滚、布局、显示器和恢复证据。
- 性能基线：扫描 64/500/3,000 项，以及 1,000 次日志 upsert/重放/压缩。

当前机器的 Command Line Tools 默认 SDK 与编译器小版本不一致，`scripts/select_macos_sdk.zsh` 在此环境选用 15.4 SDK；完整 Xcode 环境会自动使用 Xcode 默认 SDK。

## 8. 版本与打包

版本唯一配置在 `config/release.env`，必须与 `Assets/Info.plist` 一致。打包：

```zsh
./scripts/package_app.zsh
```

2.5 产物位于：

- `Release/2.5.0/空间文件夹.app`
- `Release/2.5.0/空间文件夹-v2.5.0.zip`

脚本会严格 Release 构建、本地 ad-hoc 签名、压缩、再解压并复验签名。不得覆盖 `Release/2.4.0` 或修改 2.4 冻结分支。

## 9. 2.6 之前的优先债务

1. 建立正式 Xcode 工程和 XCUITest，覆盖外部拖放、恢复向导和右键批量交互。
2. 继续从主模型拆出书签/最近空间仓库和事务 UI 编排，但不得复制两份可观察状态。
3. 正式分发前完成 Developer ID、Hardened Runtime、公证、自动更新和隐私政策。
4. 保持范围约束：暂不引入递归子画布、云同步或 AI 自动整理。
