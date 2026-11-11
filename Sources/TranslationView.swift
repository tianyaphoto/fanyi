import SwiftUI
import AVFoundation

@MainActor
@Observable
final class TranslationModel {
    var source = ""
    /// 选中词所在的原句、来源 App / 文档
    var context: String?
    var origin: String?
    var result = ""
    var localDefinition: String?
    var isLoading = false
    var errorMessage: String?
    var needsAPIKey = false
    var pinned = false
    var isFavorited = false
    /// 这是第几次查这个词（0 表示未记录历史）。
    var lookupCount = 0
    /// 看图翻译：截图本身发给了模型，source 是本地 OCR 的文字（可能为空）。
    var fromImage = false

    /// 输入翻译模式：浮窗顶部显示输入框。
    var inputMode = false
    var inputText = ""
    var focusRequest = 0

    /// 最近一次请求，出错后重试用
    private var lastCapture: Capture?
    var canRetry: Bool { errorMessage != nil && lastCapture != nil }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let speaker = AVSpeechSynthesizer()

    func retry() {
        if let lastCapture { translate(lastCapture, isRetry: true) }
    }

    func translate(_ capture: Capture, isRetry: Bool = false) {
        let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || capture.image != nil else { return }
        cancel()
        lastCapture = capture
        fromImage = capture.image != nil
        source = text
        context = capture.context
        origin = capture.origin
        result = ""
        errorMessage = nil
        needsAPIKey = false
        // 看图翻译而本地又没识别出文字时，没有可以查词典、记历史的原文
        isFavorited = !text.isEmpty && VocabularyStore.shared.contains(text)
        localDefinition = text.isEmpty ? nil : LocalDictionary.lookup(text)
        // 重试不算一次新的查询
        if !isRetry {
            lookupCount = text.isEmpty ? 0 : HistoryStore.shared.record(text, context: context, origin: origin)
        }

        isLoading = true
        task = Task {
            do {
                for try await chunk in Translator.stream(text: text, context: context, image: capture.image) {
                    result += chunk
                }
                if Task.isCancelled { return }
                HistoryStore.shared.updateTranslation(text, translation: result)
                if isFavorited { saveToVocabulary() }
            } catch {
                if Task.isCancelled { return }
                errorMessage = error.localizedDescription
                needsAPIKey = (error as? TranslateError)?.needsSetup ?? false
                // AI 失败时，至少把系统词典的释义存进历史
                if let local = localDefinition { HistoryStore.shared.updateTranslation(text, translation: local) }
            }
            isLoading = false
        }
    }

    func startInput() {
        cancel()
        inputMode = true
        inputText = ""
        reset()
        focusRequest += 1
    }

    func submitInput() {
        translate(Capture(text: inputText))
    }

    func showMessage(_ message: String) {
        cancel()
        inputMode = false
        reset()
        errorMessage = message
    }

    private func reset() {
        source = ""
        lastCapture = nil
        fromImage = false
        context = nil
        origin = nil
        result = ""
        localDefinition = nil
        errorMessage = nil
        needsAPIKey = false
        isFavorited = false
        lookupCount = 0
    }

    func cancel() {
        task?.cancel()
        task = nil
        isLoading = false
        speaker.stopSpeaking(at: .immediate)
    }

    func toggleFavorite() {
        guard !source.isEmpty else { return }
        if isFavorited {
            VocabularyStore.shared.remove(text: source)
        } else {
            saveToVocabulary()
        }
        isFavorited.toggle()
    }

    private func saveToVocabulary() {
        VocabularyStore.shared.save(text: source,
                                    translation: result.isEmpty ? (localDefinition ?? "") : result,
                                    context: context, origin: origin)
    }

    func speak() {
        guard !source.isEmpty else { return }
        speaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: source)
        let isChinese = source.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        utterance.voice = AVSpeechSynthesisVoice(language: isChinese ? "zh-CN" : "en-US")
        speaker.speak(utterance)
    }

    func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.isEmpty ? (localDefinition ?? "") : result, forType: .string)
    }
}

