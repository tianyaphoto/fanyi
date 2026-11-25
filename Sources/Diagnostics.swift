import SwiftUI
import os

/// 一键改写的运行记录：最近 250 条，只在内存里，退出即清空；同样的内容写进系统日志供开发调试。
/// 只记状态（收到快捷键、复制是否完成、HTTP 状态、耗时、粘贴是否确认），不记原文、结果和密钥。
@MainActor
@Observable
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    enum Level { case info, warning, error }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.local.fanyi", category: "polish")
    @ObservationIgnored private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func add(_ message: String, _ level: Level = .info) {
        entries.append(Entry(date: Date(), level: level, message: message))
        if entries.count > 250 { entries.removeFirst(entries.count - 250) }
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    func clear() { entries.removeAll() }

    func time(_ entry: Entry) -> String { formatter.string(from: entry.date) }

    var text: String {
        entries.map { "\(time($0)) \($0.level == .info ? "" : $0.level == .warning ? "[注意] " : "[错误] ")\($0.message)" }
            .joined(separator: "\n")
    }
}

struct DiagnosticsView: View {
    @State private var log = DiagnosticsLog.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            HStack {
                Text("一键改写的最近 \(log.entries.count) 条记录（最多 250 条，退出后清空；不含原文、结果和密钥）")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "已复制" : "复制全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text, forType: .string)
                    copied = true
                }
                .disabled(log.entries.isEmpty)
                Button("清空") { log.clear() }
                    .disabled(log.entries.isEmpty)
            }
            if log.entries.isEmpty {
                EmptyState(title: "还没有记录",
                           detail: "在输入框里按「改写当前输入框」的快捷键（默认 ⌃⌥⌘T），这里会显示每一步的结果。")
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
            } else {
                ScrollViewReader { proxy in
                    List(log.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.gapS) {
                            Text(log.time(entry))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(entry.message)
                                .font(Theme.body)
                                .foregroundStyle(entry.level == .error ? Theme.danger
                                                 : entry.level == .warning ? Theme.repeated : Color.primary)
                                .textSelection(.enabled)
                        }
                        .id(entry.id)
                    }
                    .listStyle(.bordered)
                    .onAppear { if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: log.entries.count) {
                        copied = false
                        if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(Theme.gapL)
        .frame(minWidth: 560, minHeight: 380)
    }
}

/// 不抢焦点的短提示：屏幕上方居中出现几秒，鼠标可以穿过去。
@MainActor
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    enum Style { case info, warning, error }

    func show(_ message: String, style: Style = .info, seconds: Double = 3.5) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: ToastView(message: message, style: style))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - panel.frame.height - 16))
        }
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.panel?.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

private struct ToastView: View {
    let message: String
    let style: Toast.Style

    var body: some View {
        HStack(spacing: Theme.gapS) {
            Image(systemName: style == .info ? "checkmark.circle.fill"
                  : style == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundStyle(style == .info ? Theme.success : style == .warning ? Theme.repeated : Theme.danger)
            Text(message)
                .font(Theme.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .padding(8)
    }
}
