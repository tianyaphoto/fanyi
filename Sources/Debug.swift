import AppKit
import SwiftUI

/// 开发用：不调用翻译服务，把假的原文和译文塞进浮窗并截图，用来检查长文本的排版。
///
///     FANYI_DEMO_DIR=/path/to/dir build/Build/Products/Release/Fanyi.app/Contents/MacOS/Fanyi
///
/// 目录里放 source.txt（原文）、result.txt（译文），可选 context.txt（原句）、origin.txt（来源）、
/// scene.txt（场景 id）。截图写到同目录的 snapshot.png，然后退出。
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
        popup.showDemo(capture, result: read("result.txt") ?? "", sceneID: read("scene.txt"),
                       near: NSPoint(x: screen.midX - 200, y: screen.midY + 200))
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            popup.snapshot(to: dir.appendingPathComponent("snapshot.png"))
            NSApp.terminate(nil)
        }
    }
}
