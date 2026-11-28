import SwiftUI

struct VocabEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var translation: String
    var createdAt = Date()
    var mastered = false
    /// 收藏时所在的原句
    var context: String?
    /// 来源 App / 文档，例如「预览：paper.pdf」
    var origin: String?
    /// 复习进度：已经连续记得几次、下次什么时候复习（旧数据没有这两项，所以是可选的）
    var reviewStage: Int?
    var nextReview: Date?
}

/// 生词本：保存在 ~/Library/Application Support/Fanyi/vocabulary.json
@MainActor
@Observable
final class VocabularyStore {
    static let shared = VocabularyStore()

    private(set) var entries: [VocabEntry] = []

    @ObservationIgnored private let fileURL: URL = {
        let dir = SelfTest.dataDirectory
        return dir.appendingPathComponent("vocabulary.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([VocabEntry].self, from: data) {
            entries = decoded
        }
    }

    private func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func contains(_ text: String) -> Bool {
        let k = key(text)
        return entries.contains { key($0.text) == k }
    }

    /// 新增；如果已存在则更新译文（以及新的原句、来源）。
    func save(text: String, translation: String, context: String? = nil, origin: String? = nil) {
        let k = key(text)
        if let index = entries.firstIndex(where: { key($0.text) == k }) {
            if !translation.isEmpty { entries[index].translation = translation }
            if let context { entries[index].context = context }
            if let origin { entries[index].origin = origin }
        } else {
            entries.insert(VocabEntry(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                      translation: translation, context: context, origin: origin), at: 0)
        }
        persist()
    }

