import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage(Settings.baseURLKey) private var baseURL = Settings.defaultBaseURL
    @AppStorage(Settings.modelKey) private var model = Settings.defaultModel
    @AppStorage(Settings.providerKey) private var provider = Provider.claude
    @AppStorage(Settings.openAIBaseURLKey) private var openAIBaseURL = Settings.defaultOpenAIBaseURL
    @AppStorage(Settings.openAIModelKey) private var openAIModel = Settings.defaultOpenAIModel
    @AppStorage(Settings.cliModelKey) private var cliModel = Settings.defaultCLIModel
    @AppStorage(Settings.cliPathKey) private var cliPath = ""
    @AppStorage(Settings.selectionIconKey) private var selectionIcon = true
    @AppStorage(Settings.copyFallbackKey) private var copyFallback = true
    @AppStorage(Settings.historyEnabledKey) private var historyEnabled = true
    @AppStorage(Settings.screenshotVisionKey) private var screenshotVision = false

    @State private var apiKey = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenGranted = CGPreflightScreenCaptureAccess()

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("翻译服务") {
                Picker("服务", selection: $provider) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: provider) { _, value in apiKey = Keychain.apiKey(for: value) ?? "" }

                switch provider {
                case .claude:
                    keyField(prompt: "sk-ant-…")
                    TextField("API 地址", text: $baseURL, prompt: Text(Settings.defaultBaseURL))
                    modelField($model, prompt: Settings.defaultModel, presets: Settings.presetModels)
                    note("API Key 保存在系统钥匙串中。默认模型质量最好；想更快更省可以换成 claude-haiku-5-5。")
                case .openai:
                    keyField(prompt: "sk-…")
                    TextField("API 地址", text: $openAIBaseURL, prompt: Text(Settings.defaultOpenAIBaseURL))
                    TextField("模型", text: $openAIModel, prompt: Text(Settings.defaultOpenAIModel))
                    note("使用 Chat Completions 接口，也兼容 DeepSeek 等同格式的服务（改 API 地址和模型名即可）。")
                case .claudeCLI:
                    modelField($cliModel, prompt: Settings.defaultCLIModel, presets: Settings.presetCLIModels)
                    TextField("claude 路径", text: $cliPath, prompt: Text("留空自动查找"))
                    note("调用本机的 Claude Code（claude -p），使用你已登录的 Claude 账号，不需要 API Key。每次翻译要启动一次命令，比直接调 API 慢 1-2 秒。")
                }
            }

            Section("划词翻译") {
                Toggle("选中文字后显示翻译小图标", isOn: $selectionIcon)
                Toggle("兼容模式：读取不到选中文字时模拟 ⌘C", isOn: $copyFallback)
                Text("兼容模式用于 Chrome、VS Code 等应用，取词后会自动恢复剪贴板。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("截图翻译") {
                Toggle("看图翻译：把截图直接发给模型", isOn: $screenshotVision)
                note("对表格、公式、手写体效果更好，但更慢、更费额度，截图本身会上传给所选的翻译服务。关闭时只在本机识别文字，再发送文字。使用 OpenAI 兼容服务时，所选模型需要支持图片输入。")
            }

            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) { ShortcutRecorder(action: action) }
                }
            } header: {
                HStack {
                    Text("快捷键")
                    Spacer()
                    Button("恢复默认") { ShortcutCenter.shared.resetToDefaults() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } footer: {
                note("点击后按下新的组合键（需包含 ⌘、⌥ 或 ⌃），Esc 取消。")
            }

            Section("查词历史") {
                Toggle("记录查词历史", isOn: $historyEnabled)
                note("重复查询同一个词时会提示次数，方便发现该收藏的生词。历史只保存在本机。")
            }

            Section("权限") {
                permissionRow("辅助功能（划词取词）", granted: accessibilityGranted,
                              pane: "Privacy_Accessibility")
                permissionRow("屏幕录制（截图翻译）", granted: screenGranted,
                              pane: "Privacy_ScreenCapture")
            }

            Section {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .onAppear { apiKey = Keychain.apiKey(for: provider) ?? "" }
        .onReceive(timer) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            screenGranted = CGPreflightScreenCaptureAccess()
        }
    }

    private func keyField(prompt: String) -> some View {
        SecureField("API Key", text: $apiKey, prompt: Text(prompt))
            .onChange(of: apiKey) { _, value in
                // 切换服务时 apiKey 会被重新载入，只在内容确实变化时写钥匙串。
                if value != (Keychain.apiKey(for: provider) ?? "") {
                    Keychain.setAPIKey(value, for: provider)
                }
            }
    }

    private func modelField(_ binding: Binding<String>, prompt: String, presets: [String]) -> some View {
        HStack {
            TextField("模型", text: binding, prompt: Text(prompt))
            Menu("选择") {
                ForEach(presets, id: \.self) { name in
                    Button(name) { binding.wrappedValue = name }
                }
            }
            .fixedSize()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func permissionRow(_ title: String, granted: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if !granted {
                Button("去授权") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                Text("已授权").foregroundStyle(.secondary)
            }
        }
    }
}

/// 点击后录制一个新的全局快捷键。
struct ShortcutRecorder: View {
    let action: HotKeyAction

    @State private var recording = false
    @State private var monitor: Any?
    private var center: ShortcutCenter { .shared }

    var body: some View {
        HStack(spacing: 6) {
            if center.failed.contains(action) && !recording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("这个快捷键已被其他应用占用，请换一个")
            }
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "请按下快捷键…" : (center.display(for: action) ?? "未设置"))
                    .frame(minWidth: 96)
            }
            if center.display(for: action) != nil && !recording {
                Button {
                    center.set(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("清除快捷键")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        center.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
            } else if let shortcut = ShortcutCenter.make(from: event) {
                center.set(shortcut, for: action)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            center.apply()
        }
    }
}
