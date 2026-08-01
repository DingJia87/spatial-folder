# 当前项目状态与任务交接

最后更新：2026-08-01

## 产品定位

指针空间是一款原生 macOS 空间文件画布，帮助用户依靠文件的稳定位置快速定位。真实文件夹是数据源，画布只保存布局元数据；不可违反的文件安全规则见根目录 `AGENTS.md`。

## 当前基线

- 当前版本：`v5.0.0`，构建号 `5000`
- 开发分支：`codex/5.0-pointer-space`
- 上一冻结版本：`v4.3.0`，提交 `f51db01`
- 5.0 正式产物：`Release/5.0.0/指针空间.app`、`Release/5.0.0/指针空间.zip`
- 稳定 Bundle ID：`com.dingjia.spatialfolder`
- 稳定数据目录：`Application Support/SpatialFolder`

`Release/4.3.0/`必须保持不变。5.0 的 App/ZIP 只有在完整测试和签名复验通过后才视为冻结产物。

## 5.0 范围

- 用户可见品牌从“空间文件夹”更名为“指针空间”。
- 保留 Bundle ID、Swift 模块、布局目录、偏好和操作历史，确保无缝升级。
- 主窗口隐藏、关闭或最小化时停止 Finder 标签定时核对；重新可见时立即补查。
- GitHub 主页改为面向用户的产品介绍，历史功能细节归入 `CHANGELOG.md` 和版本文档。
- 补齐用户指南、隐私说明、支持入口和安全政策。

## 不变边界

- 只显示所选真实文件夹的直接子项目。
- 画布拖动不移动真实文件。
- 删除必须进入 macOS 废纸篓。
- 新项目不得重排已有项目。
- 不增加索引、云同步、遥测或常驻自动整理。

## 验证要求

```zsh
./scripts/run_standard_tests.zsh
./scripts/run_self_tests.zsh
./scripts/run_performance_baseline.zsh
./scripts/package_app.zsh
```

正式发布还需校验 App/ZIP 命名、内部版本、Bundle ID、可执行文件、签名和解压后签名。

## 待观察事项

1. 日常使用中的全局快捷键冲突。
2. 桌面访问权限和超大批次收纳体验。
3. Apple Developer ID 签名、公证与正式分发。
4. iCloud 多设备同时修改布局时的冲突处理。

历史版本、计划、维护说明和性能结果统一由 `docs/README.md` 索引，不在本文件重复记录。
