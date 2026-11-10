import SwiftUI

struct VocabEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var translation: String
    var createdAt = Date()
    var mastered = false
    /// 收藏时所在的原句
    var context: String?
    /// 来源 App / 文档，例如「预览 · paper.pdf」
    var origin: String?
}

/// 生词本：保存在 ~/Library/Application Support/Fanyi/vocabulary.json
@MainActor
@Observable
final class VocabularyStore {
    static let shared = VocabularyStore()

    private(set) var entries: [VocabEntry] = []

    @ObservationIgnored private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fanyi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    func remove(id: VocabEntry.ID) {
        entries.removeAll { $0.id == id }
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
                VStack(spacing: 8) {
                    TextField("搜索生词或释义", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(10)

                if filtered.isEmpty {
                    Spacer()
                    Text(store.entries.isEmpty ? "还没有收藏。\n翻译时点击 ☆ 即可加入生词本。" : "没有符合条件的生词")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(filtered, selection: $selection) { entry in
                        row(entry)
                            .tag(entry.id)
                            .contextMenu { actions(for: entry) }
                    }
                }

                Divider()
                Text("共 \(store.entries.count) 条，已掌握 \(store.entries.filter(\.mastered).count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)

            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 400)
        .onChange(of: selection) { editingContext = false }
    }

    private func contextSection(_ entry: VocabEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("原句", systemImage: "text.quote")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
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
            .font(.system(size: 11))

            if editingContext {
                TextField("粘贴这个词所在的句子", text: $contextDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
            } else if let context = entry.context {
                Text(highlighted(context, term: entry.text))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
            } else {
                Text("收藏时没有读取到原句，可以手动添加")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func row(_ entry: VocabEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text(entry.translation.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let context = entry.context {
                    Text(highlighted(context, term: entry.text))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if entry.mastered {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func actions(for entry: VocabEntry) -> some View {
        Button(entry.mastered ? "标记为未掌握" : "标记为已掌握") { store.toggleMastered(id: entry.id) }
        Button("复制原文") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
        }
        Divider()
        Button("删除", role: .destructive) { store.remove(id: entry.id) }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = store.entries.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(entry.text)
                            .font(.system(size: 20, weight: .semibold))
                            .textSelection(.enabled)
                        contextSection(entry)
                        Text(entry.translation.isEmpty ? "（没有保存译文）" : entry.translation)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                        Text((entry.origin.map { "来自 \($0) · " } ?? "") + "收藏于 \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                }
                Divider()
                HStack {
                    Button(entry.mastered ? "标记为未掌握" : "标记为已掌握") { store.toggleMastered(id: entry.id) }
                    Spacer()
                    Button("删除", role: .destructive) {
                        store.remove(id: entry.id)
                        selection = nil
                    }
                }
                .padding(10)
            }
        } else {
            Text("选择左侧的生词查看详情")
                .foregroundStyle(.secondary)
        }
    }
}
