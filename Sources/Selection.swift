import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 读取当前前台 App 中被选中的文字。
///
/// 依次尝试：辅助功能直接读 → 网页的 text marker → 打开 Chrome / Electron 的辅助功能支持后重读
/// → 触发「拷贝」菜单项 → 模拟 ⌘C。
enum SelectionReader {
    private enum AXResult {
        case text(String)   // 该 App 支持辅助功能读取（可能为空串 = 没有选中）
        case unsupported    // 该 App 不支持，需用拷贝兜底
    }

    private static func axSelectedText() -> AXResult {
        guard let focused = ContextReader.focusedElement() else { return .unsupported }
        var value: CFTypeRef?
        let native = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success
            ? value as? String : nil
        if let native, !native.isEmpty { return .text(native) }
        // Safari、Chrome 的网页内容不一定回答 AXSelectedText，但能用 text marker 读到
        if let marked = ContextReader.markerSelectedText(focused) { return .text(marked) }
        return native.map { .text($0) } ?? .unsupported
    }

    /// 读取选中文字，并附带所在原句、来源和选区位置。
    @MainActor
    static func capture(forceCopy: Bool) async -> Capture? {
        let focused = ContextReader.focusedElement()
        let source = ContextReader.sourceInfo(focused: focused)
        // Google 文档等 canvas 编辑器：辅助功能读到的是隐藏输入框里的残留字符，直接走拷贝
        if let source, source.isCanvasEditor {
            guard forceCopy || Settings.copyFallbackEnabled,
                  let text = clean(await copiedText(strategy: .keystroke)) else { return nil }
            return Capture(text: text, source: source)
        }
        guard let text = await selectedText(forceCopy: forceCopy) else { return nil }
        return Capture(text: text,
                       context: ContextReader.sentence(containing: text),
                       source: source,
                       anchor: ContextReader.selectionRect())
    }

    /// 去掉首尾空白和零宽字符（网页的隐藏输入框里常有 U+200B 之类）。
    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let invisible = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}"))
        let trimmed = text.trimmingCharacters(in: invisible)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonEmpty(_ result: AXResult) -> String? {
        guard case .text(let text) = result else { return nil }
        return clean(text)
    }

    /// - Parameter forceCopy: 即使辅助功能返回空也尝试拷贝（用于快捷键主动触发）。
    @MainActor
    static func selectedText(forceCopy: Bool) async -> String? {
        var ax = axSelectedText()
        if let text = nonEmpty(ax) { return text }

        let front = NSWorkspace.shared.frontmostApplication
        let isSelf = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        // Chrome、Electron 应用默认不暴露文字：打开它们的辅助功能支持，稍等内容建好后再读一次
        if case .unsupported = ax, !isSelf, let front, AccessibilityBooster.enable(for: front) {
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(120))
                ax = axSelectedText()
                if let text = nonEmpty(ax) { return text }
            }
        }
        // 以前辅助功能回答“空选区”时，划词手势直接放弃；但 Chrome 网页、Electron 等常把真实选区报成空，
        // 于是只有 ⌥D 能翻、鼠标划词没反应（用户反馈）。现在照样走拷贝兜底：menuIfEnabled 只在
        // 「拷贝」菜单可用时才拷，菜单是灰的说明真没选中，不会乱拷。

        guard forceCopy || Settings.copyFallbackEnabled, !isSelf,
              front?.bundleIdentifier != "com.apple.finder" else { return nil }
        return clean(await copiedText(strategy: forceCopy ? .menuOrKeystroke : .menuIfEnabled))
    }

    // MARK: - 拷贝兜底

    /// 让前台 App 执行一次拷贝并读出剪贴板，然后恢复剪贴板原内容。
    @MainActor
    private enum CopyStrategy {
        /// 菜单项可用才拷贝（划词手势：灰的说明没选中）
        case menuIfEnabled
        /// 优先菜单项，不行就按 ⌘C（快捷键主动触发）
        case menuOrKeystroke
        /// 直接按 ⌘C。Google 文档只响应键盘拷贝，浏览器的「拷贝」菜单项在那里是灰的
        case keystroke
    }

    private static func copiedText(strategy: CopyStrategy) async -> String? {
        let pasteboard = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let before = pasteboard.changeCount

        if strategy == .keystroke {
            postCommandC()
        } else {
            switch copyMenuItem() {
            case .enabled(let item):
                if AXUIElementPerformAction(item, kAXPressAction as CFString) != .success { postCommandC() }
            case .disabled:
                // 菜单项是灰的，一般说明没有选中内容；主动按快捷键时仍然试一次 ⌘C
                guard strategy == .menuOrKeystroke else { return nil }
                postCommandC()
            case .notFound:
                postCommandC()
            }
        }

        // 每 5 毫秒看一次剪贴板，一变化就返回。Google 文档写剪贴板较慢，最多等 1 秒；其他应用 0.3 秒
        for _ in 0..<(strategy == .keystroke ? 200 : 60) {
            try? await Task.sleep(for: .milliseconds(5))
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        return text
    }

    /// 和一键改写共用：完整发出 ⌘ 的按下和松开，避免系统以为 ⌘ 一直按着。
    private static func postCommandC() {
        KeySynth.press(kVK_ANSI_C)
    }

    private enum CopyMenuItem {
        case enabled(AXUIElement), disabled, notFound
    }

    /// 在前台 App 的菜单栏里找快捷键是 ⌘C 的菜单项（即「拷贝」）。
    private static func copyMenuItem() -> CopyMenuItem {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .notFound }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        guard let menuBar = element(axApp, kAXMenuBarAttribute) else { return .notFound }
        var menus = children(menuBar)
        // 「编辑」菜单通常排在第 4 个（苹果、应用名、文件之后），先查它
        if menus.count > 3 { menus.insert(menus.remove(at: 3), at: 0) }
        for title in menus.prefix(8) {
            guard let menu = children(title).first else { continue }
            for item in children(menu) {
                var char: CFTypeRef?, modifiers: CFTypeRef?
                guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &char) == .success,
                      (char as? String)?.uppercased() == "C" else { continue }
                // 修饰键为 0 表示只有 ⌘
                AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modifiers)
                guard (modifiers as? Int ?? 0) == 0 else { continue }
                var enabled: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabled)
                return (enabled as? Bool ?? true) ? .enabled(item) : .disabled
            }
        }
        return .notFound
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ parent: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement }
    }
}

