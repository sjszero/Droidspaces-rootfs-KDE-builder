#!/usr/bin/python3
"""Replace the FEX plumbing ArmadaOS ships with box64 equivalents.

Applied inside the image build (root of the image), idempotent so a rebuild from
an already-patched base image is a no-op:

  /usr/share/armada/box64-profiles.json                       (profile contract)
  /usr/share/decky-plugins/armada-control/py_modules/.../tweaks.py
  /usr/share/decky-plugins/armada-control/py_modules/.../config.py
  /usr/share/decky-plugins/armada-control/dist/index.js
  /usr/libexec/armada/armada-game-launch
  /usr/share/armada/game-tweaks.json

Why box64 rcfiles and not environment variables: box64 resolves settings from
~/.box64rc and /etc/box64.box64rc before the environment, so a per-game profile
has to be a generated rcfile (BOX64_RCFILE) with the [*] section overlaid.

ARMADA_PLUGIN_DIR selects the plugin tree: the image build patches the packaged
copy, while an already booted container also carries a seeded copy under
~/homebrew/plugins that Decky actually loads.
"""

import json
import os
import pathlib
import re
import sys

PLUGIN = pathlib.Path(os.environ.get('ARMADA_PLUGIN_DIR',
                                     '/usr/share/decky-plugins/armada-control'))
TWEAKS = PLUGIN / 'py_modules/armada_control/tweaks.py'
CONFIG = PLUGIN / 'py_modules/armada_control/config.py'
DIST = PLUGIN / 'dist/index.js'
LAUNCH = pathlib.Path('/usr/libexec/armada/armada-game-launch')
DEFAULTS = pathlib.Path('/usr/share/armada/game-tweaks.json')
PROFILES = pathlib.Path('/usr/share/armada/box64-profiles.json')

NL_ESCAPE = chr(92) + 'n'

PROFILE_CONTRACT = {
    'profiles': {
        'default': {
            'label': 'Default',
            'config': {
                'BOX64_DYNAREC_STRONGMEM': '1',
                'BOX64_DYNAREC_SAFEFLAGS': '0',
            },
        },
        'fast': {
            'label': 'Fast',
            'config': {
                'BOX64_DYNAREC_STRONGMEM': '0',
                'BOX64_DYNAREC_SAFEFLAGS': '0',
            },
        },
        'compatible': {
            'label': 'Compatible',
            'config': {
                'BOX64_DYNAREC_STRONGMEM': '2',
                'BOX64_DYNAREC_SAFEFLAGS': '2',
                'BOX64_DYNAREC_FASTNAN': '0',
                'BOX64_DYNAREC_FASTROUND': '0',
            },
        },
    }
}

NEW_APPLY = '''def resolve_box64_config(settings, profiles):
    profile_id = settings.get("box64Profile")
    if isinstance(profile_id, str) and profile_id in profiles:
        return profiles[profile_id]["config"]
    explicit = settings.get("box64Config")
    if isinstance(explicit, dict):
        return explicit
    # tweaks written before the FEX removal carry the old key names
    legacy_id = settings.get("fexProfile")
    if isinstance(legacy_id, str) and legacy_id in profiles:
        return profiles[legacy_id]["config"]
    legacy_config = settings.get("fexConfig")
    if isinstance(legacy_config, dict):
        return legacy_config
    return profiles["default"]["config"]


def rcfile_with_overrides(overrides):
    lines = BASE_BOX64_RCFILE.read_text(encoding="utf-8").splitlines()
    out, seen, in_global = [], set(), False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_global:
                for key, value in overrides.items():
                    if key not in seen:
                        out.append(f"{key}={value}")
                        seen.add(key)
            in_global = stripped == RC_GLOBAL_SECTION
            out.append(line)
            continue
        match = RC_KEY.match(line)
        if in_global and match and match.group(1) in overrides:
            out.append(f"{match.group(1)}={overrides[match.group(1)]}")
            seen.add(match.group(1))
            continue
        out.append(line)
    if in_global:
        for key, value in overrides.items():
            if key not in seen:
                out.append(f"{key}={value}")
    return "@@NL@@".join(out) + "@@NL@@"


def apply_box64(settings, game_id, profiles, env):
    box64_config = resolve_box64_config(settings, profiles)
    overrides = {
        str(key): str(value) for key, value in box64_config.items()
        if re.fullmatch(r"BOX64_[A-Z0-9_]+", str(key)) and value is not None
    }
    if not overrides:
        return
    rcfile_dir = cache_dir("armada-box64")
    rcfile_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    cutoff = time.time() - 86400
    for old in rcfile_dir.glob("*.box64rc"):
        try:
            if old.stat().st_mtime < cutoff:
                old.unlink()
        except OSError:
            pass
    name = f"{game_id or 'global'}.{os.getpid()}.box64rc"
    target = rcfile_dir / name
    tmp = target.with_name(f".{name}.tmp")
    try:
        with tmp.open("w", encoding="utf-8") as f:
            f.write(rcfile_with_overrides(overrides))
        os.chmod(tmp, 0o600)
        os.replace(tmp, target)
        env["BOX64_RCFILE"] = str(target)
    finally:
        tmp.unlink(missing_ok=True)


def inject_x86_protocol_libs():'''.replace('@@NL@@', NL_ESCAPE)

