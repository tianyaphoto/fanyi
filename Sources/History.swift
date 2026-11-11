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

    /// 删除一条，返回它原来的位置，供撤销时放回。
    @discardableResult
    func remove(id: HistoryEntry.ID) -> Int? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries.remove(at: index)
        persist()
        return index
    }

    func restore(_ entry: HistoryEntry, at index: Int) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.insert(entry, at: min(max(index, 0), entries.count))
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
    @State private var removed: (entry: HistoryEntry, index: Int)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

                if store.entries.isEmpty {
                    if Settings.historyEnabled {
                        EmptyState(title: "还没有查词记录",
                                   detail: "每次查词都会记在这里。同一个词查了几次会标出来，方便发现该收藏的生词。",
                                   actionTitle: "输入翻译") { Coordinator.shared.showInput() }
                    } else {
                        EmptyState(title: "查词历史已关闭",
                                   detail: "打开后，查过的词和重复查询的次数会记在这里，只保存在本机。",
                                   actionTitle: "打开设置") { Windows.showSettings() }
                    }
                } else if filtered.isEmpty {
                    EmptyState(title: "没有符合条件的记录",
                               detail: "换一个关键词再试。",
                               actionTitle: "清除搜索") { query = "" }
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
                    HStack {
                        Text("共 \(store.entries.count) 条")
                            .font(Theme.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("清空历史…") { confirmClear = true }
                            .controlSize(.small)
                            .disabled(store.entries.isEmpty)
                    }
                    .padding(6)
                    .transition(.opacity)
                }
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
                removed = nil
            }
        } message: {
            Text("生词本不受影响。此操作无法撤销。")
        }
    }

    private func delete(_ entry: HistoryEntry) {
        if selection == entry.id { selection = nil }
        withAnimation(listAnimation) {
            guard let index = store.remove(id: entry.id) else { return }
            removed = (entry, index)
        }
    }

    /// 行的删除和恢复、撤销条的出现；开了「减弱动态效果」时不移动列表行。
    private var listAnimation: Animation? { reduceMotion ? nil : Theme.quick }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: Theme.gapS) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.gapXS) {
                    Text(entry.text)
                        .font(Theme.bodyStrong)
                        .lineLimit(1)
                    if vocabulary.contains(entry.text) {
                        Image(systemName: "star.fill")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.favorite)
                            .accessibilityLabel("已在生词本中")
                    }
                }
                Text(entry.translation.replacingOccurrences(of: "\n", with: " "))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                if entry.count > 1 {
                    Text("\(entry.count) 次")
                        .font(Theme.captionStrong)
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(entry.count >= 3 ? Theme.repeated.opacity(0.25) : Theme.surface))
                }
                Text(entry.lastAt, format: .relative(presentation: .named))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
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
        Button("删除", role: .destructive) { delete(entry) }
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

    private func meta(_ entry: HistoryEntry) -> MetaList {
        var rows: [(label: String, value: String)] = [("查询次数", "\(entry.count) 次")]
        if entry.count > 1 {
            rows.append(("首次查询", entry.firstAt.formatted(date: .abbreviated, time: .shortened)))
        }
        rows.append(("最近查询", entry.lastAt.formatted(date: .abbreviated, time: .shortened)))
        if let origin = entry.origin { rows.append(("来源", displayOrigin(origin))) }
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
                        if let context = entry.context {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionLabel("原句")
                                Text(highlighted(context, term: entry.text))
                                    .font(Theme.reading)
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                            }
                            .surface()
                        }
                        Text(entry.translation.isEmpty ? "没有保存译文。" : entry.translation)
                            .font(Theme.body)
                            .lineSpacing(4)
                            .foregroundStyle(entry.translation.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                        meta(entry)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                }
                Divider()
                HStack {
                    favoriteButton(entry)
                    Spacer()
                    Button("删除", role: .destructive) { delete(entry) }
                }
                .padding(10)
            }
        } else if !store.entries.isEmpty {
            Text("选择左侧的记录查看详情")
                .font(Theme.body)
                .foregroundStyle(.secondary)
        } else {
            Color.clear
        }
    }
}
