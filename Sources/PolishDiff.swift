import AppKit
import SwiftUI
import ApplicationServices

// 改写完成后的小浮窗：显示改了哪里（删的标红划掉、加的标绿），可以一键撤回、换一种语气。
// 浮窗不抢焦点，输入框的光标留在原处；几秒后自动消失，鼠标移上去时不消失。

// MARK: - 逐词对比

enum TextDiff {
    enum Kind { case same, removed, added }

    struct Piece: Equatable {
        var kind: Kind
        var text: String
    }

    /// 拆成词、空白、单个标点（中日韩文字按单字拆）。
    static func tokens(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]|[\p{L}\p{N}_'’]+|\s+|."#,
                                                   options: [.dotMatchesLineSeparators]) else { return [text] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// 逐词对比，相邻的同类片段合并。太长（各超过 3000 个词）时不比，直接返回 nil。
    static func pieces(from old: String, to new: String) -> [Piece]? {
        let a = tokens(old), b = tokens(new)
        guard a.count <= 3000, b.count <= 3000 else { return nil }
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Piece] = []
        func emit(_ kind: Kind, _ text: String) {
            if let last = result.last, last.kind == kind {
                result[result.count - 1].text += text
            } else {
                result.append(Piece(kind: kind, text: text))
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                emit(.removed, a[i]); i += 1
            } else if j < b.count, inserted.contains(j) {
                emit(.added, b[j]); j += 1
            } else if i < a.count, j < b.count {
                emit(.same, b[j]); i += 1; j += 1
            } else {
                break
            }
        }
        return mergeAcrossSpaces(result)
    }

    /// 「改 A、空格不变、改 B」这种被单个空格隔开的相邻改动并成一段（空格同时算进删和加），读起来不碎。
    private static func mergeAcrossSpaces(_ pieces: [Piece]) -> [Piece] {
        var result: [Piece] = []
        var removed = "", added = ""
        func flush() {
            let blank: (String) -> Bool = { $0.allSatisfy(\.isWhitespace) }
            // 只有一边有实际内容时，另一边攒下的空格按没改动处理
            if !removed.isEmpty { result.append(Piece(kind: blank(removed) ? .same : .removed, text: removed)) }
            if !added.isEmpty { result.append(Piece(kind: blank(added) ? .same : .added, text: added)) }
            removed = ""; added = ""
        }
        for (index, piece) in pieces.enumerated() {
            switch piece.kind {
            case .removed: removed += piece.text
            case .added: added += piece.text
            case .same:
                let bridging = piece.text == " " && !(removed.isEmpty && added.isEmpty)
                    && index + 1 < pieces.count && pieces[index + 1].kind != .same
                if bridging {
                    removed += " "; added += " "
                } else {
                    flush()
                    result.append(piece)
                }
            }
        }
        flush()
        return result
    }

    /// 改动的比例（按字符）：太大说明是整段重写或翻译，逐词标色没有意义。
    static func changeRatio(_ pieces: [Piece]) -> Double {
        let changed = pieces.filter { $0.kind != .same }.reduce(0) { $0 + $1.text.count }
        let total = pieces.reduce(0) { $0 + $1.text.count }
        return total == 0 ? 0 : Double(changed) / Double(total)
    }
}

// MARK: - 浮窗内容

/// 一次改写的结果，供浮窗显示和撤回 / 换语气用。
struct PolishOutcome {
    var original: String
    var result: String
    var tone: PolishRules.Tone
    /// 改写当前输入框（可以撤回、换语气）；改写剪贴板时只显示对比
    var canReplace: Bool
}

@MainActor
@Observable
final class PolishPanelModel {
    var outcome: PolishOutcome?
    var busy = false
    var hovering = false
}

