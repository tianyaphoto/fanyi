<img src="docs/assets/app-icon-256.png" width="128" alt="Fanyi icon">

# Fanyi (翻译神器)

[中文](README.md) · **English**

A lightweight macOS menu bar translator. Select text in any app and get a translation; translate screenshots; rewrite what you are typing into natural English with one shortcut; keep a vocabulary book. Translation is done by an LLM of your choice: Claude API, AWS Bedrock, OpenAI, DeepSeek, Qwen, any OpenAI-compatible service, or the Claude Code CLI on your Mac (`claude -p`).

> **Language note:** the app's interface is in Chinese. By default it translates between **English and Simplified Chinese**; in settings you can pick any two of 16 languages instead (Vietnamese ⇄ English, English ⇄ Korean, Japanese ⇄ Chinese …). One-key polish always produces English.

Homepage: <https://tianyaphoto.github.io/fanyi/en.html> · Download: [latest release](https://github.com/tianyaphoto/fanyi/releases/latest)

## Features

- **Select to translate**: select text in any app and a small icon appears next to the pointer; click it, or press `⌥D`.
- **Screenshot translation**: press `⌥S`, drag a box; text is recognised locally (Apple Vision) and translated. Optional "vision mode" sends the image itself to the model for tables, formulas and handwriting.
- **Input translation**: press `⌥A`, type, press Return.
- **Any two languages**: Simplified Chinese ⇄ English by default. In settings, choose a primary and a second language from 16 (Chinese, English, Japanese, Korean, Vietnamese, Thai, Indonesian, Malay, French, German, Spanish, Portuguese, Italian, Russian, Arabic …): each is translated into the other, and anything else goes into the primary language. The "→ language" chip in the popup overrides the target for one translation. Screenshot OCR follows the same languages.
- **Words with context**: looking up a word shows the macOS dictionary instantly, then an AI explanation of what the word means *in the sentence you selected it from*.
- **Translation scenes**: six built-in scenes — General, Document, Technical, Academic, Email & Chat, Contracts — each with its own rules (documents keep headings and lists; technical text keeps code, commands and identifiers; contracts translate *shall not* strictly). The scene is picked automatically from the current app, window title and URL (Google Docs → Document, GitHub → Technical, Slack → Chat …). Switch it in the popup, tell it to remember a site, edit the rules or add your own scenes.
- **Knowledge base and glossary**: add your docs, product notes or past translations (text, Markdown, PDF, Word, RTF, HTML); relevant passages are retrieved locally (BM25) and sent as reference. Glossary terms (`underwriting = 核保`) are always translated your way. The popup shows what was referenced.
- **One-key polish**: in any text field press `⌃⌥⌘T`. Fanyi selects all, copies, translates Chinese (or mixed text) into English or fixes English spelling and grammar, and pastes the result back — it never presses Return for you. `⌃⇧⌘C` polishes the clipboard and pastes at the cursor. British spelling by default (American optional), custom instructions, links and code kept verbatim.
- **Translates, never answers**: text to translate may be a question or an instruction ("What is the capital of China?"); it is translated, not answered. Fanyi decides word vs. sentence and target language locally, checks the output (language, questions kept as questions, length) and retries once if it doesn't look like a translation.
- **Vocabulary book and history**: save words with the sentence and document they came from; repeated lookups are flagged so you notice words worth learning.
- **Google Docs** works too (its text is drawn on a canvas, so Fanyi copies the selection instead).
- **Long text**: a larger popup, collapsible source, paragraph-by-paragraph bilingual view; the popup is placed so it doesn't cover your selection.
- **Auto-update** via [Sparkle](https://sparkle-project.org/) (from 1.2).

## One-key polish in detail

- Before pasting, Fanyi checks you are still in the same app, window and field, that you didn't type or click while waiting, and that the clipboard wasn't replaced; otherwise it leaves the result on the clipboard for you to paste.
- In fields it can read (most native apps, Electron apps with accessibility enabled) it reads the whole field back after pasting and only reports success if it matches.
- Links, inline code and code blocks are replaced by placeholders and restored afterwards; a broken placeholder means nothing is written. Empty input, copy failures, network errors, more than 10,000 characters, or output that doesn't look like a rewrite leave your text untouched.
- One task at a time, 30-second timeout, cancel from the menu. A diagnostics log (last 250 steps, no text or keys) shows why something didn't paste.
- Uses the translation service you selected. With `claude -p` a rewrite takes 10–25 s; with an API it usually takes 1–2 s.

## Translation services

| Service | You need | Notes |
|---|---|---|
| Claude API | Claude API key | Default `claude-opus-5-5`; `claude-haiku-5-5` is faster and cheaper. |
| AWS Bedrock (Claude) | Amazon Bedrock API key | Region + model ID with the `anthropic.` prefix. |
| Bedrock gateway (Claude) | Gateway URL, model ID, API key | Corporate gateway or proxy: `URL/model/{modelId}/invoke`, `x-api-key` or Bearer, extra headers. No SigV4 signing, no local AWS credentials. |
| OpenAI API | OpenAI API key | Chat Completions, default `gpt-5-mini`. |
| DeepSeek | DeepSeek API key | Default `deepseek-chat`; no vision. |
| Qwen (通义千问) | Alibaba Cloud Model Studio key | OpenAI-compatible, default `qwen-plus`. |
| Custom (OpenAI-compatible) | URL and model | Kimi, Zhipu, OpenRouter, local Ollama (`http://localhost:11434/v1`, no key) … |
| claude -p | [Claude Code](https://claude.com/claude-code) installed and logged in | No API key; uses your Claude plan. Runs with `--safe-mode` so your own CLAUDE.md and hooks don't leak into translations. |

API keys are stored per service in a plaintext file under `~/Library/Application Support/Fanyi/` (permissions 600, readable only by you; not encrypted, never bundled or committed), shared by translation and polish. HTTP redirects are never followed.

## Install

1. With Homebrew: `brew install --cask tianyaphoto/tap/fanyi`. Or download `Fanyi.zip` from the [latest release](https://github.com/tianyaphoto/fanyi/releases/latest), unzip, and drag `Fanyi.app` into Applications. Apple silicon and Intel; macOS 14 Sonoma or later.
2. It is signed with a Developer ID and notarised by Apple — just double-click to open. A speech-bubble icon with 「译」 appears in the menu bar and settings open on first launch.
3. Pick a translation service in settings and enter its key (not needed for `claude -p`).
4. Grant **Accessibility** (select-to-translate, one-key polish) and **Screen Recording** (screenshot translation) in System Settings → Privacy & Security; the settings window has shortcuts to both. Relaunch after granting Screen Recording.

## Default shortcuts

| Action | Shortcut |
|---|---|
| Translate selection | `⌥D` |
| Screenshot translation | `⌥S` |
| Input translation | `⌥A` |
| Polish current field | `⌃⌥⌘T` |
| Polish clipboard | `⌃⇧⌘C` |

All can be changed in Settings → Shortcuts.

## Tips

- **Can't read the selection in Chrome / VS Code**: "Enhanced capture" (on by default) turns on their accessibility support; if that still fails, "Compatibility mode" triggers the app's Copy command and restores your clipboard afterwards.
- **Dictionary language**: the dictionary shown depends on which dictionaries are enabled in the Dictionary app.
- **Permissions lost after switching builds**: a build signed with a different certificate counts as a different app to macOS; grant Accessibility and Screen Recording again.
- **Privacy**: vocabulary, history, knowledge base and keys stay on your Mac. The text you translate, the surrounding sentence and any retrieved reference passages are sent to the service you selected.

## Build from source

Requires Xcode (developed with Xcode 26.3) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/tianyaphoto/fanyi.git
cd fanyi
./build.sh install     # generate the project, build, install to /Applications and launch
```

`./build.sh` builds without installing. Release builds (Developer ID signing, notarisation, Sparkle appcast) are produced by `release.sh`; see the comments at the top of the script.

## License

[MIT](LICENSE)
