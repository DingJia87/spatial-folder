# 空间文件夹 2.4 代码维护手册

本文面向后续人工维护者。目标是让维护者不依赖原开发对话，也能判断每个模块做什么、数据放在哪里、哪些修改会触及真实文件，以及如何安全发布新版本。

## 1. 产品边界

必须长期保持以下规则：

1. 只显示用户所选真实文件夹的第一级内容，不递归扫描。
2. 画布图标不是快捷方式；每个图标直接对应真实 URL。
3. 拖动图标只改变布局元数据，不移动真实文件。
4. 双击文件交给 macOS 默认 App；双击文件夹在 Finder 中打开。
5. “移至废纸篓”必须操作真实项目，并留下可恢复的操作记录。
6. 外部新增文件不能打乱已有坐标；没有空位时进入待放置区。
7. 文件系统是事实来源。布局或历史记录不能凭空制造一个不存在的文件状态。

如果新需求违背这些规则，应先修改产品定义和测试，不能只在界面层绕过。

## 2. 源码模块地图

| 文件 | 职责 | 不应承担的职责 |
|---|---|---|
| `SpatialFolderApp.swift` | App 启动、菜单命令、外观注入、偏好迁移 | 文件操作和布局算法 |
| `ContentView.swift` | 工具栏、画布、图标、右键菜单、进度条、待放置区等 SwiftUI 界面 | 直接调用 FileManager 修改真实文件 |
| `FolderCanvasModel.swift` | 主线程状态编排：把扫描、布局、操作历史和界面命令连接起来 | 在主线程执行大目录扫描、批量复制或壁纸解码 |
| `CanvasLayoutStore.swift` | 画布 JSON 的原子保存、备份、恢复、导入导出 | 修改真实文件 |
| `OperationHistoryStore.swift` | 可逆文件动作、事务状态、原子保存和恢复引擎 | 管理 SwiftUI 状态 |
| `FileOperationCoordinator.swift` | 串行执行批量复制、移动、压缩、废纸篓和撤销/重做；逐步汇报和失败回滚 | 决定按钮文案和图标坐标 |
| `FolderScanService.swift` | 后台读取文件夹直接子项的轻量元数据 | 读取图标或递归子目录 |
| `FileIconCache.swift` | 主线程按需读取 Finder 图标并限制缓存数量 | 首次扫描时预加载全部图标 |
| `WallpaperImageLoader.swift` | 后台按显示尺寸降采样壁纸并缓存 CGImage | 保存画布布局 |
| `CanvasSessionLock.swift` | 使用 `flock` 保证同一画布只有一个写入会话 | 依赖锁文件内容判断锁是否有效 |
| `PreferencesMigrator.swift` | 从旧 Bundle ID 迁移入口偏好 | 迁移 Application Support 布局或移动用户文件 |
| `CanvasViewport.swift` | 逻辑画布到可见视口的等比缩放和背景覆盖尺寸 | 写回图标坐标 |
| `WindowAspectRatioController.swift` | 普通窗口锁比例，最大化/全屏解除约束 | 改变逻辑画布数据 |

`FolderCanvasModel` 仍然是最大的编排层。2.4 已把耗时和高风险职责拆出，但它仍包含布局算法、书签恢复和历史编排。以后继续拆分时，应优先抽出“布局放置算法”和“书签/最近空间仓库”，不要复制状态形成两个事实来源。

## 3. 启动流程

启动顺序如下：

1. `SpatialFolderApp` 调用 `PreferencesMigrator.migrateIfNeeded()`。
2. 创建 `FolderCanvasModel`。
3. 模型从稳定偏好域读取外观、最近空间和上次文件夹书签。
4. 如能恢复上次文件夹，则调用 `open(folder:)`。
5. 计算画布 key，尝试取得 `CanvasSessionLock`。
6. 载入布局和操作记录，再启动文件夹扫描及文件系统监听。

2.4 的稳定 Bundle ID 是 `com.dingjia.spatialfolder`。后续版本不要为了隔离测试随意更换 Bundle ID，否则 UserDefaults、系统权限和最近空间会再次分裂。测试隔离应依赖独立构建目录或专用 UserDefaults suite。

## 4. 打开文件夹与刷新流程

`open(folder:)` 只负责切换空间和发起后续工作。生产模式下扫描由 `FolderScanService` actor 执行：

1. 生成新的 `scanGeneration`。
2. 后台用 `FileManager.contentsOfDirectory` 读取直接子项。
3. 只取隐藏状态、Finder 标签和资源标识，不取 NSImage。
4. 返回主线程前同时核对文件夹 URL 和 generation。
5. `applyScan` 合并新快照、资源标识迁移、已有位置和新增项目。
6. 新项目寻找可预测空位；主画布满 64 项后进入待放置区。

