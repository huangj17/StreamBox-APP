#!/usr/bin/env bash
#
# StreamBox 开发脚本 —— 在仓库根目录直接启动子项目，不用手动 cd
#
#   ./dev.sh              同时启动 Bridge（后台）+ Flutter 客户端（前台）
#   ./dev.sh bridge       只启动 JAR Bridge
#   ./dev.sh client       只启动 Flutter 客户端
#   ./dev.sh stop         停掉后台 Bridge
#   ./dev.sh test         跑两个子项目的测试
#   ./dev.sh build        构建两个子项目
#   ./dev.sh clean        清理构建产物
#
# 环境变量：
#   DEVICE=macos          Flutter 目标设备（默认 macos）
#   BRIDGE_PORT=9978      Bridge 端口（默认 9978）
#   BRIDGE_TIMEOUT=300    all 模式等 Bridge 就绪的秒数（默认 300）
#
# 透传参数：client / bridge 之后的参数原样传给 flutter run / gradlew
#   ./dev.sh client -d chrome --verbose
#
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
CLIENT_DIR="$ROOT_DIR/client"
BRIDGE_DIR="$ROOT_DIR/jar-bridge"
LOG_DIR="$ROOT_DIR/.dev-logs"
BRIDGE_LOG="$LOG_DIR/bridge.log"

DEVICE="${DEVICE:-macos}"
BRIDGE_PORT="${BRIDGE_PORT:-9978}"
BRIDGE_TIMEOUT="${BRIDGE_TIMEOUT:-300}"   # all 模式等 Bridge 就绪的秒数

# ---------- 输出 ----------
if [ -t 1 ]; then
  C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_OFF=''
