import AppKit
import ApplicationServices
import NaturalLanguage
import SwiftUI

/// 一次翻译请求的内容：选中的文字、所在原句、来源。
struct Capture {
    var text: String
    var context: String? = nil
    var source: SourceInfo? = nil
    /// 看图翻译时附带的截图；此时 text 是本地 OCR 的结果（可能为空），只用于显示和历史记录。
    var image: ImageAttachment? = nil
    /// 选中文字在屏幕上的位置（Cocoa 坐标），浮窗尽量不挡住它。读不到时为 nil。
    var anchor: NSRect? = nil

    /// 例如「预览：paper.pdf」，存进历史和生词本。
    var origin: String? { source?.label }
}

/// 文字来自哪里：App、窗口标题、网页地址或文档路径。用于显示来源，也用于自动判断翻译场景。
struct SourceInfo: Equatable {
    var appName = ""
    var bundleID = ""
    var windowTitle = ""
    /// 网页地址，或原生文档的 file:// 路径
    var url = ""
    /// 附加在来源后面的说明，例如「（截图）」
    var suffix = ""

    var label: String? {
        var title = windowTitle
        if title.count > 80 { title = String(title.prefix(80)) + "…" }
        let base: String
        if title.isEmpty || title == appName { base = appName } else if appName.isEmpty { base = title } else { base = "\(appName)：\(title)" }
        if base.isEmpty { return suffix.isEmpty ? nil : String(suffix.trimmingCharacters(in: CharacterSet(charactersIn: "（）"))) }
        return base + suffix
    }

    var host: String? { URL(string: url)?.host?.lowercased() }

    /// 场景匹配用的文本：App 名、Bundle ID、窗口标题、地址，全部小写。
    var matchText: String { [appName, bundleID, windowTitle, url].joined(separator: "\n").lowercased() }

    private static let googleEditorTitles = [
        "Google Docs", "Google 文档", "Google 文件", "Google ドキュメント",
        "Google Slides", "Google 幻灯片", "Google 簡報", "Google スライド",
        "Google Sheets", "Google 表格", "Google 試算表", "Google スプレッドシート",
    ]

    /// Google 文档 / 幻灯片 / 表格：正文画在 canvas 上，辅助功能读不到选中的文字，只能靠拷贝。
    var isCanvasEditor: Bool {
        if host == "docs.google.com" { return true }
        return Self.googleEditorTitles.contains { windowTitle.contains(" - \($0)") || windowTitle.hasSuffix($0) }
    }
}

struct ImageAttachment {
    let data: Data
    let mediaType: String
}

