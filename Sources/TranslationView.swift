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
    /// 来源信息（App、窗口标题、网址），用于选场景和「以后这里都用这个场景」
    var sourceInfo: SourceInfo?
    /// 本次使用的翻译场景
    var scene: TranslationScene = TranslationScene.defaults[0]
    /// 本次参考的术语和资料片段
    var retrieval: Retrieval = .empty
    /// 第几次翻译（第一次的输出不像译文时会自动重翻）
    var attempt = 1
    /// 两次都没通过检查时的问题说明
    var qualityWarning: String?

    /// 输入翻译模式：浮窗顶部显示输入框。
    var inputMode = false
    var inputText = ""
    var focusRequest = 0

    /// 最近一次请求，出错后重试用
    private var lastCapture: Capture?
    var canRetry: Bool { errorMessage != nil && lastCapture != nil }

    /// 正在朗读原文
    var isSpeaking = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let speaker = AVSpeechSynthesizer()
    @ObservationIgnored private let speechDelegate = SpeechDelegate()
    @ObservationIgnored private var speakingID: ObjectIdentifier?

    init() {
        speechDelegate.onEnd = { [weak self] id in
            Task { @MainActor in
                // 只处理当前这一段：上一段被打断时的回调可能晚于新一段开始
                guard let self, self.speakingID == id else { return }
                self.speakingID = nil
                self.isSpeaking = false
            }
        }
        speaker.delegate = speechDelegate
    }

    func retry() {
        if let lastCapture { translate(lastCapture, isRetry: true, sceneID: scene.id) }
    }

    /// 换一个场景重新翻译（不算新的查询）。
    func changeScene(_ id: String) {
        guard let lastCapture, id != scene.id || errorMessage != nil else { return }
        translate(lastCapture, isRetry: true, sceneID: id)
    }

    /// 「以后这里都用这个场景」可以记住的关键词（网站域名或 App）。
    var rememberKeyword: String? { sourceInfo.flatMap(SceneStore.rememberKeyword(for:)) }

    func rememberScene() {
        if let sourceInfo { SceneStore.shared.remember(sourceInfo, as: scene.id) }
    }

    /// - Parameter sceneID: 指定场景；为 nil 时按来源自动选择。
    func translate(_ capture: Capture, isRetry: Bool = false, sceneID: String? = nil) {
        let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || capture.image != nil else { return }
        cancel()
        lastCapture = capture
        fromImage = capture.image != nil
        source = text
        context = capture.context
        origin = capture.origin
        sourceInfo = capture.source
        scene = sceneID.map { SceneStore.shared.scene(id: $0) } ?? SceneStore.shared.detect(for: capture.source)
        retrieval = text.isEmpty ? .empty : KnowledgeStore.shared.retrieve(text: text, context: capture.context, sceneID: scene.id)
        attempt = 1
        qualityWarning = nil
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
                let outcome = try await Translator.translate(
                    text: text, context: context, image: capture.image, scene: scene, retrieval: retrieval
                ) { [weak self] partial, attempt in
                    guard let self, !Task.isCancelled else { return }
                    // 第二次开始时清空第一次的输出，并说明为什么重翻
                    if attempt > self.attempt { self.attempt = attempt }
                    self.result = partial
                }
                if Task.isCancelled { return }
                result = outcome.text
                qualityWarning = outcome.problems.isEmpty ? nil : outcome.problems.joined(separator: "；")
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
        sourceInfo = nil
        retrieval = .empty
        attempt = 1
        qualityWarning = nil
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
        stopSpeaking()
    }

    private func stopSpeaking() {
        speakingID = nil
        isSpeaking = false
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
        // 朗读中再点一次就是停止
        let wasSpeaking = isSpeaking
        stopSpeaking()
        if wasSpeaking { return }
        let utterance = AVSpeechUtterance(string: source)
        let isChinese = source.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        utterance.voice = AVSpeechSynthesisVoice(language: isChinese ? "zh-CN" : "en-US")
        speakingID = ObjectIdentifier(utterance)
        isSpeaking = true
        speaker.speak(utterance)
    }

    func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.isEmpty ? (localDefinition ?? "") : result, forType: .string)
    }
}

/// 朗读结束或被打断时通知模型。
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onEnd: (@Sendable (ObjectIdentifier) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onEnd?(ObjectIdentifier(utterance))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onEnd?(ObjectIdentifier(utterance))
    }
}


extension TranslationModel {
    /// 整段、多段的长文本：浮窗开大一些，原文收进正文区。
    static func isLong(_ text: String) -> Bool { text.count > 200 || text.contains("\n") }

    var isLong: Bool { Self.isLong(source) }
}

