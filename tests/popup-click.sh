#!/bin/bash
# 用真实鼠标点击翻译浮窗的朗读、固定、复制按钮，检查浮窗不会被误关。需要屏幕解锁；鼠标会被移动。
# 用法：tests/popup-click.sh
set -uo pipefail
for button in speak pin copy; do
  FANYI_CLICK_SELFTEST=$button /Applications/Fanyi.app/Contents/MacOS/Fanyi
done
