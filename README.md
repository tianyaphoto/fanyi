# 翻译神器（Fanyi）

一个轻量的 macOS 菜单栏翻译工具：看文档时划词就能翻译，截图也能翻译，还能把不熟悉的词收进生词本。翻译由大模型完成，可以接 Claude API、OpenAI API，也可以直接调用本机的 Claude Code（`claude -p`）。

## 功能

- **划词翻译**：在任意应用里选中文字，鼠标旁出现翻译小图标，点击即可翻译；也可以选中后按快捷键（默认 `⌥D`）。
- **截图翻译**：按 `⌥S` 框选屏幕区域，本地 OCR（Apple Vision）识别文字后翻译。适合图片、PDF 扫描件、视频字幕。
- **看图翻译（可选）**：在设置里打开后，截图本身会直接发给模型，表格、公式、手写体的效果更好，但更慢、更费额度。
- **输入翻译**：按 `⌥A` 弹出输入框，打字后按回车翻译。
- **单词秒出**：查英文单词时，先从 macOS 系统词典（如牛津英汉）即时显示释义，AI 释义随后流式补充。
- **智能翻译**：单词给出音标、词性释义和例句；句子和段落直接给出通顺译文；选中中文时自动翻成英文。
- **结合语境**：划词时会同时读取这个词所在的原句，AI 会先说明它在这句话里的具体含义。
- **生词本**：一键收藏单词或句子，并自动保存当时的原句（生词高亮）和来源文档，复习时能回到当初的语境；没读取到原句时可以手动补充。支持搜索、标记已掌握、删除。
- **查词历史**：自动记录查过的内容；同一个词查到第 2 次起会提示「第 N 次查询」，方便发现该收藏的生词。
- **自定义快捷键**：在设置里录制自己的组合键，被其他应用占用时会提示。
- **浮窗操作**：朗读原文、复制译文、固定浮窗，按 Esc 关闭。

## 翻译服务

在「设置 → 翻译服务」中切换：

| 服务 | 需要什么 | 说明 |
|---|---|---|
| Claude API | Claude API Key | 默认模型 `claude-opus-5-5`，想更快更省可换成 `claude-haiku-5-5`。API 地址可改。 |
| OpenAI API | OpenAI API Key | 使用 Chat Completions 接口。改 API 地址和模型名后，也能接 DeepSeek 等同格式的服务。 |
| claude -p | 已安装并登录的 [Claude Code](https://claude.com/claude-code) | 不需要 API Key，使用你的 Claude 账号额度。每次翻译要启动一次命令，比直接调 API 慢 1–2 秒。 |

API Key 保存在 macOS 钥匙串中，不会写入任何文件。

## 系统要求

- macOS 14 Sonoma 或更新
- 从源码编译需要：Xcode（开发时使用 Xcode 26.3）和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 安装

```bash
brew install xcodegen
git clone https://github.com/tianyaphoto/fanyi.git
cd fanyi
./build.sh install
```

`./build.sh install` 会生成 Xcode 工程、编译，把 App 安装到 `/Applications/Fanyi.app` 并启动。只想编译不安装的话，运行 `./build.sh`。

启动后菜单栏会出现一个气泡图标，第一次运行会自动打开设置窗口。

## 首次使用

1. **配置翻译服务**：在设置中选择服务；使用 API 的话，填入对应的 API Key。
2. **授予「辅助功能」权限**（划词翻译需要）：系统设置 → 隐私与安全性 → 辅助功能 → 允许「Fanyi」。
3. **授予「屏幕录制」权限**（截图翻译需要）：系统设置 → 隐私与安全性 → 录屏与系统录音 → 允许「Fanyi」，然后重新打开 App。

设置窗口的「权限」一栏会显示当前授权状态，并提供跳转按钮。

> 如果你的电脑上没有代码签名证书，App 会使用临时签名，每次重新编译后可能需要重新授予上面两项权限。`build.sh` 检测到本机有签名证书时会自动使用。

## 默认快捷键

| 功能 | 快捷键 |
|---|---|
| 翻译选中文字 | `⌥D` |
| 截图翻译 | `⌥S` |
| 输入翻译 | `⌥A` |

可以在「设置 → 快捷键」中修改或清除。注意 `⌥` 加字母的组合会占用 å、ß 这类特殊字符的输入。

## 小贴士

- **读取不到选中文字**：Chrome、VS Code 等应用不提供标准的取词接口，设置里的「兼容模式」会在这种情况下模拟一次 `⌘C` 取词，并自动恢复剪贴板原内容。
- **系统词典结果**：显示哪本词典的内容取决于「词典」App 里启用的词典。想看英汉释义，请在「词典 → 设置」中勾选「牛津英汉汉英词典」。
- **原句读取范围**：备忘录、文本编辑、Pages、预览等原生应用读取效果最好，Safari 网页通常也可以；Chrome、VS Code 等走「兼容模式」取词的应用读不到原句，可以在生词本里手动添加。
- **截图识别效果**：OCR 支持中英文。识别出的文字如果有错字或多余断行，模型会先修正再翻译。
- **看图翻译**：设置 → 截图翻译 里打开。默认关闭，此时截图只在本机识别，发给模型的只有文字；打开后截图会上传给所选的翻译服务。三种服务都支持，使用 OpenAI 兼容服务时所选模型需要支持图片输入。

## 数据存储

所有数据都只保存在本机：

| 内容 | 位置 |
|---|---|
| 生词本 | `~/Library/Application Support/Fanyi/vocabulary.json` |
| 查词历史（最多 2000 条，可在设置中关闭） | `~/Library/Application Support/Fanyi/history.json` |
| API Key | macOS 钥匙串（服务名 `com.local.fanyi`） |

要翻译的文字，以及划词时读取到的所在原句，会发送给你选择的翻译服务。

## 项目结构

```
Sources/
├── App.swift              # 入口、菜单栏菜单、窗口管理
├── Coordinator.swift      # 串联划词、截图、输入翻译；小图标和翻译浮窗
├── Selection.swift        # 读取选中文字、监听划词手势
├── Context.swift          # 读取原句和来源文档
├── Translator.swift       # 三种翻译服务的流式调用
├── LocalDictionary.swift  # macOS 系统词典查询
├── TranslationView.swift  # 翻译浮窗界面
├── Vocabulary.swift       # 生词本
├── History.swift          # 查词历史
├── Shortcuts.swift        # 快捷键配置与录制
├── HotKeys.swift          # 全局快捷键注册（Carbon）
├── Settings.swift         # 设置项与钥匙串
└── SettingsView.swift     # 设置界面
project.yml                # XcodeGen 工程描述
build.sh                   # 编译与安装脚本
```

`Fanyi.xcodeproj` 和 `Info.plist` 都由 XcodeGen 根据 `project.yml` 生成，不纳入版本管理。想在 Xcode 里开发的话，先运行 `xcodegen generate`，再打开 `Fanyi.xcodeproj`。

## 许可证

[MIT](LICENSE)
