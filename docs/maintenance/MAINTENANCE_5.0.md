# 指针空间 5.0 维护说明

## 品牌层与稳定身份

可以修改的用户可见名称包括 `CFBundleDisplayName`、`CFBundleName`、App 包名、窗口标题、菜单栏标题和文案。

以下身份必须保持稳定：

- Bundle ID：`com.dingjia.spatialfolder`
- Swift 包、模块和可执行构建目标：`SpatialFolder`
- 数据根目录：`Application Support/SpatialFolder`
- 已有 UserDefaults 键、布局键和操作日志格式

未经迁移设计不得修改这些值，否则会拆分权限、最近空间、布局或可逆操作历史。

## 标签轮询生命周期

`FolderCanvasModel.setTagReconciliationActive(_:)`是唯一启停入口：

- 主窗口出现或取消最小化时启用，并立即补查一次。
- App 隐藏、窗口关闭或最小化时取消 timer 和正在进行的标签任务。
- 文件夹 FSEvents 监听保持运行，用于低成本感知新增、删除和重命名。
- 重复启用不得创建多个 timer。

未来修改窗口生命周期时，必须保留以上不变量和标准回归测试。

## 打包

`config/release.env`是版本和产品名的唯一来源。`scripts/package_app.zsh`生成无版本后缀的正式文件名：

- `Release/<版本>/指针空间.app`
- `Release/<版本>/指针空间.zip`

脚本必须继续执行严格签名、压缩、解压和二次签名复验。
