# 空间文件夹 4.0 一键收纳维护说明

本文补充 2.5—3.0 的事务、筛选和工具栏维护规则。

## 1. 来源筛选

`FolderAccessRepository.desktopCollectionSources` 只读取桌面第一级，不递归展开文件夹。文件夹 URL 本身进入批次，因此 `FileManager.moveItem` 会保持全部内部内容。

必须排除：

- Finder 隐藏项目和点号名称；
- `.download`、`.crdownload`、`.part`、`.icloud`；
- 当前目标空间本身；
- 包含当前目标空间的桌面祖先项目。

桌面枚举属于文件系统 I/O，必须保留在 `FolderAccessRepository` actor，不得移回主线程。

## 2. 文件事务

收纳调用现有 `FileOperationCoordinator.performTransfers`，每项完成后立即追加事务事件。冲突策略固定为 `.keepBoth`，不得改成静默替换。

整个批次使用一个 `.moveItems` 记录，撤销时每个 `.relocate` 动作回到桌面原路径。失败或取消必须继续使用协调器已有的整批回滚。

## 3. 右下角落位

收纳以逻辑画布右下角内缩 72 点为锚点，调用 `CanvasLayoutEngine.placeImportedItems`。该引擎只读取已有图标占用区，不允许重新排列既有坐标；没有空位的新增项目进入待放置区。

落位后必须把 `OperationCanvasItem` 写入事务记录，使撤销和重做能够恢复对应布局元数据。

## 4. 界面

顶部按钮是高频捷径，使用紧凑图标并放在刷新按钮左侧。`⇧⌘D` 与按钮调用同一模型方法。完成结果使用非模态短提示，不能要求用户再关闭确认对话框。
