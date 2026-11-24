import Foundation
import Observation

/// 翻译场景：不同来源的文字用不同的翻译要求（文档要书面、保留结构；聊天要口语；代码要保留标识符……）。
struct TranslationScene: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    /// 写进提示词的翻译要求
    var instructions: String
    /// 自动识别用的关键词：命中 App 名、Bundle ID、窗口标题或网址（不分大小写）就用这个场景
    var keywords: [String]
    var builtIn: Bool

    static let generalID = "general"

    func matches(_ source: SourceInfo) -> Bool {
        let haystack = source.matchText
        return keywords.contains { keyword in
            let k = keyword.trimmingCharacters(in: .whitespaces).lowercased()
            return !k.isEmpty && haystack.contains(k)
        }
    }
}

extension TranslationScene {
    static let defaults: [TranslationScene] = [
        TranslationScene(
            id: generalID, name: "通用",
            instructions: "",
            keywords: [], builtIn: true),
        TranslationScene(
            id: "document", name: "文档",
            instructions: """
            这是一份正式文档（方案、报告、说明、会议纪要等）。
            - 用规范的书面语，句子完整，不口语化，不加原文没有的内容，也不省略。
            - 保留原文结构：标题、编号、列表、表格行、段落一一对应，列表符号和编号照原样输出。
            - 同一个术语全文译法一致；产品名、项目名、人名、代码、链接、数字、日期和单位保持原样。
            - 缩写第一次出现时可以在括号里保留原文，例如「服务等级协议（SLA）」。
            """,
            keywords: ["docs.google.com", "Google Docs", "Google 文档", "Google Slides", "Google 幻灯片",
                       "com.apple.iWork.Pages", "com.microsoft.Word", "com.microsoft.Powerpoint",
                       "notion.so", "notion.site", "notion.id", "atlassian.net/wiki", "confluence",
                       "feishu.cn/docx", "feishu.cn/wiki", "larksuite.com/docx", "larksuite.com/wiki", "quip.com",
                       "dropbox.com/paper", ".docx", ".pages"],
            builtIn: true),
        TranslationScene(
            id: "tech", name: "技术",
            instructions: """
            这是技术内容（技术文档、代码、命令行输出、报错、设计评审）。
            - 代码、函数名、类名、变量名、命令、参数、路径、配置项、报错原文一律保持原样，不翻译。
            - 代码块只翻译其中的注释和说明文字。
            - 用业界通用的中文译法（如 thread→线程、cache→缓存、deploy→部署）；没有公认译法的词保留英文。
            - 风格简洁准确，像国内大厂的技术文档。
            """,
            keywords: ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                       "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp", "com.jetbrains", "ghostty",
                       "github.com", "gitlab", "stackoverflow.com", "developer.apple.com", "developer.mozilla.org",
                       "readthedocs", "docs.python.org", "pkg.go.dev", "docs.rs", "kubernetes.io", "docs.aws.amazon.com",
                       "cloud.google.com/docs", "learn.microsoft.com", "npmjs.com"],
            builtIn: true),
        TranslationScene(
            id: "academic", name: "学术",
            instructions: """
            这是学术论文或研究资料。
            - 用严谨的学术书面语，忠实原文的限定词（may、likely、significantly 等）和逻辑关系。
            - 引用标记（如 [12]、(Smith et al., 2020)）、公式、变量、数据和单位保持原样。
            - 专业术语用学界通用译法，第一次出现时在括号里附上英文原词。
            """,
            keywords: ["arxiv.org", "scholar.google", "semanticscholar.org", "ieeexplore", "dl.acm.org",
                       "sciencedirect.com", "springer.com", "nature.com", "science.org", "pubmed", "ncbi.nlm.nih.gov",
                       "openreview.net", "researchgate.net", "jstor.org", "org.zotero.zotero", "arXiv"],
            builtIn: true),
        TranslationScene(
            id: "chat", name: "邮件与聊天",
            instructions: """
            这是邮件或即时消息。
            - 跟着原文的语气走：正式邮件就礼貌得体，同事聊天就自然随意，不要翻成书面公文。
            - 译成英文时写成母语者会发出的消息，地道、简短，不要中式英语。
            - 保留 @人名、表情、链接、代码片段和格式。
            """,
            keywords: ["com.tinyspeck.slackmacgap", "app.slack.com", "com.apple.mail", "com.microsoft.Outlook",
                       "com.microsoft.teams", "com.tencent.xinWeChat", "com.electron.lark", "com.bytedance.lark",
                       "ru.keepcoder.Telegram", "org.telegram", "net.whatsapp", "com.hnc.Discord", "mail.google.com",
                       "outlook.office", "outlook.live.com", "com.apple.MobileSMS", "com.readdle.smartemail"],
            builtIn: true),
        TranslationScene(
            id: "legal", name: "合同与条款",
            instructions: """
            这是合同、协议、政策或法律条款。
            - 严格忠实原文，宁可直译也不意译，不增不减，不做总结。
            - 区分情态：shall / must 译「应」，may 译「可以」，shall not 译「不得」；中译英时反之。
            - 条款编号、定义术语（首字母大写的词）保持一致，同一定义全文同一译法；金额、日期、期限原样保留。
            """,
            keywords: ["Agreement", "Contract", "Terms of Service", "Terms and Conditions", "Privacy Policy",
                       "合同", "docusign", "ironcladapp"],
            builtIn: true),
    ]
}

