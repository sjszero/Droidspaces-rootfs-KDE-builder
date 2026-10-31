#!/usr/bin/python3
"""Point Armada Control's desktop-mode read at the container session state.

`set_desktop_mode` already goes through `steamosctl`, which reaches the
container session manager over DBus. Only the read path is wrong here: it
parses the hardware steamos-manager state.toml, which does not exist in a
Droidspaces container, so every read fell back to "desktop".

The matching write path needs ARMADA_SESSION_USER to point at the container
account; the base service leaves it at the hardware "armada" user, which has no
user manager (and therefore no session bus) inside the container.
"""

from __future__ import annotations

import sys
from pathlib import Path

START = "def get_desktop_mode() -> str:\n"
END = "def set_desktop_mode(mode: str):\n"
MARKER = "CONTAINER_SESSION_STATE = Path("
PATCHED = '''CONTAINER_SESSION_USER = "__DS_USER__"
CONTAINER_SESSION_STATE = Path(
    f"/home/{CONTAINER_SESSION_USER}/.config/armada/container-session.json"
)
CONTAINER_DESKTOP_SESSIONS = {
    "desktop": "armada-plasma.desktop",
    "mobile": "armada-plasma-mobile.desktop",
}


def get_desktop_mode() -> str:
    # The container session manager owns this preference and steamosctl reaches
    # it over DBus; the hardware state.toml is not present in this container.
    try:
        state = json.loads(CONTAINER_SESSION_STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError, AttributeError):
        return "desktop"
    session = state.get("desktop_session")
    for mode, desktop_session in CONTAINER_DESKTOP_SESSIONS.items():
        if session == desktop_session:
            return mode
    return "desktop"


'''


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: patch-armada-container-desktop-mode.py <path> <user>", file=sys.stderr)
        return 2

    path = Path(argv[1])
    user = argv[2]
    if not user or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for char in user):
        print("invalid container user", file=sys.stderr)
        return 2

    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"{path}: already patched")
        return 0

    start = text.find(START)
    end = text.find(END, start + len(START))
    if start < 0 or end < 0:
        print(f"{path}: desktop mode functions not found", file=sys.stderr)
        return 1
    original = text[start:end]
    if "STEAMOS_MANAGER_STATE.read_text" not in original:
        print(f"{path}: unexpected desktop mode implementation", file=sys.stderr)
        return 1

    replacement = PATCHED.replace("__DS_USER__", user)
    path.write_text(text[:start] + replacement + text[end:], encoding="utf-8")
    print(f"{path}: patched")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))