generation 校验非常重要：用户快速切换文件夹时，旧文件夹的慢扫描可能晚于新扫描返回。删除该校验会让旧结果覆盖当前空间。

文件夹监听使用防抖刷新。不要把每个文件系统事件直接变成一次完整扫描，否则批量复制时会产生刷新风暴。

## 5. 布局数据

布局保存在：

`~/Library/Application Support/SpatialFolder/Layouts`

一张画布主要保存：

- 根文件夹资源标识与回退路径；
- 逻辑画布尺寸；
- `真实路径 -> CanvasPoint`；
- `真实路径 -> 图标/字体缩放`；
- 待放置区路径集合；
- 壁纸 URL；
- 布局锁定状态和格式版本。

保存必须通过 `CanvasLayoutStore` 的临时文件 + 原子替换流程。重大布局修改应先创建备份。布局格式升级时：

1. 增加格式版本；
2. 保留旧格式解码路径；
3. 在迁移前生成备份；
4. 增加从旧 JSON 打开的自动测试；
5. 禁止把当前显示器尺寸无条件写成逻辑画布，否则跨屏会再次挤压坐标。

## 6. 真实文件操作

所有可能修改真实文件的入口必须先通过 `realFileMutationsAllowed()`。它会检查：

- 已选择文件夹；
- 布局和操作记录没有损坏阻断；
- 当前会话不是只读；
- 没有另一个长文件操作正在执行。

长操作的标准链路：

1. 模型预先生成确定的计划，例如来源、目标、是否替换。
2. `beginFileOperation` 先把 `pending` 事务写入磁盘。
3. 模型显示 `FileOperationProgressState`。
4. `FileOperationCoordinator` actor 串行执行每一步。
5. 每完成一个真实文件步骤，通过 `didApply` 回到主模型。
6. 主模型立即追加 `ReversibleFileAction` 并原子保存操作记录。
7. 全部完成后把事务改为 `applied`，刷新目录并补记画布位置。

不要先把整批文件改完、最后才写一条记录。App 在中间崩溃时，这会留下无法解释的半批状态。

### 6.1 动作类型

- `materialize`：新建或复制出目标，撤销时移除目标。
- `relocate`：从来源移动到目标，撤销时移回。
- `discard`：真实项目进入废纸篓，撤销时恢复原路径。
- `tags`：记录 Finder 标签前后值。

### 6.2 状态含义

- `pending`：操作已登记但未完成。
- `applied`：真实变更完成，可撤销。
- `undoing` / `redoing`：后台转换中；如进程中断，重启后进入需核对。
- `undone`：已撤销，可重做。
- `failed`：失败但已安全回滚。
- `unavailable`：无法确认或无法完整回滚，必须让用户核对，不能伪装成功。
- `viewOnly`：记录仍可查看，但布局快照已经超过内存撤销深度。

### 6.3 取消语义

`FileManager.copyItem` 等同步系统调用不能安全地在执行中强杀。取消按钮只取消“下一步”：

1. 当前单文件系统调用结束；
2. coordinator 检查 Task cancellation；
3. 停止后续文件；
4. 反向回滚本批次已完成动作。

界面文案必须保持这个事实，不能承诺瞬时取消。

## 7. 多选和拖放

右键点击已选图标时，`contextItems(for:)` 返回整个选择集合；点击未选图标时只返回该项目。新增右键动作时应明确它是批量动作还是单项动作：

- 批量：打开、显示、复制、剪切、副本、压缩、分享、标签、大小、待放置区、废纸篓。
- 单项：重命名、显示简介。

外部拖入由 `DroppedURLCollector` 等待所有 `NSItemProvider` 回调，再一次调用 `importFiles`。不要恢复逐回调导入，否则一次拖入会生成多条记录、多个进度任务，并互相覆盖冲突弹窗。

多选拖动使用同一个 `dragTranslation`：先按网格吸附，再用整个选择集合的外接边界限位。不要逐图标单独夹取坐标，否则靠近边缘时会改变相对间距甚至重叠。

## 8. 待放置区

主画布默认容量为 8×8，共 64 项。多出的项目仍是真实文件，只是进入 `inboxIDs`，不显示在主画布。

`InboxPanelView` 提供独立搜索和多选。它的搜索状态不能复用主工具栏 `searchText`，否则用户在面板搜索时会意外隐藏主画布图标。批量放回时按当前空位数量执行，空间不足的项目继续留在待放置区，并给出提示。

## 9. 屏幕、窗口和壁纸

逻辑画布与窗口视口是两层概念：

