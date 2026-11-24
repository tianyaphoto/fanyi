import Foundation

/// 在本地先判断好的翻译方式：单词还是句子、译成什么语言、原文是不是问句或指令。
/// 这些不交给模型猜，直接写进提示词，也用来检查译文。
struct TranslationPlan: Equatable, Sendable {
    enum Mode: Sendable { case term, passage }

    enum Target: Sendable {
        case chinese, english
        var name: String { self == .chinese ? "简体中文" : "英文" }
    }

    var mode: Mode
    var target: Target
    var isQuestion: Bool
    var isImperative: Bool

    init(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        target = TranslationCheck.cjkRatio(text) >= 0.3 ? .english : .chinese

        let sentenceEnd: Set<Character> = [".", "?", "!", "。", "？", "！", ";", "；", "…"]
        let endsLikeSentence = text.last.map { sentenceEnd.contains($0) } ?? false
        let hasClausePunctuation = text.contains { "，,：:".contains($0) }
        let latinWords = text.split(whereSeparator: \.isWhitespace).count
        let cjkCount = text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
        let short = target == .chinese ? latinWords <= 4 : cjkCount <= 8
        mode = (!text.contains("\n") && text.count <= 40 && !endsLikeSentence && !hasClausePunctuation && short)
            ? .term : .passage

        let lower = text.lowercased()
        isQuestion = text.hasSuffix("?") || text.hasSuffix("？")
            || (target == .english && ["吗", "呢", "么"].contains { text.hasSuffix($0) })
        let englishVerbs = ["please", "translate", "write", "tell", "list", "summarize", "summarise", "explain",
                            "ignore", "give", "show", "help", "make", "create", "answer", "describe", "generate",
                            "draft", "rewrite", "act as", "pretend", "respond", "reply", "forget", "say", "repeat"]
        let chineseVerbs = ["请", "帮我", "给我", "忽略", "告诉我", "写", "列出", "翻译", "总结", "解释", "回答",
                            "生成", "扮演", "假装", "忘记", "重复", "说", "改写", "起草"]
        isImperative = !isQuestion && (target == .chinese
            ? englishVerbs.contains { lower.hasPrefix($0 + " ") || lower.hasPrefix("system:") }
            : chineseVerbs.contains { text.hasPrefix($0) })
    }
}

/// 判断译文是否可信、清理多余格式的本地检查。
enum TranslationCheck {
    /// 原文里和提示词标签同名的写法（例如故意写一个 </text> 想提前结束原文）换成形状相近的书名号，
    /// 这样原文无论写什么都出不了 <text> 标签。
    static func neutralizeTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<(/?)(text|context|glossary|reference)\b"#, with: "‹$1$2",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"‹(/?)(text|context|glossary|reference)([^>]*)>"#, with: "‹$1$2$3›",
                                  options: [.regularExpression, .caseInsensitive])
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
    }

    /// 文字中汉字所占比例。英文按 4 个字母折算成 1 个“字”，不数标点、数字、空白。
    static func cjkRatio(_ text: String) -> Double {
        let units = size(text)
        guard units.total > 0 else { return 0 }
        return Double(units.cjk) / units.total
    }

    /// 信息量的粗略度量：汉字数 + 英文字母数 / 4。
    static func size(_ text: String) -> (cjk: Int, total: Double) {
        var cjk = 0, letters = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) { cjk += 1 } else if CharacterSet.letters.contains(scalar) { letters += 1 }
        }
        return (cjk, Double(cjk) + Double(letters) / 4)
    }

    private static func questionMarks(_ text: String) -> Int {
        text.filter { $0 == "?" || $0 == "？" }.count
    }

    /// 句子模式的译文有没有问题；空数组表示通过。
    static func problems(source: String, output: String, plan: TranslationPlan) -> [String] {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return ["输出为空"] }
        var problems: [String] = []

        let src = size(source), dst = size(out)
        switch plan.target {
        case .chinese where src.total >= 2 && cjkRatio(out) < 0.25:
            problems.append("没有译成中文")
        case .english where cjkRatio(out) > 0.15:
            problems.append("没有译成英文")
        default:
            break
        }
        if questionMarks(source) > 0 && questionMarks(out) == 0 {
            problems.append("原文是问句，输出却不是问句，像是回答了问题")
        }
        if src.total >= 4 {
            let ratio = dst.total / src.total
            if ratio < 0.4 { problems.append("输出比原文短太多，像是只给了答案") }
            if ratio > 3.5 { problems.append("输出比原文长太多，像是在回答、解释或执行") }
        }
        return problems
    }

    /// 去掉模型常加的多余格式：「译文：」前缀、整段外面的引号、原文没有的 Markdown 加粗和标题符号。
    static func clean(_ output: String, source: String) -> String {
        var text = output
        if let range = text.range(of: #"^\s*(译文|翻译|中文译文|英文译文|Translation|Translated text)\s*[:：]\s*"#,
                                  options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("'", "'")]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in quotes where trimmed.count > 2 && trimmed.first == open && trimmed.last == close
            && src.first != open && !trimmed.dropFirst().dropLast().contains(close) {
            text = String(trimmed.dropFirst().dropLast())
            break
        }
        if !source.contains("**") { text = text.replacingOccurrences(of: "**", with: "") }
        if !source.contains("__") { text = text.replacingOccurrences(of: "__", with: "") }
        let sourceHasHeadings = source.components(separatedBy: .newlines).contains { $0.hasPrefix("#") }
        if !sourceHasHeadings {
            text = text.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
        }
        return text
    }
}

extension Translator {
    struct Result {
        var text: String
        var attempts: Int
        /// 两次都没通过检查时，剩下的问题（界面上提示“可能不准确”）
        var problems: [String]
    }

    /// 翻译并检查：句子模式的输出不像译文时，带着原因自动重翻一次；两次都不过关就返回问题较少的那次。
    /// - Parameter onUpdate: 流式进度（当前文字、第几次）。
    @MainActor
    static func translate(text: String, context: String? = nil, image: ImageAttachment? = nil,
                          scene: TranslationScene? = nil, retrieval: Retrieval = .empty,
                          onUpdate: (String, Int) -> Void = { _, _ in }) async throws -> Result {
        let plan = TranslationPlan(text)
        let checked = image == nil && plan.mode == .passage
        var correction: String?
        var best: Result?
        for attempt in 1...2 {
            var raw = ""
            for try await chunk in stream(text: text, context: context, image: image, scene: scene,
                                          retrieval: retrieval, plan: plan, correction: correction) {
                raw += chunk
                onUpdate(TranslationCheck.clean(raw, source: text), attempt)
            }
            try Task.checkCancellation()
            let output = TranslationCheck.clean(raw, source: text).trimmingCharacters(in: .whitespacesAndNewlines)
            let problems = checked ? TranslationCheck.problems(source: text, output: output, plan: plan) : []
            let result = Result(text: output, attempts: attempt, problems: problems)
            if problems.isEmpty { return result }
            if best == nil || problems.count < best!.problems.count { best = result }
            correction = problems.joined(separator: "；")
        }
        best!.attempts = 2
        return best!
    }
}
