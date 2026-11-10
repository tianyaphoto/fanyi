import SwiftUI
import AVFoundation

@MainActor
@Observable
final class TranslationModel {
    var source = ""
    var result = ""
    var isLoading = false
    var errorMessage: String?
    var needsAPIKey = false
    var pinned = false
    var isFavorited = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let speaker = AVSpeechSynthesizer()

    func translate(_ text: String) {
        cancel()
        source = text
        result = ""
        errorMessage = nil
        needsAPIKey = false
        isFavorited = VocabularyStore.shared.contains(text)

        isLoading = true
        task = Task {
            do {
                for try await chunk in Translator.stream(text: text) {
                    result += chunk
                }
                if Task.isCancelled { return }
                if isFavorited { VocabularyStore.shared.save(text: text, translation: result) }
            } catch {
                if Task.isCancelled { return }
                errorMessage = error.localizedDescription
                needsAPIKey = (error as? TranslateError)?.needsSetup ?? false
            }
            isLoading = false
        }
    }

    func showMessage(_ message: String) {
        cancel()
        source = ""
        result = ""
        needsAPIKey = false
        isFavorited = false
        errorMessage = message
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
            VocabularyStore.shared.save(text: source, translation: result)
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
        NSPasteboard.general.setString(result, forType: .string)
    }
}

struct TranslationView: View {
    @Bindable var model: TranslationModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.result.isEmpty {
                        Text(model.result)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if model.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("翻译中…").foregroundStyle(.secondary)
                        }
                    }
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
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(model.source.isEmpty ? "翻译神器" : model.source)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                if !model.source.isEmpty {
                    iconButton("speaker.wave.2", help: "朗读原文") { model.speak() }
                    iconButton("doc.on.doc", help: "复制译文") { model.copyResult() }
                        .disabled(model.result.isEmpty)
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
