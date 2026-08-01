import AppKit
import Carbon
import Foundation

struct GlobalShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    static let defaultToggle = GlobalShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(controlKey | optionKey),
        keyLabel: "Space"
    )

    var displayName: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.displayLabel(for: keyLabel)
    }

    var isAllowed: Bool {
        let hasPrimaryModifier = carbonModifiers &
            UInt32(controlKey | optionKey | cmdKey) != 0
        return hasPrimaryModifier || Self.functionKeyCodes.contains(keyCode)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
        keyLabel = Self.keyLabel(for: event)
    }

    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20)
    ]

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let relevant = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if relevant.contains(.control) { result |= UInt32(controlKey) }
        if relevant.contains(.option) { result |= UInt32(optionKey) }
        if relevant.contains(.shift) { result |= UInt32(shiftKey) }
        if relevant.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private static func keyLabel(for event: NSEvent) -> String {
        let specialKeys: [UInt16: String] = [
            UInt16(kVK_Space): "Space",
            UInt16(kVK_Return): "Return",
            UInt16(kVK_Tab): "Tab",
            UInt16(kVK_Escape): "Escape",
            UInt16(kVK_Delete): "Delete",
            UInt16(kVK_ForwardDelete): "ForwardDelete",
            UInt16(kVK_LeftArrow): "Left",
            UInt16(kVK_RightArrow): "Right",
            UInt16(kVK_UpArrow): "Up",
            UInt16(kVK_DownArrow): "Down",
            UInt16(kVK_Home): "Home",
            UInt16(kVK_End): "End",
            UInt16(kVK_PageUp): "PageUp",
            UInt16(kVK_PageDown): "PageDown",
            UInt16(kVK_F1): "F1",
            UInt16(kVK_F2): "F2",
            UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4",
            UInt16(kVK_F5): "F5",
            UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7",
            UInt16(kVK_F8): "F8",
            UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10",
            UInt16(kVK_F11): "F11",
            UInt16(kVK_F12): "F12",
            UInt16(kVK_F13): "F13",
            UInt16(kVK_F14): "F14",
            UInt16(kVK_F15): "F15",
            UInt16(kVK_F16): "F16",
            UInt16(kVK_F17): "F17",
            UInt16(kVK_F18): "F18",
            UInt16(kVK_F19): "F19",
            UInt16(kVK_F20): "F20"
        ]
        if let special = specialKeys[event.keyCode] { return special }
        return event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .first
            .map(String.init) ?? "Key\(event.keyCode)"
    }

    private static func displayLabel(for label: String) -> String {
        switch label {
        case "Space": "空格"
        case "Return": "回车"
        case "Tab": "Tab"
        case "Escape": "Esc"
        case "Delete": "⌫"
        case "ForwardDelete": "⌦"
        case "Left": "←"
        case "Right": "→"
        case "Up": "↑"
        case "Down": "↓"
        case "Home": "Home"
        case "End": "End"
        case "PageUp": "Page Up"
        case "PageDown": "Page Down"
        default: label
        }
    }
}

enum GlobalHotKeyRegistrationError: Error, Equatable {
    case conflict
    case systemError(OSStatus)
}

protocol GlobalHotKeyRegistering: AnyObject {
    func replaceShortcut(_ shortcut: GlobalShortcut) throws
    func unregister()
}

final class CarbonGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    private static let hotKeyID = EventHotKeyID(
        signature: OSType(0x5350464C), // "SPFL"
        id: 1
    )

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
        installEventHandler()
    }

    deinit {
        unregister()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func replaceShortcut(_ shortcut: GlobalShortcut) throws {
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            Self.hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &replacement
        )
        guard status == noErr, let replacement else {
            if status == eventHotKeyExistsErr {
                throw GlobalHotKeyRegistrationError.conflict
            }
            throw GlobalHotKeyRegistrationError.systemError(status)
        }
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        hotKey = replacement
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let registrar = Unmanaged<CarbonGlobalHotKeyRegistrar>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                registrar.onPress()
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandler
        )
    }
}

@MainActor
final class GlobalShortcutSettings: ObservableObject {
    private static let enabledKey = "globalShortcutEnabled"
    private static let shortcutKey = "globalShortcutValue"

    @Published private(set) var shortcut: GlobalShortcut
    @Published private(set) var registrationMessage: String?
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                registerCurrentShortcut()
            } else {
                registrar.unregister()
                registrationMessage = nil
            }
        }
    }

    private let defaults: UserDefaults
    private let registrar: GlobalHotKeyRegistering

    convenience init(
        userDefaults: UserDefaults = .standard,
        onToggle: @escaping () -> Void
    ) {
        self.init(
            userDefaults: userDefaults,
            registrar: CarbonGlobalHotKeyRegistrar(onPress: onToggle)
        )
    }

    init(
        userDefaults: UserDefaults,
        registrar: GlobalHotKeyRegistering
    ) {
        defaults = userDefaults
        self.registrar = registrar
        if let data = userDefaults.data(forKey: Self.shortcutKey),
           let saved = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .defaultToggle
        }
        isEnabled = userDefaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if isEnabled { registerCurrentShortcut() }
    }

    @discardableResult
    func updateShortcut(_ newShortcut: GlobalShortcut) -> Bool {
        guard newShortcut.isAllowed else {
            registrationMessage = "请至少使用 Control、Option 或 Command；F1–F20 可以单独使用。"
            return false
        }
        guard newShortcut != shortcut else {
            registrationMessage = nil
            return true
        }
        if isEnabled {
            do {
                try registrar.replaceShortcut(newShortcut)
            } catch {
                registrationMessage = message(for: error)
                return false
            }
        }
        shortcut = newShortcut
        persistShortcut()
        registrationMessage = nil
        return true
    }

    func restoreDefault() {
        _ = updateShortcut(.defaultToggle)
    }

    private func registerCurrentShortcut() {
        do {
            try registrar.replaceShortcut(shortcut)
            registrationMessage = nil
        } catch {
            isEnabled = false
            registrationMessage = message(for: error)
        }
    }

    private func persistShortcut() {
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: Self.shortcutKey)
        }
    }

    private func message(for error: Error) -> String {
        if error as? GlobalHotKeyRegistrationError == .conflict {
            return "这个组合键已被 macOS 或其他 App 占用，原快捷键保持不变。"
        }
        return "无法注册这个全局快捷键，请换一个组合键。"
    }
}