NEW_FUNCS = '''def load_box64_contract():
    with BOX64_PROFILES_CONFIG.open(encoding="utf-8") as f:
        contract = json.load(f)
    profiles = contract.get("profiles")
    if not isinstance(profiles, dict) or "default" not in profiles:
        raise ValueError("invalid box64 profile contract")
    for profile in profiles.values():
        if not isinstance(profile, dict) or not isinstance(profile.get("config"), dict):
            raise ValueError("invalid box64 profile contract")
    return contract


def cache_dir(name):'''


def edit(path, pairs, failures):
    text = path.read_text(encoding='utf-8')
    for label, old, new, expected in pairs:
        found = text.count(old)
        if found != expected:
            failures.append(f'{path.name}: {label}: expected {expected}, found {found}')
            continue
        text = text.replace(old, new)
        print(f'ok  {path.name}: {label}')
    path.write_text(text, encoding='utf-8')


def port_tweaks(failures):
    edit(TWEAKS, [
        (
            'constants',
            'FEX_PROFILES_CONFIG = Path("/usr/share/armada/fex-profiles.json")\n'
            'PLUGIN_FEX_PROFILES_CONFIG = Path(__file__).resolve().parent.parent / "fex-profiles.json"\n',
            'BOX64_PROFILES_CONFIG = Path("/usr/share/armada/box64-profiles.json")\n'
            'PLUGIN_BOX64_PROFILES_CONFIG = Path(__file__).resolve().parent.parent / "box64-profiles.json"\n',
            1,
        ),
        (
            'loader',
            'def load_fex_contract():\n'
            '    path = FEX_PROFILES_CONFIG if FEX_PROFILES_CONFIG.exists() else PLUGIN_FEX_PROFILES_CONFIG\n'
            '    with path.open(encoding="utf-8") as f:\n'
            '        contract = json.load(f)\n'
            '    profiles = contract.get("profiles")\n'
            '    if not isinstance(profiles, dict) or "default" not in profiles:\n'
            '        raise ValueError("invalid FEX profile contract")\n'
            '    for profile in profiles.values():\n'
            '        if not isinstance(profile, dict) or not isinstance(profile.get("config"), dict):\n'
            '            raise ValueError("invalid FEX profile contract")\n'
            '    return contract\n'
            '\n'
            '\n'
            'def fex_profile_labels(contract):\n',
            'def load_box64_contract():\n'
            '    path = BOX64_PROFILES_CONFIG if BOX64_PROFILES_CONFIG.exists() \\\n'
            '        else PLUGIN_BOX64_PROFILES_CONFIG\n'
            '    with path.open(encoding="utf-8") as f:\n'
            '        contract = json.load(f)\n'
            '    profiles = contract.get("profiles")\n'
            '    if not isinstance(profiles, dict) or "default" not in profiles:\n'
            '        raise ValueError("invalid box64 profile contract")\n'
            '    for profile in profiles.values():\n'
            '        if not isinstance(profile, dict) or not isinstance(profile.get("config"), dict):\n'
            '            raise ValueError("invalid box64 profile contract")\n'
            '    return contract\n'
            '\n'
            '\n'
            'def box64_profile_labels(contract):\n',
            1,
        ),
        (
            'legacy aliases',
            'def turnip_drivers():\n',
            '# The plugin keeps the old names working for a frontend that still asks for\n'
            '# them; both sides now describe box64 instead of FEX.\n'
            'load_fex_contract = load_box64_contract\n'
            'fex_profile_labels = box64_profile_labels\n'
            '\n'
            '\n'
            'def turnip_drivers():\n',
            1,
        ),
    ], failures)


