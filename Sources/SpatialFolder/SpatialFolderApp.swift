import SwiftUI

@main
struct SpatialFolderApp: App {
    @StateObject private var model = FolderCanvasModel()

    var body: some Scene {
        WindowGroup("空间文件夹") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(model.preferredColorScheme)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("撤销布局修改") { model.undoLayoutChange() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                Button("重做布局修改") { model.redoLayoutChange() }
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
                Button(model.isLocked ? "解锁画布" : "锁定画布") { model.toggleLocked() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("找回越界项目") { model.recoverOutOfBoundsItems() }
                    .disabled(model.isLocked || model.folderURL == nil)
                Divider()
                Button("导出布局…") { model.exportLayout() }
                    .disabled(model.folderURL == nil)
                Button("导入布局…") { model.importLayout() }
                    .disabled(model.folderURL == nil)
            }
        }
    }
}
