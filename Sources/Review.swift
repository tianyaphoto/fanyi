import SwiftUI

// 轻量复习：每天从生词本里抽几个到期的词，先看原句回想意思，再翻开看释义，点「记得 / 忘了」。
// 间隔固定（1、3、7、14、30 天），不做完整的记忆算法；每天默认只给 5 个，免得越攒越多。
// 想认真背的，用生词本里的「导出到 Anki」。

extension VocabularyStore {
    /// 记得一次，下次隔多少天再出现；全部走完就标记为已掌握。
    static let reviewIntervals: [Double] = [1, 3, 7, 14, 30]
    static let dailyLimit = 5

    private static let dayKey = "review.day"
    private static let doneKey = "review.doneToday"

    private static func dayStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 什么时候该复习：没复习过的，收藏满一天后。
    func dueDate(_ entry: VocabEntry) -> Date {
        entry.nextReview ?? entry.createdAt.addingTimeInterval(86400)
    }

    /// 到期的生词，最早到期的排前面。
    func dueEntries(now: Date = Date()) -> [VocabEntry] {
        entries.filter { !$0.mastered && dueDate($0) <= now }.sorted { dueDate($0) < dueDate($1) }
    }

    var reviewedToday: Int {
        UserDefaults.standard.string(forKey: Self.dayKey) == Self.dayStamp() ? UserDefaults.standard.integer(forKey: Self.doneKey) : 0
    }

    /// 今天还该复习的（到期的里取前几个，扣掉今天已经复习的）。
    func todayQueue(now: Date = Date()) -> [VocabEntry] {
        Array(dueEntries(now: now).prefix(max(0, Self.dailyLimit - reviewedToday)))
    }

    /// 记录一次复习结果。记得：进下一个间隔，走完全部间隔就算掌握；忘了：从头来，明天再出现。
    func review(id: VocabEntry.ID, remembered: Bool, now: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        if remembered {
            let stage = entry.reviewStage ?? 0
            if stage >= Self.reviewIntervals.count - 1 {
                entry.mastered = true
                entry.nextReview = nil
            } else {
                entry.nextReview = now.addingTimeInterval(Self.reviewIntervals[stage + 1] * 86400)
            }
            entry.reviewStage = stage + 1
        } else {
            entry.reviewStage = 0
            entry.nextReview = now.addingTimeInterval(Self.reviewIntervals[0] * 86400)
        }
        update(entry)
        let done = reviewedToday + 1
        UserDefaults.standard.set(Self.dayStamp(), forKey: Self.dayKey)
        UserDefaults.standard.set(done, forKey: Self.doneKey)
    }
}

/// 学习数字：菜单和复习窗口共用。
@MainActor
enum LearningStats {
    /// 最近 7 天查过的词和句子数（同一个词查多次算一个）。
    static var lookedUpThisWeek: Int {
        let since = Date().addingTimeInterval(-7 * 86400)
        return HistoryStore.shared.entries.filter { $0.lastAt >= since }.count
    }

    /// 反复查的词：查过 2 次以上的单词或短语，按次数排。
    static func repeated(limit: Int = 10) -> [HistoryEntry] {
        Array(HistoryStore.shared.entries
            .filter { $0.count >= 2 && $0.text.count <= 40 && !$0.text.contains("\n") }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastAt > $1.lastAt }
            .prefix(limit))
    }

    static var menuLine: String {
        let store = VocabularyStore.shared
        return "本周查了 \(lookedUpThisWeek) 个词 · 生词本 \(store.entries.count) 条（已掌握 \(store.entries.filter(\.mastered).count)）"
    }
}

/// 每天第一次翻译时，如果有到期的生词，轻轻提醒一次（不抢焦点的短提示）。
@MainActor
enum ReviewReminder {
    static let enabledKey = "review.reminder"
    private static let nudgedKey = "review.nudgedDay"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static func nudgeIfNeeded() {
        guard enabled, !FanyiApp.isDevRun else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        guard UserDefaults.standard.string(forKey: nudgedKey) != today else { return }
        let due = VocabularyStore.shared.todayQueue().count
        guard due > 0 else { return }
        UserDefaults.standard.set(today, forKey: nudgedKey)
        Task {
            // 等翻译浮窗先出来，再在屏幕上方提示
            try? await Task.sleep(for: .seconds(2))
            Toast.shared.show("今天有 \(due) 个生词该复习了：菜单栏图标 → 今日复习", seconds: 5)
        }
    }
}

struct ReviewView: View {
    private var store: VocabularyStore { .shared }
    private var history: HistoryStore { .shared }
    /// 打开窗口时定下这一轮要复习的词（复习过程中不变）
    @State private var queue: [VocabEntry.ID] = []
    @State private var position = 0
    @State private var revealed = false
    @State private var remembered = 0
    @State private var started = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: VocabEntry? {
        guard position < queue.count else { return nil }
        return store.entries.first { $0.id == queue[position] }
    }

