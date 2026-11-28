#!/bin/bash
# 一键改写的端到端测试：打开一个测试记事本窗口，用已安装（已授权辅助功能）的翻译神器改写其中的文字，
# 打印诊断日志和窗口里的最终内容。测试期间窗口会到最前面约半分钟，请不要操作键盘鼠标；屏幕锁定时无法运行。
# 用法：tests/polish-e2e.sh [field|clipboard|tone]
#   tone：改写输入框后，再按一次快捷键（换下一种语气）→ 点「更简短」→ 撤回，每步打印输入框内容；最后应该回到原文。
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-field}"
WORK=$(mktemp -d)
trap 'pkill -f "$WORK/TestPad.app" 2>/dev/null || true; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/TestPad.app/Contents/MacOS"
cat > "$WORK/TestPad.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>TestPad</string><key>CFBundleIdentifier</key><string>local.fanyi.testpad</string><key>CFBundleName</key><string>TestPad</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
swiftc -O -o "$WORK/TestPad.app/Contents/MacOS/TestPad" TestPad/main.swift
codesign -s - --force "$WORK/TestPad.app" >/dev/null 2>&1

if [[ "$MODE" == "clipboard" ]]; then
  printf 'Hi team, ' > "$WORK/in.txt"
  printf '我们明天下午三点开会，链接 https://example.com/meet 。' > "$WORK/clip.txt"
else
  printf '你明天有空吗？想跟你对一下 Q4 的规划，链接是 https://example.com/q4 。' > "$WORK/in.txt"
fi
open -n "$WORK/TestPad.app" --args "$WORK/in.txt" "$WORK/out.txt" -1 45
sleep 1.5
open "$WORK/TestPad.app"
STEPS=""
if [[ "$MODE" == "tone" ]]; then MODE=field; STEPS="again,concise,revert"; fi
FANYI_SELFTEST_STEPS="$STEPS" FANYI_POLISH_SELFTEST="$MODE" FANYI_SELFTEST_BUNDLE=local.fanyi.testpad FANYI_SELFTEST_CLIPBOARD="$WORK/clip.txt" \
  /Applications/Fanyi.app/Contents/MacOS/Fanyi || true
for _ in $(seq 1 60); do [[ -f "$WORK/out.txt" ]] && break; sleep 1; done
echo "--- 原文："; cat "$WORK/in.txt"; echo
echo "--- 测试窗口最终内容："; cat "$WORK/out.txt" 2>/dev/null || echo "（没拿到）"; echo
