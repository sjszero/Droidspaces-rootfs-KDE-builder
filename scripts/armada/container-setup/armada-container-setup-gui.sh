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
# 排障/自动化用：--choice=check|fix|offline|sync 直接进入该分支，不弹菜单。
CHOICE_PRESET=""
for a in "$@"; do
    case "$a" in
        --selftest) SELFTEST=1 ;;
        --choice=*) CHOICE_PRESET="${a#--choice=}" ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- 自检模式：不依赖图形 ----------
if [ "$SELFTEST" = 1 ]; then
    "$BIN" --check-only >"$REPORT" 2>&1
    rc=$?
    cat "$REPORT"
    exit $rc
fi

if ! have zenity && ! have kdialog; then
    # 没有图形工具：退回终端模拟器；连终端都没有就直接在前台跑
    if have konsole; then exec konsole -e "$BIN"; fi
    exec "$BIN"
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

ui_info() {   # 不是错误，只是提示（例如只检查模式发现待修复项）
    if have zenity; then zenity --info --title "$TITLE" --text "$1" --width 480
    else kdialog --title "$TITLE" --msgbox "$1"; fi
}

ui_busy() {   # 在后台跑 $*，期间显示脉冲进度条；关掉进度条＝取消
    local pid zrc t0 elapsed
    "$@" >"$REPORT" 2>&1 &
    pid=$!
    t0=$(date +%s)
    if have zenity; then
        # 这个 zenity 不支持 --cancel-ok（传了就 255 直接退出），只用它认的参数；
        # 用户关掉进度条仍然可以取消。
        ( while kill -0 "$pid" 2>/dev/null; do echo; sleep 0.4; done ) |
            zenity --progress --pulsate --auto-close \
                   --title "$TITLE" --text "正在同步仓库脚本并逐项检查…" --width 460 2>/dev/null
        zrc=${PIPESTATUS[1]:-0}
        elapsed=$(( $(date +%s) - t0 ))
        if [ "$zrc" -ne 0 ] && kill -0 "$pid" 2>/dev/null; then
            if [ "$elapsed" -le 2 ]; then
                # 进度条没起来（参数不兼容/显示不出来）——不能当成用户取消
                glog "进度条立即退出（rc=$zrc），按不可用处理，继续等待主脚本"
            else
                kill "$pid" 2>/dev/null
                wait "$pid" 2>/dev/null
                glog "用户关闭进度条，已取消主脚本"
                ui_error "已取消。已经改动的条目不会自动回滚；日志：$LOG"
                exit 0
            fi
        fi
    else
        kdialog --title "$TITLE" --passivepopup "正在同步仓库脚本并逐项检查…" 4
    fi
    wait "$pid"
    return $?
}

ui_summary_of() { sed -n 's/^结果：//p' "$REPORT" | tail -1; }

# ---------- 提权 ----------
# Passwordless sudo is not the default in this image, so ask once and hand the main
# script an askpass helper (it then runs every privileged step as `sudo -A`). The
# password never touches the command line and the helper is wiped on exit.
ASKPASS_DIR=""
cleanup_askpass() { [ -n "$ASKPASS_DIR" ] && rm -rf "$ASKPASS_DIR"; }
trap cleanup_askpass EXIT INT TERM HUP

GUI_LOG="$STATE/gui.log"
glog() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$GUI_LOG"; }

