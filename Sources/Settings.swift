import Foundation
import Security

/// 翻译服务。
enum Provider: String, CaseIterable, Identifiable {
    case claude, bedrock, bedrockGateway, openai, deepseek, qwen, custom, claudeCLI

    /// 接口格式：同一种格式的服务共用一套请求代码。
    enum Kind { case anthropic, openAICompatible, bedrockInvoke, cli }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude API"
        case .bedrock: return "AWS Bedrock（Claude）"
        case .bedrockGateway: return "Bedrock 网关（Claude）"
        case .openai: return "OpenAI API"
        case .deepseek: return "DeepSeek"
        case .qwen: return "通义千问"
        case .custom: return "自定义（OpenAI 兼容）"
        case .claudeCLI: return "claude -p"
        }
    }

    var kind: Kind {
        switch self {
        case .claude, .bedrock: return .anthropic
        case .openai, .deepseek, .qwen, .custom: return .openAICompatible
        case .bedrockGateway: return .bedrockInvoke
        case .claudeCLI: return .cli
        }
    }

    /// 默认模型能否接收图片（看图翻译）。不能时截图翻译退回本地识别文字。
    var supportsVision: Bool {
        switch self {
        case .deepseek, .qwen: return false
        default: return true
        }
    }

    /// 是否已经配置到可以直接使用。
    var isConfigured: Bool {
        guard !Settings.model(for: self).isEmpty else { return false }
        switch self {
        case .claudeCLI: return true
        // 自定义服务可以没有 API Key（例如本机的 Ollama），但必须填地址和模型
        case .custom: return !Settings.baseURL(for: self).isEmpty
        case .bedrockGateway:
            return !Settings.baseURL(for: self).isEmpty && !(APIKeyStore.apiKey(for: self) ?? "").isEmpty
        default: return !(APIKeyStore.apiKey(for: self) ?? "").isEmpty
        }
    }
}

enum Settings {
    static let providerKey = "provider"
    static let cliPathKey = "cliPath"
    static let bedrockRegionKey = "bedrock.region"
    static let selectionIconKey = "selectionIconEnabled"
    static let copyFallbackKey = "copyFallbackEnabled"
    static let enhancedAccessibilityKey = "enhancedAccessibilityEnabled"
    static let historyEnabledKey = "historyEnabled"
    static let screenshotVisionKey = "screenshotVisionEnabled"
    static let bedrockGatewayAuthKey = "bedrockGateway.auth"

    enum GatewayAuth: String, CaseIterable, Identifiable {
        case apiKey, bearer
        var id: String { rawValue }
        var title: String { self == .apiKey ? "x-api-key" : "Bearer Token" }
    }

    static var bedrockGatewayAuth: GatewayAuth {
        GatewayAuth(rawValue: UserDefaults.standard.string(forKey: bedrockGatewayAuthKey) ?? "") ?? .apiKey
    }

    static func extraHeadersKey(for provider: Provider) -> String { "\(provider.rawValue).headers" }

