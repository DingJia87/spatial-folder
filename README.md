# 空间文件夹

将本地文件夹的第一级内容呈现为可长期记忆位置的 macOS 空间画布。

## 当前基线：v1.0.0

- 图标化画布、固定布局与网格吸附
- 文件默认应用打开、文件夹 Finder 打开
- 多选与框选拖动
- 真实重命名、移至废纸篓
- 原生桌面壁纸与可选自定义壁纸
- 右键新建文件夹、Excel、Word、PowerPoint 文件
- Excel / Word / PowerPoint 静默模板创建

## 开发运行

```zsh
swift build
./.build/arm64-apple-macosx/debug/SpatialFolder
```

发布包通过 `Release/空间文件夹.app` 单独生成，不提交到 Git。
