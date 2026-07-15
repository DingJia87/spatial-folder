import AppKit
import SwiftUI

enum WindowAspectSizing {
    static func constrainedContentSize(
        proposedSize: CGSize,
        currentSize: CGSize,
        canvasSize: CGSize,
        fixedChromeHeight: CGFloat,
        minimumSize: CGSize = .zero,
        maximumSize: CGSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    ) -> CGSize {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return proposedSize }

        let chromeHeight = max(0, fixedChromeHeight)
        let widthChange = abs(proposedSize.width - currentSize.width) / max(1, currentSize.width)
        let heightChange = abs(proposedSize.height - currentSize.height) / max(1, currentSize.height)
        let proposedScale: CGFloat
        if heightChange > widthChange {
            proposedScale = max(0, proposedSize.height - chromeHeight) / canvasSize.height
        } else {
            proposedScale = proposedSize.width / canvasSize.width
        }

        let minimumScale = max(
            minimumSize.width / canvasSize.width,
            max(0, minimumSize.height - chromeHeight) / canvasSize.height
        )
        let maximumScale = min(
            maximumSize.width / canvasSize.width,
            max(0, maximumSize.height - chromeHeight) / canvasSize.height
        )

        // Fitting on the current screen takes precedence if the configured minimum
        // window size cannot fit on a particularly small display.
        let lowerBound = min(minimumScale, maximumScale)
        let scale = min(max(proposedScale, lowerBound), maximumScale)
        return CGSize(
            width: canvasSize.width * scale,
            height: canvasSize.height * scale + chromeHeight
        )
    }
}

struct WindowAspectRatioController: NSViewRepresentable {
    var canvasSize: CGSize
    var fixedChromeHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(canvasSize: canvasSize, fixedChromeHeight: fixedChromeHeight)
    }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        context.coordinator.update(canvasSize: canvasSize, fixedChromeHeight: fixedChromeHeight)
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    static func dismantleNSView(_ nsView: WindowProbeView, coordinator: Coordinator) {
        nsView.windowDidChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var proxy: WindowResizeDelegateProxy?
        private var observers: [NSObjectProtocol] = []
        private var canvasSize: CGSize
        private var fixedChromeHeight: CGFloat
        private var scheduledAdjustment = false

        init(canvasSize: CGSize, fixedChromeHeight: CGFloat) {
            self.canvasSize = canvasSize
            self.fixedChromeHeight = fixedChromeHeight
        }

        func update(canvasSize: CGSize, fixedChromeHeight: CGFloat) {
            let changed = abs(self.canvasSize.width - canvasSize.width) > 0.5 ||
                abs(self.canvasSize.height - canvasSize.height) > 0.5 ||
                abs(self.fixedChromeHeight - fixedChromeHeight) > 0.5
            self.canvasSize = canvasSize
            self.fixedChromeHeight = fixedChromeHeight
            proxy?.configuration = configuration
            if changed { scheduleAdjustment() }
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else {
                installProxyIfNeeded()
                return
            }
            detach()
            guard let newWindow else { return }
            window = newWindow
            installProxyIfNeeded()
            observe(newWindow)
            scheduleAdjustment()
        }

        func detach() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            if let window, let proxy, window.delegate === proxy {
                window.delegate = proxy.originalDelegate
            }
            proxy = nil
            window = nil
            scheduledAdjustment = false
        }

        private var configuration: WindowAspectConfiguration {
            WindowAspectConfiguration(canvasSize: canvasSize, fixedChromeHeight: fixedChromeHeight)
        }

        private func installProxyIfNeeded() {
            guard let window else { return }
            if let proxy, window.delegate === proxy {
                proxy.configuration = configuration
                return
            }
            let newProxy = WindowResizeDelegateProxy(
                originalDelegate: window.delegate,
                configuration: configuration
            )
            proxy = newProxy
            window.delegate = newProxy
        }

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.proxy?.bypassConstraints = true }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.proxy?.bypassConstraints = false }
            })
            observers.append(center.addObserver(
                forName: NSWindow.willExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.proxy?.bypassConstraints = true }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.proxy?.bypassConstraints = false
                    self?.scheduleAdjustment()
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleAdjustment() }
            })
        }

        private func scheduleAdjustment() {
            guard !scheduledAdjustment else { return }
            scheduledAdjustment = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduledAdjustment = false
                self.adjustCurrentWindowIfNeeded()
            }
        }

        private func adjustCurrentWindowIfNeeded() {
            guard let window,
                  !window.styleMask.contains(.fullScreen),
                  proxy?.bypassConstraints != true else { return }
            installProxyIfNeeded()

            let currentContentSize = window.contentView?.bounds.size ??
                window.contentRect(forFrameRect: window.frame).size
            let targetContentSize = WindowAspectSizing.constrainedContentSize(
                proposedSize: currentContentSize,
                currentSize: currentContentSize,
                canvasSize: canvasSize,
                fixedChromeHeight: fixedChromeHeight,
                minimumSize: window.contentMinSize,
                maximumSize: maximumContentSize(for: window)
            )
            guard abs(targetContentSize.width - currentContentSize.width) > 0.5 ||
                    abs(targetContentSize.height - currentContentSize.height) > 0.5 else { return }

            let frameSize = window.frameRect(
                forContentRect: NSRect(origin: .zero, size: targetContentSize)
            ).size
            var targetFrame = window.frame
            let originalTop = targetFrame.maxY
            targetFrame.size = frameSize
            targetFrame.origin.y = originalTop - frameSize.height
            targetFrame = constrainedFrame(targetFrame, to: window.screen?.visibleFrame)
            window.setFrame(targetFrame, display: true)
        }

        private func maximumContentSize(for window: NSWindow) -> CGSize {
            guard let visibleSize = window.screen?.visibleFrame.size else {
                return CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
            return window.contentRect(
                forFrameRect: NSRect(origin: .zero, size: visibleSize)
            ).size
        }

        private func constrainedFrame(_ frame: NSRect, to visibleFrame: NSRect?) -> NSRect {
            guard let visibleFrame else { return frame }
            var result = frame
            if result.maxX > visibleFrame.maxX { result.origin.x -= result.maxX - visibleFrame.maxX }
            if result.minX < visibleFrame.minX { result.origin.x = visibleFrame.minX }
            if result.maxY > visibleFrame.maxY { result.origin.y -= result.maxY - visibleFrame.maxY }
            if result.minY < visibleFrame.minY { result.origin.y = visibleFrame.minY }
            return result
        }
    }
}