/// 让默认不暴露文字内容的应用打开辅助功能支持。每个进程只设置一次。
@MainActor
enum AccessibilityBooster {
    private static var attempted: Set<pid_t> = []

    /// Chromium 内核的浏览器靠 AXEnhancedUserInterface 打开。这个属性在普通应用上有副作用，所以只对它们用。
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// 返回 true 表示这次刚打开，调用方需要等内容建好再读。
    static func enable(for app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        guard Settings.enhancedAccessibilityEnabled, !attempted.contains(pid) else { return false }
        attempted.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        // Electron 应用（VS Code、Obsidian 等）认 AXManualAccessibility，对其他应用无效也无害
        if AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            return true
        }
        guard chromiumBrowsers.contains(app.bundleIdentifier ?? "") else { return false }
        // Chrome 即使照做了也可能返回错误码，所以不看返回值
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return true
    }
}

/// 监听全局鼠标事件，识别"拖选 / 双击选词"手势。
@MainActor
final class SelectionMonitor {
    var onSelection: ((Capture, NSPoint) -> Void)?
    var onMouseDown: (() -> Void)?
    var onActivity: (() -> Void)?

    private var downPoint = NSPoint.zero
    private var pending: Task<Void, Never>?
    private var monitors: [Any] = []

    func start() {
        add([.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // 点的是本 App 自己的窗口（翻译浮窗、小图标、设置）：不算“点了别处”，不关浮窗
            guard !Self.isOverOwnWindow() else { return }
            self?.downPoint = NSEvent.mouseLocation
            self?.pending?.cancel()
            self?.onMouseDown?()
        }
        add(.leftMouseUp) { [weak self] event in
            // 在浮窗里拖选译文不触发划词
            guard !Self.isOverOwnWindow() else { return }
            self?.handleMouseUp(clickCount: event.clickCount)
        }
        add([.scrollWheel, .keyDown]) { [weak self] _ in
            self?.onActivity?()
        }
    }

    /// 鼠标是否在本 App 的某个可见窗口上。浮窗是不激活 App 的面板，点它时全局监听也会收到这次点击。
    static func isOverOwnWindow() -> Bool {
        let point = NSEvent.mouseLocation
        return NSApp.windows.contains { $0.isVisible && $0.alphaValue > 0 && $0.frame.contains(point) }
    }

    private func add(_ mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) {
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { handler(event) }
        }
        if let monitor { monitors.append(monitor) }
    }

    private func handleMouseUp(clickCount: Int) {
        guard Settings.selectionIconEnabled, AXIsProcessTrusted() else { return }
        let point = NSEvent.mouseLocation
        let dragged = hypot(point.x - downPoint.x, point.y - downPoint.y) > 4
        guard dragged || clickCount >= 2 else { return }

        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            guard var capture = await SelectionReader.capture(forceCopy: false),
                  capture.text.count <= 12000, !Task.isCancelled, let self else { return }
            // 浮窗要避开的范围：拖选的起止点（补上一行字的高度），再并上辅助功能给出的选区位置
            let gesture = NSRect(x: min(self.downPoint.x, point.x), y: min(self.downPoint.y, point.y),
                                 width: abs(point.x - self.downPoint.x), height: abs(point.y - self.downPoint.y))
                .insetBy(dx: -4, dy: -14)
            if let ax = capture.anchor, ax.insetBy(dx: -80, dy: -80).contains(point) {
                capture.anchor = ax.union(gesture)
            } else {
                capture.anchor = gesture
            }
            self.onSelection?(capture, point)
        }
    }
}
