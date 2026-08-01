import AppKit
import Carbon
import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var settings: GlobalShortcutSettings

    var body: some View {
        Form {
            Section("全局唤醒") {
                Toggle("启用全局显示/隐藏快捷键", isOn: $settings.isEnabled)
                HStack {
                    Text("快捷键")
                    Spacer()
                    ShortcutRecorderField(
                        shortcut: settings.shortcut,
                        isEnabled: settings.isEnabled,
                        onShortcut: settings.updateShortcut
                    )
                    .frame(width: 180, height: 28)
                }
                HStack {
                    Text("默认：⌃⌥空格")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认", action: settings.restoreDefault)
                        .disabled(settings.shortcut == .defaultToggle)
                }
                if let message = settings.registrationMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("使用方式") {
                Text("App 在后台或被遮挡时，按一次置于最前；App 已在最前时，再按一次隐藏。")
                Text("菜单栏中的指针空间图标始终提供同样的显示/隐藏入口。")
                Text("使用系统级热键注册，不需要辅助功能或输入监控权限。")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 330)
        .padding()
    }
}

private struct ShortcutRecorderField: NSViewRepresentable {
    var shortcut: GlobalShortcut
    var isEnabled: Bool
    var onShortcut: (GlobalShortcut) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onShortcut = onShortcut
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.isEnabled = isEnabled
        button.onShortcut = onShortcut
        button.updateTitle()
    }
}

private final class ShortcutRecorderButton: NSButton {
    var shortcut = GlobalShortcut.defaultToggle
    var onShortcut: ((GlobalShortcut) -> Bool)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { isEnabled }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        setAccessibilityLabel("录制全局快捷键")
        updateTitle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isRecording = true
        window?.makeFirstResponder(self)
        updateTitle()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            updateTitle()
            return
        }
        let candidate = GlobalShortcut(event: event)
        guard candidate.isAllowed else {
            NSSound.beep()
            return
        }
        if onShortcut?(candidate) == true {
            shortcut = candidate
            isRecording = false
            window?.makeFirstResponder(nil)
        } else {
            NSSound.beep()
        }
        updateTitle()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        updateTitle()
        return super.resignFirstResponder()
    }

    func updateTitle() {
        title = isRecording ? "请按新组合键（Esc 取消）" : shortcut.displayName
        toolTip = isEnabled ? "点击后按下新的全局组合键" : "请先启用全局快捷键"
    }
}