fi
info() { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()   { printf '%s✓%s %s\n'   "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n'   "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '%s✗%s %s\n'   "$C_ERR"  "$C_OFF" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "找不到命令 $1，请先安装（$2）"; }

# ---------- Gradle ----------
# ~/.gradle/gradle.properties 里配了代理、但代理没在跑时，Gradle 会卡到超时后
# 报 "plugin not found"。这里探测一下，不通就本次绕过（不改动全局配置）。
# macOS 自带的 Bash 3.2 在 `set -u` 下不能展开空数组。把始终需要的
# console 参数也放进数组，确保没有代理参数时数组仍非空。
GRADLE_ARGS=("--console=plain")

detect_gradle_proxy() {
  local props="$HOME/.gradle/gradle.properties" host port
  [ -f "$props" ] || return 0
  host="$(sed -n 's/^systemProp\.https\{0,1\}\.proxyHost=//p' "$props" | head -1 | tr -d '[:space:]')"
  port="$(sed -n 's/^systemProp\.https\{0,1\}\.proxyPort=//p' "$props" | head -1 | tr -d '[:space:]')"
  [ -n "$host" ] && [ -n "$port" ] || return 0
  if nc -z -G 2 "$host" "$port" >/dev/null 2>&1; then
    return 0
  fi
  warn "Gradle 配了代理 ${host}:${port}，但它没在运行 —— 本次绕过代理直连"
  warn "长期修复：启动代理软件，或注释掉 ${props} 里的 systemProp.*.proxy* 四行"
  # Wrapper 会在解析命令行 -D 之后再加载 ~/.gradle/gradle.properties，
  # 因此单纯清空 proxyHost 会被全局配置覆盖。nonProxyHosts 未在那四行
  # 代理配置中定义，可以让 Wrapper 下载和后续 Gradle 请求都直连。
  GRADLE_ARGS=(
    "-Dhttp.proxyHost="
    "-Dhttps.proxyHost="
    "-Dhttp.nonProxyHosts=*"
    "-Dhttps.nonProxyHosts=*"
    "--console=plain"
  )
}

# ---------- Bridge ----------
BRIDGE_WRAPPER_PID=""   # all 模式下后台 gradle 的 pid

bridge_pids() { lsof -ti "tcp:$BRIDGE_PORT" -sTCP:LISTEN 2>/dev/null || true; }
bridge_up()   { [ -n "$(bridge_pids)" ]; }

# 等 Bridge 监听端口。首次冷启动要下载 Gradle 依赖，给足时间；
# 中途 gradle 自己挂了会立刻返回，不会干等到超时。
wait_bridge() {
  local i
  for i in $(seq 1 "$BRIDGE_TIMEOUT"); do
    if bridge_up; then return 0; fi
    if [ -n "$BRIDGE_WRAPPER_PID" ] && ! kill -0 "$BRIDGE_WRAPPER_PID" 2>/dev/null; then
      BRIDGE_WRAPPER_PID=""
      return 1
    fi
    if [ $((i % 20)) -eq 0 ]; then
      info "Bridge 仍在构建/启动中… ${i}s / ${BRIDGE_TIMEOUT}s"
    fi
    sleep 1
  done
  return 1
}

stop_bridge() {
  # 先收掉本脚本拉起的 gradle wrapper，避免它比 JVM 活得久
  if [ -n "$BRIDGE_WRAPPER_PID" ]; then
    kill "$BRIDGE_WRAPPER_PID" 2>/dev/null || true
    BRIDGE_WRAPPER_PID=""
  fi

  local pids
  pids="$(bridge_pids)"
  if [ -z "$pids" ]; then
    info "端口 $BRIDGE_PORT 上没有运行中的 Bridge"
    return 0
  fi
  info "停止 Bridge (pid: $(echo "$pids" | tr '\n' ' '))"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  local i
  for i in $(seq 1 10); do
    bridge_up || { ok "Bridge 已停止"; return 0; }
    sleep 1
  done
  warn "Bridge 未响应，强制结束"
  # shellcheck disable=SC2086
  kill -9 $(bridge_pids) 2>/dev/null || true
}

# ---------- 子命令 ----------
run_bridge() {
  need java "JDK 17+"
  if bridge_up; then
    die "端口 $BRIDGE_PORT 已被占用，先执行 ./dev.sh stop"
  fi
  detect_gradle_proxy
  info "启动 JAR Bridge → http://localhost:$BRIDGE_PORT"
  cd "$BRIDGE_DIR"
  exec ./gradlew "${GRADLE_ARGS[@]}" run "$@"
}

run_client() {
  need flutter "https://docs.flutter.dev/get-started/install"
  info "启动 Flutter 客户端（device: ${DEVICE}）"
  cd "$CLIENT_DIR"
  exec flutter run -d "$DEVICE" "$@"
}

run_all() {
  need java "JDK 17+"
  need flutter "https://docs.flutter.dev/get-started/install"

  local started_by_us=0
  if bridge_up; then
    ok "Bridge 已在 $BRIDGE_PORT 运行，直接复用"
  else
    detect_gradle_proxy
    mkdir -p "$LOG_DIR"
    info "后台启动 JAR Bridge，日志：$BRIDGE_LOG"
    ( cd "$BRIDGE_DIR" && ./gradlew "${GRADLE_ARGS[@]}" run ) >"$BRIDGE_LOG" 2>&1 &
    BRIDGE_WRAPPER_PID=$!
    started_by_us=1
    if wait_bridge; then
      ok "Bridge 就绪 → http://localhost:$BRIDGE_PORT"
    else
      warn "Bridge 未能就绪，最后 20 行日志（完整日志见 ${BRIDGE_LOG}）："
      tail -n 20 "$BRIDGE_LOG" || true
      warn "客户端仍会启动（Bridge 是可选组件）"
    fi
  fi

  # 客户端退出时，只清理本次脚本拉起来的 Bridge
  if [ "$started_by_us" -eq 1 ]; then
    trap 'echo; stop_bridge' EXIT
  fi

  info "启动 Flutter 客户端（device: ${DEVICE}）"
  cd "$CLIENT_DIR"
  flutter run -d "$DEVICE" "$@"
}

run_test() {
  info "client: flutter analyze && flutter test"
  ( cd "$CLIENT_DIR" && flutter analyze && flutter test )
  detect_gradle_proxy
  info "jar-bridge: gradlew test"
  ( cd "$BRIDGE_DIR" && ./gradlew "${GRADLE_ARGS[@]}" test )
  ok "全部测试通过"
}

run_build() {
  detect_gradle_proxy
  info "client: flutter build macos"
  ( cd "$CLIENT_DIR" && flutter build macos )
  info "jar-bridge: gradlew build"
  ( cd "$BRIDGE_DIR" && ./gradlew "${GRADLE_ARGS[@]}" build )
  ok "构建完成"
}

run_clean() {
  detect_gradle_proxy   # clean 的配置阶段也要解析 Kotlin 插件，同样需要网络
  info "client: flutter clean"
  ( cd "$CLIENT_DIR" && flutter clean )
  info "jar-bridge: gradlew clean"
  ( cd "$BRIDGE_DIR" && ./gradlew "${GRADLE_ARGS[@]}" clean )
  rm -rf "$LOG_DIR"
  ok "清理完成"
}

usage() {
  # 打印文件头部的注释块（跳过 shebang，遇到第一行非注释即停）
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$SCRIPT_PATH"
}

# ---------- 入口 ----------
cmd="${1:-all}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
  all)            run_all "$@" ;;
  bridge)         run_bridge "$@" ;;
  client|app)     run_client "$@" ;;
  stop)           stop_bridge ;;
  test)           run_test ;;
  build)          run_build ;;
  clean)          run_clean ;;
  -h|--help|help) usage ;;
  *)              die "未知命令：${cmd}（用 ./dev.sh --help 查看用法）" ;;
esac
