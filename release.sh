#!/bin/bash
# 打包可分发的版本：归档 → Developer ID 签名导出（Xcode 云签名）→ 苹果公证 → 钉上公证票据 → 压缩成 dist/Fanyi.zip。
#
# 需要：
#   - Apple Developer Program 账号
#   - App Store Connect API 密钥：~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8，
#     和同目录上一级的 issuer_id 文件（只有一行 Issuer ID）。也可以用环境变量 ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID。
#   - TEAM_ID 环境变量（开发者账号的 Team ID）
#
#   - Sparkle 更新签名私钥（EdDSA）在登录钥匙串里（generate_keys 生成；账户名可用 SPARKLE_ACCOUNT 指定，默认 ed25519）
#
# 用法：TEAM_ID=XXXXXXXXXX [RELEASE_NOTES=更新说明.html] ./release.sh
#   更新说明是一段 HTML 片段（不要 DOCTYPE 和 body），会显示在用户的更新弹窗里。
# 产物：dist/Fanyi.zip（上传到 GitHub Release v版本号），docs/appcast.xml（更新信息，推送后由 GitHub Pages 提供）
set -euo pipefail
cd "$(dirname "$0")"

: "${TEAM_ID:?请设置 TEAM_ID（开发者账号的 Team ID）}"
ASC_DIR="${HOME}/.appstoreconnect"
ASC_KEY_PATH="${ASC_KEY_PATH:-$(ls "${ASC_DIR}"/private_keys/AuthKey_*.p8 2>/dev/null | head -1)}"
[[ -f "$ASC_KEY_PATH" ]] || { echo "找不到 App Store Connect API 密钥（AuthKey_*.p8）"; exit 1; }
ASC_KEY_ID="${ASC_KEY_ID:-$(basename "$ASC_KEY_PATH" .p8 | sed 's/^AuthKey_//')}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-$(tr -d '[:space:]' < "${ASC_DIR}/issuer_id")}"
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

OUT=dist
ARCHIVE="$OUT/Fanyi.xcarchive"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "▸ 生成工程并归档（Apple 芯片 + Intel）"
xcodegen generate --quiet
xcodebuild -project Fanyi.xcodeproj -scheme Fanyi -configuration Release \
  -archivePath "$ARCHIVE" -destination "generic/platform=macOS" -derivedDataPath build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  "${AUTH[@]}" -quiet archive

echo "▸ 用 Developer ID 签名导出"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${TEAM_ID}</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" "${AUTH[@]}" -quiet
APP="$OUT/export/Fanyi.app"
codesign --verify --deep --strict "$APP"

echo "▸ 提交公证（通常几分钟）"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" --wait --timeout 30m
rm "$OUT/notarize.zip"

echo "▸ 钉上公证票据并检查"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Fanyi.zip"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "▸ 生成自动更新信息（Sparkle appcast）"
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin
UPDATES="$OUT/updates"
mkdir -p "$UPDATES"
cp "$OUT/Fanyi.zip" "$UPDATES/Fanyi.zip"
[[ -f docs/appcast.xml ]] && cp docs/appcast.xml "$UPDATES/appcast.xml"
[[ -n "${RELEASE_NOTES:-}" ]] && cp "$RELEASE_NOTES" "$UPDATES/Fanyi.html"
"$SPARKLE_BIN/generate_appcast" --account "${SPARKLE_ACCOUNT:-ed25519}" \
  --download-url-prefix "https://github.com/tianyaphoto/fanyi/releases/download/v${VERSION}/" \
  --link "https://tianyaphoto.github.io/fanyi/" \
  "$UPDATES"
cp "$UPDATES/appcast.xml" docs/appcast.xml
echo "已更新 docs/appcast.xml"
echo "完成：$OUT/Fanyi.zip（版本 ${VERSION}）"
shasum -a 256 "$OUT/Fanyi.zip"
