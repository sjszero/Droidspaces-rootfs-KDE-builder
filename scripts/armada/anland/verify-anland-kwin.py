#!/usr/bin/python3
"""Fail the build when the container's KWin cannot drive the Anland backend.

The armada base image ships `kwin-<ver>.fc44.armada`, which is a plain KWin: no
Anland backend, so it picks DRM at startup, finds no `/dev/dri/card0` inside a
container, and exits. SDDM respawns it roughly every 5 s, which reaches the user
as "desktop mode switches and there is no picture at all" with nothing in the UI
to explain it.

`install-anland-kde` replaces those packages with `kwin-<ver>-1.anland.fc44`,
whose binary contains `KWin::AnlandBackend` and renders to the display daemon
instead of a DRM connector. This script asserts that outcome, so the build stops
instead of producing an image whose desktop mode is a black screen.

Usage:
    verify-anland-kwin.py            # check the live system
    verify-anland-kwin.py --explain  # also print what was found
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

# The KWin binary, not a library: the backend is compiled in, and the plugin
# directory (org.kde.kwin.waylandbackends) does not exist in this packaging.
KWIN_BINARY = "/usr/bin/kwin_wayland"
KWIN_PACKAGES = ("kwin", "kwin-common", "kwin-libs")


def rpm_version(package: str) -> str | None:
    """Return the installed version of `package`, or None when absent."""
    rpm = shutil.which("rpm")
    if rpm is None:
        return None
    result = subprocess.run(
        [rpm, "-q", "--qf", "%{VERSION}-%{RELEASE}", package],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def binary_has_anland(path: str) -> bool | None:
    """True when the binary carries the Anland backend, None when unreadable."""
    strings = shutil.which("strings")
    if strings is None or not os.access(path, os.R_OK):
        return None
    result = subprocess.run([strings, path], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return None
    return "AnlandBackend" in result.stdout


def main(argv: list[str]) -> int:
    explain = "--explain" in argv[1:]

    problems: list[str] = []
    details: list[str] = []

    for package in KWIN_PACKAGES:
        version = rpm_version(package)
        if version is None:
            problems.append(f"{package} is not installed")
            details.append(f"{package}: missing")
            continue
        details.append(f"{package}: {version}")
        # The distribution build is not an alternative: it has no Anland backend.
        if "anland" not in version:
            problems.append(
                f"{package} is {version}, which is not the Anland build "
                "(its KWin has no Anland backend and desktop mode will be black)"
            )

    has_backend = binary_has_anland(KWIN_BINARY)
    if has_backend is None:
        details.append(f"{KWIN_BINARY}: unreadable or `strings` missing")
    elif has_backend:
        details.append(f"{KWIN_BINARY}: AnlandBackend present")
    else:
        details.append(f"{KWIN_BINARY}: AnlandBackend absent")
        problems.append(
            f"{KWIN_BINARY} has no AnlandBackend symbol, so it would fall back to "
            "DRM and fail on /dev/dri/card0 inside the container"
        )

    if explain:
        for line in details:
            print(line)
    for problem in problems:
        print(f"anland kwin: {problem}", file=sys.stderr)
    if problems:
        print(
            "anland kwin: install the patched build with "
            "`install-anland-kde -1` (it also needs "
            "`dnf remove xorg-x11-server-Xwayland-devel` first when that package "
            "pins the distribution Xwayland)",
            file=sys.stderr,
        )
        return 1
    if explain:
        print("anland kwin: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))