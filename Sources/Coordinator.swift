import AppKit
import SwiftUI
import Carbon.HIToolbox
import Vision

/// 串联：划词监听 → 小图标 → 翻译浮窗；截图 → OCR → 翻译浮窗。
@MainActor
final class Coordinator {
    static let shared = Coordinator()

    private let monitor = SelectionMonitor()
    private let icon = IconPanelController()
    private let popup = PopupController()
    private var capturing = false

    func start() {
        if let dir = DemoMode.directory {
            DemoMode.run(in: dir, popup: popup)
            return
        }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        monitor.onSelection = { [weak self] capture, point in
            guard let self else { return }
            self.icon.show(near: point) { [weak self] origin in
                self?.popup.show(capture, near: origin)
            }
        }
        monitor.onMouseDown = { [weak self] in
            self?.icon.hide()
            self?.popup.closeIfNotPinned()
        }
        monitor.onActivity = { [weak self] in self?.icon.hide() }
        monitor.start()

        ShortcutCenter.shared.handler = { [weak self] action in self?.perform(action) }
        ShortcutCenter.shared.apply()
    }

    func perform(_ action: HotKeyAction) {
        switch action {
        case .selection: translateSelection()
        case .screenshot: captureAndTranslate()
        case .input: showInput()
        }
    }

    // MARK: 输入翻译

    func showInput() {
        icon.hide()
        popup.showInput()
    }

    // MARK: 划词（快捷键）

    func translateSelection() {
        icon.hide()
        let point = NSEvent.mouseLocation
        guard AXIsProcessTrusted() else {
            popup.showMessage("需要「辅助功能」权限才能读取选中的文字，请在设置中授权。", near: point)
            return
        }
        Task {
            if let capture = await SelectionReader.capture(forceCopy: true) {
                popup.show(capture, near: point)
            } else {
                popup.showMessage("没有读取到选中的文字。", near: point)
            }
        }
    }

    // MARK: 截图翻译

    func captureAndTranslate() {
        guard !capturing else { return }
        icon.hide()
        popup.close()

        if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            popup.showMessage("需要「屏幕录制」权限才能截图翻译。请在 系统设置 → 隐私与安全性 → 录屏与系统录音 中允许本 App，然后重新打开 App。", near: NSEvent.mouseLocation)
            return
        }

        var source = ContextReader.sourceInfo()
        source?.suffix = "（截图）"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fanyi-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path] // -i 交互式框选，-x 静音
        let useVision = Settings.screenshotVisionEnabled && Settings.provider.supportsVision
        process.terminationHandler = { _ in
            let shot = Self.readScreenshot(at: url, withImage: useVision)
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let coordinator = Coordinator.shared
                    coordinator.capturing = false
                    let point = NSEvent.mouseLocation
                    guard let shot else { return } // 用户按 Esc 取消了截图
                    if shot.text.isEmpty && shot.image == nil {
                        coordinator.popup.showMessage("截图中没有识别到文字。", near: point)
                    } else {
                        coordinator.popup.show(Capture(text: shot.text, source: source ?? SourceInfo(suffix: "（截图）"),
                                                       image: shot.image), near: point)
                    }
                }
            }
        }
        do {
            try process.run()
            capturing = true
        } catch {
            popup.showMessage("无法启动截图：\(error.localizedDescription)", near: NSEvent.mouseLocation)
        }
    }

    private struct Shot {
        var text: String
        var image: ImageAttachment?
    }

    /// 读取截图：本地 OCR（Apple Vision），看图翻译时再附上图片本身。返回 nil 表示没有截图文件（用户取消）。
    nonisolated private static func readScreenshot(at url: URL, withImage: Bool) -> Shot? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return Shot(text: recognizeText(in: cgImage), image: withImage ? attachment(from: cgImage) : nil)
    }

    /// 压到模型接口能接受的大小：长边不超过 2000 像素，PNG 过大时改用 JPEG。
    nonisolated private static func attachment(from cgImage: CGImage) -> ImageAttachment? {
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        let scale = min(1, 2000 / max(width, height))
        var output = cgImage
        if scale < 1 {
            let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
            guard let scaled = context.makeImage() else { return nil }
            output = scaled
        }
        let rep = NSBitmapImageRep(cgImage: output)
        if let png = rep.representation(using: .png, properties: [:]), png.count <= 3_000_000 {
            return ImageAttachment(data: png, mediaType: "image/png")
        }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        return ImageAttachment(data: jpeg, mediaType: "image/jpeg")
    }

    nonisolated private static func recognizeText(in cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 小图标

private final class IconView: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        let symbol = NSImage(systemSymbolName: "translate", accessibilityDescription: "翻译")
            ?? NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: "翻译")
        let imageView = NSImageView(frame: bounds.insetBy(dx: 4, dy: 4))
        imageView.image = symbol
        imageView.contentTintColor = .white
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        toolTip = "翻译"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

@MainActor
final class IconPanelController {
    private let size: CGFloat = 26
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(near point: NSPoint, onClick: @escaping (NSPoint) -> Void) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        var origin = NSPoint(x: point.x + 10, y: point.y - size - 10)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size)
        }
        panel.setFrameOrigin(origin)
        (panel.contentView as? IconView)?.onClick = { [weak self] in
            self?.hide()
            onClick(origin)
        }
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.hide() }
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = IconView(frame: rect)
        return panel
    }
}

