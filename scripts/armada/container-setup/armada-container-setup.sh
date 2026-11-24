#!/usr/bin/env bash
# armada-container-setup.sh — ArmadaOS 容器自检/补齐
#
# 1) 从 GitHub 同步容器仓库（Droidspaces-rootfs-KDE-builder）的脚本，多加速节点，
#    全部失败时退回上次同步的副本，离线可用。
# 2) 把仓库里能在「运行中的容器」使用的脚本逐条检查：已满足跳过，不满足就地修复，
#    镜像内置项只报告不擅自动。
#
# 用法：
#   armada-container-setup.sh                    # 同步 + 检查 + 修复
#   armada-container-setup.sh --check-only       # 只检查，不改任何东西
#   armada-container-setup.sh --no-sync          # 不联网，用上次同步的副本
#   armada-container-setup.sh --only box64-binfmt,fex-maxbuffer
#   armada-container-setup.sh --json             # 机器可读结果（stdout）
#   armada-container-setup.sh --quiet            # 只输出摘要
#   armada-container-setup.sh --list             # 列出条目 id 与标题
#
# 退出码：0 全部满足/已修复；1 有失败；2 有需要人工处理的项；3 已有实例在跑
set -u

usage() {
    cat <<'EOF'
armada-container-setup.sh — ArmadaOS 容器自检/补齐

  1) 从 GitHub 同步容器仓库（Droidspaces-rootfs-KDE-builder）的脚本，多加速节点，
     全部失败时退回上次同步的副本，离线可用。
  2) 把仓库里能在「运行中的容器」使用的脚本逐条检查：已满足跳过，不满足就地修复，
     镜像内置项只报告不擅自动。

printf 'STEAM_CGROUP
'; cat /proc/2351135/cgroup 2>/dev/null | head -2
  armada-container-setup.sh                    # 同步 + 检查 + 修复
  armada-container-setup.sh --check-only       # 只检查，不改任何东西
  armada-container-setup.sh --no-sync          # 不联网，用上次同步的副本
  armada-container-setup.sh --only box64-binfmt,fex-maxbuffer
  armada-container-setup.sh --json             # 机器可读结果（stdout）
  armada-container-setup.sh --quiet            # 只输出摘要
  armada-container-setup.sh --list             # 列出条目 id 与标题
  armada-container-setup.sh --sync-only        # 只同步仓库脚本

printf 'STEAM_CGROUP
'; cat /proc/2351135/cgroup 2>/dev/null | head -20 全部满足/已修复；1 有失败；2 有需要人工处理的项；3 已有实例在跑
EOF
}

REPO_SLUG="sjszero/Droidspaces-rootfs-KDE-builder"
BRANCH="main"
MIRRORS=(
    "https://gh.monlor.com/https://github.com"
    "https://gh-proxy.com/https://github.com"
    "https://github.com"
)
STATE="${XDG_DATA_HOME:-$HOME/.local/share}/armada-container-setup"
SRC="$STATE/repo"
LOG="$STATE/last-run.log"
JSON_OUT="$STATE/last-run.json"
LOCKFILE="$STATE/.lock"
USB_UPSTREAM="Yizhou147/Droidspaces-USB-Manager"
PROTON_TOOL="/usr/share/steam/compatibilitytools.d/proton-cachyos-11.0-arm64"
FEX_CFG="$PROTON_TOOL/files/share/fex-emu/Config.json"
PROTON_FETCH="$HOME/.local/bin/armada-proton-fetch"
STEAM_COMPAT="$HOME/.local/bin/armada-steam-compat"

MODE=fix
NO_SYNC=0
ONLY=""
JSON=0
QUIET=0
LIST_ONLY=0
SYNC_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check-only) MODE=check ;;
        --no-sync) NO_SYNC=1 ;;
        --only) ONLY=${2:-}; shift ;;
        --only=*) ONLY=${1#--only=} ;;
        --json) JSON=1; QUIET=1 ;;
        --quiet) QUIET=1 ;;
        --list) LIST_ONLY=1 ;;
        --sync-only) SYNC_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$STATE"
: >"$LOG"

