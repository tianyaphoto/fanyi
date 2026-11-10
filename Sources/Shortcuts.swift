import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int   // Carbon 修饰键掩码
    var display: String
}

enum HotKeyAction: String, CaseIterable, Identifiable {
    case selection, screenshot, input

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selection: return "翻译选中文字"
        case .screenshot: return "截图翻译"
        case .input: return "输入翻译"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .selection: return Shortcut(keyCode: kVK_ANSI_D, modifiers: optionKey, display: "⌥D")
        case .screenshot: return Shortcut(keyCode: kVK_ANSI_S, modifiers: optionKey, display: "⌥S")
        case .input: return Shortcut(keyCode: kVK_ANSI_A, modifiers: optionKey, display: "⌥A")
        }
    }

    fileprivate var defaultsKey: String { "shortcut.\(rawValue)" }
}

/// 管理可自定义的全局快捷键：读写设置、注册、记录冲突。
@MainActor
@Observable
final class ShortcutCenter {
    static let shared = ShortcutCenter()

    private(set) var shortcuts: [HotKeyAction: Shortcut] = [:]
    /// 注册失败（通常是被其他 App 占用）的动作。
    private(set) var failed: Set<HotKeyAction> = []
    @ObservationIgnored var handler: ((HotKeyAction) -> Void)?

    private init() {
        for action in HotKeyAction.allCases {
            // 没存过 → 默认值；存了空串 → 用户清除了
            guard let raw = UserDefaults.standard.string(forKey: action.defaultsKey) else {
                shortcuts[action] = action.defaultShortcut
                continue
            }
            if let data = raw.data(using: .utf8), let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) {
                shortcuts[action] = shortcut
            }
        }
    }

    func display(for action: HotKeyAction) -> String? { shortcuts[action]?.display }

    func set(_ shortcut: Shortcut?, for action: HotKeyAction) {
        if let shortcut {
            // 同一组合键只能给一个动作用
            for other in HotKeyAction.allCases where other != action {
                if let existing = shortcuts[other], existing.keyCode == shortcut.keyCode, existing.modifiers == shortcut.modifiers {
                    shortcuts[other] = nil
                    persist(other)
                }
            }
        }
        shortcuts[action] = shortcut
        persist(action)
        apply()
    }

    func resetToDefaults() {
        for action in HotKeyAction.allCases {
            shortcuts[action] = action.defaultShortcut
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
        apply()
    }

    /// 重新注册所有快捷键。
    func apply() {
        HotKeys.shared.unregisterAll()
        var failures: Set<HotKeyAction> = []
        for action in HotKeyAction.allCases {
            guard let shortcut = shortcuts[action] else { continue }
            let ok = HotKeys.shared.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) {
                MainActor.assumeIsolated { ShortcutCenter.shared.handler?(action) }
            }
            if !ok { failures.insert(action) }
        }
        failed = failures
    }

    /// 录制新快捷键时暂停全局快捷键，否则按下已有组合会被系统拦走。
    func suspend() {
        HotKeys.shared.unregisterAll()
    }

    private func persist(_ action: HotKeyAction) {
        let raw = shortcuts[action]
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        UserDefaults.standard.set(raw, forKey: action.defaultsKey)
    }

    /// 从按键事件生成快捷键；必须包含 ⌘、⌥ 或 ⌃ 之一。
    static func make(from event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else { return nil }
        var carbon = 0
        var display = ""
        if flags.contains(.control) { carbon |= controlKey; display += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; display += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; display += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; display += "⌘" }
        display += keyName(event)
        return Shortcut(keyCode: Int(event.keyCode), modifiers: carbon, display: display)
    }

    private static func keyName(_ event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(event.keyCode)] { return name }
        let chars = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespaces) ?? ""
        return chars.isEmpty ? "?" : chars.uppercased()
    }
}
