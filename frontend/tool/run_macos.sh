#!/usr/bin/env bash
# macOS 运行 / 构建入口（HANDOFF.md §12）。
#
# Xcode 27.2 会把 iOS、tvOS 等平台的部署目标导出到 macOS 构建环境，
# 导致 Flutter 编译 App.framework 时 clang 报 "conflicting deployment targets"。
# 这里把这些变量清空后再调用 flutter；iOS 构建不受影响，不需要本脚本。
#
# 用法：
#   tool/run_macos.sh                 # flutter run -d macos
#   tool/run_macos.sh run [参数...]    # 同上，附加参数
#   tool/run_macos.sh build [参数...]  # flutter build macos（默认 --debug）
#   tool/run_macos.sh test [参数...]   # flutter test -d macos（原生集成测试）
set -euo pipefail

cd "$(dirname "$0")/.."

export FLUTTER_XCODE_IPHONEOS_DEPLOYMENT_TARGET=
export FLUTTER_XCODE_TVOS_DEPLOYMENT_TARGET=
export FLUTTER_XCODE_WATCHOS_DEPLOYMENT_TARGET=
export FLUTTER_XCODE_XROS_DEPLOYMENT_TARGET=
export FLUTTER_XCODE_DRIVERKIT_DEPLOYMENT_TARGET=

cmd="${1:-run}"
[[ $# -gt 0 ]] && shift

case "$cmd" in
  run) exec flutter run -d macos "$@" ;;
  test) exec flutter test -d macos "$@" ;;
  build)
    if [[ $# -eq 0 ]]; then set -- --debug; fi
    exec flutter build macos "$@"
    ;;
  *)
    echo "用法: tool/run_macos.sh [run|build|test] [flutter 参数...]" >&2
    exit 64
    ;;
esac
