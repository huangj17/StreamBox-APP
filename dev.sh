#!/usr/bin/env bash
# StreamBox 开发脚本：只运行客户端，无需独立后端。
# ./dev.sh                      启动客户端（DEVICE 默认 macos）
# ./dev.sh client [参数]        参数传给 flutter run
# ./dev.sh test                 Flutter analyze + test
# ./dev.sh test-android         Android 原生单元测试
# ./dev.sh build [平台] [参数]  平台默认 macos，支持 apk 等 Flutter 构建目标
# ./dev.sh clean                清理客户端构建产物
set -euo pipefail
STREAMBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STREAMBOX_ROOT/client"
STREAMBOX_COMMAND="${1:-client}"
if [ "$#" -gt 0 ]; then shift; fi
case "$STREAMBOX_COMMAND" in
  client|app|all) exec flutter run -d "${DEVICE:-macos}" "$@" ;;
  test) flutter analyze; exec flutter test "$@" ;;
  test-android) exec ./android/gradlew -p android :app:testDebugUnitTest "$@" ;;
  build)
    STREAMBOX_BUILD_TARGET="${1:-macos}"
    if [ "$#" -gt 0 ]; then shift; fi
    exec flutter build "$STREAMBOX_BUILD_TARGET" "$@"
    ;;
  clean) exec flutter clean ;;
  -h|--help|help) sed -n '2,8s/^# //p' "$STREAMBOX_ROOT/dev.sh" ;;
  *) printf '未知命令：%s；使用 ./dev.sh --help 查看用法。\n' "$STREAMBOX_COMMAND" >&2; exit 1 ;;
esac
