import AppKit
import ApplicationServices
import NaturalLanguage
import SwiftUI

/// 一次翻译请求的内容：选中的文字、所在原句、来源。
struct Capture {
    var text: String
    var context: String? = nil
    var origin: String? = nil
    /// 看图翻译时附带的截图；此时 text 是本地 OCR 的结果（可能为空），只用于显示和历史记录。
    var image: ImageAttachment? = nil
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

    /// 例如「预览：paper.pdf」。
    static func originDescription() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let name = app.localizedName ?? ""
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var title = ""
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success {
                title = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if title.count > 80 { title = String(title.prefix(80)) + "…" }
        if title.isEmpty || title == name { return name.isEmpty ? nil : name }
        return name.isEmpty ? title : "\(name)：\(title)"
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

    // MARK: - 网页（Safari 等基于 WebKit 的视图使用 text marker）

    private static func viaTextMarkers(_ element: AXUIElement) -> String? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let markerRange,
              let start = parameterized(element, "AXStartTextMarkerForTextMarkerRange", markerRange) else { return nil }
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
