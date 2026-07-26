# 空间文件夹 4.2 标签维护说明

## 组件职责

- `FolderChangeMonitor.swift`：文件级FSEvents监听新增、删除、重命名和扩展属性变化。
- `FolderScanService.swift`：后台读取Finder标签原生扩展属性，保留颜色编号。
- `FolderCanvasModel.swift`：协调事件刷新、轻量标签核对、最新项目解析及标签事务。
- `FileIconCache.swift`：生成按标签颜色区分的文件夹图标缓存。
- `FinderTagColor.swift`：解析Finder颜色编号并生成非模板菜单原色图标。
- `ContentView.swift`：显示文件夹颜色、标签点、筛选菜单及右键标签菜单。

## 不变量

- 文件系统是真实来源；标签写入必须修改真实文件，不创建副本或替代链接。
- 标签操作必须按路径从模型取得最新项目，不能使用视图缓存中的旧`tags`数组。
- 清除标签必须同时移除`_kMDItemUserTags`并清理FinderInfo标签位。
- 文件夹标签变化必须更新图标本体和颜色点；普通文件不得丢失原系统图标。
- 标签未变化时不得发布新的`items`，不得触发布局保存或位置重算。
- 普通画布只每秒核对当前可见项目；筛选状态下全目录核对不得高于每五秒一次。
- 菜单颜色图标必须使用`isTemplate = false`的`NSImage`；模板SF Symbol会被macOS改成单色。
- 标签筛选隐藏的项目不得继续留在选择集合或参与批量命令。
