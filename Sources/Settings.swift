import Foundation
import Security

/// 翻译服务。
enum Provider: String, CaseIterable, Identifiable {
    case claude, openai, claudeCLI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude API"
        case .openai: return "OpenAI API"
        case .claudeCLI: return "claude -p"
        }
    }

    /// 是否已经配置到可以直接使用。
    var isConfigured: Bool {
        switch self {
        case .claude, .openai: return !(Keychain.apiKey(for: self) ?? "").isEmpty
        case .claudeCLI: return true
        }
    }
}

enum Settings {
    static let providerKey = "provider"
    static let baseURLKey = "baseURL"
    static let modelKey = "model"
    static let openAIBaseURLKey = "openAIBaseURL"
    static let openAIModelKey = "openAIModel"
    static let cliModelKey = "cliModel"
    static let cliPathKey = "cliPath"
    static let selectionIconKey = "selectionIconEnabled"
    static let copyFallbackKey = "copyFallbackEnabled"

    static let defaultBaseURL = "https://api.anthropic.com"
    static let defaultModel = "claude-opus-5-5"
    static let presetModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"]

    static let defaultOpenAIBaseURL = "https://api.openai.com/v1"
    static let defaultOpenAIModel = "gpt-5-mini"

    static let defaultCLIModel = "haiku"
    static let presetCLIModels = ["haiku", "sonnet", "opus"]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            providerKey: Provider.claude.rawValue,
            baseURLKey: defaultBaseURL,
            modelKey: defaultModel,
            openAIBaseURLKey: defaultOpenAIBaseURL,
            openAIModelKey: defaultOpenAIModel,
            cliModelKey: defaultCLIModel,
            cliPathKey: "",
            selectionIconKey: true,
            copyFallbackKey: true,
        ])
    }

    private static func string(_ key: String, default fallback: String) -> String {
        let value = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    static var provider: Provider {
        Provider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .claude
    }

    static var baseURL: String { string(baseURLKey, default: defaultBaseURL) }
    static var model: String { string(modelKey, default: defaultModel) }
    static var openAIBaseURL: String { string(openAIBaseURLKey, default: defaultOpenAIBaseURL) }
    static var openAIModel: String { string(openAIModelKey, default: defaultOpenAIModel) }
    static var cliModel: String { string(cliModelKey, default: defaultCLIModel) }
    static var cliPath: String { string(cliPathKey, default: "") }

    static var selectionIconEnabled: Bool { UserDefaults.standard.bool(forKey: selectionIconKey) }
    static var copyFallbackEnabled: Bool { UserDefaults.standard.bool(forKey: copyFallbackKey) }
}

/// API Key 存在系统钥匙串里，每个服务一条。
enum Keychain {
    private static let service = "com.local.fanyi"

    private static func account(_ provider: Provider) -> String {
        provider == .openai ? "openai-api-key" : "anthropic-api-key"
    }

    private static func baseQuery(_ provider: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(provider)]
    }

    static func apiKey(for provider: Provider) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setAPIKey(_ value: String, for provider: Provider) {
        SecItemDelete(baseQuery(provider) as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var query = baseQuery(provider)
        query[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }
}
