#!/usr/bin/env bash
# jlink-remote-server.sh —— 把本机上的 J-Link 通过 TCP/IP 提供给另一台机器使用
#
# 什么时候需要它
#   老 J-Link（V8 一代、SAM-ICE 等）在 Windows ARM64 上装不了驱动：SEGGER 的老驱动是
#   内核态 x64 .sys，而 Windows ARM64 只能模拟 x64 用户态，内核驱动无法加载，
#   SEGGER 也没有 ARM64 版本 —— 设备管理器里永远是代码 28（找不到驱动）。
#   而在 macOS/Linux 上，探针走的是系统自带的通用 USB 栈，压根不需要驱动。
#   所以把探针留在 macOS/Linux，用这个服务把它"借"给别处的 IDE（Keil µVision 支持 LAN 模式）。
#
# 用法
#   ./jlink-remote-server.sh start     启动（默认动作）
#   ./jlink-remote-server.sh stop      停止
#   ./jlink-remote-server.sh status    状态 + 端口监听
#   ./jlink-remote-server.sh ip        打印对方应该填的本机地址
#
# 配置
#   可选：在脚本同目录放一个 .env（键见 .env.example）。
#   真实环境变量优先于 .env，所以临时覆盖这样写：
#     JLINK_SN=123456789 ./jlink-remote-server.sh start
#
# 依赖
#   SEGGER J-Link 软件包。macOS: brew install --cask segger-jlink
#   注意：该 cask 目前常因 SEGGER 云端 AWS WAF 拦截非浏览器请求而下载失败
#   （拿到 0 字节 / 报 Cask reports different checksum）。此时请用浏览器到
#   https://www.segger.com/downloads/jlink/ 手动下载 pkg 安装。

set -u

# ---------- 定位脚本目录（符号链接安全；macOS 没有 readlink -f 也能用）----------
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _link="$(readlink "$_src")"
  case "$_link" in
    /*) _src="$_link" ;;
    *)  _src="$(dirname "$_src")/$_link" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"

# ---------- 加载 .env（真实环境变量优先；兼容 bash 3.2，不用 ${!var}）----------
load_env() {
  local conf="$SCRIPT_DIR/.env" line k v cur
  [ -f "$conf" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    k="${line%%=*}"
    v="${line#*=}"
    k="$(printf '%s' "$k" | tr -d '[:space:]')"
    [ -n "$k" ] || continue
    eval "cur=\${$k:-}"
    [ -n "$cur" ] && continue          # 环境里已有 -> 不覆盖
    export "$k=$v"
  done < "$conf"
}
load_env

# ---------- 配置 ----------
PORT="${JLINK_REMOTE_PORT:-19020}"
SN="${JLINK_SN:-}"
BIN="${JLINK_REMOTE_BIN:-$(command -v JLinkRemoteServerCLExe 2>/dev/null || echo /usr/local/bin/JLinkRemoteServerCLExe)}"
LOG="${JLINK_REMOTE_LOG:-${TMPDIR:-/tmp}/jlink_remote_server.log}"
PAT="JLinkRemoteServerCLExe -Port $PORT"

print_ip() {
  echo "本机地址（对方机器填其中【能被它访问到】的那个）："
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig -a 2>/dev/null | awk '
      /^[a-zA-Z0-9_.]+:/ { ifc=$1; sub(/:$/,"",ifc) }
      $1=="inet" && ifc !~ /^lo/ { printf "  %-12s = %s\n", ifc, $2 }'
  elif command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show 2>/dev/null | awk '$2!="lo"{split($4,a,"/"); printf "  %-12s = %s\n", $2, a[1]}'
  fi
  echo "  怎么选：虚拟机的 NAT 网段填它的网关接口（VMware 常见 bridge101 / vmnet8）；"
  echo "          物理局域网填 en0 / eth0。拿不准就在对方机器上 ping 一下。"
}

case "${1:-start}" in
  ip)
    print_ip
    exit 0
    ;;
  stop)
    if pkill -f "$PAT"; then echo "已停止（端口 ${PORT}）"; else echo "未在运行"; fi
    exit 0
    ;;
  status)
    if pgrep -fl "$PAT"; then
      lsof -nP -iTCP:"$PORT" 2>/dev/null | tail -1
    else
      echo "未运行（端口 $PORT 无监听）"
    fi
    exit 0
    ;;
esac

# ---------- start ----------
if pgrep -f "$PAT" >/dev/null; then
  echo "已在运行（端口 ${PORT}）"
  print_ip
  exit 0
fi

if [ ! -x "$BIN" ]; then
  echo "找不到可执行的 JLinkRemoteServerCLExe：$BIN" >&2
  echo "装 SEGGER 软件包，或用 JLINK_REMOTE_BIN 指定路径。" >&2
  exit 1
fi

if [ -n "$SN" ]; then
  nohup "$BIN" -Port "$PORT" -USB "$SN" > "$LOG" 2>&1 &
else
  nohup "$BIN" -Port "$PORT" > "$LOG" 2>&1 &
fi

sleep 3
echo "启动完成，日志：$LOG"
tail -5 "$LOG"
echo
if grep -q "Waiting for client connections" "$LOG"; then
  echo "✅ 服务就绪"
else
  echo "⚠️  日志里没有 'Waiting for client connections'，请检查上面几行报错" >&2
fi
echo
print_ip
echo
echo "下一步：在 IDE（如 Keil µVision）里选 TCP/IP，IP 填上面那个，"
echo "        端口填 $PORT 或 0（0 = 走 J-Link 标准端口）。"
