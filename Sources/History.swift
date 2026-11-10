import SwiftUI

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var translation = ""
    var count = 1
    var firstAt = Date()
    var lastAt = Date()
    /// 最近一次查询时的原句和来源
    var context: String?
    var origin: String?
}

/// 查词历史：保存在 ~/Library/Application Support/Fanyi/history.json，最近查询的排在前面。
@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored private let limit = 2000

    @ObservationIgnored private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fanyi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    private func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 记录一次查询，返回这是第几次查（未开启历史时返回 0）。
    func record(_ text: String, context: String? = nil, origin: String? = nil) -> Int {
        guard Settings.historyEnabled else { return 0 }
        let k = key(text)
        var entry: HistoryEntry
        if let index = entries.firstIndex(where: { key($0.text) == k }) {
            entry = entries.remove(at: index)
            entry.count += 1
            entry.lastAt = Date()
        } else {
            entry = HistoryEntry(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let context { entry.context = context }
        if let origin { entry.origin = origin }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
        return entry.count
    }

    func updateTranslation(_ text: String, translation: String) {
        let k = key(text)
        guard !translation.isEmpty, let index = entries.firstIndex(where: { key($0.text) == k }) else { return }
        entries[index].translation = translation
        persist()
    }

    func remove(id: HistoryEntry.ID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct HistoryView: View {
    private var store: HistoryStore { .shared }
    private var vocabulary: VocabularyStore { .shared }
    @State private var query = ""
    @State private var selection: HistoryEntry.ID?
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.text.localizedCaseInsensitiveContains(query) || $0.translation.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("搜索历史", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)

                if filtered.isEmpty {
                    Spacer()
                    Text(store.entries.isEmpty ? (Settings.historyEnabled ? "还没有查词记录" : "查词历史已关闭，可在设置中开启") : "没有符合条件的记录")
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
                HStack {
                    Text("共 \(store.entries.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空历史…") { confirmClear = true }
                        .controlSize(.small)
                        .disabled(store.entries.isEmpty)
                }
                .padding(6)
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)

            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 400)
        .confirmationDialog("清空全部查词历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                store.clear()
                selection = nil
            }
        } message: {
            Text("生词本不受影响。此操作无法撤销。")
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(entry.text)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if vocabulary.contains(entry.text) {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                    }
                }
                Text(entry.translation.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                if entry.count > 1 {
                    Text("\(entry.count) 次")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(entry.count >= 3 ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.15)))
                }
                Text(entry.lastAt, format: .relative(presentation: .named))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func actions(for entry: HistoryEntry) -> some View {
        favoriteButton(entry)
        Button("复制原文") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
        }
        Divider()
        Button("删除", role: .destructive) { store.remove(id: entry.id) }
    }

    private func favoriteButton(_ entry: HistoryEntry) -> some View {
        let favorited = vocabulary.contains(entry.text)
        return Button(favorited ? "从生词本移除" : "加入生词本") {
            if favorited {
                vocabulary.remove(text: entry.text)
            } else {
                vocabulary.save(text: entry.text, translation: entry.translation, context: entry.context, origin: entry.origin)
            }
        }
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
                        if let context = entry.context {
                            Text(highlighted(context, term: entry.text))
                                .font(.system(size: 13))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                        }
                        Text(entry.translation.isEmpty ? "（没有保存译文）" : entry.translation)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                        if let origin = entry.origin {
                            Text("来源：\(origin)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("共查询 \(entry.count) 次 · 首次 \(entry.firstAt.formatted(date: .abbreviated, time: .shortened)) · 最近 \(entry.lastAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                }
                Divider()
                HStack {
                    favoriteButton(entry)
                    Spacer()
                    Button("删除", role: .destructive) {
                        store.remove(id: entry.id)
                        selection = nil
                    }
                }
                .padding(10)
            }
        } else {
            Text("选择左侧的记录查看详情")
                .foregroundStyle(.secondary)
        }
    }
}