if [ -t 1 ] && [ "$QUIET" = 0 ]; then
    C_OK=$'\033[32m'; C_FIX=$'\033[36m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_0=$'\033[0m'
else
    C_OK=""; C_FIX=""; C_WARN=""; C_ERR=""; C_DIM=""; C_0=""
fi
log() { printf '%s\n' "$*" >>"$LOG"; }
say() { [ "$QUIET" = 1 ] && return 0; printf '%s\n' "$*"; }

# ---------- 单实例 ----------
exec 9>"$LOCKFILE" || true
if ! flock -n 9; then
    echo "另一个 armada-container-setup 正在运行（$LOCKFILE），稍后再试" >&2
    exit 3
fi

# ---------- 权限 ----------
SUDO_OK=0
SUDO=""
if sudo -n true 2>/dev/null; then SUDO_OK=1; SUDO="sudo -n"; fi

# ---------- 仓库同步 ----------
sync_repo() {
    local m url commit
    if [ "$NO_SYNC" = 1 ]; then
        [ -d "$SRC/scripts" ] || { log "缓存不存在，但指定了 --no-sync"; return 1; }
        log "跳过同步（--no-sync），使用 $(git -C "$SRC" log -1 --format=%h 2>/dev/null)"
        return 0
    fi
    for m in "${MIRRORS[@]}"; do
        url="$m/$REPO_SLUG.git"
        log "同步尝试：$m"
        if [ -d "$SRC/.git" ]; then
            if timeout 90 git -C "$SRC" remote set-url origin "$url" 2>/dev/null &&
               timeout 90 git -C "$SRC" fetch --depth 1 origin "$BRANCH" >>"$LOG" 2>&1 &&
               timeout 30 git -C "$SRC" reset --hard FETCH_HEAD >>"$LOG" 2>&1; then
                commit=$(git -C "$SRC" log -1 --format='%h %s' 2>/dev/null)
                log "同步成功：$commit"
                return 0
            fi
        elif timeout 180 git clone --depth 1 --branch "$BRANCH" "$url" "$SRC" >>"$LOG" 2>&1; then
            commit=$(git -C "$SRC" log -1 --format='%h %s' 2>/dev/null)
            log "同步成功：$commit"
            return 0
        fi
        log "  该节点不可用"
    done
    if [ -d "$SRC/scripts" ]; then
        log "所有节点不可用，改用上次同步的副本：$(git -C "$SRC" log -1 --format=%h 2>/dev/null)"
        return 0
    fi
    log "拿不到仓库脚本，也没有缓存"
    return 1
}

# ---------- 公共 ----------
has() { command -v "$1" >/dev/null 2>&1; }

# 仓库脚本带构建期占位符（Dockerfile 里 sed 成镜像用户），比对/安装前先渲染
DS_USER="${DS_USER_OVERRIDE:-}"
if [ -z "$DS_USER" ]; then
    DS_USER=$(sed -n 's/^SESSION_USER=//p' /usr/libexec/armada/session-control 2>/dev/null | head -1)
fi
[ -n "$DS_USER" ] || DS_USER=$(id -un)
render_template() { sed -e "s|__DS_USER__|${DS_USER}|g" -e "s|__DS_HOME__|${HOME}|g" "$1"; }
same_as_template() { diff -q <(render_template "$1") "$2" >/dev/null 2>&1; }
install_template() { render_template "$1" | $SUDO tee "$2" >/dev/null && $SUDO chmod "$3" "$2"; }

# ---------- 检查 ----------
check_box64_package() { rpm -q box64-armada >/dev/null 2>&1; }
fix_box64_package() {
    local rpm
    if [ -x /usr/bin/box64 ] && ! check_box64_package; then
        log "/usr/bin/box64 存在但不在 RPM 数据库里（手工安装？），不自动装以免冲突"
        return 3   # 3 = 需人工
    fi
    rpm=$(ls -1 "$SRC"/scripts/armada/box64/rpm/*.aarch64.rpm 2>/dev/null | sort -V | tail -1)
    [ -n "$rpm" ] || { log "仓库里没有 box64 rpm 产物（只有 spec）；需要先构建"; return 3; }
    $SUDO dnf install -y --nogpgcheck "$rpm"
}

check_box64_libs() { [ -d /usr/lib/box64-x86_64-linux-gnu ] && [ -n "$(ls -A /usr/lib/box64-x86_64-linux-gnu 2>/dev/null)" ]; }
fix_box64_libs() { $SUDO bash "$SRC/scripts/armada/box64/install-x86-64-libs.sh"; }

BINFMT_ENTRIES="box64-x86_64 box64-i386"
check_box64_binfmt() {
    local e
    for e in $BINFMT_ENTRIES; do
        [ -e "/proc/sys/fs/binfmt_misc/$e" ] || return 1
    done
    return 0
}
fix_box64_binfmt() { $SUDO bash "$SRC/scripts/armada/box64/box64-binfmt"; }

# The entry list lives in one file that the unit, the image and the RPM share.
check_box64_binfmt_conf() {
    [ -f /usr/lib/binfmt.d/box64.conf ] &&
        diff -q "$SRC/scripts/armada/box64/box64-binfmt.conf" /usr/lib/binfmt.d/box64.conf >/dev/null 2>&1
}
fix_box64_binfmt_conf() {
    $SUDO install -d -m 0755 /usr/lib/binfmt.d
    $SUDO install -m 0644 "$SRC/scripts/armada/box64/box64-binfmt.conf" /usr/lib/binfmt.d/box64.conf
}

check_box64_config() { same_as_template "$SRC/scripts/armada/box64/box64.box64rc" /etc/box64.box64rc; }
fix_box64_config() { install_template "$SRC/scripts/armada/box64/box64.box64rc" /etc/box64.box64rc 0644; }

check_session_control() { same_as_template "$SRC/scripts/armada/armada-container-session-control" /usr/libexec/armada/session-control; }
fix_session_control() { install_template "$SRC/scripts/armada/armada-container-session-control" /usr/libexec/armada/session-control 0755; }

check_gamescope_startup() { same_as_template "$SRC/scripts/armada/anland/armada-gamescope-startup.sh" /usr/libexec/armada/gamescope-startup-wait; }
fix_gamescope_startup() { install_template "$SRC/scripts/armada/anland/armada-gamescope-startup.sh" /usr/libexec/armada/gamescope-startup-wait 0755; }

check_usb_manager() { [ -d /usr/share/usb-manager ] && [ -f /etc/sudoers.d/droidspaces-usb-manager ]; }
fix_usb_manager() {
    local m url tmp dir
    tmp="$STATE/tmp/usb-manager"; rm -rf "$tmp"; mkdir -p "$tmp"
    for m in "${MIRRORS[@]}"; do
        url="$m/$USB_UPSTREAM/archive/refs/heads/main.tar.gz"
        if timeout 120 curl -fL --retry 2 -o "$tmp/src.tar.gz" "$url" >>"$LOG" 2>&1 && [ -s "$tmp/src.tar.gz" ]; then
            tar -xzf "$tmp/src.tar.gz" -C "$tmp" 2>>"$LOG" || continue
            dir=$(find "$tmp" -maxdepth 1 -type d -name 'Droidspaces-USB-Manager-*' | head -1)
            [ -n "$dir" ] || continue
            $SUDO bash "$SRC/scripts/install-usb-manager.sh" --user "$DS_USER" --source "$dir"
            return $?
        fi
    done
    log "USB Manager 上游压缩包所有节点都下载失败"
    return 1
}

check_bashrc() { grep -q '^# >>> armada-container-setup: bashrc.sh' "$HOME/.bashrc" 2>/dev/null; }
fix_bashrc() {
    {
        printf '\n# >>> armada-container-setup: bashrc.sh >>>\n'
        cat "$SRC/scripts/bashrc.sh"
        printf '# <<< armada-container-setup: bashrc.sh <<<\n'
    } >>"$HOME/.bashrc"
}

check_fex_maxbuffer() { [ -f "$FEX_CFG" ] && grep -q 'EnableCodeCachingWIP' "$FEX_CFG"; }
fix_fex_maxbuffer() {
    [ -f "$FEX_CFG" ] || { log "proton 工具不存在：$PROTON_TOOL"; return 3; }
    $SUDO python3 - "$FEX_CFG" <<'PY'
import json, re, sys
path = sys.argv[1]
lines = open(path, encoding='utf-8').read().splitlines()
idx = None
for i, line in enumerate(lines):
    if re.match(r'^\s*"[^"]+"\s*:\s*"[^"]*"\s*,?\s*$', line):
        idx = i
if idx is None:
    sys.exit('cannot locate insertion point')
indent = re.match(r'^(\s*)', lines[idx]).group(1)
if not lines[idx].rstrip().endswith(','):
    lines[idx] = lines[idx].rstrip() + ','
lines.insert(idx + 1, indent + '"EnableCodeCachingWIP": "1"')
out = '\n'.join(lines) + '\n'
json.loads(out)
open(path, 'w', encoding='utf-8').write(out)
print('EnableCodeCachingWIP enabled')
PY
}

check_proton_tool() { [ -d "$PROTON_TOOL" ]; }
fix_proton_tool() {
    if [ "${ARMADA_NO_PROTON_DOWNLOAD:-0}" = 1 ]; then
        log "ARMADA_NO_PROTON_DOWNLOAD=1：跳过 proton 下载"
        return 3
    fi
    [ -x "$PROTON_FETCH" ] || { log "缺 $PROTON_FETCH"; return 3; }
    "$PROTON_FETCH" --install --source cachyos --json
}

check_steam_compat() {
    [ -x "$STEAM_COMPAT" ] || return 1
    "$STEAM_COMPAT" --list --json 2>/dev/null | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(1)
tools = {t["name"] for t in doc.get("tools") or []}
default = (doc.get("mappings") or {}).get("0")
sys.exit(0 if default in tools else 1)
'
}
fix_steam_compat() {
    [ -x "$STEAM_COMPAT" ] || { log "缺 $STEAM_COMPAT"; return 3; }
    if pgrep -x steam >/dev/null 2>&1; then
        log "Steam 正在运行，此时写 config.vdf 会在 Steam 退出时被覆盖"
        return 3
    fi
    "$STEAM_COMPAT" --set 0 "$(basename "$PROTON_TOOL")"
}

check_fex_runtime() {
    [ -x /usr/bin/FEX ] && [ -d /usr/local/share/fex-emu/GuestThunks ] &&
        [ -d /usr/local/lib64/fex-emu/HostThunks ]
}

check_container_action() { [ -x /usr/libexec/armada/container-action ]; }
check_desktop_conf() { [ -f /etc/droidspaces-desktop.conf ]; }

# ---------- 条目表 ----------
IDS=(); TITLES=(); NEEDS=()
add() { IDS+=("$1"); TITLES+=("$2"); NEEDS+=("$3"); }

add box64-package     "box64 RPM（box64-armada）"           root
add box64-libs        "box64 x86-64 库目录"                root
add box64-binfmt      "box64 binfmt 注册（x86 + x86-64）"    root
add box64-binfmt-conf "binfmt 条目文件 /usr/lib/binfmt.d"     root
add box64-config      "/etc/box64.box64rc 与仓库一致"      root
add session-control   "容器 session-control"               root
add gamescope-startup "gamescope 启动等待脚本"             root
add usb-manager       "Droidspaces USB Manager"            root
add bashrc            "~/.bashrc 辅助函数"                 user
add fex-maxbuffer     "FEX 最大 code buffer（proton 工具）" root
add proton-tool       "proton-cachyos-11.0-arm64 工具"     root
add steam-compat      "Steam 默认兼容工具映射"             user
add fex-runtime       "FEX 运行时与 thunks（镜像内置）"      root
add container-action  "container-action（镜像内置）"       root
add desktop-conf      "droidspaces-desktop.conf（镜像内置）" root

if [ "$LIST_ONLY" = 1 ]; then
    i=0
    for id in "${IDS[@]}"; do printf '%-20s %s\n' "$id" "${TITLES[$i]}"; i=$((i+1)); done
    exit 0
fi

# ---------- 执行 ----------
STARTED=$(date '+%F %T')
SECONDS=0
say "${C_DIM}== ArmadaOS 容器自检 ${STARTED} ==${C_0}"
if ! sync_repo; then
    say "${C_ERR}仓库同步失败且没有缓存${C_0}"
    exit 1
fi
REV=$(git -C "$SRC" log -1 --format='%h %s' 2>/dev/null)
if [ "$SYNC_ONLY" = 1 ]; then
    printf '仓库已同步：%s\n' "$REV"
    exit 0
fi
[ "$MODE" = check ] && say "${C_WARN}只检查模式：不会改动任何文件${C_0}"
say "仓库版本：${C_DIM}${REV}${C_0}"
say ""

# --only 过滤（逗号或空格分隔都可以）
WANT=" $(printf '%s' "$ONLY" | tr ',' ' ') "
selected=()
i=0
for id in "${IDS[@]}"; do
    if [ -n "$ONLY" ]; then
        case "$WANT" in *" $id "*) ;; *) i=$((i+1)); continue ;; esac
    fi
    selected+=("$id")
    i=$((i+1))
done
[ ${#selected[@]} -gt 0 ] || { say "${C_ERR}--only 没匹配到任何条目${C_0}"; exit 2; }

n_ok=0; n_fixed=0; n_manual=0; n_failed=0
TSV=$(mktemp)
trap 'rm -f "$TSV"' EXIT
manual_list=(); failed_list=()

for id in "${selected[@]}"; do
    idx=0
    for x in "${IDS[@]}"; do [ "$x" = "$id" ] && break; idx=$((idx+1)); done
    title=${TITLES[$idx]}; need=${NEEDS[$idx]}
    check_fn="check_${id//-/_}"; fix_fn="fix_${id//-/_}"
    status=""; detail=""

    if ! declare -F "$check_fn" >/dev/null; then
        status=manual; detail="脚本里没有检查函数"
    elif "$check_fn"; then
        status=ok; detail=""
    elif [ "$MODE" = check ]; then
        status=manual; detail="待修复（只检查模式未改动）"
    elif [ "$need" = root ] && [ "$SUDO_OK" != 1 ]; then
        status=manual; detail="需要 root（sudo -n 不可用）"
    elif ! declare -F "$fix_fn" >/dev/null; then
        status=manual; detail="镜像内置项，脚本不自动处理"
    else
        log "执行修复：$id"
        if "$fix_fn" >>"$LOG" 2>&1; then
            if "$check_fn"; then status=fixed; else status=failed; detail="修复后仍不通过"; fi
        else
            rc=$?
            if [ "$rc" = 3 ]; then status=manual; detail="需要人工处理（见日志）"; else status=failed; detail="修复命令失败 rc=$rc"; fi
        fi
    fi

    case "$status" in
        ok)      n_ok=$((n_ok+1));      [ "$QUIET" = 0 ] && say "${C_OK}✓${C_0}  $title" ;;
        fixed)   n_fixed=$((n_fixed+1)); [ "$QUIET" = 0 ] && say "${C_FIX}✓${C_0}  $title ${C_FIX}已修复${C_0}" ;;
        manual)  n_manual=$((n_manual+1)); manual_list+=("$id")
                 [ "$QUIET" = 0 ] && say "${C_WARN}!${C_0}  $title ${C_WARN}${detail}${C_0}" ;;
        failed)  n_failed=$((n_failed+1)); failed_list+=("$id")
                 [ "$QUIET" = 0 ] && say "${C_ERR}✗${C_0}  $title ${C_ERR}${detail}（看 $LOG）${C_0}" ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$id" "$status" "$title" "$detail" >>"$TSV"
done

DURATION=$SECONDS
SUMMARY="结果：${n_ok} 已满足，${n_fixed} 已修复，${n_manual} 需人工，${n_failed} 失败（${DURATION}s）"

if [ "$JSON" = 1 ]; then
    python3 - "$TSV" "$REV" "$STARTED" "$DURATION" "$JSON_OUT" <<'PY'
import json, sys
tsv, rev, started, duration, out = sys.argv[1:6]
items = []
with open(tsv, encoding='utf-8') as fh:
    for line in fh:
        parts = line.rstrip('\n').split('\t')
        if len(parts) < 3:
            continue
        items.append({'id': parts[0], 'status': parts[1], 'title': parts[2],
                      'detail': parts[3] if len(parts) > 3 else ''})
summary = {s: sum(1 for i in items if i['status'] == s)
           for s in ('ok', 'fixed', 'manual', 'failed')}
doc = {'repo': rev, 'started': started, 'duration_s': int(duration),
       'items': items, 'summary': summary}
blob = json.dumps(doc, ensure_ascii=False, indent=2)
open(out, 'w', encoding='utf-8').write(blob + '\n')
print(blob)
PY
else
    [ "$QUIET" = 1 ] || say ""
    say "$SUMMARY"
    [ ${#failed_list[@]} -gt 0 ] && say "失败：${failed_list[*]}"
    [ ${#manual_list[@]} -gt 0 ] && say "需人工：${manual_list[*]}"
    say "日志：$LOG"
fi

[ "$n_failed" -gt 0 ] && exit 1
[ "$n_manual" -gt 0 ] && exit 2
exit 0