/// 场景的保存和自动识别。内置场景可以改要求和关键词，也可以恢复默认；自定义场景可以删除。
@MainActor
@Observable
final class SceneStore {
    static let shared = SceneStore()

    private(set) var scenes: [TranslationScene]

    private static let storageKey = "scenes.v1"
    static let autoDetectKey = "scenes.autoDetect"
    static let defaultSceneKey = "scenes.default"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([TranslationScene].self, from: data) {
            // 新版本增加的内置场景补进来
            var merged = saved
            for scene in TranslationScene.defaults where !merged.contains(where: { $0.id == scene.id }) {
                merged.append(scene)
            }
            scenes = merged
        } else {
            scenes = TranslationScene.defaults
        }
    }

    var autoDetect: Bool { UserDefaults.standard.object(forKey: Self.autoDetectKey) as? Bool ?? true }
    var defaultSceneID: String { UserDefaults.standard.string(forKey: Self.defaultSceneKey) ?? TranslationScene.generalID }

    func scene(id: String?) -> TranslationScene {
        scenes.first { $0.id == id } ?? scenes.first { $0.id == TranslationScene.generalID } ?? TranslationScene.defaults[0]
    }

    /// 按来源选场景：自定义场景优先，其次内置场景，都不命中时用默认场景。
    func detect(for source: SourceInfo?) -> TranslationScene {
        if autoDetect, let source {
            let ordered = scenes.filter { !$0.builtIn } + scenes.filter(\.builtIn)
            if let hit = ordered.first(where: { $0.id != TranslationScene.generalID && $0.matches(source) }) { return hit }
        }
        return scene(id: defaultSceneID)
    }

    func update(_ scene: TranslationScene) {
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[index] = scene
        persist()
    }

    @discardableResult
    func add(name: String) -> TranslationScene {
        let scene = TranslationScene(id: "custom-\(UUID().uuidString.prefix(8))", name: name,
                                     instructions: "", keywords: [], builtIn: false)
        scenes.append(scene)
        persist()
        return scene
    }

    func remove(id: String) {
        scenes.removeAll { $0.id == id && !$0.builtIn }
        if defaultSceneID == id { UserDefaults.standard.removeObject(forKey: Self.defaultSceneKey) }
        persist()
    }

    func resetToDefault(id: String) {
        guard let original = TranslationScene.defaults.first(where: { $0.id == id }) else { return }
        update(original)
    }

    /// 「以后这里都用这个场景」：把来源的网站或 App 加进场景关键词，并从其他场景里去掉。
    func remember(_ source: SourceInfo, as sceneID: String) {
        guard let keyword = Self.rememberKeyword(for: source) else { return }
        for index in scenes.indices {
            scenes[index].keywords.removeAll { $0.lowercased() == keyword.lowercased() }
        }
        if let index = scenes.firstIndex(where: { $0.id == sceneID }), sceneID != TranslationScene.generalID {
            scenes[index].keywords.insert(keyword, at: 0)
        }
        persist()
    }

    /// 网页用域名，其他用 Bundle ID。
    static func rememberKeyword(for source: SourceInfo) -> String? {
        if let host = source.host, !host.isEmpty, !source.url.hasPrefix("file:") { return host }
        return source.bundleID.isEmpty ? nil : source.bundleID
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(scenes) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
