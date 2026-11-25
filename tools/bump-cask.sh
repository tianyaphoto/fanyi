#!/bin/bash
# 发布新版本后更新 Homebrew 安装源（github.com/tianyaphoto/homebrew-tap）：
# 下载 GitHub Release 上的 Fanyi.zip，算 sha256，改 Casks/fanyi.rb 的版本号，提交并推送。
# 用法：tools/bump-cask.sh [版本号]   不写版本号时用 project.yml 里的 MARKETING_VERSION
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)}"
TAP="${TAP_DIR:-$HOME/Documents/projects/homebrew-tap}"
[[ -d "$TAP/.git" ]] || git clone -q https://github.com/tianyaphoto/homebrew-tap.git "$TAP"
git -C "$TAP" pull -q --ff-only
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
curl -fsSL -o "$WORK/Fanyi.zip" "https://github.com/tianyaphoto/fanyi/releases/download/v${VERSION}/Fanyi.zip"
SHA=$(shasum -a 256 "$WORK/Fanyi.zip" | awk '{print $1}')
sed -i '' -e "s/^  version \".*\"/  version \"${VERSION}\"/" -e "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" "$TAP/Casks/fanyi.rb"
git -C "$TAP" diff --stat
if git -C "$TAP" diff --quiet; then echo "安装源已经是 ${VERSION}，不用改"; exit 0; fi
git -C "$TAP" commit -qam "fanyi ${VERSION}"
git -C "$TAP" push -q
echo "已把 Homebrew 安装源更新到 ${VERSION}（sha256 ${SHA}）"
