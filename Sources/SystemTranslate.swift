import SwiftUI
import NaturalLanguage
import Translation

/// 系统翻译（苹果的 Translation 框架，macOS 15 起）：在本机完成，不用 API Key、不联网发送文字。
/// 新用户没配任何服务时默认用它，装上就能翻；它只会翻译，没有语境释义、「帮你记住」、场景、术语表和一键改写。
///
/// 两种调用方式：
/// - macOS 26 起可以直接建会话（要求语言包已经下载）；
/// - macOS 15–25 只能通过界面上的 `.translationTask` 拿到会话，所以挂在翻译浮窗上（`SystemTranslationHost`）。
/// 语言包没下载时不弹系统的下载框（浮窗不抢焦点，弹框容易藏在后面），直接告诉用户去哪里下载。
enum SystemTranslator {
    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// 开发用：FANYI_SYSTEM_TASK=1 时在 macOS 26 上也走浮窗上的 `.translationTask`，用来测 macOS 15 的那条路。
    private static var forceTaskPath: Bool { ProcessInfo.processInfo.environment["FANYI_SYSTEM_TASK"] != nil }

    /// 原文语言：先用翻译流程里已经判断好的，判断不出来再问系统的语言识别。
    static func sourceLanguage(_ text: String, plan: TranslationPlan) -> Locale.Language? {
        if let source = plan.source { return Locale.Language(identifier: source.code) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    @MainActor
    static func translate(_ text: String, plan: TranslationPlan) async throws -> String {
        guard #available(macOS 15.0, *) else {
            throw TranslateError(message: "系统翻译需要 macOS 15 或更新的系统。请在设置里换一个翻译服务。", needsSetup: true)
        }
        guard let source = sourceLanguage(text, plan: plan) else {
            throw TranslateError(message: "判断不出这段文字是什么语言，系统翻译没法处理。")
        }
        let target = Locale.Language(identifier: plan.target.code)
        if source.minimalIdentifier == target.minimalIdentifier { return text }
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            break
        case .supported:
            // 新装的系统默认没有语言包：让用户点一下下载（系统会再确认一次），下完自动重翻
            throw LanguagePackMissing(source: source, target: target,
                                      sourceName: plan.source?.name ?? "原文的语言", targetName: plan.target.name)
        case .unsupported:
            throw TranslateError(message: "系统翻译不支持把这种语言译成\(plan.target.name)。请在设置里换成大模型服务。", needsSetup: true)
        @unknown default:
            break
        }
        // 按行翻译，保住原文的段落和换行
        let lines = text.components(separatedBy: "\n")
        let requests = lines.enumerated()
            .filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        let responses: [TranslationSession.Response]
        if #available(macOS 26.0, *), !forceTaskPath {
            responses = try await TranslationSession(installedSource: source, target: target).translations(from: requests)
        } else {
            responses = try await SystemTranslationBroker.shared.translate(requests, source: source, target: target)
        }
        var output = lines.map { _ in "" }
        for response in responses {
            if let id = response.clientIdentifier, let index = Int(id), output.indices.contains(index) {
                output[index] = response.targetText
            }
        }
        return output.joined(separator: "\n")
    }
}

/// 系统翻译支持这两种语言，但语言包还没下载。
struct LanguagePackMissing: LocalizedError {
    let source: Locale.Language
    let target: Locale.Language
    let sourceName: String
    let targetName: String
    var errorDescription: String? {
        "系统翻译要先下载「\(sourceName)」和「\(targetName)」的语言包（只需一次，由 macOS 下载，之后在本机翻译、不联网）。"
    }
}

/// 下载语言包的小窗口：系统的下载确认框要挂在一个正常的窗口上，所以不放在不抢焦点的翻译浮窗里。
@available(macOS 15.0, *)
struct LanguagePackDownloadView: View {
    let missing: LanguagePackMissing
    var onDone: () -> Void
    var onClose: () -> Void
    @State private var configuration: TranslationSession.Configuration?
    @State private var failure: String?
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            Text("下载系统翻译的语言包").font(Theme.heading)
            Text("「\(missing.sourceName)」⇄「\(missing.targetName)」。macOS 会弹出确认框，点「下载」即可；语言包由系统保存，下载一次以后都在本机翻译。")
                .font(Theme.body)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.body)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Text("也可以手动下载：系统设置 → 通用 → 语言与地区 → 翻译语言。")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            } else if finished {
                Label("下载好了，可以翻译了。", systemImage: "checkmark.circle.fill")
                    .font(Theme.body)
                    .foregroundStyle(Theme.success)
            } else {
                HStack(spacing: Theme.gapS) {
                    ProgressView().controlSize(.small)
                    Text("等待下载完成…").font(Theme.body).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                if failure != nil {
                    Button("重试") {
                        failure = nil
                        configuration?.invalidate()
                    }
                }
                Button(finished ? "好" : "关闭", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { configuration = TranslationSession.Configuration(source: missing.source, target: missing.target) }
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
                // 有的系统版本在下载完成前就返回：等到确实装好（最多 10 分钟）
                for _ in 0..<600 {
                    if await LanguageAvailability().status(from: missing.source, to: missing.target) == .installed { break }
                    try await Task.sleep(for: .seconds(1))
                }
                guard await LanguageAvailability().status(from: missing.source, to: missing.target) == .installed else {
                    failure = "语言包还没装好。"
                    return
                }
                finished = true
                onDone()
            } catch is CancellationError {
            } catch {
                failure = "没有下载成功：\(error.localizedDescription)"
            }
        }
    }
}

/// 把翻译请求交给挂在浮窗上的 `.translationTask`，等它拿到会话后翻完再交回来。同一时间只处理一个请求。
@available(macOS 15.0, *)
@MainActor
@Observable
final class SystemTranslationBroker {
    static let shared = SystemTranslationBroker()

    var configuration: TranslationSession.Configuration?
    @ObservationIgnored private var requests: [TranslationSession.Request] = []
    @ObservationIgnored private var continuation: CheckedContinuation<[TranslationSession.Response], Error>?
    /// 每来一个新请求加一：翻到一半被新请求顶掉的那次，回来时不能把结果交给新请求
    @ObservationIgnored private var generation = 0

    func translate(_ requests: [TranslationSession.Request], source: Locale.Language,
                   target: Locale.Language) async throws -> [TranslationSession.Response] {
        // 上一个还没翻完就来了新的：让上一个按取消结束
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        generation += 1
        self.requests = requests
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let next = TranslationSession.Configuration(source: source, target: target)
                if configuration == next {
                    // 语言对没变时改配置不会重新触发，要显式作废一次
                    configuration?.invalidate()
                } else {
                    configuration = next
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.continuation?.resume(throwing: CancellationError())
                self.continuation = nil
                self.generation += 1
            }
        }
    }

    func run(_ session: TranslationSession) async {
        guard continuation != nil else { return }
        let current = generation
        let result: Result<[TranslationSession.Response], Error>
        do {
            result = .success(try await session.translations(from: requests))
        } catch {
            result = .failure(error)
        }
        guard current == generation, let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// 挂在翻译浮窗上：macOS 15 起提供系统翻译的会话。
struct SystemTranslationHost: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.translationTask(SystemTranslationBroker.shared.configuration) { session in
                await SystemTranslationBroker.shared.run(session)
            }
        } else {
            content
        }
    }
}
