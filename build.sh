#!/bin/bash
# 生成 Xcode 工程、编译，并把 App 安装到 /Applications 后启动。
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate --quiet
xcodebuild -project Fanyi.xcodeproj -scheme Fanyi -configuration Release \
  -derivedDataPath build -quiet build

APP="build/Build/Products/Release/Fanyi.app"

# 用本机的签名证书重新签名（如果有），这样重新编译后不用反复授予辅助功能/屏幕录制权限。
# 优先用 Developer ID（和发布包同一个签名：在本机编译版和下载版之间换装时权限也不会丢），没有再用第一个可用证书。
IDENTITIES=$(security find-identity -v -p codesigning)
IDENTITY=$(echo "$IDENTITIES" | awk '/Developer ID Application/ && $2 ~ /^[0-9A-F]{40}$/ {print $2; exit}')
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(echo "$IDENTITIES" | awk 'NR==1 && $2 ~ /^[0-9A-F]{40}$/ {print $2}')
fi
if [[ -n "$IDENTITY" ]]; then
  # --deep：连同内嵌的 Sparkle.framework（含更新器和 XPC 服务）一起签，否则开了运行时加固后加载会失败
  codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
fi
if [[ "${1:-}" == "install" ]]; then
  pkill -x Fanyi 2>/dev/null || true
  rm -rf /Applications/Fanyi.app
  cp -R "$APP" /Applications/Fanyi.app
  open /Applications/Fanyi.app
  echo "已安装并启动 /Applications/Fanyi.app"
else
  echo "编译完成：$APP"
fi
