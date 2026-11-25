import AppKit
// 测试用记事本：一个窗口一个文本框。参数：初始文字文件、结果输出文件、光标位置（-1 = 末尾）、运行秒数
let args = CommandLine.arguments
let initial = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
let outPath = args[2]
let cursor = Int(args[3]) ?? -1
let seconds = Double(args[4]) ?? 30

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let editItem = NSMenuItem(); menu.addItem(NSMenuItem()); menu.addItem(editItem)
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editItem.submenu = edit
app.mainMenu = menu

let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 520, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "翻译神器测试记事本（测试中，请勿操作）"
let text = NSTextView(frame: window.contentView!.bounds)
text.isRichText = false
text.string = initial
window.contentView = text
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(text)
let ns = initial as NSString
text.setSelectedRange(NSRange(location: cursor < 0 ? ns.length : cursor, length: 0))
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    try? text.string.write(toFile: outPath, atomically: true, encoding: .utf8)
    exit(0)
}
app.run()
