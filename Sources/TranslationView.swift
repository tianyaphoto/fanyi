import SwiftUI
import AVFoundation

@MainActor
@Observable
final class TranslationModel {
    var source = ""
    var result = ""
    var localDefinition: String?
    var isLoading = false
    var errorMessage: String?
    var needsAPIKey = false
    var pinned = false
    var isFavorited = false
    /// 这是第几次查这个词（0 表示未记录历史）。
    var lookupCount = 0

    /// 输入翻译模式：浮窗顶部显示输入框。
    var inputMode = false
    var inputText = ""
    var focusRequest = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let speaker = AVSpeechSynthesizer()

    func translate(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancel()
        source = text
        result = ""
        errorMessage = nil
        needsAPIKey = false
        isFavorited = VocabularyStore.shared.contains(text)
        localDefinition = LocalDictionary.lookup(text)
        lookupCount = HistoryStore.shared.record(text)

        isLoading = true
        task = Task {
            do {
                for try await chunk in Translator.stream(text: text) {
                    result += chunk
                }
                if Task.isCancelled { return }
                HistoryStore.shared.updateTranslation(text, translation: result)
                if isFavorited { VocabularyStore.shared.save(text: text, translation: result) }
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
        translate(inputText)
    }

    func showMessage(_ message: String) {
        cancel()
        inputMode = false
        reset()
        errorMessage = message
    }

    private func reset() {
        source = ""
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
            VocabularyStore.shared.save(text: source, translation: result.isEmpty ? (localDefinition ?? "") : result)
        }
        isFavorited.toggle()
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
                VStack(alignment: .leading, spacing: 12) {
                    if let local = model.localDefinition {
                        localSection(local)
                    }
                    aiSection
                    if let error = model.errorMessage {
                        Text(error)
                            .foregroundStyle(model.source.isEmpty ? Color.primary : Color.red)
                            .textSelection(.enabled)
                        if model.needsAPIKey {
                            Button("打开设置") {
                                onClose()
                                Windows.showSettings()
                            }
                        }
                    }
                    if model.inputMode && model.source.isEmpty && model.errorMessage == nil {
                        Text("输入单词或句子后按 ↩ 翻译，⌥↩ 换行")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
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

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.inputMode {
                TextField("输入要翻译的内容", text: $model.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { model.submitInput() }
                    .onExitCommand { onClose() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(model.source.isEmpty ? "翻译神器" : model.source)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 2) {
                if !model.source.isEmpty {
                    iconButton("speaker.wave.2", help: "朗读原文") { model.speak() }
                    iconButton("doc.on.doc", help: "复制译文") { model.copyResult() }
                        .disabled(model.result.isEmpty && model.localDefinition == nil)
                    iconButton(model.isFavorited ? "star.fill" : "star",
                               help: model.isFavorited ? "从生词本移除" : "收藏到生词本",
                               tint: model.isFavorited ? .yellow : nil) { model.toggleFavorite() }
                }
                iconButton(model.pinned ? "pin.fill" : "pin", help: model.pinned ? "取消固定" : "固定浮窗",
                           tint: model.pinned ? .accentColor : nil) { model.pinned.toggle() }
                iconButton("xmark", help: "关闭（Esc）") { onClose() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var repeatHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
            Text("这是你第 \(model.lookupCount) 次查询")
            Spacer()
            if !model.isFavorited {
                Button("加入生词本") { model.toggleFavorite() }
                    .buttonStyle(.link)
            } else {
                Text("已在生词本中").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(model.lookupCount >= 3 ? 0.18 : 0.10))
    }

    // MARK: 内容

    private func localSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("系统词典", systemImage: "book.closed")
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .lineLimit(showFullLocal ? nil : 6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if text.split(separator: "\n").count > 6 || text.count > 300 {
                Button(showFullLocal ? "收起" : "展开全部") { showFullLocal.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private var aiSection: some View {
        if !model.result.isEmpty || model.isLoading {
            VStack(alignment: .leading, spacing: 6) {
                if model.localDefinition != nil {
                    sectionLabel("AI 释义", systemImage: "sparkles")
                }
                if !model.result.isEmpty {
                    Text(model.result)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("翻译中…").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func iconButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