ensure_sudo() {
    sudo -n true 2>/dev/null && { unset SUDO_ASKPASS; glog "已有免密 sudo"; return 0; }
    if [ -n "${SUDO_ASKPASS:-}" ] && sudo -A true 2>/dev/null; then
        glog "沿用已有的 SUDO_ASKPASS"
        return 0
    fi

    # zenity --password 在这个构建里不把密码写到 stdout（拿到空值），改用
    # --entry --hide-text：它和 --list 走同一条输出通道，实测可靠。
    local pw="" rc=0 backend=""
    # 只在后端「不认这些参数」(rc=255) 时才换下一个；rc=1 是用户主动取消，
    # 那时再弹第二个框只会让用户连点三次取消。
    if have zenity; then
        backend=zenity-entry
        pw=$(zenity --entry --hide-text --title "$TITLE（需要管理员密码）" \
                    --text "修改容器里的系统文件需要管理员密码" 2>/dev/null)
        rc=$?
        glog "密码框：后端=$backend rc=$rc 长度=${#pw}"
        if [ "$rc" = 255 ]; then backend=""; pw=""
        elif [ -z "$pw" ]; then return 1; fi
    fi
    if [ -z "$backend" ] && have zenity; then
        backend=zenity-password
        pw=$(zenity --password --title "$TITLE（需要管理员密码）" 2>/dev/null)
        rc=$?
        glog "密码框：后端=$backend rc=$rc 长度=${#pw}"
        if [ "$rc" = 255 ]; then backend=""; pw=""
        elif [ -z "$pw" ]; then return 1; fi
    fi
    if [ -z "$backend" ] && have kdialog; then
        backend=kdialog
        pw=$(kdialog --title "$TITLE" --password "需要管理员密码（改写容器里的系统文件）" 2>/dev/null)
        rc=$?
        glog "密码框：后端=$backend rc=$rc 长度=${#pw}"
        if [ -z "$pw" ]; then return 1; fi
    fi
    [ -n "$pw" ] || { glog "没有可用的密码框后端"; return 1; }

    ASKPASS_DIR="${XDG_RUNTIME_DIR:-/tmp}/armada-sudo.$$"
    mkdir -p "$ASKPASS_DIR" || { glog "建目录失败：$ASKPASS_DIR"; return 1; }
    chmod 700 "$ASKPASS_DIR"
    printf '%s\n' "$pw" > "$ASKPASS_DIR/pw"
    chmod 600 "$ASKPASS_DIR/pw"
    unset pw
    printf '%s\n' '#!/bin/sh' 'cat "$(dirname -- "$0")/pw" 2>/dev/null' > "$ASKPASS_DIR/askpass.sh"
    chmod 700 "$ASKPASS_DIR/askpass.sh"
    export SUDO_ASKPASS="$ASKPASS_DIR/askpass.sh"

    local err
    if err=$(sudo -A true 2>&1); then
        glog "sudo -A 校验通过"
        return 0
    fi
    glog "sudo -A 校验失败：$err"
    cleanup_askpass; ASKPASS_DIR=""; unset SUDO_ASKPASS
    return 1
}


# ---------- 主菜单 ----------
if [ -n "$CHOICE_PRESET" ]; then
    choice="$CHOICE_PRESET"
else
    choice=$(ui_menu "选择要做什么：

只检查不会改动任何文件；检查并修复会按仓库当前内容覆盖已列出的路径。" \
        check   "只检查（推荐先跑这个，不改任何文件）" \
        fix     "检查并修复（会覆盖 session-control / box64 配置等）" \
        offline "离线模式（用上次同步的副本，检查并修复）" \
        sync    "只同步仓库脚本，不做检查" \
        log     "查看上次运行日志" \
        items   "查看检查条目清单")
    [ -n "${choice:-}" ] || exit 0
fi

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

# 除「只同步」和查看类菜单外，一律先提权：这个镜像默认没有免密 sudo，不先
# 要密码的话修复必定报「未取得提权」。密码框放在确认框之前，保证一定被看到。
case "$choice" in
    sync|log|items) : ;;
    check)
        # 所有检查项都是只读的：能提权就提，用户取消也照样跑
        ensure_sudo || glog "只检查模式未取得提权，继续（检查项只读）"
        ;;
    *)
        ensure_sudo || { ui_error "没有取得管理员密码，已取消。详情：$GUI_LOG"; exit 0; }
        ;;
esac

if [ "$choice" != check ] && [ -z "$CHOICE_PRESET" ]; then
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
    4) ui_info "没有改动任何文件。上面这些条目与仓库不一致，选「检查并修复」会逐项尝试；个别需要人工处理的项会在报告里单独列出。" ;;
    2) ui_error "有需要人工处理的条目（详见报告）。日志：$LOG" ;;
    3) ui_error "另一个实例正在运行，稍后再试。" ;;
    *) ui_error "有失败条目（详见报告）。日志：$LOG" ;;
esac
exit 0