- `canvasSize`：坐标使用的固定逻辑尺寸。
- `CanvasViewport.displayScale`：小屏显示时的统一缩放。
- `presentationSize`：全屏比逻辑画布更高时，扩展背景而不拉伸坐标。

普通窗口由 `WindowAspectRatioController` 保持画布比例；最大化和系统全屏绕开比例约束，使用完整可见区域。切换状态只能改变显示，不能把新窗口尺寸写回图标坐标。

壁纸通过 `WallpaperImageLoader` 在后台按像素档位降采样。缓存 key 包含规范化路径和像素尺寸，最多保留 8 份。系统壁纸 URL 可能随显示器变化，因此视图需要在屏幕变化时重新请求。

## 10. 并发规则

- `FolderCanvasModel` 标记为 `@MainActor`，所有 `@Published` 状态只能在主线程更新。
- 文件夹扫描、壁纸解码和文件操作分别由 actor 隔离。
- `NSImage` 只在主线程的 `FileIconCache` 中使用；后台扫描只传递 Sendable 元数据。
- 切换文件夹时取消旧扫描，并用 generation 防止迟到结果。
- 同一模型一次只允许一个长文件事务；跨进程再由 `CanvasSessionLock` 保证单写者。

如果 Swift 6 报 Sendable 警告，不要用大范围 `@unchecked Sendable` 消音。只有像 `FileOperationEngine` 这种内部依赖可证明线程使用方式的类型，才可局部声明并用中文注释说明理由。

## 11. 测试

日常修改至少运行：

```zsh
swift test -Xswiftc -warnings-as-errors
./scripts/run_self_tests.zsh
swift build -c release -Xswiftc -warnings-as-errors
```

测试分两层：

- `Tests/SpatialFolderTests`：标准 SwiftPM 快速测试，CI 直接执行。
- `Tests/SelfTests`：56 项兼容性与真实文件事务回归，使用隔离的 `/tmp` 文件夹、偏好域、布局和模拟废纸篓。

新增真实文件动作时至少增加：成功、部分失败回滚、撤销、重做和跨重启状态测试。新增窗口逻辑时至少覆盖普通窗口、最大化、全屏和小屏视口。GUI 冒烟测试不能替代数据层自动测试。

## 12. 版本与打包

版本单一配置位于 `config/release.env`。同时必须保证 `Assets/Info.plist` 的营销版本和构建号一致；打包脚本会主动校验。

打包命令：

```zsh
./scripts/package_app.zsh
```

2.4 产物位于：

- `Release/2.4.0/空间文件夹.app`
- `Release/2.4.0/空间文件夹-v2.4.0.zip`

脚本使用独立版本目录，不会覆盖冻结的 2.3.2 产物。当前是 ad-hoc 本地签名。正式商业分发还需要 Developer ID、Hardened Runtime、公证、更新渠道和隐私说明。

## 13. 常见故障定位

### 打开后没有文件

先确认文件夹仍存在、是否进入 `folderUnavailable`、扫描 generation 是否与当前 folder 一致，再检查文件是否全部是隐藏项目。不要先重置布局。

### 第二个窗口不能编辑

这是会话锁设计。退出另一个 App 进程后锁会随文件描述符自动释放。锁文件中的 JSON 只是占用者说明，不要手工把“删除锁文件”当作解锁实现。

### 操作记录显示需核对

不要自动改为成功。先在 Finder 核对真实来源和目标，再决定存档记录或人工恢复。`unavailable` 是安全护栏。

### 切换屏幕后图标挤在一起

检查是否误把当前显示器尺寸写回 `canvasSize`，以及是否对每个图标分别缩放。正确做法是统一缩放整个逻辑画布。

### 大目录打开卡顿

检查是否在扫描阶段调用 `NSWorkspace.icon`、是否取消了图标缓存上限、是否把壁纸恢复为主线程完整解码，以及监听是否失去防抖。

## 14. 下一阶段建议

2.5 建议优先做工程债务而不是继续堆菜单：

1. 从 `FolderCanvasModel` 抽出纯布局引擎，输入项目和画布尺寸、输出位置变化，便于更完整的单元测试。
2. 抽出书签与最近空间仓库，减少 UserDefaults/URL bookmark 逻辑对主模型的占用。
3. 为操作恢复增加用户可见的“核对向导”，展示动作类型而不泄露诊断导出隐私。
4. 建立正式 Xcode 工程和 XCUITest，自动验证框选、右键批量、待放置区和窗口状态。
5. 商业发布前完成 Developer ID 签名、公证、自动更新、崩溃报告开关和隐私政策。

不建议在上述基础完成前做递归子画布、云同步或 AI 自动整理；这些功能会显著扩大真实文件一致性和冲突处理范围。
