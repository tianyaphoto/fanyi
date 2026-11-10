import AppKit
import ApplicationServices

/// 读取当前前台 App 中被选中的文字。
enum SelectionReader {
    private enum AXResult {
        case text(String)   // 该 App 支持辅助功能读取（可能为空串 = 没有选中）
        case unsupported    // 该 App 不支持，需用模拟复制兜底
    }

    private static func axSelectedText() -> AXResult {
        guard let focused = ContextReader.focusedElement() else { return .unsupported }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return .unsupported }
        return .text(text)
    }

    /// 读取选中文字，并附带所在原句和来源。
    @MainActor
    static func capture(forceCopy: Bool) async -> Capture? {
        guard let text = await selectedText(forceCopy: forceCopy) else { return nil }
        return Capture(text: text,
                       context: ContextReader.sentence(containing: text),
                       origin: ContextReader.originDescription())
    }

    /// - Parameter forceCopy: 即使辅助功能返回空也尝试模拟 ⌘C（用于快捷键主动触发）。
    @MainActor
    static func selectedText(forceCopy: Bool) async -> String? {
        let ax = axSelectedText()
        if case .text(let text) = ax {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            if !forceCopy { return nil }
        }
        let front = NSWorkspace.shared.frontmostApplication
        guard forceCopy || Settings.copyFallbackEnabled,
              front?.bundleIdentifier != "com.apple.finder",
              front?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let copied = await copiedText()?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (copied?.isEmpty ?? true) ? nil : copied
    }

    /// 模拟 ⌘C 取得选中文字，然后恢复剪贴板原内容。
    @MainActor
    private static func copiedText() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let before = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true) // 8 = C
        let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(25))
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
            self?.downPoint = NSEvent.mouseLocation
            self?.pending?.cancel()
            self?.onMouseDown?()
        }
        add(.leftMouseUp) { [weak self] event in
            self?.handleMouseUp(clickCount: event.clickCount)
        }
        add([.scrollWheel, .keyDown]) { [weak self] _ in
            self?.onActivity?()
        }
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
            guard let capture = await SelectionReader.capture(forceCopy: false),
                  capture.text.count <= 5000, !Task.isCancelled else { return }
            self?.onSelection?(capture, point)
        }
    }
}
