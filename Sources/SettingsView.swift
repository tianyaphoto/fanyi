import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage(Settings.providerKey) private var provider = Provider.claude
    @AppStorage(Settings.selectionIconKey) private var selectionIcon = true
    @AppStorage(Settings.copyFallbackKey) private var copyFallback = true
    @AppStorage(Settings.enhancedAccessibilityKey) private var enhancedAccessibility = true
    @AppStorage(Settings.historyEnabledKey) private var historyEnabled = true
    @AppStorage(Settings.screenshotVisionKey) private var screenshotVision = false
    @AppStorage(ClipboardHistory.enabledKey) private var clipboardHistory = true
    @AppStorage(Settings.bedrockGatewayAuthKey) private var gatewayAuth = Settings.GatewayAuth.apiKey
    @AppStorage(PolishRules.spellingKey) private var spelling = PolishRules.Spelling.british
    @AppStorage(PolishRules.translateInstructionsKey) private var translateInstructions = ""
    @AppStorage(PolishRules.polishInstructionsKey) private var polishInstructions = ""
    @AppStorage(Settings.primaryLanguageKey) private var primaryLanguage = Language.chinese.code
    @AppStorage(Settings.secondaryLanguageKey) private var secondaryLanguage = Language.english.code
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

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
                .onChange(of: provider) { _, value in apiKey = APIKeyStore.apiKey(for: value) ?? "" }

                Group {
                    switch provider {
                    case .claude:
                        keyField(prompt: "sk-ant-…")
                        urlField()
                        modelField()
                        note("模型名在 Anthropic 的模型列表里查，需要自己填写。")
                    case .bedrock:
                        keyField(prompt: "Amazon Bedrock API Key")
                        StoredField("区域", key: Settings.bedrockRegionKey, prompt: Settings.defaultBedrockRegion)
                        modelField()
                        note("通过 Amazon Bedrock 使用 Claude，模型名带 anthropic. 前缀。在 AWS 控制台的 Amazon Bedrock → API keys 中生成 Key，并确认账号已开通所选模型。短期 Key 最长 12 小时有效，过期后要重新填写。")
                    case .bedrockGateway:
                        keyField(prompt: "网关的 API Key")
                        Picker("认证方式", selection: $gatewayAuth) {
                            ForEach(Settings.GatewayAuth.allCases) { Text($0.title).tag($0) }
                        }
                        urlField(prompt: "https://你的网关地址")
                        modelField()
                        headersField()
                        note("通过企业网关或代理调用 Bedrock 上的 Claude：请求发到「API 地址/model/模型ID/invoke」（地址里已经带 /invoke 时原样使用）。不做 AWS 签名，也不读取本机的 AWS 凭据。模型 ID 例如 us.anthropic.claude-sonnet-4-5-20250929-v1:0。")
                    case .openai:
                        keyField(prompt: "sk-…")
                        urlField()
                        modelField()
                        note("使用 Chat Completions 接口。")
                    case .deepseek:
                        keyField(prompt: "sk-…")
                        urlField()
                        modelField()
                        note("在 platform.deepseek.com 获取 API Key。DeepSeek 不能看图，截图翻译会先在本机识别文字。")
                    case .qwen:
                        keyField(prompt: "sk-…")
                        urlField()
                        modelField()
                        note("阿里云百炼的 OpenAI 兼容接口。截图翻译会先在本机识别文字，再发给模型。")
                    case .custom:
                        keyField(prompt: "不需要时留空")
                        urlField(prompt: "https://…/v1")
                        modelField()
                        headersField()
                        note("任何兼容 OpenAI Chat Completions 的服务，例如 Kimi、智谱、硅基流动、OpenRouter，或本机的 Ollama（地址填 http://localhost:11434/v1，API Key 留空）。")
                    case .claudeCLI:
                        modelField()
                        StoredField("claude 路径", key: Settings.cliPathKey, prompt: "留空自动查找")
                        note("调用本机的 Claude Code（claude -p），使用你已登录的 Claude 账号，不需要 API Key。每次翻译要启动一次命令，比直接调 API 慢 1-2 秒。")
                    }
                }
                .id(provider)
            }

            Section {
                note("所有服务的 API Key 都以明文保存在本机 ~/Library/Application Support/Fanyi/ 下（文件权限仅本人可读写），翻译和一键改写共用，不写入安装包或源码。")
            }

            Section("翻译语言") {
                Picker("主要语言", selection: $primaryLanguage) {
                    ForEach(Language.all) { Text($0.name).tag($0.code) }
                }
                HStack {
                    Picker("另一种语言", selection: $secondaryLanguage) {
                        ForEach(Language.all) { Text($0.name).tag($0.code) }
                    }
                    Button {
                        (primaryLanguage, secondaryLanguage) = (secondaryLanguage, primaryLanguage)
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .help("对调两种语言")
                }
                note("主要语言的文字译成另一种语言，另一种语言的文字译成主要语言，其它语言一律译成主要语言。默认是简体中文 ⇄ 英语。翻译浮窗上的「→ 语言」可以临时换成任意一种语言。一键改写不受影响，总是输出英文。")
                if primaryLanguage == secondaryLanguage {
                    note("两种语言相同时，所有文字都译成\(Language.find(primaryLanguage)?.name ?? "")。")
                }
            }

            Section("划词翻译") {
                Toggle("选中文字后显示翻译小图标", isOn: $selectionIcon)
                Toggle("增强取词：直接读取 Chrome、VS Code 等应用里的文字", isOn: $enhancedAccessibility)
                Text("这类应用默认不提供文字内容。打开后会让它们开启辅助功能支持，这样不经过剪贴板也能取词，还能读到原句。它们可能因此略微变慢；如果窗口管理工具的动画变得异常，请关闭这一项并重启对应的应用。Google 文档的正文画在画布上，读不到，会自动改用拷贝取词（需要打开下面的兼容模式）。")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Toggle("兼容模式：读取不到选中文字时执行一次拷贝", isOn: $copyFallback)
                Text("优先触发应用的「拷贝」菜单项，没有时模拟 ⌘C，取词后会自动恢复剪贴板。")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }

            Section("场景与资料库") {
                HStack {
                    Text("按来源自动选翻译场景（文档、技术、学术、邮件与聊天……），并参考你的资料库和术语表。")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开…") { Windows.showLibrary() }
                }
            }

            Section {
                Picker("英文拼写", selection: $spelling) {
                    ForEach(PolishRules.Spelling.allCases) { Text($0.title).tag($0) }
                }
                instructionsEditor("中文译成英文时的额外要求", text: $translateInstructions,
                                   placeholder: "例如：保留产品名 GrabPay 不翻译；称呼同事用名字")
                instructionsEditor("英文纠错润色时的额外要求", text: $polishInstructions,
                                   placeholder: "例如：语气友好但简短；不要用感叹号")
                HStack {
                    Button(testing ? "测试中…" : "测试连接") {
                        testing = true
                        testResult = nil
                        Task {
                            testResult = await PolishService.testConnection()
                            testing = false
                        }
                    }
                    .disabled(testing)
                    Button("诊断日志…") { Windows.showDiagnostics() }
                    Spacer()
                }
                if let testResult {
                    Text(testResult.message)
                        .font(Theme.caption)
                        .foregroundStyle(testResult.ok ? Color.secondary : Theme.danger)
                        .textSelection(.enabled)
                }
            } header: {
                Text("一键改写")
            } footer: {
                note("在聊天框或文档里按「改写当前输入框」（默认 ⌃⌥⌘T）：自动全选、复制，中文和中英混合译成英文，英文纠错并改得自然简洁，然后替换原文，不会按回车发送。也可以先复制文字，再按「改写剪贴板内容」（默认 ⌃⇧⌘C），改完自动粘贴到当时有焦点的输入框（等待时切换了窗口也会贴到新位置），结果同时留在剪贴板里。使用上面选的翻译服务；链接和代码原样保留；最多 10,000 字，30 秒超时。需要「辅助功能」权限。")
            }

            Section("剪贴板历史") {
                Toggle("记录最近 \(ClipboardHistory.limit) 条复制的文字", isOn: $clipboardHistory)
                    .onChange(of: clipboardHistory) { _, on in if !on { ClipboardHistory.shared.clear() } }
                note("按「剪贴板历史」（默认 ⌃⌥⌘V）弹出列表，可以搜索；点一条（或回车）会把它放回剪贴板第一条，并粘贴到当前输入框。只保存在内存里，退出即清空；密码管理器标记为隐藏的内容不记录。关闭时会清空已有记录。")
            }

            Section("截图翻译") {
                Toggle("看图翻译：把截图直接发给模型", isOn: $screenshotVision)
                note("对表格、公式、手写体效果更好，但更慢、更费额度，截图本身会上传给所选的翻译服务。关闭时只在本机识别文字，再发送文字。使用自定义服务时，所选模型需要支持图片输入；DeepSeek 和通义千问不看图，仍按本机识别处理。")
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
                        .font(Theme.caption)
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

            Section("更新") {
                LabeledContent("当前版本", value: Updater.shared.versionDescription)
                if Updater.shared.isAvailable {
                    Toggle("自动检查更新（每天一次）", isOn: Binding(
                        get: { Updater.shared.automaticallyChecksForUpdates },
                        set: { Updater.shared.automaticallyChecksForUpdates = $0 }))
                    Button("立即检查更新") { Updater.shared.checkForUpdates() }
                        .disabled(!Updater.shared.canCheckForUpdates)
                    note("有新版本时会弹窗显示更新说明，点「安装」后自动下载、校验签名、替换并重启。设置、生词本、历史、资料库和 API Key 都会保留。")
                } else {
                    note("这是本机编译的开发版，不检查更新。")
                }
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
        .frame(minWidth: 520, minHeight: 640)
        .onAppear { apiKey = APIKeyStore.apiKey(for: provider) ?? "" }
        .onReceive(timer) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            screenGranted = CGPreflightScreenCaptureAccess()
        }
    }

    private func keyField(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("API Key", text: $apiKey, prompt: Text(prompt))
                .onChange(of: apiKey) { _, value in
                    // 切换服务时 apiKey 会被重新载入，只在内容确实变化时写文件。
                    if value != (APIKeyStore.apiKey(for: provider) ?? "") {
                        APIKeyStore.setAPIKey(value, for: provider)
                    }
                }
            if APIKeyStore.needsReentry.contains(provider) && apiKey.isEmpty {
                Text("以前保存在钥匙串里的 Key 没能自动搬过来（系统要求确认），请重新填写一次。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.repeated)
            }
        }
    }

    private func urlField(prompt: String? = nil) -> some View {
        StoredField("API 地址", key: Settings.baseURLKey(for: provider),
                    prompt: prompt ?? Settings.defaultBaseURL(for: provider))
    }

    private func modelField() -> some View {
        StoredField("模型", key: Settings.modelKey(for: provider),
                    prompt: provider == .claudeCLI ? "必填，例如 sonnet" : "必填，服务商提供的模型名")
    }

    private func headersField() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("额外请求头（每行「名称: 值」，认证头由 API Key 管理）")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            HeadersEditor(key: Settings.extraHeadersKey(for: provider))
        }
    }

    private func instructionsEditor(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(Theme.body)
                .frame(height: 48)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.surface))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder).font(Theme.body).foregroundStyle(.tertiary).padding(9).allowsHitTesting(false)
                    }
                }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    private func permissionRow(_ title: String, granted: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Theme.success : Theme.repeated)
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

/// 多行请求头编辑框，直接读写某个 UserDefaults 键。
private struct HeadersEditor: View {
    @AppStorage private var value: String

    init(key: String) { _value = AppStorage(wrappedValue: "", key) }

    var body: some View {
        TextEditor(text: $value)
            .font(.system(size: 12, design: .monospaced))
            .frame(height: 44)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.surface))
    }
}

/// 直接读写某个 UserDefaults 键的文本框。
private struct StoredField: View {
    let title: String
    let prompt: String
    @AppStorage private var value: String

    init(_ title: String, key: String, prompt: String) {
        self.title = title
        self.prompt = prompt
        _value = AppStorage(wrappedValue: "", key)
    }

    var body: some View {
        TextField(title, text: $value, prompt: Text(prompt))
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
                    .foregroundStyle(Theme.repeated)
                    .help("这个快捷键已被其他应用占用，请换一个")
                    .accessibilityLabel("快捷键被占用")
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
