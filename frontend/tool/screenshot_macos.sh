#!/usr/bin/env bash
# 阶段验收截图（HANDOFF.md §9）：启动 debug 版 macOS 应用，按指定窗口尺寸渲染后存 PNG。
# 需先执行 tool/run_macos.sh build。截图由应用内的 debug 钩子生成（不含窗口标题栏），
# 见 lib/core/dev/debug_screenshot.dart。
#
# 用法：tool/screenshot_macos.sh <输出.png> <宽x高> [路由] [滚动像素] [light|dark]
#   例：tool/screenshot_macos.sh screenshots/phase2/1440.png 1440x900 /devices
set -euo pipefail

cd "$(dirname "$0")/.."

out="$1"; size="$2"; route="${3:-}"; scroll="${4:-}"; theme="${5:-light}"
app="build/macos/Build/Products/Debug/uniconsole.app/Contents/MacOS/uniconsole"
[[ -x "$app" ]] || { echo "找不到 $app，先运行 tool/run_macos.sh build" >&2; exit 1; }

log="$(mktemp)"
UNICONSOLE_WINDOW_SIZE="$size" UNICONSOLE_SCREENSHOT="$(basename "$out")" \
UNICONSOLE_SCREENSHOT_SCROLL="$scroll" UNICONSOLE_THEME="$theme" UNICONSOLE_ROUTE="$route" \
  "$app" >"$log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true; rm -f "$log"' EXIT

for _ in $(seq 1 60); do
  grep -q "UNICONSOLE_SCREENSHOT saved" "$log" && break
  sleep 0.5
done
line="$(grep "UNICONSOLE_SCREENSHOT saved" "$log" || true)"
[[ -n "$line" ]] || { echo "截图失败：" >&2; tail -20 "$log" >&2; exit 1; }

mkdir -p "$(dirname "$out")"
cp "${line##*→ }" "$out"
echo "$out"
