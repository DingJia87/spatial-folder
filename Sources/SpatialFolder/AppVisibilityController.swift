import AppKit
import SwiftUI

@MainActor
final class AppVisibilityController: ObservableObject {
    private weak var mainWindow: NSWindow?
    private var openWindowAction: (() -> Void)?

    var isMainWindowFrontmost: Bool {
        guard let mainWindow else { return false }
        return NSApp.isActive && mainWindow.isVisible && mainWindow.isKeyWindow
    }

    func register(mainWindow: NSWindow?) {
        self.mainWindow = mainWindow
    }

    func configureOpenWindow(_ action: @escaping () -> Void) {
        openWindowAction = action
    }

    func toggleMainWindow() {
        if isMainWindowFrontmost {
            NSApp.hide(nil)
        } else {
            showMainWindow()
        }
    }

    func showMainWindow() {
        if let mainWindow {
            NSApp.unhide(nil)
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        openWindowAction?()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}

struct MainWindowRegistrationView: NSViewRepresentable {
    let controller: AppVisibilityController

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.windowDidChange = { [weak controller] window in
            controller?.register(mainWindow: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        controller.register(mainWindow: nsView.window)
    }

    static func dismantleNSView(
        _ nsView: WindowProbeView,
        coordinator: Void
    ) {
        nsView.windowDidChange = nil
    }
}
