import AppKit
import Sparkle

/// 自动更新（Sparkle 2）。启动后按设置每天检查一次更新信息（appcast.xml）。
/// 更新信息先从计数服务取（Cloudflare，原样转发 GitHub Pages 上的那份，顺便数一下当天有多少台机器在用，
/// 只带版本号，见 cloudflare/README.md）；取不到就改从 GitHub Pages 直接取一次，计数服务挂了不影响更新。
/// 默认（SUAutomaticallyUpdate）发现新版就在后台下载、校验签名；菜单栏 App 很少退出，所以下载好后
/// 等用户空闲（2 分钟没操作、没有浮窗/设置窗、没在改写）时静默替换并重启，退出时也会装。
/// 关掉「自动下载并安装」则回到弹窗模式：显示更新说明，点「安装」后下载、替换并重启。设置和数据都在
/// ~/Library/Application Support 和偏好设置里，升级不会动它们；签名不变，系统权限也不会丢。
@MainActor
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updater()

    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var idleTimer: Timer?
    /// 这一轮检查改用 GitHub Pages 上的原始地址（Info.plist 的 SUFeedURL）。
    @ObservationIgnored private var usingFallbackFeed = false
    private static let countingFeed = "https://fanyi-updates.pages.dev/appcast.xml"

    /// 开发运行（评测、演示截图）和没配公钥的本机编译版不启动更新。
    var isAvailable: Bool { controller != nil }

    func start() {
        guard !FanyiApp.isDevRun, controller == nil else { return }
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, key != "PLACEHOLDER" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// 发现新版后自动下载，并在空闲时静默安装重启。
    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version)（\(build)）"
    }

    // MARK: SPUStandardUserDriverDelegate

    /// 菜单栏 App 没有 Dock 图标，后台定时检查发现新版本时，把 App 拉到前面再显示更新窗口，免得窗口藏在别的窗口后面。
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                                state: SPUUserUpdateState) {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: SPUUpdaterDelegate

    /// 返回 nil 时 Sparkle 用 Info.plist 里的 SUFeedURL（GitHub Pages）。
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated {
            guard !usingFallbackFeed else { return nil }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            return "\(Self.countingFeed)?v=\(version)"
        }
    }

    /// 计数服务取不到或返回的内容读不懂：马上改从 GitHub Pages 再查一次；下一轮仍先试计数服务。
    /// 实测取不到更新信息时 Sparkle 报的是 downloadError（2001），和安装包下载失败同一个码，所以那种情况也会多查一次，无害。
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let nsError = error as NSError?
        let feedFailed = nsError?.domain == SUSparkleErrorDomain
            && [SUError.downloadError, .appcastError, .appcastParseError].map { Int($0.rawValue) }.contains(nsError?.code ?? 0)
        MainActor.assumeIsolated {
            if usingFallbackFeed {
                usingFallbackFeed = false
            } else if feedFailed {
                usingFallbackFeed = true
                DiagnosticsLog.shared.add("自动更新：计数服务取不到更新信息，改从 GitHub Pages 取")
                // 必须在这个回调里当场发起：回调一返回 Sparkle 就开始排下一次定时检查，那之后再调会被当成“检查进行中”忽略。
                updater.checkForUpdatesInBackground()
            }
        }
    }

    /// 自动下载好的更新：接管安装时机，空闲时立即装（不弹任何窗口），而不是只等退出。
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        Task { @MainActor in self.scheduleInstall(immediateInstallHandler) }
        return true
    }

    private func scheduleInstall(_ install: @escaping () -> Void) {
        pendingInstall = install
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in Updater.shared.installIfIdle() }
        }
    }

    private func installIfIdle() {
        guard let install = pendingInstall, Self.userIsIdle else { return }
        pendingInstall = nil
        idleTimer?.invalidate()
        idleTimer = nil
        DiagnosticsLog.shared.add("自动更新：空闲，静默安装并重启")
        install()
    }

    /// 2 分钟没碰键盘鼠标、没有可见的浮窗/设置窗（菜单栏图标本身除外）、没在改写。
    private static var userIsIdle: Bool {
        let anyEvent = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
        guard idle >= 120 else { return false }
        guard !PolishCoordinator.shared.isRunning else { return false }
        let windowOpen = NSApp.windows.contains { $0.isVisible && $0.className != "NSStatusBarWindow" && $0.frame.width > 40 }
        return !windowOpen
    }
}
