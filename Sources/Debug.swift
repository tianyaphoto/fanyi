import AppKit
import SwiftUI
import Carbon.HIToolbox
import Translation

/// 开发用：不调用翻译服务，把假的原文和译文塞进浮窗并截图，用来检查长文本的排版。
///
///     FANYI_DEMO_DIR=/path/to/dir build/Build/Products/Release/Fanyi.app/Contents/MacOS/Fanyi
///
/// 目录里放 source.txt（原文）、result.txt（译文），可选 context.txt（原句）、origin.txt（来源）、
/// scene.txt（场景 id）、glossary.txt（假装命中的术语）。截图写到同目录的 snapshot.png，然后退出。
@MainActor
enum DemoMode {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["FANYI_DEMO_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func run(in dir: URL, popup: PopupController) {
        func read(_ name: String) -> String? {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let capture = Capture(text: read("source.txt") ?? "", context: read("context.txt"),
                              source: read("origin.txt").map { SourceInfo(appName: $0) })
        let screen = NSScreen.main?.visibleFrame ?? .zero
        // FANYI_DEMO_LIVE=1：真的调用翻译服务（来源信息来自 app.txt / bundle.txt / title.txt / url.txt，
        // 场景自动识别；scene.txt 可强制场景；glossary.txt 临时术语表；input=1 文件存在时走输入翻译）。
        // 翻完截图，并把译文写到 result-live.txt、场景写到 scene-live.txt。
        if ProcessInfo.processInfo.environment["FANYI_DEMO_LIVE"] != nil {
            KnowledgeStore.shared.demoGlossary = read("glossary.txt").map { KnowledgeStore.parseGlossary($0) } ?? []
            let source = SourceInfo(appName: read("app.txt") ?? "", bundleID: read("bundle.txt") ?? "",
                                    windowTitle: read("title.txt") ?? "", url: read("url.txt") ?? "")
            var live = Capture(text: read("source.txt") ?? "", context: read("context.txt"),
                               source: source.appName.isEmpty && source.url.isEmpty ? nil : source)
            // shot.png：当作截图翻译的截图（走本地 OCR，设置里开了看图翻译时也附上图片），识别结果写到 ocr.txt
            let shotURL = dir.appendingPathComponent("shot.png")
            if FileManager.default.fileExists(atPath: shotURL.path),
               let shot = Coordinator.readScreenshot(at: shotURL, withImage: Settings.screenshotVisionEnabled && Settings.provider.supportsVision) {
                try? shot.text.write(to: dir.appendingPathComponent("ocr.txt"), atomically: true, encoding: .utf8)
                live.text = shot.text
                live.image = shot.image
            }
            if read("input") != nil {
                popup.showInput()
                popup.model.inputText = live.text
                popup.model.submitInput()
            } else {
                popup.show(live, near: NSPoint(x: screen.midX - 200, y: screen.midY + 250))
                if let forced = read("scene.txt") { popup.model.translate(live, isRetry: true, sceneID: forced) }
                if let h = read("height.txt").flatMap(Double.init) { popup.resizeForDemo(height: h) }
            }
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                for _ in 0..<900 where popup.model.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(800))
                try? popup.model.result.write(to: dir.appendingPathComponent("result-live.txt"), atomically: true, encoding: .utf8)
                try? popup.model.scene.name.write(to: dir.appendingPathComponent("scene-live.txt"), atomically: true, encoding: .utf8)
                popup.snapshot(to: dir.appendingPathComponent("snapshot.png"))
                NSApp.terminate(nil)
            }
            return
        }
        // FANYI_DEMO_SETTINGS=1：截设置窗口（滚到一键改写那一节）
        if ProcessInfo.processInfo.environment["FANYI_DEMO_SETTINGS"] != nil {
            Windows.showSettings()
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                if let window = NSApp.windows.first(where: { $0.title == "翻译神器设置" }), let view = window.contentView {
                    window.setContentSize(NSSize(width: 520, height: 1900))
                    try? await Task.sleep(for: .milliseconds(600))
                    // 从顶部截（窗口会记住上次的滚动位置）
                    func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
                    for scroll in scrollViews(view) {
                        let flipped = scroll.documentView?.isFlipped ?? true
                        let top = flipped ? NSPoint.zero : NSPoint(x: 0, y: max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height))
                        scroll.contentView.scroll(to: top); scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings.png"))
                    }
                }
                NSApp.terminate(nil)
            }
            return
        }
        // FANYI_DEMO_POLISH=1：截改写后的对比浮窗。original.txt / result.txt 是改写前后；tone.txt 可选（formal 等）；
        // replace=0 文件存在时模拟「改写剪贴板」（没有撤回和语气按钮）。图片写到 polish.png，逐词对比写到 diff.txt。
        if ProcessInfo.processInfo.environment["FANYI_DEMO_POLISH"] != nil {
            let original = read("original.txt") ?? "", result = read("result.txt") ?? ""
            let tone = read("tone.txt").flatMap(PolishRules.Tone.init) ?? .standard
            let pieces = TextDiff.pieces(from: original, to: result) ?? []
            let marked = pieces.map { $0.kind == .same ? $0.text : $0.kind == .removed ? "[-\($0.text)-]" : "{+\($0.text)+}" }.joined()
            try? marked.write(to: dir.appendingPathComponent("diff.txt"), atomically: true, encoding: .utf8)
            PolishPanelController.shared.show(PolishOutcome(original: original, result: result, tone: tone,
                                                            canReplace: read("replace") != "0"), anchor: nil, seconds: 30)
            Task {
                try? await Task.sleep(for: .milliseconds(1000))
                PolishPanelController.shared.snapshot(to: dir.appendingPathComponent("polish.png"))
                NSApp.terminate(nil)
            }
            return
        }
        // FANYI_DEMO_INPUT=1：截输入翻译的空窗口
        if ProcessInfo.processInfo.environment["FANYI_DEMO_INPUT"] != nil {
            popup.showInput()
            finish(dir: dir, popup: popup)
            return
        }
        popup.showDemo(capture, result: read("result.txt") ?? "", sceneID: read("scene.txt"),
                       near: NSPoint(x: screen.midX - 200, y: screen.midY + 200))
        finish(dir: dir, popup: popup)
    }

    /// 等界面画好；FANYI_DEMO_CLICK=pin 时先模拟点一下固定按钮并打印结果；然后截图退出。
    private static func finish(dir: URL, popup: PopupController) {
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            if ProcessInfo.processInfo.environment["FANYI_DEMO_CLICK"] == "pin" {
                let before = popup.model.pinned
                popup.clickPinForTesting()
                try? await Task.sleep(for: .milliseconds(300))
                print("pin: \(before) -> \(popup.model.pinned)")
            }
            // FANYI_DEMO_CLICK=copysource：调一次「复制原文」，打印剪贴板是否等于原文（会改剪贴板）
            if ProcessInfo.processInfo.environment["FANYI_DEMO_CLICK"] == "copysource" {
                popup.model.copySource()
                print("copysource: \(NSPasteboard.general.string(forType: .string) == popup.model.source)")
            }
            popup.snapshot(to: dir.appendingPathComponent("snapshot.png"))
            NSApp.terminate(nil)
        }
    }
}

