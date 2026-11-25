import AppKit
import Sparkle

/// 自动更新（Sparkle 2）。启动后按设置每天检查一次 GitHub Pages 上的更新信息（appcast.xml），
/// 有新版本时弹窗显示更新说明，点「安装」后下载、校验签名、替换并重启。设置和数据都在
/// ~/Library/Application Support 和偏好设置里，升级不会动它们；签名不变，系统权限也不会丢。
@MainActor
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// 开发运行（评测、演示截图）和没配公钥的本机编译版不启动更新。
    var isAvailable: Bool { controller != nil }

    func start() {
        guard !FanyiApp.isDevRun, controller == nil else { return }
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, key != "PLACEHOLDER" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
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
}
