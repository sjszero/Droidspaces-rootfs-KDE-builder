#!/bin/bash
# Launch the i386 Steam client under FEX, with the right interpreter, locale and
# identity. Three things here are load-bearing and each one was found the hard way.
#
# 1. Identity. Run as the user that owns ~/.local/share/Steam -- never via sudo.
#    tier0 creates a SysV semaphore with mode 0600 and the creator's uid, then
#    reuses it by key; ipcperms() rejects any process with a different euid, so a
#    root-owned leftover kills the client with
#      semget(0x2f0fb4e4, 1, 0600) = -1 EACCES
#      ../tier0/threadtools.cpp (2526) : Assertion Failed: Permission denied
#    which surfaces as SIGTRAP (rc 133). This is also why Steam must be stopped
#    with SIGTERM: kill -9 leaves that semaphore behind.
#
# 2. Locale. LANG/LC_ALL must be C. The FEX RootFS ships no zh_CN locale data, and
#    when the host locale leaks through Xlib reports "XOpenIM() failed" and the
#    client tears itself down before the window ever appears. XMODIFIERS=@im=none
#    keeps Xlib from looking for an XIM server at all.
#
# 3. Interpreter. box64 is the machine default (see build-box64.sh); FEX is
#    switched in only for this client's lifetime, because the i386 client and the
#    x86-64 helpers it spawns (pressure-vessel-wrap, steamwebhelper) fail silently
#    under box64, and because FEX is the side with the GL/Vulkan thunks.
set -u

STEAM_HOME=${STEAM_HOME:-$HOME}
CLIENT=$STEAM_HOME/.local/share/Steam/ubuntu12_32/steam
[[ -x $CLIENT ]] || { echo "steam-fex: no client at $CLIENT" >&2; exit 1; }

: "${DISPLAY:=:0}"
if [[ -z ${XAUTHORITY:-} ]]; then
    XAUTHORITY=$(ls -t /run/user/"$(id -u)"/xauth_* 2>/dev/null | head -1)
    export XAUTHORITY
fi
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export DISPLAY XDG_RUNTIME_DIR
export LANG=C LANGUAGE=C LC_ALL=C XMODIFIERS=@im=none
export PATH=/usr/local/bin:/usr/bin:/bin

if [[ $(id -u) -eq 0 ]]; then
    echo "steam-fex: do not run this as root -- see the semaphore note above" >&2
    exit 1
fi

sudo -n fex-binfmt on || { echo "steam-fex: cannot switch binfmt to FEX" >&2; exit 1; }
trap 'sudo -n fex-binfmt off >/dev/null 2>&1' EXIT INT TERM HUP

# No `exec` here on purpose: exec would replace this shell and the EXIT trap would
# never run, leaving FEX as the machine-wide interpreter after Steam quits.
FEX "$CLIENT" "$@"