/// 读取选中内容所在的句子，以及来源 App / 文档标题。
enum ContextReader {
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }

    /// 选中的是单词或短语时，返回它所在的句子；读不到或没意义时返回 nil。
    static func sentence(containing text: String) -> String? {
        let term = collapse(text)
        guard !term.isEmpty, term.count <= 80, term.split(separator: " ").count <= 8,
              let element = focusedElement() else { return nil }
        guard let raw = viaSelectedRange(element) ?? viaTextMarkers(element) else { return nil }
        return clean(raw, term: term)
    }

    /// 当前前台 App 的来源信息。前台是本 App 时返回 nil。
    static func sourceInfo(focused: AXUIElement? = nil) -> SourceInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var info = SourceInfo(appName: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "")
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        if let window = element(axApp, kAXFocusedWindowAttribute) {
            info.windowTitle = (string(window, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 原生文档窗口会给出文件路径（AXDocument）
            info.url = string(window, kAXDocumentAttribute) ?? ""
        }
        if let focused = focused ?? focusedElement(), let url = webAreaURL(above: focused) {
            info.url = url
        }
        return info
    }

    /// 网页：从焦点元素往上找到网页区域（AXWebArea），读它的地址。
    private static func webAreaURL(above element: AXUIElement) -> String? {
        var current = element
        for _ in 0..<20 {
            if string(current, kAXRoleAttribute) == "AXWebArea" {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current, kAXURLAttribute as CFString, &value) == .success else { return nil }
                if let url = value as? URL { return url.absoluteString }
                if let url = value as? NSURL { return url.absoluteString }
                return value as? String
            }
            guard let parent = self.element(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    /// 选中文字在屏幕上的范围（Cocoa 坐标，原点在主屏左下角）。
    static func selectionRect(_ focused: AXUIElement? = nil) -> NSRect? {
        guard let element = focused ?? focusedElement() else { return nil }
        var bounds: CFTypeRef?
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length > 0 {
                bounds = parameterized(element, kAXBoundsForRangeParameterizedAttribute, rangeRef)
            }
        }
        if bounds == nil, let host = markerHost(element) {
            bounds = parameterized(host.element, "AXBoundsForTextMarkerRange", host.range)
        }
        guard let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.width > 1, rect.height > 1,
              let primary = NSScreen.screens.first else { return nil }
        // 辅助功能用左上角为原点的坐标
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - 普通文本控件（TextEdit、备忘录、Pages、预览等）

    private static func viaSelectedRange(_ element: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &selection), selection.length > 0 else { return nil }

        // 只取选区前后一段文字，避免读取整篇长文档
        let pad = 600
        var total: Int?
        var countRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success {
            total = countRef as? Int
        }
        let start = max(0, selection.location - pad)
        var end = selection.location + selection.length + pad
        if let total { end = min(end, total) }
        guard end > start else { return nil }

        var window = CFRange(location: start, length: end - start)
        var text: String?
        if let axRange = AXValueCreate(.cfRange, &window) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &value) == .success {
                text = value as? String
            }
        }
        if text?.isEmpty ?? true {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                  let full = value as? String else { return nil }
            let ns = full as NSString
            let clippedEnd = min(end, ns.length)
            guard clippedEnd > start else { return nil }
            text = ns.substring(with: NSRange(location: start, length: clippedEnd - start))
        }
        guard let text else { return nil }
        return sentence(in: text, utf16Offset: selection.location - start, length: selection.length)
    }

    // MARK: - 网页（Safari、Chrome 等的网页视图使用 text marker）

    /// 找到能回答 text marker 查询的元素：焦点元素自己，或它上层的网页区域。
    private static func markerHost(_ element: AXUIElement) -> (element: AXUIElement, range: CFTypeRef)? {
        var current = element
        for _ in 0..<12 {
            var range: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, "AXSelectedTextMarkerRange" as CFString, &range) == .success, let range {
                return (current, range)
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    /// 网页视图里被选中的文字。
    static func markerSelectedText(_ element: AXUIElement) -> String? {
        guard let host = markerHost(element) else { return nil }
        return parameterized(host.element, "AXStringForTextMarkerRange", host.range) as? String
    }

    private static func viaTextMarkers(_ focused: AXUIElement) -> String? {
        guard let host = markerHost(focused) else { return nil }
        let element = host.element
        guard let start = parameterized(element, "AXStartTextMarkerForTextMarkerRange", host.range) else { return nil }
        for attribute in ["AXSentenceTextMarkerRangeForTextMarker", "AXParagraphTextMarkerRangeForTextMarker"] {
            if let range = parameterized(element, attribute, start),
               let text = parameterized(element, "AXStringForTextMarkerRange", range) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private static func parameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success else { return nil }
        return value
    }

    // MARK: - 文本处理

    /// 找出覆盖 [offset, offset+length) 的句子。
    static func sentence(in text: String, utf16Offset: Int, length: Int) -> String? {
        let utf16Count = text.utf16.count
        guard utf16Offset >= 0, length > 0, utf16Offset + length <= utf16Count else { return nil }
        let selStart = String.Index(utf16Offset: utf16Offset, in: text)
        let selEnd = String.Index(utf16Offset: utf16Offset + length, in: text)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: Range<String.Index>?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if range.upperBound > selStart && range.lowerBound < selEnd {
                result = result.map { $0.lowerBound..<range.upperBound } ?? range
            }
            return range.lowerBound < selEnd
        }
        return result.map { String(text[$0]) }
    }

    private static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clean(_ raw: String, term: String) -> String? {
        var text = collapse(raw)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        // 拿到的是整段时，缩小到包含这个词的那一句
        if text.count > 300, let range = text.range(of: term, options: options) {
            let offset = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
            if let sentence = sentence(in: text, utf16Offset: offset, length: term.utf16.count) {
                text = collapse(sentence)
            }
        }
        guard let range = text.range(of: term, options: options),
              text.count >= term.count + 6 else { return nil }
        // 超长句子只保留选中词前后一段
        if text.count > 500 {
            let lower = text.index(range.lowerBound, offsetBy: -220, limitedBy: text.startIndex) ?? text.startIndex
            let upper = text.index(range.upperBound, offsetBy: 220, limitedBy: text.endIndex) ?? text.endIndex
            text = (lower > text.startIndex ? "…" : "") + text[lower..<upper] + (upper < text.endIndex ? "…" : "")
        }
        return text
    }
}

/// 把原句中的生词加粗高亮。
func highlighted(_ context: String, term: String) -> AttributedString {
    var attributed = AttributedString(context)
    let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return attributed }
    var searchStart = attributed.startIndex
    while searchStart < attributed.endIndex,
          let range = attributed[searchStart...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
        attributed[range].inlinePresentationIntent = .stronglyEmphasized
        attributed[range].foregroundColor = Theme.accent
        searchStart = range.upperBound
    }
    return attributed
}
