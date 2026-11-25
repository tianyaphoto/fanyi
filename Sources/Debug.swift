import AppKit
import SwiftUI
import Carbon.HIToolbox

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
        // FANYI_DEMO_SETTINGS=1：截设置窗口（滚到一键改写那一节）
        if ProcessInfo.processInfo.environment["FANYI_DEMO_SETTINGS"] != nil {
            Windows.showSettings()
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                if let window = NSApp.windows.first(where: { $0.title == "翻译神器设置" }), let view = window.contentView {
                    window.setContentSize(NSSize(width: 520, height: 1900))
                    try? await Task.sleep(for: .milliseconds(600))
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings.png"))
                    }
                }
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
            } else {
                polish.polishField()
            }
            try? await Task.sleep(for: .milliseconds(200))
            for _ in 0..<600 where polish.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            for entry in DiagnosticsLog.shared.entries { print("  \(entry.message)") }
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
