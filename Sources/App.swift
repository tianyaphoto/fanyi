import SwiftUI
import AppKit

@main
struct FanyiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("翻译神器", systemImage: "character.bubble") {
            MenuContent()
        }
    }
}

private struct MenuContent: View {
    private var shortcuts: ShortcutCenter { .shared }

    var body: some View {
        Button("输入翻译" + suffix(.input)) { Coordinator.shared.showInput() }
        Button("截图翻译" + suffix(.screenshot)) { Coordinator.shared.captureAndTranslate() }
        Text(shortcuts.display(for: .selection).map { "划词后点击小图标，或按 \($0) 翻译选中文字" } ?? "划词后点击小图标翻译选中文字")
        Divider()
        Button("生词本") { Windows.showVocabulary() }
        Button("查词历史") { Windows.showHistory() }
        Button("设置…") { Windows.showSettings() }
        Divider()
        Button("退出") { NSApp.terminate(nil) }
    }

    private func suffix(_ action: HotKeyAction) -> String {
        shortcuts.display(for: action).map { "（\($0)）" } ?? ""
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        ensureEditMenu()
        Coordinator.shared.start()
        if !Settings.provider.isConfigured {
            Windows.showSettings()
        }
    }

    /// 菜单栏 App 没有可见主菜单，但文本框的 ⌘C/⌘V/⌘A 依赖"编辑"菜单里的快捷键。
    private func ensureEditMenu() {
        let hasEdit = NSApp.mainMenu?.items.contains { $0.submenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } ?? false } ?? false
        guard !hasEdit else { return }
        let main = NSApp.mainMenu ?? NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        main.addItem(item)
        NSApp.mainMenu = main
    }
}

/// 生词本和设置窗口（用 AppKit 管理，便于从任何地方打开）。
@MainActor
enum Windows {
    private static var windows: [String: NSWindow] = [:]

    static func showVocabulary() {
        show(id: "vocabulary", title: "生词本", size: NSSize(width: 780, height: 520), resizable: true) {
            VocabularyView()
        }
    }

    static func showHistory() {
        show(id: "history", title: "查词历史", size: NSSize(width: 780, height: 520), resizable: true) {
            HistoryView()
        }
    }

    static func showSettings() {
        show(id: "settings", title: "翻译神器设置", size: NSSize(width: 480, height: 640), resizable: false) {
            SettingsView()
        }
    }

    private static func show<V: View>(id: String, title: String, size: NSSize, resizable: Bool, @ViewBuilder content: () -> V) {
        if windows[id] == nil {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
            if resizable { style.insert(.resizable) }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: content())
            window.setContentSize(size)
            window.center()
            windows[id] = window
        }
        NSApp.activate(ignoringOtherApps: true)
        windows[id]?.makeKeyAndOrderFront(nil)
    }
}
