import Foundation
import LocalAuthentication
import Security

/// API Key 保存在 ~/Library/Application Support/Fanyi/credentials.json（文件权限 600，目录 700），明文、不加密。
/// 翻译和一键改写共用这一份，每个服务一条。以前存在钥匙串里的密钥，启动时无提示搬过来，确认后从钥匙串删除；
/// 之后不再访问钥匙串。
enum APIKeyStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fanyi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("credentials.json")
    }()

    /// 每个服务在文件里的键名（沿用旧钥匙串的账户名；Claude API 和 claude -p 共用一条）。
    static func account(_ provider: Provider) -> String {
        switch provider {
        case .claude, .claudeCLI: return "anthropic-api-key"
        default: return "\(provider.rawValue)-api-key"
        }
    }

    static func apiKey(for provider: Provider) -> String? {
        let value = load()[account(provider)]
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func setAPIKey(_ value: String, for provider: Provider) {
        var all = load()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        all[account(provider)] = trimmed.isEmpty ? nil : trimmed
        save(all)
        needsReentry.remove(provider)
    }

    private static func load() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let decoded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = decoded
        return decoded
    }

    @discardableResult
    private static func save(_ all: [String: String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            return false
        }
        cache = all
        return true
    }

    /// 钥匙串里有、但没能无提示读出来的服务（设置里提示重新填写）。
    nonisolated(unsafe) private(set) static var needsReentry: Set<Provider> = []

    /// 一次性迁移：钥匙串里的旧密钥无提示读出来写进文件，确认文件里读得到后删掉钥匙串里的旧项目。
    /// 系统要求确认（例如换过签名）时不弹窗，记下来让用户在设置里重新填。全部处理完以后不再访问钥匙串。
    static func migrateFromKeychain() {
        let doneKey = "apiKeys.migratedFromKeychain"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        var all = load()
        var migrated: [String] = []
        var pending: Set<Provider> = []
        var seen = Set<String>()
        for provider in Provider.allCases {
            let acct = account(provider)
            guard seen.insert(acct).inserted, all[acct] == nil else { continue }
            switch LegacyKeychain.read(account: acct) {
            case .found(let key):
                all[acct] = key
                migrated.append(acct)
            case .needsInteraction:
                pending.insert(provider)
            case .missing:
                break
            }
        }
        if !migrated.isEmpty {
            guard save(all) else { return }
            lock.lock(); cache = nil; lock.unlock()
            let reloaded = load()
            for acct in migrated where reloaded[acct] != nil {
                LegacyKeychain.delete(account: acct)
            }
        }
        needsReentry = pending
        // 有读不出来的就下次启动再试（用户重新填写后自然不用再迁）
        if pending.isEmpty { UserDefaults.standard.set(true, forKey: doneKey) }
    }
}

/// 旧版本的钥匙串存储，只用于一次性迁移。
private enum LegacyKeychain {
    private static let service = "com.local.fanyi"

    enum ReadResult { case found(String), needsInteraction, missing }

    static func read(account: String) -> ReadResult {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return .missing }
            return .found(key)
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return .needsInteraction
        default:
            return .missing
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