def port_config(failures):
    edit(CONFIG, [
        (
            'imports',
            'from .tweaks import (\n'
            '    fex_profile_labels,\n'
            '    load_env_presets,\n'
            '    load_fex_contract,\n'
            '    load_tweaks,\n'
            '    turnip_drivers,\n'
            ')\n',
            'from .tweaks import (\n'
            '    box64_profile_labels,\n'
            '    load_box64_contract,\n'
            '    load_env_presets,\n'
            '    load_tweaks,\n'
            '    turnip_drivers,\n'
            ')\n',
            1,
        ),
        (
            'contract load',
            '    fex_contract = load_fex_contract()\n',
            '    box64_contract = load_box64_contract()\n',
            1,
        ),
        (
            'profiles key',
            '        "fexProfiles": fex_profile_labels(fex_contract),\n',
            '        "box64Profiles": box64_profile_labels(box64_contract),\n'
            '        # kept for a cached frontend that still reads the old key\n'
            '        "fexProfiles": box64_profile_labels(box64_contract),\n',
            1,
        ),
    ], failures)


OLD_KNOBS = '''const fexKnobs = [
    { key: "TSOEnabled", label: "TSO Enabled" },
    { key: "X87ReducedPrecision", label: "X87 Reduced Precision" },
    { key: "Multiblock", label: "Multiblock" },
    { key: "VectorTSOEnabled", label: "Vector TSO Enabled" },
    { key: "MemcpySetTSOEnabled", label: "Memcpy Set TSO Enabled" },
    { key: "HalfBarrierTSOEnabled", label: "Half Barrier TSO Enabled" },
];'''

NEW_KNOBS = '''const box64Knobs = [
    { key: "BOX64_DYNAREC_BIGBLOCK", label: "Big Block" },
    { key: "BOX64_DYNAREC_SAFEFLAGS", label: "Safe Flags" },
    { key: "BOX64_DYNAREC_FASTNAN", label: "Fast NaN" },
    { key: "BOX64_DYNAREC_FASTROUND", label: "Fast Round" },
    { key: "BOX64_DYNAREC_X87DOUBLE", label: "x87 Double Precision" },
];'''


def port_dist(failures):
    text = DIST.read_text(encoding='utf-8')
    if text.count(OLD_KNOBS) != 1:
        failures.append(f'dist knobs: found {text.count(OLD_KNOBS)}')
    else:
        text = text.replace(OLD_KNOBS, NEW_KNOBS)
        print('ok  dist: knobs')
    for old, new, expected in (
        ('fexProfiles', 'box64Profiles', 1),
        ('fexProfile', 'box64Profile', 4),
        ('fexConfig', 'box64Config', 9),
        ('fexKnobs', 'box64Knobs', 1),
    ):
        found = text.count(old)
        if found != expected:
            failures.append(f'dist {old}: expected {expected}, found {found}')
            continue
        text = text.replace(old, new)
        print(f'ok  dist: {old} -> {new}')

    def relabel(match):
        value = match.group(1)
        if re.search(r'[\u4e00-\u9fff]', value):
            return '"compatibility.fexPreset": "box64 预设"'
        return '"compatibility.fexPreset": "' + value.replace('FEX', 'box64') + '"'

    text, count = re.subn(r'"compatibility\.fexPreset"\s*:\s*"([^"]*)"', relabel, text)
    print(f'ok  dist: relabelled {count} preset label(s)')
    text, count = re.subn(r'\bFEX\b', 'box64', text)
    print(f'ok  dist: remaining FEX tokens -> box64 ({count})')
    DIST.write_text(text, encoding='utf-8')


OLD_HEADER = '''# Game launch-option prefix wrapper ("armada-game-launch %command%"). Applies
# per-game settings via FEX_APP_CONFIG, the only knob every compat tool's FEX reads
# (the on-disk FEX config files are seen only by the system FEX, not arm64ec/wow64).'''
NEW_HEADER = '''# Game launch-option prefix wrapper ("armada-game-launch %command%"). Applies
# per-game settings through BOX64_RCFILE, a generated copy of /etc/box64.box64rc with
# the selected box64 profile overlaid: rcfiles outrank environment variables in box64,
# so exporting BOX64_DYNAREC_* alone would be ignored by the system rcfile.'''
OLD_CONST = '''BASE_FEX_CONFIG = pathlib.Path("/usr/share/fex-emu/Config.json")
FEX_PROFILES_CONFIG = pathlib.Path("/usr/share/armada/fex-profiles.json")'''
NEW_CONST = '''BASE_BOX64_RCFILE = pathlib.Path("/etc/box64.box64rc")
BOX64_PROFILES_CONFIG = pathlib.Path("/usr/share/armada/box64-profiles.json")
# box64 reads rcfiles before the environment and applies the last matching key, so a
# generated file with an overlaid [*] section is the only reliable per-game override.
RC_GLOBAL_SECTION = "[*]"
RC_KEY = re.compile(r"^\\s*([A-Za-z0-9_]+)\\s*=")'''
OLD_THUNKS = '''VK_DRIVER_ENV = ("VK_DRIVER_FILES", "VK_ICD_FILENAMES")
# Never enabled by a generated FEX config regardless of what the base or user
# settings say, and always written as an explicit 0; see thunk_settings.
UNSUPPORTED_THUNKS = frozenset(("asound", "WaylandClient"))'''
NEW_THUNKS = '''VK_DRIVER_ENV = ("VK_DRIVER_FILES", "VK_ICD_FILENAMES")'''
OLD_CALL = '''        contract = load_fex_contract()
        settings = armada_game_tweaks.merged_settings(
            armada_game_tweaks.load(), game_id)
        apply_fex(settings, game_id, contract["profiles"], os.environ)'''
