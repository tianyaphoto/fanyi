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

        let origin = ContextReader.originDescription()
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
                        coordinator.popup.show(Capture(text: shot.text, origin: origin.map { "\($0)（截图）" } ?? "截图",
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
    private let size = NSSize(width: 420, height: 300)

    func show(_ capture: Capture, near point: NSPoint) {
        present(near: point)
        model.inputMode = false
        model.translate(capture)
    }

    func showMessage(_ message: String, near point: NSPoint) {
        present(near: point)
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
                let origin = NSPoint(x: visible.midX - panel.frame.width / 2,
                                     y: visible.maxY - visible.height * 0.22 - panel.frame.height)
                panel.setFrameOrigin(origin)
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

    private func present(near point: NSPoint) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !(panel.isVisible && model.pinned) {
            var origin = NSPoint(x: point.x, y: point.y - panel.frame.height - 8)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                if origin.y < visible.minY { origin.y = point.y + 30 } // 下方放不下就放到上方
                origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
                origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panel.frame.height - 8)
            }
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> PopupPanel {
        let panel = PopupPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 300, height: 180)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onEscape = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: TranslationView(model: model, onClose: { [weak self] in self?.close() }))
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(size)
        return panel
    }
}