    /// 额外请求头：每行「名称: 值」。
    static func extraHeaders(for provider: Provider) -> [(String, String)] {
        let raw = UserDefaults.standard.string(forKey: extraHeadersKey(for: provider)) ?? ""
        return raw.components(separatedBy: .newlines).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        }
    }

    static let defaultBedrockRegion = "us-east-1"

    // Claude API 和 OpenAI 沿用最早的键名，其余服务按「服务名.字段」存。
    static func baseURLKey(for provider: Provider) -> String {
        switch provider {
        case .claude: return "baseURL"
        case .openai: return "openAIBaseURL"
        default: return "\(provider.rawValue).baseURL"
        }
    }

    static func modelKey(for provider: Provider) -> String {
        switch provider {
        case .claude: return "model"
        case .openai: return "openAIModel"
        case .claudeCLI: return "cliModel"
        default: return "\(provider.rawValue).model"
        }
    }

    static func defaultBaseURL(for provider: Provider) -> String {
        switch provider {
        case .claude: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .bedrock, .bedrockGateway, .custom, .claudeCLI: return ""
        }
    }

    static func registerDefaults() {
        var defaults: [String: Any] = [
            providerKey: Provider.claude.rawValue,
            cliPathKey: "",
            bedrockRegionKey: defaultBedrockRegion,
            selectionIconKey: true,
            copyFallbackKey: true,
            enhancedAccessibilityKey: true,
            historyEnabledKey: true,
            screenshotVisionKey: false,
        ]
        for provider in Provider.allCases {
            defaults[baseURLKey(for: provider)] = defaultBaseURL(for: provider)
        }
        defaults[modelKey(for: .deepseek)] = deepSeekModels[0]
        // 旧版本手填的 DeepSeek 模型名（如已下线的 deepseek-chat）不在下拉列表里：清掉，回到默认
        let deepSeekKey = modelKey(for: .deepseek)
        if let stored = UserDefaults.standard.string(forKey: deepSeekKey), !deepSeekModels.contains(stored) {
            UserDefaults.standard.removeObject(forKey: deepSeekKey)
        }
        UserDefaults.standard.register(defaults: defaults)
    }

    private static func string(_ key: String, default fallback: String) -> String {
        let value = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    static var provider: Provider {
        Provider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .claude
    }

    static var bedrockRegion: String { string(bedrockRegionKey, default: defaultBedrockRegion) }

    /// 接口根地址。Bedrock 的地址由区域决定。
    static func baseURL(for provider: Provider) -> String {
        if provider == .bedrock { return "https://bedrock-mantle.\(bedrockRegion).api.aws/anthropic" }
        return string(baseURLKey(for: provider), default: defaultBaseURL(for: provider))
    }

    /// DeepSeek 用下拉菜单选模型（官方只有这两个），默认 deepseek-flash。
    static let deepSeekModels = ["deepseek-flash", "deepseek-v4-pro"]

    static func model(for provider: Provider) -> String {
        if provider == .deepseek {
            // 旧版本手填的名字（如已下线的 deepseek-chat）不在列表里时，按默认的 deepseek-flash
            let stored = string(modelKey(for: provider), default: "")
            return deepSeekModels.contains(stored) ? stored : deepSeekModels[0]
        }
        // 其它服务不内置默认模型：模型名由用户自己填写。
        return string(modelKey(for: provider), default: "")
    }

    static var cliPath: String { string(cliPathKey, default: "") }

    static var selectionIconEnabled: Bool { UserDefaults.standard.bool(forKey: selectionIconKey) }
    static var copyFallbackEnabled: Bool { UserDefaults.standard.bool(forKey: copyFallbackKey) }
    static var enhancedAccessibilityEnabled: Bool { UserDefaults.standard.bool(forKey: enhancedAccessibilityKey) }
    /// 演示截图模式（Debug.swift）不记历史，免得假数据混进真实的查词历史。
    static var historyEnabled: Bool {
        UserDefaults.standard.bool(forKey: historyEnabledKey) && ProcessInfo.processInfo.environment["FANYI_DEMO_DIR"] == nil
    }
    static var screenshotVisionEnabled: Bool { UserDefaults.standard.bool(forKey: screenshotVisionKey) }

    /// 「帮你记住」：查外语单词时，在释义后面附上拆词、近义词区别、反义词、搭配、易混词。
    enum MemoryAid: String, CaseIterable, Identifiable {
        case off, repeated, always
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "关闭"
            case .repeated: return "同一个词查到第 3 次时"
            case .always: return "每次查单词"
            }
        }
    }
    static let memoryAidKey = "memoryAid"
    static var memoryAid: MemoryAid {
        MemoryAid(rawValue: UserDefaults.standard.string(forKey: memoryAidKey) ?? "") ?? .off
    }
    /// 第几次查询时要不要附「帮你记住」（lookupCount 为 0 表示没记历史，按第一次算）。
    static func wantsMemoryAid(lookupCount: Int) -> Bool {
        // 演示截图（Debug.swift）不记历史，用 FANYI_DEMO_MEMORY=1 强制打开
        if ProcessInfo.processInfo.environment["FANYI_DEMO_MEMORY"] != nil { return true }
        switch memoryAid {
        case .off: return false
        case .always: return true
        case .repeated: return lookupCount >= 3
        }
    }
}

