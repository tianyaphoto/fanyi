#!/bin/bash
# 由 design/ 里的 SVG 生成 App 图标和菜单栏图标（用本机 Chrome 的无头模式渲染，再用 sips 缩放）。
# 用法：tools/make-icons.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
render() { # svg 输出 窗口尺寸 缩放倍数
  "$CHROME" --headless=new --disable-gpu --user-data-dir="$TMP/profile" --hide-scrollbars \
    --default-background-color=00000000 --force-device-scale-factor="$4" --window-size="$3,$3" \
    --screenshot="$2" "file://$PWD/$1" >/dev/null 2>&1
}

ICONSET=Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p "$ICONSET"
render design/app-icon.svg "$TMP/icon-1024.png" 1024 1
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$TMP/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
cp "$TMP/icon-1024.png" docs/assets/app-icon.png
sips -z 256 256 "$TMP/icon-1024.png" --out docs/assets/app-icon-256.png >/dev/null
sips -z 64 64 "$TMP/icon-1024.png" --out docs/assets/favicon.png >/dev/null

MENU=Resources/Assets.xcassets/MenuBarIcon.imageset
mkdir -p "$MENU"
render design/menubar-icon.svg "$TMP/menu.png" 44 8
sips -z 22 22 "$TMP/menu.png" --out "$MENU/menubar.png" >/dev/null
sips -z 44 44 "$TMP/menu.png" --out "$MENU/menubar@2x.png" >/dev/null
echo "已生成 ${ICONSET}、${MENU}、docs/assets/app-icon*.png"