/// 开发用：一键改写的端到端自测。先让测试窗口到最前面，再用本进程跑一次改写，打印诊断日志后退出。
///
///     FANYI_POLISH_SELFTEST=field|clipboard FANYI_SELFTEST_BUNDLE=<测试窗口的 Bundle ID> \
///     [FANYI_SELFTEST_CLIPBOARD=<剪贴板文字文件>] /Applications/Fanyi.app/Contents/MacOS/Fanyi
///
/// 必须用已授权辅助功能的那个签名版本运行。
@MainActor
enum PolishSelfTest {
    static var mode: String? { ProcessInfo.processInfo.environment["FANYI_POLISH_SELFTEST"] }

    static func run(_ mode: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let env = ProcessInfo.processInfo.environment
        let bundle = env["FANYI_SELFTEST_BUNDLE"] ?? ""
        print("辅助功能已授权：\(AXIsProcessTrusted())")
        // 旧版模拟按键可能让系统以为 ⌘ 一直按着；测试前补发一次 ⌘ 松开把状态清掉
        if let up = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: CGKeyCode(kVK_Command), keyDown: false) {
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
        Task {
            for _ in 0..<100 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundle {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else {
                print("测试窗口没有到最前面，放弃"); exit(2)
            }
            try? await Task.sleep(for: .milliseconds(500))
            let polish = PolishCoordinator.shared
            if mode == "clipboard", let path = env["FANYI_SELFTEST_CLIPBOARD"],
               let text = try? String(contentsOfFile: path, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                polish.polishClipboard()
                // FANYI_SELFTEST_SWITCH=<文件>：等待模型时打开另一个文档，模拟用户换了输入框
                if let other = env["FANYI_SELFTEST_SWITCH"],
                   let app = NSWorkspace.shared.frontmostApplication?.bundleURL {
                    try? await Task.sleep(for: .milliseconds(150))
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    _ = try? await NSWorkspace.shared.open([URL(fileURLWithPath: other)], withApplicationAt: app, configuration: config)
                    print("已切换到 \(other)")
                }
            } else {
                polish.polishField()
            }
            try? await Task.sleep(for: .milliseconds(200))
            for _ in 0..<600 where polish.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            // FANYI_SELFTEST_STEPS=again,concise,revert：改写完接着做几步，每步后打印输入框内容。
            // again = 再按一次改写快捷键（浮窗还在时应该是换下一种语气）；formal / concise / casual = 点浮窗上的语气；revert = 撤回
            for step in (env["FANYI_SELFTEST_STEPS"] ?? "").split(separator: ",").map(String.init) {
                try? await Task.sleep(for: .milliseconds(600))
                switch step {
                case "again": polish.polishField()
                case "revert": polish.revert()
                default: if let tone = PolishRules.Tone(rawValue: step) { polish.retone(tone) }
                }
                try? await Task.sleep(for: .milliseconds(200))
                for _ in 0..<600 where polish.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(300))
                print("步骤 \(step) 之后：\(FocusTarget.current()?.value() ?? "（读不到）")")
            }
            for entry in DiagnosticsLog.shared.entries { print("  \(entry.message)") }
            if let now = FocusTarget.current() {
                var title: CFTypeRef?
                if let window = now.window { AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) }
                print("当前窗口：\(title as? String ?? "?")；内容：\(now.value() ?? "（读不到）")")
            }
            exit(0)
        }
    }
}