private struct PolishPanelView: View {
    var model: PolishPanelModel
    var onRevert: () -> Void
    var onTone: (PolishRules.Tone) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            HStack(spacing: Theme.gapS) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text(title).font(Theme.bodyStrong)
                Spacer(minLength: Theme.gapM)
                if model.busy { ProgressView().controlSize(.small) }
                Button(action: onClose) { Image(systemName: "xmark").font(Theme.icon) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("关闭")
            }
            if let outcome = model.outcome {
                // 不用滚动区：滚动区没有固有高度，浮窗按内容定大小时会被压成 0。长文本最多显示 10 行
                content(outcome)
                    .font(Theme.body)
                    .lineSpacing(3)
                    .lineLimit(10)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if outcome.canReplace {
                    HStack(spacing: 6) {
                        Button("撤回", action: onRevert)
                            .help("把输入框恢复成改写前的原文")
                        Spacer(minLength: Theme.gapS)
                        ForEach(PolishRules.Tone.allCases) { tone in
                            Button(tone.title) { onTone(tone) }
                                .buttonStyle(ChipStyle(active: tone == outcome.tone))
                                .disabled(tone == outcome.tone)
                        }
                    }
                    .disabled(model.busy)
                    .font(Theme.caption)
                    Text("再按一次改写快捷键，换下一种语气")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(width: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .padding(8)
        .onHover { model.hovering = $0 }
    }

    private var title: String {
        guard let outcome = model.outcome else { return "已改写" }
        return outcome.tone == .standard ? "已改写" : "已改写 · \(outcome.tone.title)"
    }

    @ViewBuilder
    private func content(_ outcome: PolishOutcome) -> some View {
        let translated = TranslationCheck.cjkRatio(outcome.original) > 0.3
        if !translated, let pieces = TextDiff.pieces(from: outcome.original, to: outcome.result),
           TextDiff.changeRatio(pieces) < 0.75 {
            if pieces.allSatisfy({ $0.kind == .same }) {
                Text("原文已经没问题，没有改动。").foregroundStyle(.secondary)
            } else {
                Text(Self.attributed(pieces))
            }
        } else {
            // 中文译成英文，或几乎整段重写：逐词标色没意义，上面放原文、下面放结果
            VStack(alignment: .leading, spacing: 6) {
                Text(outcome.original).foregroundStyle(.secondary)
                Divider()
                Text(outcome.result)
            }
        }
    }

    static func attributed(_ pieces: [TextDiff.Piece]) -> AttributedString {
        var output = AttributedString()
        for piece in pieces {
            var part = AttributedString(piece.text)
            switch piece.kind {
            case .same: break
            case .removed:
                part.foregroundColor = Theme.danger
                part.strikethroughStyle = .single
                part.backgroundColor = Theme.danger.opacity(0.10)
            case .added:
                part.foregroundColor = Color(nsColor: .systemGreen)
                part.backgroundColor = Theme.success.opacity(0.14)
            }
            output += part
        }
        return output
    }
}

// MARK: - 浮窗窗口

/// 点浮窗上的按钮不激活翻译神器、不抢走输入框的焦点。
private final class PolishPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ClickThroughHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PolishPanelController {
    static let shared = PolishPanelController()
    static let enabledKey = "polish.showChanges"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    let model = PolishPanelModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// - Parameter anchor: 输入框在屏幕上的位置（Cocoa 坐标）；没有时显示在屏幕上方居中。
    func show(_ outcome: PolishOutcome, anchor: NSRect?, seconds: Double = 12) {
        model.outcome = outcome
        model.busy = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 456, height: 160)
        panel.setContentSize(size)
        panel.setFrameOrigin(Self.origin(size: size, anchor: anchor))
        panel.orderFrontRegardless()
        scheduleHide(after: seconds)
    }

    func setBusy(_ busy: Bool) {
        model.busy = busy
        if busy { hideTask?.cancel() }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            // 鼠标停在浮窗上、或正在换语气时不收
            while let self, !Task.isCancelled, self.model.hovering || self.model.busy {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if !Task.isCancelled { self?.panel?.orderOut(nil) }
        }
    }

    /// 放在输入框上方（聊天输入框通常在窗口底部），上方放不下就放下方；都不行就贴屏幕上沿居中。
    static func origin(size: NSSize, anchor: NSRect?) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let probe = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouse
        let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard let anchor, anchor.width > 0, anchor.height > 0 else {
            return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16)
        }
        let x = min(max(anchor.minX - 8, visible.minX), visible.maxX - size.width)
        let above = anchor.maxY + 4
        if above + size.height <= visible.maxY { return NSPoint(x: x, y: above) }
        let below = anchor.minY - 4 - size.height
        if below >= visible.minY { return NSPoint(x: x, y: below) }
        return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16)
    }

    private func makePanel() -> NSPanel {
        let panel = PolishPanel(contentRect: NSRect(x: 0, y: 0, width: 456, height: 160),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = PolishPanelView(model: model,
                                   onRevert: { PolishCoordinator.shared.revert() },
                                   onTone: { PolishCoordinator.shared.retone($0) },
                                   onClose: { [weak self] in self?.hide() })
        let host = ClickThroughHost(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        return panel
    }

    /// 开发用（FANYI_DEMO_POLISH）：把浮窗内容画成图片。
    func snapshot(to url: URL) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

extension FocusTarget {
    /// 输入框在屏幕上的位置，换算成 Cocoa 坐标（原点在主屏左下角）。读不到时返回 nil。
    func frame() -> NSRect? {
        guard let element else { return nil }
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: point.x, y: primary.frame.height - point.y - size.height, width: size.width, height: size.height)
    }
}
