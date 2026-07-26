# 空间文件夹 4.3 维护说明

`FolderCanvasModel.collectDesktopItems()`从4.3起只负责只读扫描和生成`DesktopCollectionConfirmation`。真实移动只能由`confirmDesktopCollection()`启动。

`PreparedDesktopCollection`私有保存扫描结果和转移计划；公开确认状态只包含目标空间名称以及文件、文件夹数量。取消、关闭卡片或切换空间必须同时清除公开状态和私有准备数据。

确认后的执行必须继续复用4.2已有的`beginFileOperation`、`startCoordinatedTransfers`、操作日志、回滚和撤销，不得再实现第二套移动逻辑。
