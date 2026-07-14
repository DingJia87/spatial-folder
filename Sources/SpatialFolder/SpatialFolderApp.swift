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
            CommandGroup(replacing: .pasteboard) {
                Button("复制") { model.copy(model.selectedItems) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("剪切") { model.cut(model.selectedItems) }
                    .keyboardShortcut("x", modifiers: .command)
                Button("粘贴") { model.paste() }
                    .keyboardShortcut("v", modifiers: .command)
            }
        }
    }
}