    var body: some View {
        HSplitView {
            reviewPane
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            statsPane
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 320, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear { if !started { startRound(extra: false) } }
    }

    private func startRound(extra: Bool) {
        let due = store.dueEntries()
        queue = (extra ? Array(due.prefix(VocabularyStore.dailyLimit)) : store.todayQueue()).map(\.id)
        position = 0
        revealed = false
        remembered = 0
        started = true
    }

    private func answer(_ ok: Bool) {
        guard let entry = current else { return }
        store.review(id: entry.id, remembered: ok)
        if ok { remembered += 1 }
        withAnimation(reduceMotion ? nil : Theme.quick) {
            position += 1
            revealed = false
        }
    }

    // MARK: 复习

    @ViewBuilder
    private var reviewPane: some View {
        if let entry = current {
            VStack(alignment: .leading, spacing: Theme.gapL) {
                HStack {
                    SectionLabel("今日复习")
                    Spacer()
                    Text("\(position + 1) / \(queue.count)")
                        .font(Theme.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.gapM) {
                        if let context = entry.context {
                            Text(highlighted(context, term: entry.text))
                                .font(Theme.reading)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                        }
                        Text(entry.text)
                            .font(Theme.title)
                            .textSelection(.enabled)
                        if revealed {
                            let parts = Translator.splitMemory(entry.translation)
                            Text(parts.definition.isEmpty ? "没有保存译文。" : parts.definition)
                                .font(Theme.body)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                            if let memory = parts.memory, !memory.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    SectionLabel("帮你记住")
                                    Text(memory).font(Theme.body).lineSpacing(4).textSelection(.enabled)
                                }
                                .surface()
                            }
                            if let origin = entry.origin {
                                Text("来自 \(displayOrigin(origin))")
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(entry.context == nil ? "先想一想它是什么意思，再翻开看。" : "先想一想它在这句话里是什么意思，再翻开看。")
                                .font(Theme.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if revealed {
                        Button("忘了") { answer(false) }
                            .keyboardShortcut("1", modifiers: [])
                            .help("明天再出现（按 1）")
                        Spacer()
                        Button("记得") { answer(true) }
                            .keyboardShortcut(.defaultAction)
                            .help("隔更久再出现（按回车）")
                    } else {
                        Spacer()
                        Button("翻开看释义") { withAnimation(reduceMotion ? nil : Theme.expand) { revealed = true } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .controlSize(.large)
            }
            .padding(18)
        } else {
            finished
        }
    }

    @ViewBuilder
    private var finished: some View {
        let moreDue = store.dueEntries().count
        if store.entries.isEmpty {
            EmptyState(title: "生词本还是空的",
                       detail: "翻译时点一下星标收藏生词，第二天起这里每天给你 \(VocabularyStore.dailyLimit) 个复习。",
                       actionTitle: "输入翻译") { Coordinator.shared.showInput() }
        } else if queue.isEmpty && moreDue == 0 {
            EmptyState(title: "今天没有要复习的",
                       detail: "新收藏的生词第二天开始出现；记得的词会隔 1、3、7、14、30 天再出现，全部记得就算掌握。",
                       actionTitle: "打开生词本") { Windows.showVocabulary() }
        } else {
            EmptyState(title: queue.isEmpty ? "今天的 \(VocabularyStore.dailyLimit) 个已经复习完了" : "这一轮复习完了：记得 \(remembered) / \(queue.count)",
                       detail: moreDue > 0 ? "还有 \(moreDue) 个到期的生词，可以再来一轮，也可以明天再说。" : "到期的生词都复习完了。",
                       actionTitle: moreDue > 0 ? "再来 \(min(moreDue, VocabularyStore.dailyLimit)) 个" : "打开生词本") {
                if moreDue > 0 { startRound(extra: true) } else { Windows.showVocabulary() }
            }
        }
    }

    // MARK: 统计

    private var statsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapL) {
                VStack(alignment: .leading, spacing: Theme.gapS) {
                    SectionLabel("学习统计")
                    stat("最近 7 天查过", "\(LearningStats.lookedUpThisWeek) 个词 / 句")
                    stat("生词本", "\(store.entries.count) 条")
                    stat("已掌握", "\(store.entries.filter(\.mastered).count) 条")
                    stat("到期待复习", "\(store.dueEntries().count) 条")
                }
                let repeated = LearningStats.repeated()
                VStack(alignment: .leading, spacing: Theme.gapS) {
                    SectionLabel("反复查的词")
                    if repeated.isEmpty {
                        Text(Settings.historyEnabled ? "还没有查过两次以上的词。" : "查词历史已关闭，没有数据。")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(repeated) { entry in
                        HStack(spacing: 6) {
                            Text(entry.text).font(Theme.body).lineLimit(1)
                            Text("×\(entry.count)").font(Theme.caption).monospacedDigit().foregroundStyle(Theme.repeated)
                            Spacer(minLength: 0)
                            let saved = store.contains(entry.text)
                            Button {
                                if saved {
                                    store.remove(text: entry.text)
                                } else {
                                    store.save(text: entry.text, translation: entry.translation, context: entry.context, origin: entry.origin)
                                }
                            } label: {
                                Image(systemName: saved ? "star.fill" : "star")
                                    .foregroundStyle(saved ? Theme.favorite : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(saved ? "已在生词本里，点一下移除" : "收进生词本")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .background(Theme.surface)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.body).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(Theme.bodyStrong).monospacedDigit()
        }
    }
}
