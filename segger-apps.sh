#!/usr/bin/env bash
# segger-apps.sh —— 收起 /Applications/SEGGER 里用不到的 GUI 应用
#
# 背景
#   J-Link 软件包会在 /Applications/SEGGER/JLink_V* 里放十几个 .app
#   （JFlash、JFlashLite、JFlashSPI、JLinkConfig、JLinkGDBServer、
#    JLinkLicenseManager、JLinkRegistration、JLinkRemoteServer、JLinkRTTViewer、
#    JLinkSWOViewer、JMem、JScope...）。启动台 / 聚焦会把它们全列出来。
#
# 做法
#   不是删除，而是移进同级的隐藏目录 .disabled-apps/ —— 以点开头的目录
#   Launchpad 与 Spotlight 都不索引，图标随即消失，但可以随时 restore 回来。
#   这点很重要：SEGGER 官网有 WAF 反爬，重装不一定下得到包，所以不做不可逆操作。
#
# 用法（必须 sudo —— /Applications/SEGGER 是 root:wheel）
#   sudo ./segger-apps.sh list                       列出所有 GUI .app 及当前状态
#   sudo ./segger-apps.sh check                      试运行：只打印，不动文件
#   sudo ./segger-apps.sh minimal [额外要保留的.app…] 保留默认 + 追加的，其余收起
#   sudo ./segger-apps.sh all                        全部收起（启动台里不留任何图标）
#   sudo ./segger-apps.sh restore                    把收起的全部移回原位
#
# 例
#   sudo ./segger-apps.sh minimal JLinkRTTViewer.app JScope.app
#
# 重要
#   只动 .app 目录。同一目录里的 JLinkExe、*CLExe、*.dylib、Doc、Firmwares、Script
#   等本体与库一律不碰 —— 那些是程序正常运行必需的，删了就坏。
#
# 注意：本脚本【故意不读 .env】（用 sudo 跑，见 segger-links.sh 里的说明）。

set -u

SEGGER_ROOT="${SEGGER_ROOT:-/Applications/SEGGER}"
if [ -z "${SEGGER_APP_DIR:-}" ]; then
  APPROOT="$(ls -1d "$SEGGER_ROOT"/JLink_V* 2>/dev/null | sort -V | tail -1)"
else
  APPROOT="$SEGGER_APP_DIR"
fi
HIDDEN="$APPROOT/.disabled-apps"

# 备份文件放脚本同目录（.gitignore 已排除）。
# 注意 restore 不依赖任何清单文件 —— 它直接扫隐藏目录，所以这里不需要额外清单。
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _link="$(readlink "$_src")"
  case "$_link" in
    /*) _src="$_link" ;;
    *)  _src="$(dirname "$_src")/$_link" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"

# 本脚本不写任何文件（restore 直接扫隐藏目录），所以不需要 chown 处理。

# 默认保留：日常真正会打开的。按需增删。
KEEP="JFlash.app
JLinkConfig.app
JLinkRemoteServer.app
JLinkGDBServer.app"

MODE="${1:-}"
[ "$#" -ge 1 ] && shift
EXTRA="$*"

apps() { ls -1d "$APPROOT"/*.app 2>/dev/null | xargs -n1 basename 2>/dev/null; }

is_keep() {
  printf '%s\n' "$KEEP" | grep -qxF "$1" && return 0
  for e in $EXTRA; do [ "$e" = "$1" ] && return 0; done
  return 1
}

fix_owner() { [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$MANIFEST" 2>/dev/null; return 0; }

case "$MODE" in
  list)
    [ -d "$APPROOT" ] || { echo "找不到 $APPROOT" >&2; exit 1; }
    for a in $(apps); do
      if [ -d "$HIDDEN/$a" ]; then echo "  收起  $a"; else echo "  在位  $a"; fi
    done
    ;;

  check|minimal|all)
    DRY=0; [ "$MODE" = check ] && DRY=1
    # all = 一个都不留：适合"启动台里不想看到任何 J-Link 图标"的场景。
    # 命令行工具（JLinkExe / *CLExe）不受影响，仍在 /usr/local/bin。
    [ "$MODE" = all ] && KEEP=""
    [ -d "$APPROOT" ] || { echo "找不到 ${APPROOT}（用 SEGGER_APP_DIR 指定）" >&2; exit 1; }
    if [ "$DRY" = 0 ]; then
      mkdir -p "$HIDDEN"
    fi
    kept=0; hid=0
    for a in $(apps); do
      if is_keep "$a"; then
        printf '  keep    %s\n' "$a"; kept=$((kept + 1))
      else
        printf '  hide    %s\n' "$a"; hid=$((hid + 1))
        if [ "$DRY" = 0 ]; then
          mv "$APPROOT/$a" "$HIDDEN/$a"
        fi
      fi
    done
    echo
    if [ "$DRY" = 1 ]; then
      echo "[试运行] 保留 $kept 个 / 收起 $hid 个 —— 未改动任何文件"
      echo "确认后执行: sudo $0 minimal"
    else
      echo "已保留 $kept 个，收起 $hid 个 -> $HIDDEN"
      echo "还原: sudo $0 restore"
    fi
    ;;

  restore)
    n=0
    if [ -d "$HIDDEN" ]; then
      for a in "$HIDDEN"/*.app; do
        [ -e "$a" ] || continue
        b="$(basename "$a")"
        mv "$a" "$APPROOT/$b" && { echo "  还原 $b"; n=$((n + 1)); }
      done
      rmdir "$HIDDEN" 2>/dev/null
    fi
    echo "共还原 $n 个"
    ;;

  *)
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
