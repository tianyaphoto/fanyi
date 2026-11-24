import SwiftUI
import UniformTypeIdentifiers

/// 「场景与资料库」窗口：翻译场景、资料库、术语表三页。
struct LibraryView: View {
    enum Tab: String { case scenes, documents, glossary }

    @AppStorage("library.tab") private var tab = Tab.scenes

    var body: some View {
        TabView(selection: $tab) {
            ScenesPane()
                .tabItem { Text("翻译场景") }
                .tag(Tab.scenes)
            DocumentsPane()
                .tabItem { Text("资料库") }
                .tag(Tab.documents)
            GlossaryPane()
                .tabItem { Text("术语表") }
                .tag(Tab.glossary)
        }
        .padding(Theme.gapM)
        .frame(minWidth: 720, minHeight: 500)
    }
}

// MARK: - 场景

private struct ScenesPane: View {
    @State private var store = SceneStore.shared
    @State private var selection: String? = TranslationScene.generalID
    @AppStorage(SceneStore.autoDetectKey) private var autoDetect = true
    @AppStorage(SceneStore.defaultSceneKey) private var defaultScene = TranslationScene.generalID

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            HStack(spacing: Theme.gapL) {
                Toggle("按来源自动选择场景", isOn: $autoDetect)
                Picker("其余情况用", selection: $defaultScene) {
                    ForEach(store.scenes) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
                Spacer()
            }
            Text("翻译时根据当前 App、窗口标题和网址匹配下面各场景的关键词，例如在 Google 文档里自动用「文档」。浮窗左上角可以临时换场景，也可以记住「以后这个网站都用这个场景」。")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: Theme.gapM) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(store.scenes) { scene in
                            HStack {
                                Text(scene.name)
                                Spacer()
                                if scene.id == defaultScene {
                                    Text("默认").font(Theme.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(scene.id)
                        }
                    }
                    .listStyle(.bordered)
                    HStack {
                        Button {
                            selection = store.add(name: "新场景").id
                        } label: { Image(systemName: "plus") }
                        .help("新建场景")
                        Button {
                            if let selection { store.remove(id: selection) }
                            selection = TranslationScene.generalID
                        } label: { Image(systemName: "minus") }
                        .disabled(store.scene(id: selection).builtIn)
                        .help("删除自定义场景")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, Theme.gapXS)
                }
                .frame(width: 180)

                if let selection, store.scenes.contains(where: { $0.id == selection }) {
                    SceneEditor(scene: store.scene(id: selection))
                        .id(selection)
                } else {
                    EmptyState(title: "选择一个场景", detail: "左边选一个场景查看和修改它的翻译要求。")
                }
            }
        }
        .padding(Theme.gapS)
    }
}

private struct SceneEditor: View {
    @State var scene: TranslationScene
    @State private var keywordsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            HStack {
                TextField("名称", text: $scene.name)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.bodyStrong)
                    .frame(maxWidth: 220)
                Spacer()
                if scene.builtIn && TranslationScene.defaults.first(where: { $0.id == scene.id }) != scene {
                    Button("恢复默认") {
                        SceneStore.shared.resetToDefault(id: scene.id)
                        scene = SceneStore.shared.scene(id: scene.id)
                        keywordsText = scene.keywords.joined(separator: "\n")
                    }
                    .controlSize(.small)
                }
            }

            SectionLabel("翻译要求（写给模型看，越具体越好）")
            TextEditor(text: $scene.instructions)
                .font(Theme.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.surface))
                .frame(minHeight: 150)
                .overlay(alignment: .topLeading) {
                    if scene.instructions.isEmpty {
                        Text(scene.id == TranslationScene.generalID ? "通用场景只用基本规则，也可以在这里补充你的偏好。" : "例如：这是保险产品文档，保单、保费、理赔用行业标准译法……")
                            .font(Theme.body)
                            .foregroundStyle(.tertiary)
                            .padding(11)
                            .allowsHitTesting(false)
                    }
                }

            SectionLabel("自动识别关键词（每行一个，匹配 App 名、Bundle ID、窗口标题或网址）")
            TextEditor(text: $keywordsText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.surface))
                .frame(minHeight: 90)
        }
        .onAppear { keywordsText = scene.keywords.joined(separator: "\n") }
        .onChange(of: scene) { _, value in SceneStore.shared.update(value) }
        .onChange(of: keywordsText) { _, value in
            scene.keywords = value.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}

// MARK: - 资料库

