import Foundation
import NaturalLanguage
import Observation
import PDFKit
import AppKit

/// 资料库里的一份资料（一个文件或一段粘贴的文字）。
struct KnowledgeDocument: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// 来自文件时的路径，用于重新读取
    var path: String?
    var addedAt = Date()
    /// 只在这些场景里参考；空 = 所有场景
    var sceneIDs: [String] = []
    var enabled = true
    var charCount = 0
    var chunkCount = 0
}

struct KnowledgeChunk: Codable, Hashable {
    var docID: UUID
    var text: String
}

/// 术语表的一条：原文 = 译文。
struct GlossaryEntry: Hashable {
    var source: String
    var target: String
}

/// 一次检索的结果：命中的术语，以及相关的资料片段。
struct Retrieval: Equatable {
    struct Passage: Equatable, Identifiable {
        var id: Int
        var docName: String
        var text: String
    }

    var glossary: [GlossaryEntry] = []
    var passages: [Passage] = []

    var isEmpty: Bool { glossary.isEmpty && passages.isEmpty }
    static let empty = Retrieval()
}

/// 本地资料库：文件切成小段，用 BM25 关键词检索（不调用任何外部服务）；术语表按原文精确匹配。
/// 保存在 ~/Library/Application Support/Fanyi/knowledge.json
@MainActor
@Observable
final class KnowledgeStore {
    static let shared = KnowledgeStore()

    static let enabledKey = "knowledge.enabled"

    private(set) var documents: [KnowledgeDocument] = []
    /// 术语表原文，每行一条
    private(set) var glossaryText = ""
    private(set) var glossary: [GlossaryEntry] = []
    /// 正在导入的文件数
    private(set) var importing = 0
    /// 最近一次导入失败的说明
    var lastError: String?

    @ObservationIgnored private var chunks: [KnowledgeChunk] = []
    @ObservationIgnored private var index = SearchIndex(chunks: [])