struct TranslationView: View {
    @Bindable var model: TranslationModel
    var onClose: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var showFullLocal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.lookupCount >= 2 {
                repeatHint
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gapM) {
                    if let local = model.localDefinition {
                        localSection(local)
                    }
                    aiSection
                    if let error = model.errorMessage {
                        messageSection(error)
                    }
                    if model.inputMode && model.source.isEmpty && model.errorMessage == nil {
                        Text("输入单词或句子后按 ↩ 翻译，⌥↩ 换行。")
                            .font(Theme.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .ignoresSafeArea()
        .onChange(of: model.source) { showFullLocal = false }
        .task(id: model.focusRequest) {
            guard model.inputMode else { return }
            try? await Task.sleep(for: .milliseconds(60))
            inputFocused = true
        }
    }

    // MARK: 顶部

    /// 查的是单词或短语时，把它当标题显示；整句、整段则缩成几行小字。
    private var isTerm: Bool {
        !model.source.isEmpty && model.source.count <= 40 && !model.source.contains("\n")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.gapS) {
            if model.inputMode {
                TextField("输入要翻译的内容", text: $model.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.reading)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { model.submitInput() }
                    .onExitCommand { onClose() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            } else {
                VStack(alignment: .leading, spacing: Theme.gapXS) {
                    if isTerm {
                        Text(model.source)
                            .font(Theme.heading)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text(model.source.isEmpty ? (model.fromImage ? "截图（看图翻译）" : "翻译神器") : model.source)
                            .font(Theme.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .padding(.top, 3)
                    }
                    if let context = model.context {
                        Text(highlighted(context, term: model.source))
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(context)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 0) {
                if !model.source.isEmpty {
                    IconButton(symbol: "speaker.wave.2", help: "朗读原文") { model.speak() }
                }
                if !model.source.isEmpty || model.fromImage {
                    IconButton(symbol: "doc.on.doc", help: "复制译文") { model.copyResult() }
                        .disabled(model.result.isEmpty && model.localDefinition == nil)
                }
                if !model.source.isEmpty {
                    IconButton(symbol: model.isFavorited ? "star.fill" : "star",
                               help: model.isFavorited ? "从生词本移除" : "收藏到生词本",
                               tint: model.isFavorited ? Theme.favorite : nil) { model.toggleFavorite() }
                }
                IconButton(symbol: model.pinned ? "pin.fill" : "pin", help: model.pinned ? "取消固定" : "固定浮窗",
                           tint: model.pinned ? Theme.accent : nil) { model.pinned.toggle() }
                IconButton(symbol: "xmark", help: "关闭（Esc）") { onClose() }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
    }

    private var repeatHint: some View {
        HStack(spacing: 6) {
            Text("这是你第 \(model.lookupCount) 次查询")
                .monospacedDigit()
            Spacer()
            if !model.isFavorited {
                Button("加入生词本") { model.toggleFavorite() }
                    .buttonStyle(.link)
            } else {
                Text("已在生词本中").foregroundStyle(.secondary)
            }
        }
        .font(Theme.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Theme.repeated.opacity(model.lookupCount >= 3 ? 0.18 : 0.10))
    }

    // MARK: 内容

    private func localSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("系统词典")
            Text(text)
                .font(Theme.body)
                .lineSpacing(3)
                .lineLimit(showFullLocal ? nil : 6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if text.split(separator: "\n").count > 6 || text.count > 300 {
                Button(showFullLocal ? "收起" : "展开全部") { showFullLocal.toggle() }
                    .buttonStyle(.link)
                    .font(Theme.caption)
            }
        }
        .surface()
    }

    @ViewBuilder
    private var aiSection: some View {
        if !model.result.isEmpty || model.isLoading {
            VStack(alignment: .leading, spacing: 6) {
                if model.localDefinition != nil {
                    SectionLabel("AI 释义")
                }
                if !model.result.isEmpty {
                    Text(model.result)
                        // 单词释义条目多，用正文字号；整句译文用大一号方便阅读
                        .font(isTerm ? Theme.body : Theme.reading)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    SkeletonLines()
                        .padding(.top, 2)
                }
            }
        }
    }

    /// 出错（可以重试）或普通提示（例如没有读取到选中的文字）。
    private func messageSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.canRetry {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .accessibilityLabel("出错")
                }
                Text(message)
                    .textSelection(.enabled)
            }
            .font(Theme.body)
            if model.canRetry {
                HStack(spacing: Theme.gapS) {
                    Button("重试") { model.retry() }
                    if model.needsAPIKey {
                        Button("打开设置") {
                            onClose()
                            Windows.showSettings()
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}