private struct DocumentsPane: View {
    @State private var store = KnowledgeStore.shared
    @AppStorage(KnowledgeStore.enabledKey) private var enabled = true
    @State private var showPaste = false
    @State private var preview: KnowledgeDocument?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            HStack {
                Toggle("翻译时参考资料库", isOn: $enabled)
                Spacer()
                if store.importing > 0 {
                    ProgressView().controlSize(.small)
                    Text("正在读取 \(store.importing) 个文件…").font(Theme.caption).foregroundStyle(.secondary)
                }
                Button("重新读取") { store.reloadFiles() }
                    .help("文件内容改过之后，重新读取所有来自文件的资料")
                    .disabled(!store.documents.contains { $0.path != nil })
                Button("粘贴文字…") { showPaste = true }
                Button("添加文件…") { pickFiles() }
                    .keyboardShortcut("o")
            }
            Text("把项目文档、产品说明、以前的译文放进来。翻译时会在本机检索出最相关的几段，连同命中的术语一起发给翻译服务作参考，让专有名词和说法跟你的资料一致。支持文本、Markdown、PDF、Word、RTF、HTML，可以直接拖文件或文件夹进来；Google 文档请先「文件 → 下载」成 Word 或纯文本，或者复制全文后用「粘贴文字」。")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.repeated)
                    Text(error).font(Theme.caption)
                    Spacer()
                    Button("知道了") { store.lastError = nil }.buttonStyle(.link).font(Theme.caption)
                }
            }

            Group {
                if store.documents.isEmpty {
                    EmptyState(title: "资料库是空的",
                               detail: "添加文件、文件夹或粘贴一段文字。翻译相关内容时会自动参考它们。",
                               actionTitle: "添加文件…", action: pickFiles)
                        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
                } else {
                    Table(store.documents) {
                        TableColumn("启用") { doc in
                            Toggle("", isOn: Binding(get: { doc.enabled }, set: { value in
                                var updated = doc
                                updated.enabled = value
                                store.update(updated)
                            }))
                            .labelsHidden()
                        }
                        .width(36)
                        TableColumn("资料") { doc in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.name).lineLimit(1)
                                if let path = doc.path {
                                    Text((path as NSString).abbreviatingWithTildeInPath)
                                        .font(Theme.caption).foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        TableColumn("字数") { doc in
                            Text("\(doc.charCount)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .width(64)
                        TableColumn("适用场景") { doc in SceneScopeMenu(doc: doc) }
                            .width(130)
                        TableColumn("") { doc in
                            HStack(spacing: 2) {
                                IconButton(symbol: "eye", help: "查看内容") { preview = doc }
                                IconButton(symbol: "trash", help: "从资料库移除") { store.remove(doc.id) }
                            }
                        }
                        .width(60)
                    }
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.accent, lineWidth: 2)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
                return true
            }

            Text("资料只保存在本机（~/Library/Application Support/Fanyi/knowledge.json）。检索出的片段会随翻译请求发给你选择的翻译服务。")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.gapS)
        .sheet(isPresented: $showPaste) { PasteSheet() }
        .sheet(item: $preview) { doc in PreviewSheet(doc: doc) }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "选择要加入资料库的文件或文件夹"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { store.add(urls: panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in KnowledgeStore.shared.add(urls: [url]) }
            }
        }
    }
}

/// 一份资料适用哪些场景：所有场景，或勾选其中几个。
private struct SceneScopeMenu: View {
    let doc: KnowledgeDocument
    private var scenes: [TranslationScene] { SceneStore.shared.scenes }

    var body: some View {
        Menu {
            Button {
                set([])
            } label: {
                if doc.sceneIDs.isEmpty { Label("所有场景", systemImage: "checkmark") } else { Text("所有场景") }
            }
            Divider()
            ForEach(scenes) { scene in
                Button {
                    var ids = doc.sceneIDs
                    if let i = ids.firstIndex(of: scene.id) { ids.remove(at: i) } else { ids.append(scene.id) }
                    set(ids)
                } label: {
                    if doc.sceneIDs.contains(scene.id) { Label(scene.name, systemImage: "checkmark") } else { Text(scene.name) }
                }
            }
        } label: {
            Text(summary).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var summary: String {
        if doc.sceneIDs.isEmpty { return "所有场景" }
        return scenes.filter { doc.sceneIDs.contains($0.id) }.map(\.name).joined(separator: "、")
    }

    private func set(_ ids: [String]) {
        var updated = doc
        updated.sceneIDs = ids
        KnowledgeStore.shared.update(updated)
    }
}

private struct PasteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            Text("粘贴文字到资料库").font(Theme.heading)
            TextField("名称（例如：Q4 规划文档）", text: $name)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(Theme.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.surface))
            HStack {
                Text("\(text.count) 字").font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("加入资料库") {
                    KnowledgeStore.shared.addText(name: name, text: text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.gapL)
        .frame(width: 560, height: 440)
    }
}

private struct PreviewSheet: View {
    let doc: KnowledgeDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            HStack {
                Text(doc.name).font(Theme.heading).lineLimit(1)
                Spacer()
                Text("\(doc.chunkCount) 段 · \(doc.charCount) 字").font(Theme.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(String(KnowledgeStore.shared.text(of: doc.id).prefix(20000)))
                    .font(Theme.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.gapS)
            }
            .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.surface))
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.gapL)
        .frame(width: 600, height: 480)
    }
}

// MARK: - 术语表

private struct GlossaryPane: View {
    @State private var store = KnowledgeStore.shared
    @State private var text = KnowledgeStore.shared.glossaryText
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            HStack {
                Text("每行一条「原文 = 译文」。待翻译的文字里出现这些词时，必须按这里的译法翻译（中译英时反过来也生效）。")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("导入 CSV…") { importCSV() }
                    .help("两列：原文,译文。也支持制表符分隔")
            }
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("claim = 理赔\npremium = 保费\nSLA = 服务等级协议\n# 井号开头的行是注释")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(13)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text("已识别 \(store.glossary.count) 条").font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
                if let error = store.lastError {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.repeated)
                }
                Spacer()
            }
        }
        .padding(Theme.gapS)
        .onChange(of: text) { _, value in
            // 停止输入半秒后保存
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { store.setGlossary(value) }
            }
        }
        .onDisappear {
            saveTask?.cancel()
            if text != store.glossaryText { store.setGlossary(text) }
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if text != store.glossaryText { store.setGlossary(text) }
        store.appendGlossary(from: url)
        text = store.glossaryText
    }
}