    @ObservationIgnored private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fanyi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("knowledge.json")
    }()

    private struct Saved: Codable {
        var documents: [KnowledgeDocument]
        var chunks: [KnowledgeChunk]
        var glossary: String
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            documents = saved.documents
            chunks = saved.chunks
            glossaryText = saved.glossary
            glossary = Self.parseGlossary(saved.glossary)
        }
        rebuildIndex()
    }

    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    // MARK: - 检索

    /// 找出和待翻译文本相关的术语与资料片段。
    func retrieve(text: String, context: String?, sceneID: String) -> Retrieval {
        guard isEnabled else { return .empty }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        var result = Retrieval()
        result.glossary = Self.matchGlossary(glossary, in: trimmed)

        let allowed = Set(documents.filter { doc in
            doc.enabled && (doc.sceneIDs.isEmpty || doc.sceneIDs.contains(sceneID))
        }.map(\.id))
        guard !allowed.isEmpty else { return result }

        // 查单词时把原句也算进查询，能找到同一话题的资料
        let query = trimmed.count < 60 ? [trimmed, context ?? ""].joined(separator: " ") : trimmed
        let names = Dictionary(documents.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var budget = 3600
        let docIDs = chunks.map(\.docID)
        for hit in index.search(query, limit: 4, isAllowed: { allowed.contains(docIDs[$0]) }) where budget > 200 {
            var passage = chunks[hit].text
            if passage.count > min(budget, 1400) { passage = String(passage.prefix(min(budget, 1400))) + "…" }
            budget -= passage.count
            result.passages.append(.init(id: hit, docName: names[chunks[hit].docID] ?? "资料", text: passage))
        }
        return result
    }

    /// 术语表命中：英文按整词、不分大小写匹配原文；也匹配译文（中译英时）。
    nonisolated static func matchGlossary(_ entries: [GlossaryEntry], in text: String) -> [GlossaryEntry] {
        let lower = text.lowercased()
        var hits: [GlossaryEntry] = []
        for entry in entries where hits.count < 40 {
            if containsTerm(entry.source, in: lower) || containsTerm(entry.target, in: lower) {
                hits.append(entry)
            }
        }
        return hits
    }

    nonisolated private static func containsTerm(_ term: String, in lowerText: String) -> Bool {
        let t = term.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        var searchRange = lowerText.startIndex..<lowerText.endIndex
        while let range = lowerText.range(of: t, range: searchRange) {
            // 英文词要求前后不是字母数字，避免 "API" 命中 "rapid"
            let beforeOK = range.lowerBound == lowerText.startIndex
                || !isWordChar(lowerText[lowerText.index(before: range.lowerBound)]) || !isWordChar(t.first!)
            let afterOK = range.upperBound == lowerText.endIndex
                || !isWordChar(lowerText[range.upperBound]) || !isWordChar(t.last!)
            if beforeOK && afterOK { return true }
            searchRange = range.upperBound..<lowerText.endIndex
        }
        return false
    }

    nonisolated private static func isWordChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    // MARK: - 术语表

    func setGlossary(_ text: String) {
        glossaryText = text
        glossary = Self.parseGlossary(text)
        persist()
    }

    /// 每行一条，「原文 = 译文」；也接受制表符、「→」「=>」「|」，以及两列的 CSV。# 开头的行是注释。
    nonisolated static func parseGlossary(_ text: String) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var parts: [String] = []
            for separator in ["\t", "=>", "→", " = ", "=", "|", "，", ","] where line.contains(separator) {
                parts = line.components(separatedBy: separator)
                break
            }
            guard parts.count >= 2 else { continue }
            let source = parts[0].trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: "\"")))
            let target = parts[1...].joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: "\"")))
            if !source.isEmpty && !target.isEmpty { entries.append(GlossaryEntry(source: source, target: target)) }
        }
        return entries
    }

    func appendGlossary(from url: URL) {
        guard let text = try? Self.readPlainText(url) else {
            lastError = "无法读取 \(url.lastPathComponent)。"
            return
        }
        let added = Self.parseGlossary(text)
        guard !added.isEmpty else {
            lastError = "\(url.lastPathComponent) 里没有找到「原文,译文」格式的行。"
            return
        }
        let lines = added.map { "\($0.source) = \($0.target)" }.joined(separator: "\n")
        setGlossary(glossaryText.isEmpty ? lines : glossaryText + "\n" + lines)
    }

    // MARK: - 资料

    nonisolated static let supportedExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "log", "srt", "vtt",
        "pdf", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm",
    ]

    /// 添加文件或文件夹（文件夹会递归找出支持的文件）。
    func add(urls: [URL]) {
        let files = Self.expand(urls)
        guard !files.isEmpty else {
            lastError = "没有找到支持的文件（文本、Markdown、PDF、Word、RTF、HTML）。"
            return
        }
        lastError = nil
        importing += files.count
        Task.detached(priority: .userInitiated) {
            var failed: [String] = []
            for url in files {
                do {
                    let text = try Self.extractText(from: url)
                    await MainActor.run {
                        self.insert(name: url.lastPathComponent, path: url.path, text: text)
                        self.importing -= 1
                    }
                } catch {
                    failed.append(url.lastPathComponent)
                    await MainActor.run { self.importing -= 1 }
                }
            }
            if !failed.isEmpty {
                let names = failed.prefix(3).joined(separator: "、") + (failed.count > 3 ? " 等 \(failed.count) 个文件" : "")
                await MainActor.run { self.lastError = "\(names) 读不出文字（可能是扫描件或加密文件）。" }
            }
        }
    }

    func addText(name: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        insert(name: title.isEmpty ? String(trimmed.prefix(20)) : title, path: nil, text: trimmed)
    }

    private func insert(name: String, path: String?, text: String) {
        let pieces = Self.chunk(text)
        guard !pieces.isEmpty else { return }
        // 同一个文件再次添加时替换旧的
        if let path, let old = documents.first(where: { $0.path == path }) {
            var doc = old
            doc.charCount = text.count
            doc.chunkCount = pieces.count
            chunks.removeAll { $0.docID == old.id }
            chunks += pieces.map { KnowledgeChunk(docID: old.id, text: $0) }
            documents[documents.firstIndex(of: old)!] = doc
        } else {
            let doc = KnowledgeDocument(name: name, path: path, charCount: text.count, chunkCount: pieces.count)
            documents.insert(doc, at: 0)
            chunks += pieces.map { KnowledgeChunk(docID: doc.id, text: $0) }
        }
        rebuildIndex()
        persist()
    }

    func remove(_ id: KnowledgeDocument.ID) {
        documents.removeAll { $0.id == id }
        chunks.removeAll { $0.docID == id }
        rebuildIndex()
        persist()
    }

    func update(_ doc: KnowledgeDocument) {
        guard let index = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        documents[index] = doc
        persist()
    }

    /// 重新读取所有来自文件的资料（文件改过之后）。
    func reloadFiles() {
        let urls = documents.compactMap { $0.path }.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { add(urls: urls) }
    }

    /// 某份资料的全部文字（预览用）。
    func text(of id: KnowledgeDocument.ID) -> String {
        chunks.filter { $0.docID == id }.map(\.text).joined(separator: "\n\n")
    }

    private func rebuildIndex() {
        index = SearchIndex(chunks: chunks.map(\.text))
    }

    private func persist() {
        let saved = Saved(documents: documents, chunks: chunks, glossary: glossaryText)
        let url = fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: - 读取文件

    nonisolated private static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue && url.pathExtension.lowercased() != "rtfd" {
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = enumerator?.nextObject() as? URL, files.count < 500 {
                    if supportedExtensions.contains(file.pathExtension.lowercased()) { files.append(file) }
                }
            } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files
    }

    struct ExtractError: Error {}

    nonisolated static func extractText(from url: URL) throws -> String {
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let pdf = PDFDocument(url: url), let string = pdf.string else { throw ExtractError() }
            text = string
        case "docx", "doc", "rtf", "rtfd", "odt":
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        case "html", "htm":
            text = stripHTML(try readPlainText(url))
        default:
            text = try readPlainText(url)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExtractError() }
        return trimmed
    }

    nonisolated static func readPlainText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        let data = try Data(contentsOf: url)
        for candidate: String.Encoding in [.utf8, .utf16, .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))] {
            if let text = String(data: data, encoding: candidate) { return text }
        }
        throw ExtractError()
    }

    nonisolated private static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }

    /// 切成 500–900 字左右的小段：按段落累积，过长的段落再按句子切。
    nonisolated static func chunk(_ text: String, target: Int = 700, maximum: Int = 1000) -> [String] {
        let paragraphs = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var pieces: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }
        for paragraph in paragraphs {
            if paragraph.count > maximum {
                flush()
                let tokenizer = NLTokenizer(unit: .sentence)
                tokenizer.string = paragraph
                tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                    let sentence = String(paragraph[range])
                    if current.count + sentence.count > target { flush() }
                    current += sentence
                    return true
                }
                flush()
            } else {
                if current.count + paragraph.count > target { flush() }
                current += (current.isEmpty ? "" : "\n") + paragraph
            }
        }
        flush()
        return pieces
    }
}

