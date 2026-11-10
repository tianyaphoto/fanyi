#!/bin/bash
# 生成 Xcode 工程、编译，并把 App 安装到 /Applications 后启动。
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate --quiet
xcodebuild -project Fanyi.xcodeproj -scheme Fanyi -configuration Release \
  -derivedDataPath build -quiet build

APP="build/Build/Products/Release/Fanyi.app"

# 用本机的签名证书重新签名（如果有），这样重新编译后不用反复授予辅助功能/屏幕录制权限。
IDENTITY=$(security find-identity -v -p codesigning | awk 'NR==1 && $2 ~ /^[0-9A-F]{40}$/ {print $2}')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
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