/// 开发用：用真实的鼠标事件点击翻译浮窗上的按钮，检查浮窗会不会被误关。
///
///     FANYI_CLICK_SELFTEST=speak|pin|copy /Applications/Fanyi.app/Contents/MacOS/Fanyi
///
/// 需要已授权辅助功能的签名版本；屏幕锁定时无法运行。鼠标会被移到按钮上点一下。
@MainActor
enum ClickSelfTest {
    static var button: String? { ProcessInfo.processInfo.environment["FANYI_CLICK_SELFTEST"] }

    static func run(_ button: String, popup: PopupController) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        popup.showDemo(Capture(text: "regression", context: "We caught a silent regression before release."),
                       result: "n. 回归；退步", sceneID: nil, near: NSPoint(x: screen.midX - 200, y: screen.midY + 150))
        Task {
            try? await Task.sleep(for: .milliseconds(1000))
            guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.frame.width > 100 }),
                  let primary = NSScreen.screens.first else { print("浮窗没出现"); exit(2) }
            // 右上角按钮从右往左：关闭、固定、收藏、复制、朗读；每个 26 宽，右边距 8，纵向在顶部 10 + 12
            let index = ["close": 0, "pin": 1, "star": 2, "copy": 3, "speak": 4][button] ?? 4
            let x = panel.frame.maxX - 8 - CGFloat(index) * 26 - 13
            let y = panel.frame.maxY - 10 - 12
            let point = CGPoint(x: x, y: primary.frame.maxY - y) // 转成左上角为原点的屏幕坐标
            let pinnedBefore = popup.model.pinned
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await Task.sleep(for: .milliseconds(600))
            print("点击 \(button) 之后：浮窗\(panel.isVisible ? "还在" : "被关掉了")；固定 \(pinnedBefore) → \(popup.model.pinned)；朗读中 \(popup.model.isSpeaking)")
            exit(panel.isVisible || button == "close" ? 0 : 1)
        }
    }
}

/// 开发用：FANYI_DRAG_SELFTEST="x,y"（左上角为原点的屏幕坐标）在那里模拟一次鼠标双击选词，
/// 走真实的划词手势流程，打印读到的文字（读到就是会出小图标）。需要辅助功能权限；鼠标会被移动。
enum DragSelfTest {
    static var point: CGPoint? {
        guard let raw = ProcessInfo.processInfo.environment["FANYI_DRAG_SELFTEST"] else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }

    @MainActor
    static func run(at point: CGPoint, monitor: SelectionMonitor) {
        setvbuf(stdout, nil, _IOLBF, 0)
        monitor.onSelection = { capture, _ in
            print("划词读到：\(capture.text)")
            exit(0)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            for click in 1...2 {
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                    event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                    event?.post(tap: .cghidEventTap)
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            try? await Task.sleep(for: .seconds(3))
            print("划词没有读到文字（不会出小图标）")
            exit(1)
        }
    }
}

/// 开发用：探测辅助功能接口在当前环境（例如沙盒）里能读到什么。
///
///     FANYI_AX_PROBE=<目标 App 的 Bundle ID> /Applications/Fanyi.app/Contents/MacOS/Fanyi
enum AXProbe {
    static var target: String? { ProcessInfo.processInfo.environment["FANYI_AX_PROBE"] }

    static func run(_ bundle: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("辅助功能已授权：\(AXIsProcessTrusted())")
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            print("找不到 \(bundle)"); exit(2)
        }
        func copy(_ element: AXUIElement, _ attr: String) -> (AXError, CFTypeRef?) {
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
            return (err, value)
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let (e1, windows) = copy(axApp, kAXWindowsAttribute)
        print("App 元素 → 窗口列表：err=\(e1.rawValue) 数量=\((windows as? [AXUIElement])?.count ?? -1)")
        let (e2, focused) = copy(axApp, kAXFocusedUIElementAttribute)
        print("App 元素 → 焦点元素：err=\(e2.rawValue)")
        if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let el = focused as! AXUIElement
            let (e3, value) = copy(el, kAXValueAttribute)
            print("焦点元素 → 文字：err=\(e3.rawValue) 长度=\((value as? String)?.count ?? -1)")
            let (e4, sel) = copy(el, kAXSelectedTextAttribute)
            print("焦点元素 → 选中文字：err=\(e4.rawValue) 长度=\((sel as? String)?.count ?? -1)")
        }
        let (e5, _) = copy(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
        print("系统元素 → 焦点元素：err=\(e5.rawValue)")
        exit(0)
    }
}

/// 开发用：剪贴板历史自测。先把测试窗口（例如 TextEdit 的空文档）放到最前面，再运行
///     FANYI_CLIPHIST_SELFTEST=<测试窗口的 Bundle ID> [FANYI_DEMO_DIR=<截图目录>] /Applications/Fanyi.app/Contents/MacOS/Fanyi
/// 依次复制三段文字 → 弹出列表（截图 cliphist.png）→ 搜索 beta → 回车，检查剪贴板第一条和输入框内容。
@MainActor
enum ClipboardSelfTest {
    static var bundle: String? { ProcessInfo.processInfo.environment["FANYI_CLIPHIST_SELFTEST"] }

    static func run(_ bundle: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("辅助功能已授权：\(AXIsProcessTrusted())")
        ClipboardHistory.shared.start()
        Task {
            for _ in 0..<100 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundle {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else { print("测试窗口没有到最前面"); exit(2) }
            for text in ["alpha 第一条", "beta 第二条：Please review the PR before Friday.", "gamma 第三条"] {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                try? await Task.sleep(for: .milliseconds(700))
            }
            print("历史：\(ClipboardHistory.shared.items.map(\.text))")
            let controller = ClipboardPanelController.shared
            controller.show()
            try? await Task.sleep(for: .milliseconds(800))
            if let dir = ProcessInfo.processInfo.environment["FANYI_DEMO_DIR"],
               let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.frame.width > 400 }),
               let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("cliphist.png"))
            }
            let before = FocusTarget.current()?.value()
            // 真实按键：输入 beta，再回车
            for code in [kVK_ANSI_B, kVK_ANSI_E, kVK_ANSI_T, kVK_ANSI_A, kVK_Return, kVK_Return] {
                let source = CGEventSource(stateID: .privateState)
                for down in [true, false] {
                    CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)?.post(tap: .cghidEventTap)
                    try? await Task.sleep(for: .milliseconds(30))
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
            try? await Task.sleep(for: .milliseconds(1200))
            let after = FocusTarget.current()?.value()
            print("剪贴板第一条：\(NSPasteboard.general.string(forType: .string) ?? "")")
            print("历史顺序：\(ClipboardHistory.shared.items.map(\.text))")
            print("输入框之前：\(before ?? "（读不到）")")
            print("输入框之后：\(after ?? "（读不到）")")
            exit(after?.contains("beta 第二条") == true ? 0 : 1)
        }
    }
}