// MARK: - 翻译浮窗

private final class PopupPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class PopupController {
    let model = TranslationModel()
    private var panel: PopupPanel?
    /// 单词、短句的浮窗大小
    private let compactSize = NSSize(width: 420, height: 300)
    /// 整段、多段长文本的浮窗大小（会按屏幕缩小）
    private let largeSize = NSSize(width: 580, height: 560)

    func show(_ capture: Capture, near point: NSPoint) {
        present(near: point, anchor: capture.anchor, large: TranslationModel.isLong(capture.text))
        model.inputMode = false
        model.translate(capture)
    }

    func showMessage(_ message: String, near point: NSPoint) {
        present(near: point, anchor: nil, large: false)
        model.showMessage(message)
    }

    /// 输入翻译：像 Spotlight 一样出现在当前屏幕上方居中，并接收键盘输入。
    func showInput() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !(panel.isVisible && model.pinned) {
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                let size = compactSize
                let origin = NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.maxY - visible.height * 0.22 - size.height)
                panel.setFrame(NSRect(origin: origin, size: size), display: true)
            }
        }
        model.startInput()
        panel.makeKeyAndOrderFront(nil)
    }

    func closeIfNotPinned() {
        if !model.pinned { close() }
    }

    func close() {
        model.cancel()
        model.pinned = false
        panel?.orderOut(nil)
    }

    private func present(near point: NSPoint, anchor: NSRect?, large: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !(panel.isVisible && model.pinned) {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
            let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 8, dy: 8)
            var size = large ? largeSize : compactSize
            size.width = min(size.width, visible.width)
            size.height = min(size.height, visible.height * 0.75)
            panel.setFrame(Self.placement(size: size, point: point, anchor: anchor, visible: visible), display: true)
        }
        panel.orderFrontRegardless()
    }

    /// 选浮窗的位置：优先放在选中文字的下方、上方、右侧、左侧，不挡住选中的文字；
    /// 上下空间不够整窗时允许变矮（不低于 220）；都放不下时贴到空间较大的一侧屏幕边缘。
    static func placement(size: NSSize, point: NSPoint, anchor: NSRect?, visible: NSRect) -> NSRect {
        let gap: CGFloat = 8
        let minHeight: CGFloat = 220
        let a = anchor ?? NSRect(x: point.x, y: point.y - 4, width: 1, height: 8)
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, visible.minX), visible.maxX - size.width) }
        func clampY(_ y: CGFloat, _ h: CGFloat) -> CGFloat { min(max(y, visible.minY), visible.maxY - h) }
        let x = clampX(point.x - 24)

        let below = a.minY - gap - visible.minY
        let above = visible.maxY - (a.maxY + gap)
        if below >= size.height { return NSRect(x: x, y: a.minY - gap - size.height, width: size.width, height: size.height) }
        if above >= size.height { return NSRect(x: x, y: a.maxY + gap, width: size.width, height: size.height) }

        let right = visible.maxX - (a.maxX + gap)
        let left = a.minX - gap - visible.minX
        let y = clampY(point.y - size.height / 2, size.height)
        if right >= size.width { return NSRect(x: a.maxX + gap, y: y, width: size.width, height: size.height) }
        if left >= size.width { return NSRect(x: a.minX - gap - size.width, y: y, width: size.width, height: size.height) }

        // 上下都放不下整窗：放进空间大的那边并变矮
        if max(below, above) >= minHeight {
            let h = max(below, above)
            let originY = below >= above ? a.minY - gap - h : a.maxY + gap
            return NSRect(x: x, y: originY, width: size.width, height: h)
        }
        // 选区几乎占满屏幕：贴到左右空间较大的一侧
        let edgeX = (point.x - visible.minX) > (visible.maxX - point.x) ? visible.minX : visible.maxX - size.width
        return NSRect(x: edgeX, y: y, width: size.width, height: size.height)
    }

    private func makePanel() -> PopupPanel {
        let panel = PopupPanel(contentRect: NSRect(origin: .zero, size: compactSize),
                               styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 180)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onEscape = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: TranslationView(model: model, onClose: { [weak self] in self?.close() }))
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(compactSize)
        return panel
    }
}

extension PopupController {
    /// 开发用（见 Debug.swift）：显示假的原文和译文，不调用翻译服务。
    func showDemo(_ capture: Capture, result: String, sceneID: String?, near point: NSPoint) {
        show(capture, near: point)
        model.cancel()
        if let sceneID { model.scene = SceneStore.shared.scene(id: sceneID) }
        if ProcessInfo.processInfo.environment["FANYI_DEMO_STREAM"] == nil { model.result = result; return }
        model.isLoading = true
        Task {
            var rest = Substring(result)
            while !rest.isEmpty {
                model.result += rest.prefix(12)
                rest = rest.dropFirst(12)
                try? await Task.sleep(for: .milliseconds(8))
            }
            model.isLoading = false
        }
    }

    func snapshot(to url: URL) {
        guard let view = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.frame.width > 100 })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
