#!/usr/bin/python3
"""Give armada's standalone Plasma session an Anland producer environment.

`armada-plasma-session standalone` ends with a bare `exec startplasma-wayland`.
That is correct on real Armada hardware, where the desktop is started from a
running Game Mode session and the display stack is already in place. In a
Droidspaces container running Anland the situation is different:

  * kwin_wayland is the top-level compositor and talks to the Android display
    daemon through its built-in "anland" backend, which is selected by
    environment variables (ANLAND, ANLAND_SOCKET, ANLAND_DRM_DEVICE ...) plus
    the KGSL Mesa driver. Without them KWin falls back to DRM, finds no KMS
    device in the container, and exits;
  * SDDM starts Wayland sessions without a session bus. startplasma-wayland
    shuts down immediately when dbus-daemon is not already running, so nothing
    starts even with the right environment.

Those variables cannot come from sddm.service: sddm-helper rebuilds the session
environment from PAM and a fixed whitelist, so the unit can list ANLAND=1 while
the session process still sees an empty value. They have to be exported by the
session script itself, which is what this patch does.

The substitution is exact-match on purpose. If upstream rewrites the block the
build fails loudly instead of shipping a session that silently starts without
the Anland backend.
"""

from __future__ import annotations

import sys
from pathlib import Path

ORIGINAL = '''    export DESKTOP_SESSION=plasma
    exec "${ARMADA_STARTPLASMA:-/usr/bin/startplasma-wayland}"'''

PATCHED = '''    export DESKTOP_SESSION=plasma
    # Anland runs the desktop as the top-level producer: kwin_wayland's built-in
    # anland backend talks to the display daemon directly, so the session needs
    # the producer environment. sddm-helper rebuilds the session environment
    # from PAM and its own whitelist, so none of this can be inherited from the
    # sddm.service unit and it has to be set here.
    # SDDM also starts Wayland sessions without a session bus; startplasma-wayland
    # shuts down immediately unless dbus-daemon is already running.
    session_bus=0
    socket=${ANLAND_SOCKET:-/run/display.sock}
    if [[ ${ANLAND:-0} == 1 || -S $socket ]]; then
        export ANLAND=1
        export ANLAND_SOCKET="$socket"
        export ANLAND_DRM_DEVICE="${ANLAND_DRM_DEVICE:-/dev/dri/renderD128}"
        export ANLAND_SKIP_IMPLICIT_SYNC_WAIT="${ANLAND_SKIP_IMPLICIT_SYNC_WAIT:-1}"
        export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-kgsl}"
        export GALLIUM_DRIVER="${GALLIUM_DRIVER:-kgsl}"
        export FD_FORCE_KGSL="${FD_FORCE_KGSL:-1}"
        export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
        session_bus=1
    fi
    if [[ $session_bus == 1 ]] && command -v dbus-run-session >/dev/null 2>&1; then
        exec dbus-run-session "${ARMADA_STARTPLASMA:-/usr/bin/startplasma-wayland}"
    fi
    exec "${ARMADA_STARTPLASMA:-/usr/bin/startplasma-wayland}"'''

MARKER = 'ANLAND_SKIP_IMPLICIT_SYNC_WAIT'


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print('usage: patch-armada-plasma-session.py <path>', file=sys.stderr)
        return 2

    path = Path(argv[1])
    text = path.read_text()

    if MARKER in text:
        # Already patched: keep the script idempotent so a rebuilt layer or a
        # re-run inside a live container is not a build failure.
        print(f'{path}: already patched')
        return 0

    if ORIGINAL not in text:
        print(
            f'{path}: the standalone Plasma block is not the expected shape; '
            'armada-plasma-session changed upstream and this patch must be '
            'updated rather than silently skipped',
            file=sys.stderr,
        )
        return 1

    path.write_text(text.replace(ORIGINAL, PATCHED, 1))
    print(f'{path}: patched')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
