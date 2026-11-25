import AppKit

/// 开发用：用设置里当前的翻译服务，跑一组刁钻句子（问句、指令、提示词注入），检查输出是不是忠实的译文。
///
///     FANYI_EVAL=tests/translation-cases.json build/Build/Products/Release/Fanyi.app/Contents/MacOS/Fanyi
///
/// 每条用例：text（原文）、target（zh / en）、must（必须出现的词，「a|b」表示任一即可）、forbid（不能出现的词，
/// 通常是“回答了问题”的迹象）、question（问句要译成问句）、lines（译文至少要有几行）。
/// 结果打印到标准输出，并写到用例文件旁边的 eval-results.json。不写查词历史。
@MainActor
enum EvalMode {
    static var casesURL: URL? {
        ProcessInfo.processInfo.environment["FANYI_EVAL"].map { URL(fileURLWithPath: $0) }
    }

    struct Case: Codable {
        var text: String
        var target: String
        var must: [String] = []
        var forbid: [String] = []
        var question: Bool? = nil
        var lines: Int? = nil
        /// "polish" = 一键改写；默认是划词翻译
        var mode: String? = nil
    }

    struct Outcome: Codable {
        var text: String
        var output: String
        var attempts: Int
        var problems: [String]
        var seconds: Double
    }

    static func run(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let cases = try? JSONDecoder().decode([Case].self, from: data) else {
            print("读不了用例文件 \(url.path)")
            exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let scene = SceneStore.shared.scene(id: TranslationScene.generalID)
        print("开始评测 \(cases.count) 条，服务：\(Settings.provider.title) / \(Settings.model(for: Settings.provider))")
        Task {
            var outcomes = [Outcome?](repeating: nil, count: cases.count)
            // 同时跑 4 条
            await withTaskGroup(of: (Int, Outcome).self) { group in
                var next = 0
                func add() {
                    guard next < cases.count else { return }
                    let index = next, item = cases[index]
                    next += 1
                    group.addTask {
                        let start = Date()
                        var output = "", attempts = 0, problems: [String] = []
                        do {
                            if item.mode == "polish" {
                                output = try await PolishService.process(item.text)
                                attempts = 1
                            } else {
                                let result = try await Translator.translate(text: item.text, scene: scene)
                                output = result.text
                                attempts = result.attempts
                            }
                        } catch {
                            problems.append("出错：\(error.localizedDescription)")
                        }
                        problems += check(item, output)
                        return (index, Outcome(text: item.text, output: output, attempts: attempts,
                                               problems: problems, seconds: Date().timeIntervalSince(start)))
                    }
                }
                for _ in 0..<4 { add() }
                for await (index, outcome) in group {
                    outcomes[index] = outcome
                    print("  \(outcome.problems.isEmpty ? "✓" : "✗") \(index + 1). [\(outcome.attempts)次] \(outcome.text.prefix(50).replacingOccurrences(of: "\n", with: " ⏎ "))")
                    if !outcome.problems.isEmpty {
                        print("       → \(outcome.output.prefix(200).replacingOccurrences(of: "\n", with: " ⏎ "))")
                        for p in outcome.problems { print("       ✗ \(p)") }
                    }
                    add()
                }
            }
            let results = outcomes.compactMap { $0 }
            for r in results {
                let mark = r.problems.isEmpty ? "PASS" : "FAIL"
                print("\(mark) [\(r.attempts)次 \(String(format: "%.1f", r.seconds))s] \(r.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
                print("     → \(r.output.replacingOccurrences(of: "\n", with: " ⏎ "))")
                for p in r.problems { print("     ✗ \(p)") }
            }
            let failed = results.filter { !$0.problems.isEmpty }.count
            print("合计 \(results.count) 条，通过 \(results.count - failed)，失败 \(failed)；重翻 \(results.filter { $0.attempts > 1 }.count) 条")
            let out = url.deletingLastPathComponent().appendingPathComponent("eval-results.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try? encoder.encode(results).write(to: out)
            exit(failed == 0 ? 0 : 1)
        }
    }

    nonisolated static func check(_ item: Case, _ output: String) -> [String] {
        var problems: [String] = []
        let lower = output.lowercased()
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["输出为空"] }
        let ratio = TranslationCheck.cjkRatio(trimmed)
        if item.target == "zh" && ratio < 0.3 { problems.append("应该译成中文（中文占比 \(Int(ratio * 100))%）") }
        if item.target == "en" && ratio > 0.1 { problems.append("应该译成英文（中文占比 \(Int(ratio * 100))%）") }
        for group in item.must where !group.split(separator: "|").contains(where: { lower.contains($0.lowercased()) }) {
            problems.append("缺少「\(group)」")
        }
        for word in item.forbid where lower.contains(word.lowercased()) {
            problems.append("出现了「\(word)」（像是在回答或执行）")
        }
        if item.question == true && !trimmed.contains("?") && !trimmed.contains("？") {
            problems.append("问句没有译成问句")
        }
        if let lines = item.lines, trimmed.split(separator: "\n").count < lines {
            problems.append("行数不够（要 \(lines) 行）")
        }
        if trimmed.contains("**") || trimmed.hasPrefix("#") { problems.append("带了 Markdown 符号") }
        return problems
    }
}