/// 开发用：不需要屏幕操作的功能自测。
///
///     FANYI_SELFTEST=<名字> [FANYI_DATA_DIR=<临时目录>] build/Build/Products/Release/Fanyi.app/Contents/MacOS/Fanyi
///
/// - `anki`：把 3 条假生词发到 FANYI_ANKI_URL（假的 AnkiConnect，见 tests/anki-mock.py），打印结果和导出文件的内容。
/// - `system`：用系统翻译翻 FANYI_SELFTEST_TEXT（多条用 `||` 隔开），打印译文。FANYI_SELFTEST_TO=ja 指定目标语言。
/// - `ocr`：识别 FANYI_SELFTEST_IMAGE 里的文字并放进剪贴板（会改剪贴板），打印提示和剪贴板内容。
/// - `review`：在 FANYI_DATA_DIR 的假生词本上跑一遍复习规则（必须给 FANYI_DATA_DIR，不碰真实数据）。
/// - `reviewshot`：用 FANYI_DATA_DIR 里的生词本和历史截一张复习窗口，写到该目录的 review.png（step=reveal 文件存在时先翻开）。
@MainActor
enum SelfTest {
    static var name: String? { ProcessInfo.processInfo.environment["FANYI_SELFTEST"] }

    /// 生词本、历史的目录。自测时可以用 FANYI_DATA_DIR 指到临时目录。
    nonisolated static var dataDirectory: URL {
        let dir: URL
        if let custom = ProcessInfo.processInfo.environment["FANYI_DATA_DIR"], ProcessInfo.processInfo.environment["FANYI_SELFTEST"] != nil {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Fanyi", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func run(_ name: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let env = ProcessInfo.processInfo.environment
        Task {
            var ok = true
            switch name {
            case "anki":
                let entries = [
                    VocabEntry(text: "redundant", translation: "adj. 多余的\n\(Translator.memoryMarker)\n拆开记：re + und",
                               context: "The second check is <redundant> & slow.", origin: "预览：paper.pdf"),
                    VocabEntry(text: "mitigate", translation: "v. 减轻"),
                    VocabEntry(text: "tab\there", translation: "带制表符", context: "line1\nline2"),
                ]
                print("可用：\(await AnkiExport.isAvailable())")
                do {
                    let summary = try await AnkiExport.send(entries)
                    print("新增 \(summary.added)，重复 \(summary.duplicates)")
                } catch {
                    print("失败：\(error.localizedDescription)")
                    ok = false
                }
                print("--- 导出文件内容\n" + AnkiExport.fileContents(entries))
            case "system":
                let target = env["FANYI_SELFTEST_TO"].flatMap(Language.find)
                for text in (env["FANYI_SELFTEST_TEXT"] ?? "").components(separatedBy: "||") {
                    let start = Date()
                    do {
                        let output = try await SystemTranslator.translate(text, plan: TranslationPlan(text, target: target))
                        print(String(format: "✓ [%.2fs] %@ → %@", Date().timeIntervalSince(start),
                                     text.replacingOccurrences(of: "\n", with: " ⏎ "), output.replacingOccurrences(of: "\n", with: " ⏎ ")))
                    } catch {
                        print("✗ \(text) → \(error.localizedDescription)")
                        ok = false
                    }
                }
            case "langpack":
                // 打开语言包下载窗口（会弹系统的确认框），截屏写到 FANYI_DATA_DIR/langpack.png；下好后打印结果
                let pair = (env["FANYI_SELFTEST_PAIR"] ?? "en,zh-Hans").split(separator: ",").map { Locale.Language(identifier: String($0)) }
                var done = false
                Windows.showLanguagePackDownload(LanguagePackMissing(source: pair[0], target: pair[1], sourceName: "英语", targetName: "简体中文")) { done = true }
                let wait = Int(env["FANYI_SELFTEST_WAIT"] ?? "8") ?? 8
                for _ in 0..<(wait * 2) where !done { try? await Task.sleep(for: .milliseconds(500)) }
                print("下载完成：\(done)")
                if #available(macOS 15.0, *) {
                    print("状态：\(await LanguageAvailability().status(from: pair[0], to: pair[1]))")
                }
                ok = done
            case "ocr":
                let url = URL(fileURLWithPath: env["FANYI_SELFTEST_IMAGE"] ?? "")
                let shot = Coordinator.readScreenshot(at: url, withImage: false)
                print("提示：" + Coordinator.copyRecognized(shot?.text ?? ""))
                print("剪贴板：" + (NSPasteboard.general.string(forType: .string) ?? ""))
                try? await Task.sleep(for: .milliseconds(300))
            case "review":
                ok = reviewRules()
            case "reviewshot":
                Windows.showReview()
                try? await Task.sleep(for: .milliseconds(900))
                if let window = NSApp.windows.first(where: { $0.title == "今日复习与统计" }), let view = window.contentView {
                    if FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("step=reveal").path) {
                        // 回车 = 「翻开看释义」
                        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return)) {
                            window.sendEvent(event)
                        }
                        try? await Task.sleep(for: .milliseconds(700))
                    }
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dataDirectory.appendingPathComponent("review.png"))
                    }
                }
            default:
                print("没有这个自测：\(name)")
                ok = false
            }
            exit(ok ? 0 : 1)
        }
    }

    /// 复习规则：每天上限、记得后的间隔、忘了重来、走完全部间隔算掌握。
    private static func reviewRules() -> Bool {
        guard ProcessInfo.processInfo.environment["FANYI_DATA_DIR"] != nil else {
            print("必须给 FANYI_DATA_DIR，免得改到真实的生词本")
            return false
        }
        // 复习次数记在偏好设置里：测完恢复原值
        let defaults = UserDefaults.standard
        let savedDay = defaults.object(forKey: "review.day"), savedDone = defaults.object(forKey: "review.doneToday")
        defaults.removeObject(forKey: "review.day"); defaults.removeObject(forKey: "review.doneToday")
        defer {
            if let savedDay { defaults.set(savedDay, forKey: "review.day") } else { defaults.removeObject(forKey: "review.day") }
            if let savedDone { defaults.set(savedDone, forKey: "review.doneToday") } else { defaults.removeObject(forKey: "review.doneToday") }
        }
        let store = VocabularyStore.shared
        var failures = 0
        func expect(_ condition: Bool, _ what: String) {
            print("\(condition ? "✓" : "✗") \(what)")
            if !condition { failures += 1 }
        }
        let now = Date()
        for index in 0..<8 { store.save(text: "old\(index)", translation: "旧词 \(index)") }
        store.save(text: "fresh", translation: "今天刚收藏")
        // 前 8 个改成几天前收藏的（越靠前越早），最后一个是今天的
        for (offset, entry) in store.entries.filter({ $0.text.hasPrefix("old") }).enumerated() {
            var changed = entry
            changed.createdAt = now.addingTimeInterval(-Double(10 + offset) * 86400)
            store.update(changed)
        }
        expect(store.dueEntries().count == 8, "到期 8 个（今天刚收藏的不算）：实际 \(store.dueEntries().count)")
        expect(store.todayQueue().count == 5, "今天只给 5 个：实际 \(store.todayQueue().count)")
        let first = store.todayQueue()[0]
        store.review(id: first.id, remembered: true, now: now)
        var after = store.entries.first { $0.id == first.id }!
        expect(after.reviewStage == 1 && abs(after.nextReview!.timeIntervalSince(now) - 3 * 86400) < 1, "记得一次：3 天后再出现")
        expect(store.todayQueue().count == 4 && store.reviewedToday == 1, "复习 1 个后今天还剩 4 个")
        let second = store.todayQueue()[0]
        store.review(id: second.id, remembered: false, now: now)
        after = store.entries.first { $0.id == second.id }!
        expect(after.reviewStage == 0 && abs(after.nextReview!.timeIntervalSince(now) - 86400) < 1, "忘了：明天再出现")
        // 同一个词一路记得到底
        var later = now
        for _ in 0..<4 {
            later = store.entries.first { $0.id == first.id }!.nextReview!.addingTimeInterval(60)
            store.review(id: first.id, remembered: true, now: later)
        }
        after = store.entries.first { $0.id == first.id }!
        expect(after.mastered && after.reviewStage == 5, "连续记得 5 次：标记为已掌握（实际第 \(after.reviewStage ?? -1) 次，掌握 \(after.mastered)）")
        expect(!store.dueEntries(now: later.addingTimeInterval(365 * 86400)).contains { $0.id == first.id }, "已掌握的不再出现")
        expect(store.todayQueue().isEmpty, "今天复习满 5 次后不再给：实际还给 \(store.todayQueue().count) 个")
        // 旧版本的生词本文件（没有复习字段）能读
        let legacy = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","text":"legacy","translation":"旧数据","createdAt":700000000,"mastered":false}]"#
        let decoded = try? JSONDecoder().decode([VocabEntry].self, from: Data(legacy.utf8))
        expect(decoded?.first?.text == "legacy" && decoded?.first?.reviewStage == nil, "旧版生词本文件能读")
        print(failures == 0 ? "全部通过" : "失败 \(failures) 项")
        return failures == 0
    }
}
