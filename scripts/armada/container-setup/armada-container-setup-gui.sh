#!/usr/bin/env bash
# armada-container-setup-gui.sh — 给桌面图标用的图形界面
#
# 目的：不让人在不知道参数的情况下直接双击就跑默认模式（那会直接覆盖文件）。
# 所以先给一个菜单，把「只检查」和「检查并修复」分开，修复前再确认一次。
#
#   --selftest   不弹窗，直接跑一次「只检查」并打印报告（给自动化用）
set -u

# Installed copy drops the .sh suffix; the repository copy keeps it.
HERE="$(dirname -- "$(readlink -f -- "$0")")"
BIN="$HERE/armada-container-setup.sh"
[ -x "$BIN" ] || BIN="$HERE/armada-container-setup"
TITLE="ArmadaOS 容器自检"
STATE="${XDG_DATA_HOME:-$HOME/.local/share}/armada-container-setup"
REPORT="$STATE/gui-report.txt"
LOG="$STATE/last-run.log"
mkdir -p "$STATE"

SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- 自检模式：不依赖图形 ----------
if [ "$SELFTEST" = 1 ]; then
    "$BIN" --check-only >"$REPORT" 2>&1
    rc=$?
    cat "$REPORT"
    exit $rc
fi

if ! have zenity && ! have kdialog; then
    # 没有图形工具：退回终端
    exec konsole -e "$BIN" 2>/dev/null || exec "$BIN"
fi

# 统一封装：优先 zenity（不确定进度条好用），否则 kdialog
ui_menu() {   # $1=提示  $2...=key|label 对
    local prompt=$1; shift
    if have zenity; then
        local args=() first=1
        while [ $# -ge 2 ]; do
            [ $first = 1 ] && { args+=("--column" "选项" "--column" "说明"); first=0; }
            args+=("$1" "$2"); shift 2
        done
        zenity --list --title "$TITLE" --text "$prompt" --width 620 --height 330 \
               --hide-header --print-column=1 "${args[@]}" 2>/dev/null
    else
        kdialog --title "$TITLE" --menu "$prompt" "$@" 2>/dev/null
    fi
}

ui_yesno() {  # $1=标题  $2=正文
    if have zenity; then
        zenity --question --title "$TITLE" --text "$2" --width 560 2>/dev/null
    else
        kdialog --title "$TITLE" --yesno "$2"
    fi
}

ui_text() {   # $1=文件
    if have zenity; then
        zenity --text-info --title "$TITLE" --filename "$1" --width 920 --height 660 2>/dev/null
    else
        kdialog --title "$TITLE" --textbox "$1" 920 660
    fi
}

ui_error() {
    if have zenity; then zenity --error --title "$TITLE" --text "$1" --width 480
    else kdialog --title "$TITLE" --error "$1"; fi
}

ui_busy() {   # 在后台跑 $*，期间显示脉冲进度条；允许取消
    local pid zrc
    "$@" >"$REPORT" 2>&1 &
    pid=$!
    if have zenity; then
        ( while kill -0 "$pid" 2>/dev/null; do echo; sleep 0.4; done ) |
            zenity --progress --pulsate --auto-close --cancel-ok \
                   --title "$TITLE" --text "正在同步仓库脚本并逐项检查…" --width 460 2>/dev/null
        zrc=${PIPESTATUS[1]:-0}
        if [ "$zrc" -ne 0 ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            ui_error "已取消。已经改动的条目不会自动回滚；日志：$LOG"
            exit 0
        fi
    else
        kdialog --title "$TITLE" --passivepopup "正在同步仓库脚本并逐项检查…" 4
    fi
    wait "$pid"
    return $?
}

ui_summary_of() { sed -n 's/^结果：//p' "$REPORT" | tail -1; }

# ---------- 主菜单 ----------
choice=$(ui_menu "选择要做什么：\n\n只检查不会改动任何文件；检查并修复会按仓库当前内容覆盖已列出的路径。" \
    check   "只检查（推荐先跑这个，不改任何文件）" \
    fix     "检查并修复（会覆盖 session-control / box64 配置等）" \
    offline "离线模式（用上次同步的副本，检查并修复）" \
    sync    "只同步仓库脚本，不做检查" \
    log     "查看上次运行日志" \
    items   "查看检查条目清单")
[ -n "${choice:-}" ] || exit 0

case "$choice" in
    log)
        [ -f "$LOG" ] && ui_text "$LOG" || ui_error "还没有日志：$LOG"
        exit 0
        ;;
    items)
        "$BIN" --list >"$REPORT" 2>&1
        ui_text "$REPORT"
        exit 0
        ;;
    sync)
        if ui_busy "$BIN" --sync-only; then
            ui_text "$REPORT"
        else
            ui_text "$REPORT"
            ui_error "同步失败，详见报告和日志：$LOG"
        fi
        exit 0
        ;;
esac

args=()
case "$choice" in
    check)   args=(--check-only) ;;
    fix)     args=() ;;
    offline) args=(--no-sync) ;;
esac

if [ "$choice" != check ]; then
    ui_yesno "$TITLE" "检查并修复会按仓库当前内容覆盖这些路径（已满足的条目不会被动）：

  /usr/libexec/armada/session-control
  /etc/box64.box64rc
  /usr/lib/binfmt.d/box64.conf
  /usr/libexec/armada/gamescope-startup-wait
  ~/.bashrc（追加辅助函数，不覆盖原有内容）

缺什么补什么：
  box64 RPM / x86-64 库目录 / binfmt 注册 / USB Manager
  FEX 的 EnableCodeCachingWIP
  proton 工具缺失时用 armada-proton-fetch 下载（2~3 GB，走镜像加速）
  Steam 默认兼容工具映射（Steam 正在运行时跳过，避免被它覆盖）

确认继续？" || exit 0
fi

ui_busy "$BIN" "${args[@]}"
rc=$?
summary=$(ui_summary_of)
if [ -n "$summary" ]; then TITLE="$TITLE — $summary"; fi
ui_text "$REPORT"
TITLE="ArmadaOS 容器自检"
case "$rc" in
    0) : ;;
    2) ui_error "有需要人工处理的条目（详见报告）。日志：$LOG" ;;
    3) ui_error "另一个实例正在运行，稍后再试。" ;;
    *) ui_error "有失败条目（详见报告）。日志：$LOG" ;;
esac
exit 0