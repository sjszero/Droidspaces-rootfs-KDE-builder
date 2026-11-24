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
FEX is no longer deleted: /usr/share/armada/fex-profiles.json stays, apply_fex()
is kept next to apply_box64(), and armada-game-launch selects the FEX layer only
when ARMADA_X86_TOOL=fex is exported. No FEX Steam compatibility tool is shipped,
so every game Steam launches keeps box64. The FEX side of the image is built by
scripts/armada/fex and is what runs the 32-bit Steam client itself.
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
FEX_PROFILES = pathlib.Path('/usr/share/armada/fex-profiles.json')

NL_ESCAPE = chr(92) + 'n'

PROFILE_CONTRACT = {
    'profiles': {
        'default': {
            'label': 'Default',
            'config': {
                'BOX64_DYNAREC_STRONGMEM': '1',
                'BOX64_DYNAREC_SAFEFLAGS': '0',
                # Not a box64 knob: FEX's shared code buffer. Default on for every
                # profile, because it is what keeps the JIT alive long enough for
                # the crash-prone titles (Slay the Spire 2 under Proton's FEX).
                # Deliberately not a box64_dynarec key: apply_box64 exports keys
                # that are not BOX64_* as FEX_* environment variables.
                'EnableCodeCachingWIP': '1',
            },
        },
        'fast': {
            'label': 'Fast',
            'config': {
                # Everything turned towards speed: bigger dynarec blocks, box64's
                # fast-but-not-IEEE NaN/rounding, no x87 double precision, weak
                # memory ordering.
                'BOX64_DYNAREC_BIGBLOCK': '3',
                'BOX64_DYNAREC_STRONGMEM': '0',
                'BOX64_DYNAREC_SAFEFLAGS': '0',
                'BOX64_DYNAREC_FASTNAN': '1',
                'BOX64_DYNAREC_FASTROUND': '1',
                'BOX64_DYNAREC_X87DOUBLE': '0',
                'EnableCodeCachingWIP': '1',
            },
        },
        'compatible': {
            'label': 'Compatible',
            'config': {
                # The opposite end: strong memory ordering, full flag checks,
                # IEEE-correct NaN and rounding, exact x87 doubles, one block at a
                # time. Slow, and the setting that gets a stubborn game started.
                'BOX64_DYNAREC_BIGBLOCK': '0',
                'BOX64_DYNAREC_STRONGMEM': '2',
                'BOX64_DYNAREC_SAFEFLAGS': '2',
                'BOX64_DYNAREC_FASTNAN': '0',
                'BOX64_DYNAREC_FASTROUND': '0',
                'BOX64_DYNAREC_X87DOUBLE': '1',
                'EnableCodeCachingWIP': '1',
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
    # Keys that are not BOX64_* belong to FEX and share the same profile entry
    # (EnableCodeCachingWIP). They are exported as FEX_* environment variables
    # because the arm64ec/wow64 FEX inside Proton reads exactly those, which is
    # how the setting also reaches a Windows game such as Slay the Spire 2.
    # This runs before the early return below on purpose: the FEX part has to
    # apply even when the profile carries no box64 keys at all.
    for key, value in box64_config.items():
        name = str(key)
        if value is None or re.fullmatch(r"BOX64_[A-Z0-9_]+", name):
            continue
        if name.startswith("FEX_"):
            name = name[4:]
        env["FEX_" + name.upper()] = str(value)
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


FEX_PROFILE_CONTRACT = {
    'profiles': {
        'default': {
            'label': 'Default',
            # 0, not 1: measured on this build, the WIP code cache makes FEX die
            # with SIGILL (rc 132) right after the cache is generated, while the
            # same command works with it off. The knob stays on in the box64
            # profiles because that path exports it to Proton's own arm64ec/wow64
            # FEX -- a different build, and there it is what softens the Slay the
            # Spire 2 crash window.
            'config': {'EnableCodeCachingWIP': '0'},
        },
        # TSO off is the cheap side of the trade: FEX stops modelling x86 memory
        # ordering, which is faster and wrong for anything that actually relies on
        # it. Kept as a preset instead of the default for that reason.
        'fast': {
            'label': 'Fast',
            'config': {
                # Speed at any cost: no x86 memory-ordering model at all, multi-block
                # translation on, reduced-precision x87.
                'TSOEnabled': '0',
                'VectorTSOEnabled': '0',
                'HalfBarrierTSOEnabled': '0',
                'MemcpySetTSOEnabled': '0',
                'Multiblock': '1',
                'X87ReducedPrecision': '1',
                'EnableCodeCachingWIP': '0',
            },
        },
        'compatible': {
            'label': 'Compatible',
            'config': {
                # Compatibility first: full TSO modelling everywhere, one block at a
                # time, exact x87. This is the preset to try when a title crashes or
                # produces visibly wrong results.
                'TSOEnabled': '1',
                'VectorTSOEnabled': '1',
                'HalfBarrierTSOEnabled': '1',
                'MemcpySetTSOEnabled': '1',
                'Multiblock': '0',
                'X87ReducedPrecision': '0',
                'EnableCodeCachingWIP': '0',
            },
        },
    },
}

FEX_FUNCS = '''FEX_PROFILES_CONFIG = pathlib.Path("/usr/share/armada/fex-profiles.json")
FEX_APP_CONFIG_DIR = pathlib.Path.home() / ".cache" / "armada-fex"

def load_fex_contract():
    try:
        data = json.loads(FEX_PROFILES_CONFIG.read_text(encoding="utf-8"))
    except OSError:
        return {"profiles": {"default": {"label": "Default", "config": {}}}}
    if not isinstance(data.get("profiles"), dict) or not data["profiles"]:
        raise ValueError("invalid FEX profile contract")
    return data

def armada_x86_tool(game_id):
    # Which emulation layer this launch should use. No FEX Steam compatibility tool
    # is shipped any more, so the only way into the FEX layer is an explicit
    # ARMADA_X86_TOOL=fex; everything Steam launches gets box64. Printed because a
    # divergence between this choice and what the user expects is otherwise silent.
    forced = os.environ.get("ARMADA_X86_TOOL", "").strip().lower()
    tool = forced if forced in ("box64", "fex") else "box64"
    os.write(2, ("armada-game-launch: x86 layer = " + tool + "\n").encode())
    return tool
def resolve_fex_config(settings, profiles):
    profile_id = settings.get("fexProfile")
    config = dict((profiles.get(profile_id) or {}).get("config") or {})
    explicit = settings.get("fexConfig")
    if isinstance(explicit, dict):
        config.update({str(key): str(value) for key, value in explicit.items() if value is not None})
    return config

def apply_fex(settings, game_id, profiles, env):
    # FEX_APP_CONFIG is the one knob every compat tool's FEX reads, including the
    # arm64ec/wow64 builds inside Proton (they ignore /usr/share/fex-emu/Config.json).
    # Profile keys may be spelled FEX_ENABLECODECACHINGWIP (environment form) or
    # EnableCodeCachingWIP (Config.json form); both end up in the config file and
    # in the environment, so either FEX build picks it up.
    raw = resolve_fex_config(settings, profiles)
    config = {}
    for key, value in raw.items():
        name = str(key)
        if value is None or re.fullmatch(r"BOX64_[A-Z0-9_]+", name):
            continue
        if name.startswith("FEX_"):
            name = name[4:]
        config[name] = str(value)
        env["FEX_" + name.upper()] = str(value)
    if not config:
        return None
    FEX_APP_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    path = FEX_APP_CONFIG_DIR / ("%s.%d.json" % (game_id or "global", os.getpid()))
    path.write_text(json.dumps({"Config": config}, indent=2) + "\\n", encoding="utf-8")
    env["FEX_APP_CONFIG"] = str(path)
    return path
'''

def port_fex_parallel(failures):
    """Keep FEX usable as an opt-in layer next to box64.

    The box64 port replaced apply_fex() outright. Now that scripts/armada/fex
    ships a real FEX build again, the launcher has to be able to produce FEX
    settings too, and to choose between the two by looking at what the user
    selected in Steam.
    """
    text = LAUNCH.read_text(encoding='utf-8')
    if 'def apply_fex(' in text:
        print('ok  launcher: FEX layer already present, skipped')
        return
    if 'def apply_box64(' not in text:
        failures.append('launcher: box64 port missing; run the box64 steps first')
        return
    old_call = """        contract = load_box64_contract()
        settings = armada_game_tweaks.merged_settings(
            armada_game_tweaks.load(), game_id)
        apply_box64(settings, game_id, contract["profiles"], os.environ)"""
    new_call = """        settings = armada_game_tweaks.merged_settings(
            armada_game_tweaks.load(), game_id)
        if armada_x86_tool(game_id) == "fex":
            apply_fex(settings, game_id, load_fex_contract()["profiles"], os.environ)
        else:
            contract = load_box64_contract()
            apply_box64(settings, game_id, contract["profiles"], os.environ)"""
    if text.count(old_call) != 1:
        failures.append(f'launcher fex branch: found {text.count(old_call)}')
    else:
        text = text.replace(old_call, new_call)
        print('ok  launcher: apply_box64 call now honours the selected tool')
    if 'def resolve_box64_config(' not in text:
        failures.append('launcher: resolve_box64_config missing')
    else:
        text = text.replace('def resolve_box64_config(',
                            FEX_FUNCS + '\ndef resolve_box64_config(', 1)
        print('ok  launcher: FEX functions restored')
    LAUNCH.write_text(text, encoding='utf-8')
    try:
        compile(LAUNCH.read_text(encoding='utf-8'), str(LAUNCH), 'exec')
    except SyntaxError as exc:
        failures.append(f'launcher does not compile after FEX restore: {exc}')
        return
    print('ok  launcher: compiles')
    if not FEX_PROFILES.exists():
        FEX_PROFILES.write_text(json.dumps(FEX_PROFILE_CONTRACT, indent=2) + '\n',
                                encoding='utf-8')
        print(f'ok  {FEX_PROFILES} written')


LAUNCH_WIP_MARKER = 'env["FEX_" + name.upper()]'


def ensure_launcher_wip(failures):
    """An older ported launcher only knows box64 keys.

    Add the FEX_* export so the profile's EnableCodeCachingWIP also reaches the
    arm64ec/wow64 FEX inside Proton -- that is the path a Windows game such as
    Slay the Spire 2 actually runs through.
    """
    try:
        text = LAUNCH.read_text(encoding='utf-8')
    except OSError:
        return
    if LAUNCH_WIP_MARKER in text or 'def apply_box64(' not in text:
        return
    anchor = '    if not overrides:\n        return'
    if text.count(anchor) != 1:
        failures.append(f'launcher wip export: anchor found {text.count(anchor)}')
        return
    block = (
        '    # Keys that are not BOX64_* belong to FEX and share the same profile\n'
        '    # entry (EnableCodeCachingWIP); they reach the arm64ec/wow64 FEX inside\n'
        '    # Proton through the environment.\n'
        '    for key, value in box64_config.items():\n'
        '        name = str(key)\n'
        '        if value is None or re.fullmatch(r"BOX64_[A-Z0-9_]+", name):\n'
        '            continue\n'
        '        if name.startswith("FEX_"):\n'
        '            name = name[4:]\n'
        '        env["FEX_" + name.upper()] = str(value)\n'
    )
    text = text.replace(anchor, block + anchor, 1)
    try:
        compile(text, str(LAUNCH), 'exec')
    except SyntaxError as exc:
        failures.append(f'launcher wip export broke compile: {exc}')
        return
    LAUNCH.write_text(text, encoding='utf-8')
    print('ok  launcher: FEX_* profile keys exported as environment variables')


FEX_TWEAKS = '''# FEX profiles are a separate contract again: scripts/armada/fex ships a real FEX
# build and the panel offers it next to box64. The entry shape matches box64's so
# the frontend renders both rows the same way.
def load_fex_contract():
    path = FEX_PROFILES_CONFIG if FEX_PROFILES_CONFIG.exists() else PLUGIN_FEX_PROFILES_CONFIG
    with path.open(encoding="utf-8") as f:
        contract = json.load(f)
    profiles = contract.get("profiles")
    if not isinstance(profiles, dict) or "default" not in profiles:
        raise ValueError("invalid FEX profile contract")
    for profile in profiles.values():
        if not isinstance(profile, dict) or not isinstance(profile.get("config"), dict):
            raise ValueError("invalid FEX profile contract")
    return contract


def fex_profile_labels(contract):
    return {
        name: {"label": profile.get("label", name.title()), "config": profile.get("config", {})}
        for name, profile in contract["profiles"].items()
        if isinstance(profile, dict)
    }
'''

FEX_DIST_VARS = '''    const fexPresets = config.fexProfiles || {};
    const fexPresetEntries = Object.entries(fexPresets);
    const storedFexProfile = values.fexProfile;
    const storedFexConfig = values.fexConfig;
    const fexOwnConfig = (editingDefault ? tweaks.global.fexConfig : gameSettings.fexConfig) || {};
    const hasFexPreset = !!(storedFexProfile && fexPresets[storedFexProfile]);
    const fexIsCustom = storedFexProfile === "custom" || (!hasFexPreset && !!storedFexConfig);
    const fexProfileValue = fexIsCustom ? "custom" : hasFexPreset ? storedFexProfile : "default";
    const fexPresetDefaults = ((fexPresets[fexIsCustom ? "default" : fexProfileValue] || {}).config) || {};
    const fexProfileConfig = { ...fexPresetDefaults, ...(fexIsCustom ? (storedFexConfig || {}) : {}) };
    const fexProfileOptions = [...fexPresetEntries.map(([id, profile]) => ({ data: id, label: translateLabel(profile.label) })), { data: "custom", label: t("common.custom") }];
    const onSelectFexProfile = (id) => {
        if (id === "custom") {
            patchSettings({ fexProfile: "custom", fexConfig: { ...(storedFexConfig || fexPresetDefaults) } });
            return;
        }
        patchSettings({ fexProfile: id });
    };
    const setFexKnob = (key, on) => patchSettings({ fexProfile: "custom", fexConfig: { ...fexProfileConfig, [key]: on ? "1" : "0" } });'''

# The FEX row exactly like the plugin shipped it before the box64 port: preset
# select plus the knob list, the knobs only shown under the custom preset.
FEX_ROW = ('SP_JSX.jsx(SelectEdit, { label: "FEX 预设", value: fexProfileValue,'
           ' options: fexProfileOptions, onChange: onSelectFexProfile }), fexIsCustom'
           ' ? fexKnobs.map((knob) => (SP_JSX.jsx(ToggleRow, {'
           ' label: translateLabel(knob.label), value: fexProfileConfig[knob.key] === "1",'
           ' onChange: (value) => setFexKnob(knob.key, value) }, knob.key))) : null, ')


def port_fex_presets(failures):
    """Give the panel its FEX row back.

    The box64 port renamed every frontend key, so the FEX contract ended up
    pointing at box64 data and the preset row effectively disappeared (it showed
    box64 profiles under a FEX label). With a real FEX shipped again, restore a
    separate contract and a dedicated row: a preset select plus the
    EnableCodeCachingWIP toggle, which is the only FEX knob that matters here.
    """
    edit(TWEAKS, [
        (
            'fex constants',
            'PLUGIN_BOX64_PROFILES_CONFIG = Path(__file__).resolve().parent.parent'
            ' / "box64-profiles.json"',
            'PLUGIN_BOX64_PROFILES_CONFIG = Path(__file__).resolve().parent.parent'
            ' / "box64-profiles.json"\n'
            'FEX_PROFILES_CONFIG = Path("/usr/share/armada/fex-profiles.json")\n'
            'PLUGIN_FEX_PROFILES_CONFIG = Path(__file__).resolve().parent.parent'
            ' / "fex-profiles.json"',
            1,
        ),
        (
            'fex contract',
            '# The plugin keeps the old names working for a frontend that still asks for\n'
            '# them; both sides now describe box64 instead of FEX.\n'
            'load_fex_contract = load_box64_contract\n'
            'fex_profile_labels = box64_profile_labels\n',
            FEX_TWEAKS,
            1,
        ),
    ], failures)
    edit(CONFIG, [
        (
            'fex imports',
            'from .tweaks import (\n'
            '    box64_profile_labels,\n'
            '    load_box64_contract,\n',
            'from .tweaks import (\n'
            '    box64_profile_labels,\n'
            '    fex_profile_labels,\n'
            '    load_box64_contract,\n'
            '    load_fex_contract,\n',
            1,
        ),
        (
            'fex contract load',
            '    box64_contract = load_box64_contract()\n',
            '    box64_contract = load_box64_contract()\n'
            '    fex_contract = load_fex_contract()\n',
            1,
        ),
        (
            'fex profiles key',
            '        # kept for a cached frontend that still reads the old key\n'
            '        "fexProfiles": box64_profile_labels(box64_contract),\n',
            '        "fexProfiles": fex_profile_labels(fex_contract),\n',
            1,
        ),
    ], failures)
    try:
        text = DIST.read_text(encoding='utf-8')
    except OSError:
        return
    if 'fexIsCustom' in text and 'TSOEnabled' in text:
        print('ok  dist: FEX panel already restored, skipped')
        return
    # 1) The FEX knob list: the plugin's original six plus the code-cache knob.
    if 'const fexKnobs' in text:
        text = re.sub(r'const fexKnobs = \[.*?\];\n', FEX_KNOBS, text, count=1, flags=re.S)
        print('ok  dist: fexKnobs restored')
    else:
        text = text.replace('const box64Knobs = [', FEX_KNOBS + 'const box64Knobs = [', 1)
        print('ok  dist: fexKnobs added')
    # 2) box64's own custom list must not carry the FEX knob.
    text, count = re.subn(r'\n?\s*\{ key: "EnableCodeCachingWIP", label: "FEX: Code Cache WIP'
                          r' \(max buffer\)" \},', '', text, count=1)
    if count:
        print('ok  dist: stray knob removed from the box64 list')
    # 3) FEX preset variables and callbacks.
    if re.search(r'    const fexPresets = config\.fexProfiles', text):
        text, count = re.subn(r'    const fexPresets = config\.fexProfiles \|\| \{\};.*?'
                              r'const setFex(?:Wip|Knob) = [^\n]*\n',
                              FEX_DIST_VARS + '\n', text, count=1, flags=re.S)
        if count != 1:
            failures.append('dist fex vars: block not replaced')
        else:
            print('ok  dist: fex preset variables replaced')
    else:
        anchor = ('    const setKnob = (key, on) => patchSettings({ box64Profile: "custom",'
                  ' box64Config: { ...box64Config, [key]: on ? "1" : "0" } });\n')
        if anchor not in text:
            failures.append('dist fex vars: setKnob anchor missing')
        else:
            text = text.replace(anchor, anchor + FEX_DIST_VARS + '\n', 1)
            print('ok  dist: fex preset variables added')
    # 4) The row: preset select plus the knob list under the custom preset.
    replaced = False
    for pattern in (
        r'SP_JSX\.jsx\(SelectEdit, \{ label: "FEX · " \+ t\("compatibility\.fexPreset"\).*?'
        r'onChange: setFexWip \}\), ',
        r'SP_JSX\.jsx\(SelectEdit, \{ label: "FEX [^"]*", value: fexProfileValue.*?: null, ',
    ):
        text, count = re.subn(pattern, FEX_ROW, text, count=1, flags=re.S)
        if count == 1:
            replaced = True
            print('ok  dist: FEX row replaced')
            break
    if not replaced:
        box64_row = ('SP_JSX.jsx(SelectEdit, { label: t("compatibility.fexPreset"),'
                     ' value: fexValue, options: fexOptions, onChange: onSelectFex })')
        if box64_row in text:
            text = text.replace(box64_row, FEX_ROW + box64_row, 1)
            print('ok  dist: FEX row added ahead of the box64 row')
        else:
            failures.append('dist fex row: no anchor found')
    # 5) The box64 row gets a literal label: the port relabelled the shared i18n
    #    key to "box64 预设", which would read "FEX · box64 预设" next to the FEX row.
    text = text.replace('label: t("compatibility.fexPreset"), value: fexValue',
                        'label: "box64 预设", value: fexValue')
    DIST.write_text(text, encoding='utf-8')
    print('ok  dist: FEX panel restored')


def ensure_wip_defaults():
    """Make EnableCodeCachingWIP=1 the default everywhere, including for a
    container that was ported before the knob existed.

    Only keys that are absent get the default; an explicit value (the custom
    editor turning it off with 0) is left alone.
    """
    # Two different fallbacks on purpose: the box64 profiles feed Proton's own FEX
    # through the environment (the knob helps there), the FEX profiles feed this
    # build (the knob makes it SIGILL).
    for path, fallback in ((PROFILES, '1'), (FEX_PROFILES, '0')):
        try:
            data = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            continue
        profiles = data.get('profiles')
        if not isinstance(profiles, dict):
            continue
        changed = False
        for name, profile in profiles.items():
            config = profile.get('config') if isinstance(profile, dict) else None
            if not isinstance(config, dict):
                continue
            present = any(str(key).upper().endswith('ENABLECODECACHINGWIP')
                          for key in config)
            if not present:
                config['EnableCodeCachingWIP'] = fallback
                changed = True
            elif (fallback == '0' and name in ('default', 'fast', 'compatible')
                  and str(config.get('EnableCodeCachingWIP')) == '1'):
                # The shipped FEX profiles must not enable the WIP code cache: it
                # makes this build SIGILL. A profile the user creates may still
                # opt in.
                config['EnableCodeCachingWIP'] = '0'
                changed = True
        if changed:
            path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
            print(f'ok  {path.name}: EnableCodeCachingWIP={fallback} applied to profiles')
    # The panel knob belongs to fexKnobs, not to box64's list; port_fex_presets owns
    # the FEX row and adds it there.


def ensure_preset_defaults():
    """Keep the two built-in presets in step with the definitions in this script.

    fast/compatible are shipped presets, not user data, so they are refreshed: an
    image built before the presets were tuned gets the new values on the next run.
    `default` only receives missing keys and any profile the user created is left
    untouched.
    """
    for path, contract in ((PROFILES, PROFILE_CONTRACT),
                           (FEX_PROFILES, FEX_PROFILE_CONTRACT)):
        try:
            data = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            continue
        profiles = data.get('profiles')
        if not isinstance(profiles, dict):
            continue
        changed = False
        for name in ('fast', 'compatible'):
            wanted = (contract['profiles'].get(name) or {}).get('config')
            if not isinstance(wanted, dict):
                continue
            current = profiles.get(name)
            if not isinstance(current, dict):
                profiles[name] = {'label': name.title(), 'config': dict(wanted)}
                changed = True
                continue
            if current.get('config') != wanted:
                current['config'] = dict(wanted)
                changed = True
        if changed:
            path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
            print(f'ok  {path.name}: fast/compatible presets refreshed')


def edit(path, pairs, failures):
    text = path.read_text(encoding='utf-8')
    for label, old, new, expected in pairs:
        found = text.count(old)
        # Several anchors are a prefix of their own replacement (the FEX constants after
        # the box64 line, the fex_contract after the box64_contract call). A rerun then
        # still matches `old` and inserts a second copy: a container that ran this three
        # times had the constants six times over. A longer `new` already present means
        # the edit is done.
        if len(new) > len(old) and text.count(new) >= expected:
            print(f'ok  {path.name}: {label} (already applied)')
            continue
        if found != expected:
            # A rerun finds the replacement already in place and no anchor left.
            # That is the normal idempotent case, not a failure.
            if found == 0 and text.count(new) >= 1:
                print(f'ok  {path.name}: {label} (already applied)')
                continue
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

# FEX keeps its own knob list. EnableCodeCachingWIP is not a BOX64_* key; putting
# it in box64's list made the custom panel render it twice, once under each row.
FEX_KNOBS = '''const fexKnobs = [
    { key: "TSOEnabled", label: "TSO Enabled" },
    { key: "X87ReducedPrecision", label: "X87 Reduced Precision" },
    { key: "Multiblock", label: "Multiblock" },
    { key: "VectorTSOEnabled", label: "Vector TSO Enabled" },
    { key: "MemcpySetTSOEnabled", label: "Memcpy Set TSO Enabled" },
    { key: "HalfBarrierTSOEnabled", label: "Half Barrier TSO Enabled" },
    { key: "EnableCodeCachingWIP", label: "Code Cache WIP (max buffer)" },
];
'''


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


def post_port_steps(failures):
    """Edits whose anchors are written by the box64 port itself.

    They must run *after* port_tweaks/port_config/port_dist/port_launcher. On a
    freshly built image the plugin still carries the FEX names, so none of those
    anchors exist yet and the run failed with five "expected 1, found 0" errors;
    only a container that had been ported already happened to pass. Every path runs
    them, because a container ported by an older run still needs them too.
    """
    ensure_wip_defaults()
    ensure_preset_defaults()
    ensure_launcher_wip(failures)
    port_fex_presets(failures)


def main():
    if not PLUGIN.is_dir():
        print('port-fex-to-box64: decky plugin missing; nothing to port')
        return 0
    if CONFIG.exists() and 'box64Profiles' in CONFIG.read_text(encoding='utf-8'):
        launcher_text = LAUNCH.read_text(encoding='utf-8') if LAUNCH.exists() else ''
        if 'def apply_fex(' in launcher_text:
            print('port-fex-to-box64: already ported (box64 + FEX layer); refreshing presets')
            only_failures = []
            post_port_steps(only_failures)
            if only_failures:
                print('port-fex-to-box64 FAILED:', file=sys.stderr)
                for item in only_failures:
                    print(' -', item, file=sys.stderr)
                return 1
            return 0
        # The box64 side is done but the FEX layer is still missing: keep going so a
        # container that was ported before scripts/armada/fex existed picks it up.
        print('port-fex-to-box64: box64 port present, restoring the FEX layer')
        only_failures = []
        port_fex_parallel(only_failures)
        post_port_steps(only_failures)
        if only_failures:
            print('port-fex-to-box64 FAILED:', file=sys.stderr)
            for item in only_failures:
                print(' -', item, file=sys.stderr)
            return 1
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
    port_fex_parallel(failures)
    port_defaults()
    post_port_steps(failures)
    if failures:
        print('port-fex-to-box64 FAILED:', file=sys.stderr)
        for item in failures:
            print(' -', item, file=sys.stderr)
        return 1
    print('port-fex-to-box64: FEX plumbing replaced with box64')
    return 0


if __name__ == '__main__':
    sys.exit(main())