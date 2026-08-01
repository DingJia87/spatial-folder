import SwiftUI

@main
struct SpatialFolderApp: App {
    @StateObject private var model: FolderCanvasModel
    @StateObject private var visibilityController: AppVisibilityController
    @StateObject private var shortcutSettings: GlobalShortcutSettings

    init() {
        // 2.4 起使用稳定 Bundle ID；构造模型前先迁移旧测试版的最近空间和外观设置。
        PreferencesMigrator.migrateIfNeeded()
        let visibilityController = AppVisibilityController()
        _model = StateObject(wrappedValue: FolderCanvasModel())
        _visibilityController = StateObject(wrappedValue: visibilityController)
        _shortcutSettings = StateObject(
            wrappedValue: GlobalShortcutSettings {
                Task { @MainActor [weak visibilityController] in
                    visibilityController?.toggleMainWindow()
                }
            }
        )
    }

    var body: some Scene {
        Window("指针空间", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(visibilityController)
                .preferredColorScheme(model.preferredColorScheme)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("撤销上一步操作") { model.undoLastAction() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                Button("重做上一步操作") { model.redoLastAction() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("复制") { model.copy(model.selectedItems) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("剪切") { model.cut(model.selectedItems) }
                    .keyboardShortcut("x", modifiers: .command)
                Button("粘贴") { model.paste() }
                    .keyboardShortcut("v", modifiers: .command)
            }
            CommandMenu("空间") {
                Button("收纳桌面") { model.collectDesktopItems() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!model.canCollectDesktopItems)
                Divider()
                Button(model.isLocked ? "解锁画布" : "锁定画布") { model.toggleLocked() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("找回越界项目") { model.recoverOutOfBoundsItems() }
                    .disabled(model.isLocked || model.folderURL == nil)
                Divider()
                Button("导出布局…") { model.exportLayout() }
                    .disabled(model.folderURL == nil)
                Button("导入布局…") { model.importLayout() }
                    .disabled(model.folderURL == nil)
                Divider()
                Button("导出诊断信息…") { model.exportDiagnostics() }
                    .disabled(model.folderURL == nil)
            }
        }

        MenuBarExtra("指针空间", systemImage: "square.grid.2x2") {
            MenuBarContentView(
                model: model,
                visibilityController: visibilityController,
                shortcutSettings: shortcutSettings
            )
        }

        Settings {
            ShortcutSettingsView(settings: shortcutSettings)
        }
    }
}