/// 按行拆开，空行保留为段落间距。长译文拆成多个 Text，避免一整块大文本在流式刷新时重绘出错。
private func lines(_ text: String) -> [String] {
    text.components(separatedBy: "\n")
}

private func paragraphs(_ text: String) -> [String] {
    text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

struct TranslationView: View {
    @Bindable var model: TranslationModel
    var onClose: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var showFullLocal = false
    @State private var showFullSource = false
    @State private var showReferences = false
    @State private var bilingual = false
    @State private var copied = false
    @State private var copyTick = 0
    @State private var favoriteBounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showMetaBar {
                metaBar
            }
            if model.lookupCount >= 2 {
                repeatHint
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gapM) {
                    if model.isLong && !canShowBilingual {
                        sourceSection
                    }
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .onChange(of: model.source) {
            showFullLocal = false
            showFullSource = false
            showReferences = false
            copied = false
        }
        .task(id: copyTick) {
            // 复制成功的对勾停留一会儿再换回
            guard copyTick > 0 else { return }
            try? await Task.sleep(for: .milliseconds(1200))
            if !Task.isCancelled { copied = false }
        }
        .task(id: model.focusRequest) {
            guard model.inputMode else { return }
            try? await Task.sleep(for: .milliseconds(60))
            inputFocused = true
        }
    }

    // MARK: 顶部

    /// 查的是单词或短语时，把它当标题显示；整句、整段则缩成一行小字，全文放进正文区。
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
                    } else if model.isLong {
                        // 长文本：标题只放第一行和字数，全文在下面的「原文」里
                        Text(paragraphs(model.source).first ?? model.source)
                            .font(Theme.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.top, 3)
                        Text("共 \(model.source.count) 字 · \(paragraphs(model.source).count) 段")
                            .font(Theme.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    } else {
                        Text(model.source.isEmpty ? (model.fromImage ? "截图（看图翻译）" : "翻译神器") : model.source)
                            .font(Theme.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
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
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 0) {
                if !model.source.isEmpty {
                    IconButton(symbol: "speaker.wave.2", help: model.isSpeaking ? "停止朗读" : "朗读原文",
                               tint: model.isSpeaking ? Theme.accent : nil,
                               isActive: model.isSpeaking) { model.speak() }
                }
                if !model.source.isEmpty || model.fromImage {
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? "已复制" : "复制译文",
                               tint: copied ? Theme.success : nil) {
                        model.copyResult()
                        copied = true
                        copyTick += 1
                    }
                        .disabled(model.result.isEmpty && model.localDefinition == nil)
                }
                if !model.source.isEmpty {
                    IconButton(symbol: model.isFavorited ? "star.fill" : "star",
                               help: model.isFavorited ? "从生词本移除" : "收藏到生词本",
                               tint: model.isFavorited ? Theme.favorite : nil,
                               bounce: favoriteBounce) { toggleFavorite() }
                }
                IconButton(symbol: model.pinned ? "pin.fill" : "pin", help: model.pinned ? "取消固定" : "固定浮窗",
                           tint: model.pinned ? Theme.accent : nil) { model.pinned.toggle() }
                IconButton(symbol: "xmark", help: "关闭（Esc）") { onClose() }
            }
            .fixedSize()
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
                Button("加入生词本") { toggleFavorite() }
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

    /// 收藏时让星标弹一下；取消收藏不弹。
    private func toggleFavorite() {
        if !model.isFavorited { favoriteBounce += 1 }
        model.toggleFavorite()
    }

    // MARK: 场景、参考资料、来源

    private var showMetaBar: Bool {
        !model.source.isEmpty || model.fromImage
    }

    private var metaBar: some View {
        HStack(spacing: Theme.gapS) {
            sceneMenu
            if !model.retrieval.isEmpty {
                Button { showReferences.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "books.vertical")
                        Text("参考 \(model.retrieval.glossary.count + model.retrieval.passages.count)")
                    }
                }
                .buttonStyle(ChipStyle())
                .help("这次翻译参考了术语表和资料库")
                .popover(isPresented: $showReferences, arrowEdge: .bottom) { referenceList }
            }
            if bilingualAvailable {
                Button { withAnimation(reduceMotion ? nil : Theme.quick) { bilingual.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.alignleft")
                        Text("对照")
                    }
                }
                .buttonStyle(ChipStyle(active: bilingual))
                .help("原文和译文逐段对照")
            }
            Spacer(minLength: 0)
            if let origin = model.origin {
                Text(displayOrigin(origin))
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(displayOrigin(origin))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var sceneMenu: some View {
        Menu {
            Section("翻译场景") {
                ForEach(SceneStore.shared.scenes) { scene in
                    Button {
                        model.changeScene(scene.id)
                    } label: {
                        if scene.id == model.scene.id {
                            Label(scene.name, systemImage: "checkmark")
                        } else {
                            Text(scene.name)
                        }
                    }
                }
            }
            if let keyword = model.rememberKeyword {
                Divider()
                Button("以后「\(keyword)」都用「\(model.scene.name)」") { model.rememberScene() }
            }
            Divider()
            Button("管理场景和资料库…") {
                Windows.showLibrary()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "theatermasks")
                Text(model.scene.name)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(ChipStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("翻译场景：不同场景用不同的翻译要求，换一个会重新翻译")
    }

    private var referenceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                if !model.retrieval.glossary.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.gapXS) {
                        SectionLabel("术语表")
                        ForEach(model.retrieval.glossary, id: \.self) { entry in
                            Text("\(entry.source) = \(entry.target)")
                                .font(Theme.body)
                                .textSelection(.enabled)
                        }
                    }
                }
                ForEach(model.retrieval.passages) { passage in
                    VStack(alignment: .leading, spacing: Theme.gapXS) {
                        SectionLabel(passage.docName)
                        Text(passage.text)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Theme.gapM)
            .frame(width: 360, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }

    // MARK: 内容

    /// 长文本的原文：默认收起成三行，展开后可选中。
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("原文")
                Spacer()
                Button(showFullSource ? "收起" : "展开") {
                    withAnimation(reduceMotion ? nil : Theme.expand) { showFullSource.toggle() }
                }
                .buttonStyle(.link)
                .font(Theme.caption)
            }
            if showFullSource {
                LineStack(text: model.source, font: Theme.body, color: .secondary)
            } else {
                Text(paragraphs(model.source).joined(separator: " "))
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .surface()
    }

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
                Button(showFullLocal ? "收起" : "展开全部") {
                    withAnimation(reduceMotion ? nil : Theme.expand) { showFullLocal.toggle() }
                }
                    .buttonStyle(.link)
                    .font(Theme.caption)
            }
        }
        .surface()
    }

    /// 原文、译文段数一致时才能逐段对照（翻译完成后）。
    private var bilingualAvailable: Bool {
        guard model.isLong, !model.isLoading, !model.result.isEmpty else { return false }
        let count = paragraphs(model.source).count
        return count > 1 && count == paragraphs(model.result).count
    }

    private var canShowBilingual: Bool { bilingual && bilingualAvailable }

    @ViewBuilder
    private var aiSection: some View {
        if !model.result.isEmpty || model.isLoading {
            VStack(alignment: .leading, spacing: 6) {
                if model.localDefinition != nil {
                    SectionLabel("AI 释义")
                }
                if model.attempt > 1 && model.isLoading {
                    Label("第一次的输出不像译文，正在重新翻译…", systemImage: "arrow.triangle.2.circlepath")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                if let warning = model.qualityWarning, !model.isLoading {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.repeated)
                        Text("这段译文可能不准确：\(warning)。可以点「重试」，或在设置里换一个更强的模型。")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("重试") { model.retry() }
                            .buttonStyle(.link)
                    }
                    .font(Theme.caption)
                }
                if canShowBilingual {
                    bilingualList
                } else if !model.result.isEmpty {
                    // 单词释义条目多，用正文字号；整句译文用大一号方便阅读
                    LineStack(text: model.result, font: isTerm ? Theme.body : Theme.reading, color: .primary)
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 2)
                    }
                } else {
                    SkeletonLines()
                        .padding(.top, 2)
                }
            }
        }
    }

    private var bilingualList: some View {
        LazyVStack(alignment: .leading, spacing: Theme.gapM) {
            ForEach(Array(zip(paragraphs(model.source), paragraphs(model.result)).enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: Theme.gapXS) {
                    Text(pair.0)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(pair.1)
                        .font(Theme.reading)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .fixedSize(horizontal: false, vertical: true)
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

/// 多行文字逐行渲染（空行变成段落间距），每行可选中。
private struct LineStack: View {
    let text: String
    let font: Font
    let color: Color

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines(text).enumerated()), id: \.offset) { _, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Color.clear.frame(height: 6)
                } else {
                    Text(line)
                        .font(font)
                        .foregroundStyle(color)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 浮窗里的小标签按钮：场景、参考、对照。
struct ChipStyle: ButtonStyle {
    var active = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caption)
            .foregroundStyle(active ? Theme.accent : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(active ? Theme.accent.opacity(0.15) : (hovering ? Theme.hover : Theme.surface)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
            .contentShape(Capsule())
    }
}