    func updateContext(id: VocabEntry.ID, context: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].context = trimmed.isEmpty ? nil : trimmed
        persist()
    }

    func remove(text: String) {
        let k = key(text)
        entries.removeAll { key($0.text) == k }
        persist()
    }

    /// 删除一条，返回它原来的位置，供撤销时放回。
    @discardableResult
    func remove(id: VocabEntry.ID) -> Int? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries.remove(at: index)
        persist()
        return index
    }

    func restore(_ entry: VocabEntry, at index: Int) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.insert(entry, at: min(max(index, 0), entries.count))
        persist()
    }

    /// 整条替换（复习时更新进度用）。
    func update(_ entry: VocabEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        persist()
    }

    func toggleMastered(id: VocabEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].mastered.toggle()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct VocabularyView: View {
    private enum Filter: String, CaseIterable {
        case all = "全部", learning = "未掌握", mastered = "已掌握"
    }

    private var store = VocabularyStore.shared
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var selection: VocabEntry.ID?
    @State private var editingContext = false
    @State private var contextDraft = ""
    @State private var removed: (entry: VocabEntry, index: Int)?
    @State private var exporting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 发到 Anki：Anki 没开或没装插件时，改为导出文件。
    private func sendToAnki(_ entries: [VocabEntry]) {
        exporting = true
        Task {
            defer { exporting = false }
            guard await AnkiExport.isAvailable() else {
                let alert = NSAlert()
                alert.messageText = "没有连上 Anki"
                alert.informativeText = "直接制卡需要 Anki 开着，并装了 AnkiConnect 插件（Anki → 工具 → 插件 → 获取插件，代码 2055492159，装完重启 Anki）。\n\n也可以先导出成文件，再在 Anki 里用「文件 → 导入」。"
                alert.addButton(withTitle: "导出成文件…")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn { AnkiExport.saveFile(entries) }
                return
            }
            do {
                let summary = try await AnkiExport.send(entries)
                let skipped = summary.duplicates > 0 ? "，\(summary.duplicates) 条 Anki 里已经有了" : ""
                Toast.shared.show("已发到 Anki 的「\(AnkiExport.deckName)」牌组：新增 \(summary.added) 条\(skipped)", seconds: 5)
            } catch {
                Toast.shared.show("发到 Anki 失败：\(error.localizedDescription)", style: .error, seconds: 6)
            }
        }
    }

    private var filtered: [VocabEntry] {
        store.entries.filter { entry in
            switch filter {
            case .all: break
            case .learning: if entry.mastered { return false }
            case .mastered: if !entry.mastered { return false }
            }
            guard !query.isEmpty else { return true }
            return entry.text.localizedCaseInsensitiveContains(query)
                || entry.translation.localizedCaseInsensitiveContains(query)
                || (entry.context?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: Theme.gapS) {
                    TextField("搜索生词、释义或原句", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(10)

                if store.entries.isEmpty {
                    EmptyState(title: "生词本还是空的",
                               detail: "翻译时点一下星标，这个词会连同它所在的原句一起收进来，方便回头复习。",
                               actionTitle: "输入翻译") { Coordinator.shared.showInput() }
                } else if filtered.isEmpty {
                    EmptyState(title: "没有符合条件的生词",
                               detail: "换一个关键词，或者切回「全部」。",
                               actionTitle: "清除筛选") {
                        query = ""
                        filter = .all
                    }
                } else {
                    List(filtered, selection: $selection) { entry in
                        row(entry)
                            .tag(entry.id)
                            .contextMenu { actions(for: entry) }
                    }
                }

                Divider()
                if let removed {
                    UndoBar(message: "已删除「\(removed.entry.text)」") {
                        withAnimation(listAnimation) {
                            store.restore(removed.entry, at: removed.index)
                            self.removed = nil
                        }
                        selection = removed.entry.id
                    }
                    .task(id: removed.entry.id) {
                        try? await Task.sleep(for: .seconds(8))
                        if !Task.isCancelled { withAnimation(Theme.quick) { self.removed = nil } }
                    }
                } else {
                    HStack(spacing: Theme.gapS) {
                        Text("共 \(store.entries.count) 条，已掌握 \(store.entries.filter(\.mastered).count) 条")
                            .font(Theme.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if exporting { ProgressView().controlSize(.small) }
                        Menu("导出") {
                            Button("发到 Anki（当前列表的 \(filtered.count) 条）") { sendToAnki(filtered) }
                            Button("导出成文件…") { AnkiExport.saveFile(filtered) }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(Theme.caption)
                        .disabled(filtered.isEmpty || exporting)
                        .help("把当前列表里的生词做成 Anki 卡片：正面是原句和生词，背面是释义")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .transition(.opacity)
                }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)

            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 400)
        .onChange(of: selection) { editingContext = false }
    }

    private func delete(_ entry: VocabEntry) {
        if selection == entry.id { selection = nil }
        withAnimation(listAnimation) {
            guard let index = store.remove(id: entry.id) else { return }
            removed = (entry, index)
        }
    }

    /// 行的删除和恢复、撤销条的出现；开了「减弱动态效果」时不移动列表行。
    private var listAnimation: Animation? { reduceMotion ? nil : Theme.quick }

    /// 标记为已掌握是少见的成就时刻，对勾弹入一次。
    private func toggleMastered(_ entry: VocabEntry) {
        withAnimation(reduceMotion ? Theme.quick : Theme.celebrate) { store.toggleMastered(id: entry.id) }
    }

    /// 列表行：生词，下面是它所在的原句（没有原句时显示释义）。
    private func row(_ entry: VocabEntry) -> some View {
        HStack(spacing: Theme.gapS) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(Theme.bodyStrong)
                    .lineLimit(2)
                if let context = entry.context {
                    Text(highlighted(context, term: entry.text))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(Translator.splitMemory(entry.translation).definition.replacingOccurrences(of: "\n", with: " "))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if entry.mastered {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                    .accessibilityLabel("已掌握")
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func actions(for entry: VocabEntry) -> some View {
        Button(entry.mastered ? "标记为未掌握" : "标记为已掌握") { toggleMastered(entry) }
        Button("复制原文") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
        }
        Divider()
        Button("删除", role: .destructive) { delete(entry) }
    }

    private func contextSection(_ entry: VocabEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("原句")
                Spacer()
                if editingContext {
                    Button("取消") { editingContext = false }
                        .buttonStyle(.link)
                    Button("保存") {
                        store.updateContext(id: entry.id, context: contextDraft)
                        editingContext = false
                    }
                    .buttonStyle(.link)
                } else {
                    Button(entry.context == nil ? "添加原句" : "编辑") {
                        contextDraft = entry.context ?? ""
                        editingContext = true
                    }
                    .buttonStyle(.link)
                }
            }
            .font(Theme.caption)

            if editingContext {
                TextField("粘贴这个词所在的句子", text: $contextDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
            } else if let context = entry.context {
                Text(highlighted(context, term: entry.text))
                    .font(Theme.reading)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            } else {
                Text("收藏时没有读取到原句，可以手动添加。")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
            }
        }
        .surface()
    }

    private func meta(_ entry: VocabEntry) -> MetaList {
        var rows: [(label: String, value: String)] = []
        if let origin = entry.origin { rows.append(("来源", displayOrigin(origin))) }
        rows.append(("收藏于", entry.createdAt.formatted(date: .abbreviated, time: .shortened)))
        return MetaList(rows: rows)
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = store.entries.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.gapL) {
                        Text(entry.text)
                            .font(Theme.title)
                            .textSelection(.enabled)
                        contextSection(entry)
                        let parts = Translator.splitMemory(entry.translation)
                        Text(parts.definition.isEmpty ? "没有保存译文。" : parts.definition)
                            .font(Theme.body)
                            .lineSpacing(4)
                            .foregroundStyle(parts.definition.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                        if let memory = parts.memory, !memory.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionLabel("帮你记住")
                                Text(memory)
                                    .font(Theme.body)
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                            }
                            .surface()
                        }
                        meta(entry)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                }
                Divider()
                HStack {
                    Button(entry.mastered ? "标记为未掌握" : "标记为已掌握") { toggleMastered(entry) }
                    Spacer()
                    Button("删除", role: .destructive) { delete(entry) }
                }
                .padding(10)
            }
        } else if !store.entries.isEmpty {
            Text("选择左侧的生词查看详情")
                .font(Theme.body)
                .foregroundStyle(.secondary)
        } else {
            Color.clear
        }
    }
}
