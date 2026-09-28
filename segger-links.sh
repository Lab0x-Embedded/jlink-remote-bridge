#!/usr/bin/env bash
# segger-links.sh —— 精简 /usr/local/bin 里 SEGGER 铺下的一堆软链
#
# 背景
#   J-Link 软件包装完后，会往 /usr/local/bin 铺四十多个软链（JLink*、JFlash*、
#   JMem、JScope、JRun、DevPro、DDConditioner、JTAGLoad...），日常真正用到的
#   只有几个，其余纯属噪音。
#
# 安全性
#   删的只是【软链】。程序本体一直在
#   /Applications/SEGGER/JLink_V* 里，毫发无损，随时可以 restore 回来。
#   所有模式都会先把现状存成备份；restore 按备份逐条重建。
#
# 用法（必须 sudo —— /usr/local/bin 是 root:wheel）
#   sudo ./segger-links.sh list        列出当前所有 SEGGER 软链
#   sudo ./segger-links.sh check       试运行：只打印会保留/删除哪些，不动文件
#   sudo ./segger-links.sh minimal     保留 KEEP 列表里的，其余删除
#   sudo ./segger-links.sh backup      只备份现状，不做任何改动
#   sudo ./segger-links.sh restore     按备份还原全部软链
#
# 注意：本脚本【故意不读 .env】。它会以 root 身份运行，而让 root 去 source
#      一个用户可写的配置文件是提权隐患。要改配置请改下面的 KEEP / PATTERN。
#      （这也是同一仓库里只有用户态脚本才读 .env 的原因。）

set -u

BINDIR="${SEGGER_BINDIR:-/usr/local/bin}"
PATTERN="${SEGGER_LINK_PATTERN:-^(JLink|JFlash|JMem|JScope|JRun|DDConditioner|DevPro|JTAGLoad)}"

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _link="$(readlink "$_src")"
  case "$_link" in
    /*) _src="$_link" ;;
    *)  _src="$(dirname "$_src")/$_link" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
BACKUP="$SCRIPT_DIR/.segger-links-backup.txt"

# 要保留的软链。按需增删 —— 想留 RTT Viewer 就把 JLinkRTTViewer / JLinkRTTViewer.app 加进来。
KEEP="JLinkExe
JLinkRemoteServer
JLinkRemoteServerCLExe
JLinkRemoteServer.app
JLinkGDBServer
JLinkGDBServerCL
JLinkGDBServer.app
JLinkConfig
JLinkConfig.app
JFlash
JFlash.app"

names() { ls "$BINDIR" 2>/dev/null | grep -E "$PATTERN"; }

fix_owner() { [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$BACKUP" 2>/dev/null; return 0; }

write_backup() {
  cd "$BINDIR" || return 1
  : > "$BACKUP"
  for f in $(names); do
    echo "$f $(readlink "$f")" >> "$BACKUP"
  done
  fix_owner
  echo "已备份 $(wc -l < "$BACKUP" | tr -d ' ') 条 -> $BACKUP"
}

case "${1:-}" in
  list)
    cd "$BINDIR" || exit 1
    for f in $(names); do
      printf '  %-26s -> %s\n' "$f" "$(readlink "$f")"
    done
    echo "  ---- 共 $(names | wc -l | tr -d ' ') 个"
    ;;

  backup)
    write_backup
    ;;

  restore)
    [ -f "$BACKUP" ] || { echo "找不到备份文件 $BACKUP" >&2; exit 1; }
    n=0
    while read -r name target; do
      [ -n "$name" ] && [ -n "$target" ] && { ln -sf "$target" "$BINDIR/$name"; n=$((n + 1)); }
    done < "$BACKUP"
    echo "已按备份还原 $n 条"
    ;;

  check|minimal)
    cd "$BINDIR" || exit 1
    DRY=0; [ "$1" = check ] && DRY=1

    if [ "$DRY" = 0 ]; then
      write_backup
      echo
    fi

    kept=0; removed=0
    for f in $(names); do
      if printf '%s\n' "$KEEP" | grep -qxF "$f"; then
        printf '  keep  %s\n' "$f"
        kept=$((kept + 1))
      else
        printf '  rm    %s\n' "$f"
        [ "$DRY" = 0 ] && rm -f "$f"
        removed=$((removed + 1))
      fi
    done

    echo
    if [ "$DRY" = 1 ]; then
      echo "[试运行] 保留 $kept 个 / 删除 $removed 个 —— 未改动任何文件"
      echo "确认无误后执行: sudo $0 minimal"
    else
      echo "已删除 $removed 个，保留 $kept 个"
      echo "还原: sudo $0 restore"
    fi
    ;;

  *)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
