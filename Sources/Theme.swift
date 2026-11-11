import SwiftUI

/// 设计变量：界面里的字号、颜色、圆角、间距都从这里取，别处不写具体数值。
enum Theme {
    // MARK: 字阶（固定五级，约 1.15 倍递进：11 / 13 / 15 / 17 / 20）

    static let caption = Font.system(size: 11)
    static let captionStrong = Font.system(size: 11, weight: .medium)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let reading = Font.system(size: 15)
    static let heading = Font.system(size: 17, weight: .semibold)
    static let title = Font.system(size: 20, weight: .semibold)
    static let icon = Font.system(size: 12, weight: .medium)

    // MARK: 颜色（强调色只用于主操作、当前选中和状态）

    static let accent = Color.accentColor
    /// 面板底色：原句、系统词典这类成块的内容
    static let surface = Color.primary.opacity(0.05)
    static let hover = Color.primary.opacity(0.09)
    static let skeleton = Color.primary.opacity(0.12)
    /// 重复查询的提示
    static let repeated = Color.orange
    static let favorite = Color.yellow
    static let success = Color.green
    static let danger = Color.red

    // MARK: 圆角与间距

    static let radius: CGFloat = 8
    static let radiusSmall: CGFloat = 5
    static let gapXS: CGFloat = 4
    static let gapS: CGFloat = 8
    static let gapM: CGFloat = 12
    static let gapL: CGFloat = 16
}

extension View {
    /// 成块内容的统一底板。
    func surface() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
    }
}

/// 小节标题：正文字体小一号，不加图标。
struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(Theme.captionStrong)
            .foregroundStyle(.secondary)
    }
}

/// 只有图标的按钮，带悬停底色。
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.icon)
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .fill(hovering && isEnabled ? Theme.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 「标签 — 内容」的元信息表，代替用圆点串起来的一行小字。
struct MetaList: View {
    let rows: [(label: String, value: String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.gapM, verticalSpacing: Theme.gapXS) {
            ForEach(rows, id: \.label) { row in
                GridRow {
                    Text(row.label)
                        .font(Theme.captionStrong)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(row.value)
                        .font(Theme.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// 空状态：空的是什么、它有什么用、一个能填上它的操作。
struct EmptyState: View {
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.gapS) {
            Text(title)
                .font(Theme.bodyStrong)
            Text(detail)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, Theme.gapXS)
            }
        }
        .padding(Theme.gapL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 删除后的撤销条，几秒后自动消失。
struct UndoBar: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: Theme.gapS) {
            Text(message)
                .font(Theme.caption)
                .lineLimit(1)
            Spacer(minLength: Theme.gapS)
            Button("撤销", action: onUndo)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surface)
    }
}

/// 等待译文时的占位：几行和正文同形状的灰条。
struct SkeletonLines: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            ForEach([1.0, 0.86, 0.58], id: \.self) { width in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.skeleton)
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: width, y: 1, anchor: .leading)
            }
        }
        .opacity(dimmed ? 0.45 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dimmed)
        .onAppear { dimmed = true }
        .accessibilityElement()
        .accessibilityLabel("翻译中")
    }
}

/// 来源的显示写法：旧数据里用圆点连接的「App · 文档」改成「App：文档」。
func displayOrigin(_ origin: String) -> String {
    origin.replacingOccurrences(of: " · ", with: "：")
}
