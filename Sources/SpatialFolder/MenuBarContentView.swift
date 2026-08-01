import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: FolderCanvasModel
    @ObservedObject var visibilityController: AppVisibilityController
    @ObservedObject var shortcutSettings: GlobalShortcutSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            visibilityController.toggleMainWindow()
        } label: {
            Text("显示/隐藏指针空间")
            if shortcutSettings.isEnabled {
                Text(shortcutSettings.shortcut.displayName)
            }
        }

        Divider()

        Button("收纳桌面") {
            visibilityController.showMainWindow()
            model.collectDesktopItems()
        }
            .disabled(!model.canCollectDesktopItems)

        if !model.recentFolders.isEmpty {
            Menu("最近空间") {
                ForEach(model.recentFolders, id: \.path) { folder in
                    Button {
                        model.open(folder: folder)
                        visibilityController.showMainWindow()
                    } label: {
                        if folder.standardizedFileURL == model.folderURL?.standardizedFileURL {
                            Label(folder.lastPathComponent, systemImage: "checkmark")
                        } else {
                            Text(folder.lastPathComponent)
                        }
                    }
                    .help(folder.path)
                }
            }
        }

        Divider()

        Button("快捷键设置…") {
            openSettings()
            NSApp.activate()
        }

        Button("退出指针空间") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