NEW_CALL = '''        contract = load_box64_contract()
        settings = armada_game_tweaks.merged_settings(
            armada_game_tweaks.load(), game_id)
        apply_box64(settings, game_id, contract["profiles"], os.environ)'''


def port_launcher(failures):
    text = LAUNCH.read_text(encoding='utf-8')
    if 'def apply_box64(' in text:
        print('ok  launcher: already ported, skipped')
        return
    for label, old, new in (
        ('header', OLD_HEADER, NEW_HEADER),
        ('constants', OLD_CONST, NEW_CONST),
        ('thunk constants', OLD_THUNKS, NEW_THUNKS),
        ('main call', OLD_CALL, NEW_CALL),
    ):
        if text.count(old) != 1:
            failures.append(f'launcher {label}: found {text.count(old)}')
        else:
            text = text.replace(old, new)
            print(f'ok  launcher: {label}')

    text, count = re.subn(r'def load_fex_contract\(\):.*?def cache_dir\(name\):',
                          lambda _m: NEW_FUNCS, text, flags=re.S)
    if count != 1:
        failures.append(f'launcher functions: substituted {count}')
    else:
        print('ok  launcher: contract/thunk functions replaced')

    # A lambda replacement keeps re from interpreting the backslash escapes in
    # NEW_APPLY: passing it as a template would turn "\n".join(...) into a real
    # newline and break the function body.
    text, count = re.subn(r'def resolve_fex_config\(settings, profiles\):.*?def inject_x86_protocol_libs\(\):',
                          lambda _m: NEW_APPLY, text, flags=re.S)
    if count != 1:
        failures.append(f'launcher apply: substituted {count}')
    else:
        print('ok  launcher: apply_fex -> apply_box64')

    if 'import re\n' not in text:
        text = text.replace('import pathlib\n', 'import pathlib\nimport re\n', 1)
        print('ok  launcher: import re')

    LAUNCH.write_text(text, encoding='utf-8')
    compile(LAUNCH.read_text(encoding='utf-8'), str(LAUNCH), 'exec')
    print('ok  launcher: compiles')


def port_defaults():
    data = json.loads(DEFAULTS.read_text(encoding='utf-8'))
    glob = data.get('global', {})
    if 'fexProfile' in glob:
        glob['box64Profile'] = glob.pop('fexProfile')
    glob.pop('thunks', None)
    glob.setdefault('box64Profile', 'default')
    DEFAULTS.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    print(f'ok  {DEFAULTS.name}: box64Profile default, thunks dropped')


def main():
    if not PLUGIN.is_dir():
        print('port-fex-to-box64: decky plugin missing; nothing to port')
        return 0
    if CONFIG.exists() and 'box64Profiles' in CONFIG.read_text(encoding='utf-8'):
        print('port-fex-to-box64: already ported, nothing to do')
        return 0
    if not LAUNCH.exists():
        print('port-fex-to-box64: armada-game-launch missing', file=sys.stderr)
        return 1
    failures = []
    PROFILES.write_text(json.dumps(PROFILE_CONTRACT, indent=2) + '\n', encoding='utf-8')
    print(f'ok  {PROFILES} written')
    port_tweaks(failures)
    port_config(failures)
    port_dist(failures)
    port_launcher(failures)
    port_defaults()
    if failures:
        print('port-fex-to-box64 FAILED:', file=sys.stderr)
        for item in failures:
            print(' -', item, file=sys.stderr)
        return 1
    print('port-fex-to-box64: FEX plumbing replaced with box64')
    return 0


if __name__ == '__main__':
    sys.exit(main())