import AppKit
import UniformTypeIdentifiers

/// 把生词本发到 Anki。两条路：
/// 1. Anki 开着并装了 AnkiConnect 插件（插件代码 2055492159）：通过它在本机开的接口（http://127.0.0.1:8765）直接制卡；
/// 2. 否则导出成 Anki 能导入的文本文件（制表符分隔、字段里可以有 HTML）。
/// 卡片正面是原句（生词加粗）和生词，背面是释义、「帮你记住」和来源。
enum AnkiExport {
    static let deckName = "翻译神器"
    static let modelName = "翻译神器生词"
    static let fields = ["词", "原句", "释义", "帮你记住", "来源"]

    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Summary {
        var added = 0
        /// Anki 里已经有同一个词的
        var duplicates = 0
    }

    /// 接口地址。开发自测时可以用 FANYI_ANKI_URL 指到假的服务。
    static var endpoint: URL {
        URL(string: ProcessInfo.processInfo.environment["FANYI_ANKI_URL"] ?? "http://127.0.0.1:8765")!
    }

    // MARK: 卡片内容

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func html(_ text: String) -> String {
        escape(text.trimmingCharacters(in: .whitespacesAndNewlines)).replacingOccurrences(of: "\n", with: "<br>")
    }

    /// 原句里把生词加粗（不区分大小写）。
    static func contextHTML(_ context: String, term: String) -> String {
        let escaped = html(context)
        let needle = escape(term.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty,
              let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: needle), options: .caseInsensitive)
        else { return escaped }
        let range = NSRange(location: 0, length: (escaped as NSString).length)
        return regex.stringByReplacingMatches(in: escaped, range: range, withTemplate: "<b>$0</b>")
    }

    static func fieldValues(_ entry: VocabEntry) -> [String: String] {
        let parts = Translator.splitMemory(entry.translation)
        return [
            "词": html(entry.text),
            "原句": entry.context.map { contextHTML($0, term: entry.text) } ?? "",
            "释义": html(parts.definition),
            "帮你记住": parts.memory.map(html) ?? "",
            "来源": entry.origin.map { html(displayOrigin($0)) } ?? "",
        ]
    }

    // MARK: AnkiConnect

    private static func call(_ action: String, _ params: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> Any? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "version": 6, "params": params])
        let (data, _) = try await HTTP.session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExportError(message: "Anki 返回的内容读不懂")
        }
        if let error = json["error"], !(error is NSNull) {
            throw ExportError(message: "Anki 报错：\(error)")
        }
        return json["result"]
    }

    /// Anki 开着并且装了 AnkiConnect。
    static func isAvailable() async -> Bool {
        (try? await call("version", timeout: 2)) != nil
    }

    /// 发到 Anki：没有牌组和卡片模板就先建；Anki 里已有的词跳过。
    static func send(_ entries: [VocabEntry]) async throws -> Summary {
        guard !entries.isEmpty else { return Summary() }
        _ = try await call("createDeck", ["deck": deckName])
        let models = try await call("modelNames") as? [String] ?? []
        if !models.contains(modelName) {
            _ = try await call("createModel", [
                "modelName": modelName,
                "inOrderFields": fields,
                "css": """
                .card { font-family: -apple-system, "PingFang SC", sans-serif; font-size: 20px; text-align: left; color: #222; background: #fff; padding: 12px; }
                .ctx { font-size: 20px; line-height: 1.6; } .ctx b { color: #d9480f; }
                .word { font-size: 26px; font-weight: 600; margin-top: 12px; }
                .def, .mem { font-size: 17px; line-height: 1.6; margin-top: 10px; }
                .mem { color: #555; border-top: 1px dashed #ccc; padding-top: 8px; }
                .src { font-size: 13px; color: #999; margin-top: 12px; }
                .nightMode .card, .night_mode .card { color: #ddd; background: #2b2b2b; }
                """,
                "isCloze": false,
                "cardTemplates": [[
                    "Name": "原句 → 释义",
                    "Front": "{{#原句}}<div class=\"ctx\">{{原句}}</div>{{/原句}}<div class=\"word\">{{词}}</div>",
                    "Back": "{{FrontSide}}<hr id=\"answer\"><div class=\"def\">{{释义}}</div>{{#帮你记住}}<div class=\"mem\">{{帮你记住}}</div>{{/帮你记住}}{{#来源}}<div class=\"src\">{{来源}}</div>{{/来源}}",
                ]],
            ])
        }
        let notes: [[String: Any]] = entries.map { entry in
            ["deckName": deckName, "modelName": modelName, "fields": fieldValues(entry),
             "options": ["allowDuplicate": false], "tags": ["fanyi"]]
        }
        // 一批里有一条重复，addNotes 会整批拒绝，所以先问清楚哪些能加
        let allowed = try await call("canAddNotes", ["notes": notes]) as? [Bool] ?? []
        guard allowed.count == notes.count else { throw ExportError(message: "Anki 返回的检查结果条数不对") }
        let fresh = zip(notes, allowed).filter(\.1).map(\.0)
        var summary = Summary(added: 0, duplicates: notes.count - fresh.count)
        if !fresh.isEmpty {
            let ids = try await call("addNotes", ["notes": fresh], timeout: 60) as? [Any] ?? []
            summary.added = ids.filter { !($0 is NSNull) }.count
        }
        return summary
    }

    // MARK: 导出成文件

    /// Anki「文件 → 导入」能直接读的文本：开头几行说明分隔符和列，后面每行一条。
    static func fileContents(_ entries: [VocabEntry]) -> String {
        var lines = ["#separator:tab", "#html:true", "#columns:" + (fields + ["标签"]).joined(separator: "\t")]
        for entry in entries {
            let values = fieldValues(entry)
            let row = fields.map { (values[$0] ?? "").replacingOccurrences(of: "\t", with: " ") } + ["fanyi"]
            lines.append(row.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    static func saveFile(_ entries: [VocabEntry]) {
        let panel = NSSavePanel()
        panel.title = "导出生词本"
        panel.message = "导出成 Anki 能导入的文本文件：在 Anki 里选「文件 → 导入」，按列对应字段即可。"
        panel.nameFieldStringValue = "翻译神器生词本.txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try fileContents(entries).write(to: url, atomically: true, encoding: .utf8)
            Toast.shared.show("已导出 \(entries.count) 条到 \(url.lastPathComponent)")
        } catch {
            Toast.shared.show("导出失败：\(error.localizedDescription)", style: .error, seconds: 4.5)
        }
    }
}