/// BM25 倒排索引。中文用系统分词（NLTokenizer），英文按词并做简单的复数还原。
struct SearchIndex: Sendable {
    private var postings: [String: [(chunk: Int, tf: Int)]] = [:]
    private var lengths: [Int] = []
    private var averageLength: Double = 1

    init(chunks: [String]) {
        lengths = Array(repeating: 0, count: chunks.count)
        for (i, text) in chunks.enumerated() {
            let tokens = Self.tokens(text)
            lengths[i] = tokens.count
            var counts: [String: Int] = [:]
            for token in tokens { counts[token, default: 0] += 1 }
            for (token, tf) in counts { postings[token, default: []].append((i, tf)) }
        }
        averageLength = max(1, Double(lengths.reduce(0, +)) / Double(max(1, lengths.count)))
    }

    /// 返回最相关的几段的下标。分数太低（只命中常见词）时不返回。
    func search(_ query: String, limit: Int, isAllowed: (Int) -> Bool = { _ in true }) -> [Int] {
        guard !lengths.isEmpty else { return [] }
        let terms = Set(Self.tokens(query))
        let n = Double(lengths.count)
        let k1 = 1.2, b = 0.75
        var scores: [Int: Double] = [:]
        for term in terms {
            guard let list = postings[term] else { continue }
            let idf = log(1 + (n - Double(list.count) + 0.5) / (Double(list.count) + 0.5))
            for (chunk, tf) in list where isAllowed(chunk) {
                let norm = Double(tf) * (k1 + 1) / (Double(tf) + k1 * (1 - b + b * Double(lengths[chunk]) / averageLength))
                scores[chunk, default: 0] += idf * norm
            }
        }
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first?.value, best >= 0.8 else { return [] }
        return ranked.prefix(limit).filter { $0.value >= best * 0.45 }.map(\.key)
    }

    private static let stopwords: Set<String> = [
        "of", "to", "in", "on", "is", "it", "an", "as", "at", "be", "by", "or", "if", "do", "we", "so", "no", "up",
        "me", "my", "us", "he", "am", "go", "vs", "etc",
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "has", "have", "his", "how", "its", "may", "new", "now", "old", "see", "two", "who", "did", "get", "let", "say",
        "she", "too", "use", "that", "this", "with", "from", "they", "will", "would", "there", "their", "what", "about",
        "which", "when", "make", "like", "time", "just", "know", "take", "into", "year", "your", "some", "could", "them",
        "than", "then", "look", "only", "come", "over", "also", "back", "after", "work", "first", "well", "even", "want",
        "because", "these", "give", "most", "were", "been", "being", "more", "such", "should", "each", "other", "where",
        "的", "了", "是", "在", "和", "与", "及", "等", "也", "就", "都", "而", "被", "把", "这", "那", "有", "我", "你",
        "他", "她", "它", "们", "个", "上", "下", "中", "对", "为", "以", "将", "从", "到", "或", "并", "但", "不", "要",
    ]

    static func tokens(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var token = text[range].lowercased()
            let isCJK = token.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
            if !isCJK {
                guard token.count >= 2, token.contains(where: \.isLetter) else { return true }
                if token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss") { token.removeLast() }
            }
            if !stopwords.contains(token) { out.append(token) }
            return true
        }
        return out
    }
}
