import Foundation
import CoreServices

/// macOS 自带词典（词典.app 中启用的词典，如牛津英汉）——本地查询，毫秒级返回。
enum LocalDictionary {
    /// 只对英文等拉丁文字的单词/短语查询；查不到返回 nil。
    static func lookup(_ text: String) -> String? {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = term.split(whereSeparator: \.isWhitespace)
        guard !term.isEmpty, term.count <= 40, words.count <= 3,
              term.range(of: "\\p{Han}", options: .regularExpression) == nil,
              term.contains(where: \.isLetter) else { return nil }

        let cf = term as NSString as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cf))
        guard let definition = DCSCopyTextDefinition(nil, cf, range)?.takeRetainedValue() as String? else { return nil }

        // 拼音也是拉丁字母，"ran" 可能命中汉语词典的「蚺 rán」，词头含汉字的结果不要。
        let headword = definition.prefix { $0 != " " && $0 != "|" }
        guard String(headword).range(of: "\\p{Han}", options: .regularExpression) == nil else { return nil }

        // 多词短语时，词典可能只匹配到第一个词（如 "look up to" 返回 "look"），这种结果不要。
        if words.count > 1 {
            let normalize: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            guard normalize(definition).hasPrefix(normalize(term)) else { return nil }
        }
        return format(definition)
    }

    /// 词典返回的是一整段文字，按义项和例句断行，便于阅读。
    private static func format(_ raw: String) -> String {
        var text = raw
        for marker in "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳" {
            text = text.replacingOccurrences(of: String(marker), with: "\n\(marker)")
        }
        text = text.replacingOccurrences(of: "▸", with: "\n▸")
        text = text.replacingOccurrences(of: "(?<=[\\s›)])([A-H])\\.\\s(?=[a-z])", with: "\n\n$1. ", options: .regularExpression)
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("▸") else { return trimmed }
            return "    ▸ " + trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
