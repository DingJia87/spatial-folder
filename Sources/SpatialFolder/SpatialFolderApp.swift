import SwiftUI

@main
struct SpatialFolderApp: App {
    @StateObject private var model = FolderCanvasModel()

    var body: some Scene {
        WindowGroup("空间文件夹") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}
