# 空间文件夹 2.6 标签筛选维护说明

本文是 `MAINTENANCE_2.5.md` 的增量说明；真实文件事务、恢复与日志规则继续以 2.5 手册为准。

## 1. Finder 标签编码

Finder 的 `URLResourceValues.tagNames` 可能只返回显示名称。为了不让用户重命名标签或系统语言改变颜色判断，`FolderDirectoryScanner` 只读解析 `com.apple.metadata:_kMDItemUserTags` 二进制 plist，并保留字符串中的颜色编号；读取或解析失败时回退到系统 API。

`FinderTagColor` 支持 Finder 的 1—7 颜色编号，也兼容中英文默认名称。部分系统写入未注册自定义标签时会形成 `名称\n颜色\n0`，解析器从名称之后的尾部组件中寻找最后一个有效 1—7 编号。

## 2. 筛选状态

`CanvasItemFilter` 是无副作用值类型：

- 同一组颜色使用 OR。
- 搜索与标签条件使用 AND。
- 无标签是独立选项。
- 筛选不持久化，不进入布局撤销栈，不修改 `positions` 或 `inboxIDs`。
- 顶部筛选只作用于 `displayedItems`；`inboxItems` 保持完整，并由待放置面板自己的搜索控制。

切换空间必须清空筛选，避免上一空间的条件让新空间看起来为空。

## 3. 选择安全不变量

任何可执行真实文件操作的选择集合都必须是当前可见项目的子集。

- `selectedItems` 从 `displayedItems` 派生，而不是从全部 `items` 派生。
- 搜索、标签筛选和扫描结果变化后，`selectedIDs` 与可见 ID 取交集。
- `contextItems(for:)` 不得重新引入不可见项目。

修改筛选或选择逻辑时，必须保留“筛选不会让隐藏选择参与批量操作”自测。

## 4. 性能边界

读取原生标签扩展属性会为每个直接子项增加一次只读 `getxattr`。它仍在 `FolderScanService` 后台 actor 中执行，不得移回主线程。每个版本继续运行 64/500/3,000 项扫描基线。

## 5. 本地版本管理

用户需要查找或验收的 App 统一放入 `Release/<版本>/`。开发候选必须在文件名中标明“开发版”或“候选版”；用户验收后由 `scripts/package_app.zsh` 生成正式 `空间文件夹.app` 和版本 ZIP，并完成签名及解压复验。冻结后的正式版本目录不得被后续开发覆盖。
