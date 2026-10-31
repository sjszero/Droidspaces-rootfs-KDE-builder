#!/usr/bin/python3
"""Remove Bazaar from Armada's Plasma taskbar pins in Droidspaces images."""

from __future__ import annotations

import sys
from pathlib import Path

BAZAAR_ID = "io.github.kolunmi.Bazaar.desktop"
MARKER = "DROIDSPACES_NO_BAZAAR_TASKBAR_PIN"
JS_MARKER = f"// {MARKER}"
KICKER_MARKER = f"# {MARKER}"
JS_TARGET = f'                    "applications:{BAZAAR_ID}",\n'
JS_ANCHORS = (
    '                    "applications:org.mozilla.firefox.desktop",',
    '                    "applications:org.kde.konsole.desktop",',
)


def patch_armada_pins(path: Path) -> tuple[str, bool]:
    text = path.read_text(encoding="utf-8")
    marker_count = text.count(JS_MARKER)
    target_count = text.count(JS_TARGET)
    if marker_count:
        if marker_count != 1 or target_count:
            raise ValueError(f"{path}: inconsistent Bazaar pin marker")
        return text, False

    if target_count != 1 or any(text.count(anchor) != 1 for anchor in JS_ANCHORS):
        raise ValueError(f"{path}: unexpected Armada taskbar pin list")
    return text.replace(JS_TARGET, f"                    {JS_MARKER}\n", 1), True


def patch_kicker_favorites(path: Path) -> tuple[str, bool]:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    marker_count = sum(KICKER_MARKER in line for line in lines)
    prepend_indexes = [i for i, line in enumerate(lines) if line.startswith("Prepend=")]
    if len(prepend_indexes) != 1 or sum(line.strip() == "[General]" for line in lines) != 1:
        raise ValueError(f"{path}: unexpected KRunner favorites config")

    index = prepend_indexes[0]
    value = lines[index].removeprefix("Prepend=").rstrip("\r\n")
    entries = value.split(";")
    target_count = entries.count(BAZAAR_ID)
    if marker_count:
        if marker_count != 1 or target_count:
            raise ValueError(f"{path}: inconsistent Bazaar favorites marker")
        return text, False
    if target_count != 1:
        raise ValueError(f"{path}: expected one Bazaar favorite, found {target_count}")

    newline = "\r\n" if lines[index].endswith("\r\n") else "\n"
    trailing_separator = value.endswith(";")
    entries = [entry for entry in entries if entry != BAZAAR_ID]
    new_value = ";".join(entries)
    if trailing_separator and not new_value.endswith(";"):
        new_value += ";"
    lines[index] = f"Prepend={new_value}{newline}"
    lines.insert(index, f"{KICKER_MARKER}{newline}")
    return "".join(lines), True


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: patch-armada-remove-bazaar-pin.py <armada-pins.js> <kicker-extra-favoritesrc>",
            file=sys.stderr,
        )
        return 2

    js_path, kicker_path = map(Path, argv[1:])
    try:
        js_text, js_changed = patch_armada_pins(js_path)
        kicker_text, kicker_changed = patch_kicker_favorites(kicker_path)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    if js_changed:
        js_path.write_text(js_text, encoding="utf-8")
    if kicker_changed:
        kicker_path.write_text(kicker_text, encoding="utf-8")

    if js_changed or kicker_changed:
        print("Armada Plasma taskbar Bazaar pin removed")
    else:
        print("Armada Plasma taskbar Bazaar pin already removed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
