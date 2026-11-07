#!/usr/bin/python3
"""Seed /etc/armada/game-tweaks.json with the container's default env overrides.

Armada merges two files, and they are not the same thing:

  * /usr/share/armada/game-tweaks.json is the factory default set shipped by
    the base image. It has no "env" block at all.
  * /etc/armada/game-tweaks.json is the user override layer. Armada's
    armada_game_tweaks.py does a shallow `data["global"].update(overrides)`
    on top of the defaults, so anything listed here wins outright.

On real Qualcomm hardware the KGSL driver is picked automatically. Inside a
Droidspaces container the render node is exposed through the Android display
stack and Mesa otherwise probes for a DRM device that is not there, so games
launched through Armada's tweak wrapper need the loader pinned explicitly.
That is the one value this script seeds.

The script is idempotent and additive on purpose:

  * an existing override file keeps every key it already has, including any
    "env" entries the user set by hand -- only MESA_LOADER_DRIVER_OVERRIDE is
    added when it is absent;
  * a key that is already present with a different value is left untouched and
    reported, because the user may have deliberately chosen zink or another
    driver;
  * a corrupt/unparsable override file is never overwritten silently: the
    script fails loudly so the build stops instead of discarding user state.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

# ARMADA_GAME_TWEAKS_OVERRIDES exists so the image build (and the test suite)
# can point the script at a staging copy. Production always uses the default.
OVERRIDES = Path(
    os.environ.get("ARMADA_GAME_TWEAKS_OVERRIDES", "/etc/armada/game-tweaks.json")
)
KEY = "MESA_LOADER_DRIVER_OVERRIDE"
VALUE = "kgsl"


def die(message: str) -> "NoReturn":
    print(f"configure-armada-game-tweaks-env: {message}", file=sys.stderr)
    raise SystemExit(1)


def load(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        die(f"cannot read {path}: {exc}")
    if not text.strip():
        return {}
    try:
        data = json.loads(text)
    except ValueError as exc:
        die(f"{path} is not valid JSON ({exc}); refusing to overwrite it")
    if not isinstance(data, dict):
        die(f"{path} does not contain a JSON object; refusing to overwrite it")
    return data


def main() -> int:
    data = load(OVERRIDES)

    glob = data.get("global")
    if glob is None:
        glob = {}
        data["global"] = glob
    elif not isinstance(glob, dict):
        die(f'{OVERRIDES}: "global" is not an object')

    env = glob.get("env")
    if env is None:
        env = {}
        glob["env"] = env
    elif not isinstance(env, dict):
        die(f'{OVERRIDES}: "global.env" is not an object')

    if env.get(KEY) == VALUE:
        print(f"{OVERRIDES}: {KEY}={VALUE} already set, nothing to do")
        return 0

    if KEY in env:
        # Keep the operator's choice; the build must not silently override it.
        print(
            f"{OVERRIDES}: {KEY}={env[KEY]!r} already present, "
            f"keeping it instead of {VALUE!r}"
        )
        return 0

    env[KEY] = VALUE
    glob["env"] = dict(sorted(env.items()))

    OVERRIDES.parent.mkdir(parents=True, exist_ok=True)
    tmp = OVERRIDES.with_suffix(OVERRIDES.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, OVERRIDES)
    os.chmod(OVERRIDES, 0o644)
    print(f"{OVERRIDES}: added {KEY}={VALUE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())