final class WindowProbeView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}

private struct WindowAspectConfiguration {
    var canvasSize: CGSize
    var fixedChromeHeight: CGFloat
}

private final class WindowResizeDelegateProxy: NSObject, NSWindowDelegate {
    weak var originalDelegate: NSWindowDelegate?
    var configuration: WindowAspectConfiguration
    var bypassConstraints = false

    init(originalDelegate: NSWindowDelegate?, configuration: WindowAspectConfiguration) {
        self.originalDelegate = originalDelegate
        self.configuration = configuration
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposedFrameSize = originalDelegate?.windowWillResize?(sender, to: frameSize) ?? frameSize
        guard !bypassConstraints, !sender.styleMask.contains(.fullScreen) else {
            return proposedFrameSize
        }

        let proposedContentSize = sender.contentRect(
            forFrameRect: NSRect(origin: .zero, size: proposedFrameSize)
        ).size
        let currentContentSize = sender.contentView?.bounds.size ??
            sender.contentRect(forFrameRect: sender.frame).size
        let maximumContentSize: CGSize
        if let visibleSize = sender.screen?.visibleFrame.size {
            maximumContentSize = sender.contentRect(
                forFrameRect: NSRect(origin: .zero, size: visibleSize)
            ).size
        } else {
            maximumContentSize = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        let contentSize = WindowAspectSizing.constrainedContentSize(
            proposedSize: proposedContentSize,
            currentSize: currentContentSize,
            canvasSize: configuration.canvasSize,
            fixedChromeHeight: configuration.fixedChromeHeight,
            minimumSize: sender.contentMinSize,
            maximumSize: maximumContentSize
        )
        return sender.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        ).size
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if originalDelegate?.responds(to: aSelector) == true { return originalDelegate }
        return super.forwardingTarget(for: aSelector)
    }
}
