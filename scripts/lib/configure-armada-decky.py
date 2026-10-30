#!/usr/bin/env python3
'''Configure bundled Decky for the Droidspaces build account.'''
import argparse
import json
from pathlib import Path
import re
import shutil
import struct
import tempfile
import time
from urllib.parse import quote
from urllib.request import Request, urlopen


def is_arm64(path):
    try:
        with path.open('rb') as stream:
            header = stream.read(20)
        return (header[:4] == b'\x7fELF' and header[4:6] == b'\x02\x01'
                and len(header) == 20 and struct.unpack('<H', header[18:20])[0] == 183)
    except OSError:
        return False


def fetch(url, destination):
    for attempt in range(3):
        try:
            request = Request(url, headers={'User-Agent': 'Droidspaces-ArmadaOS-builder'})
            with urlopen(request, timeout=60) as response, destination.open('wb') as output:
                shutil.copyfileobj(response, output)
            return
        except OSError:
            if attempt == 2:
                raise
            time.sleep(1)


def configure(user, root=Path('/'), download=fetch):
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]{0,31}', user):
        raise ValueError('invalid build username')
    user_home = f'/home/{user}'
    loader_dir = root / 'usr/share/decky-loader'
    loader = loader_dir / 'PluginLoader'
    version_path = loader_dir / '.loader.version'
    if not is_arm64(loader):
        tag = version_path.read_text().strip()
        if not tag:
            raise RuntimeError('bundled Decky version is missing')
        # Match the image-bundled version rather than silently upgrading it.
        with tempfile.TemporaryDirectory(prefix='decky-arm64-', dir=loader_dir) as temporary:
            temporary = Path(temporary)
            metadata = temporary / 'release.json'
            download('https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases/tags/'
                     + quote(tag, safe=''), metadata)
            assets = json.loads(metadata.read_text())['assets']
            matches = [asset for asset in assets if asset['name'] == 'PluginLoader-arm64']
            if len(matches) != 1:
                raise RuntimeError(f'Decky {tag} has no unique PluginLoader-arm64 asset')
            candidate = temporary / 'PluginLoader'
            download(matches[0]['browser_download_url'], candidate)
            if not is_arm64(candidate):
                raise RuntimeError('downloaded Decky loader is not ARM64 ELF')
            candidate.chmod(0o755)
            candidate.replace(loader)
    loader.chmod(0o755)

    sync = root / 'usr/lib/decky-loader/armada-decky-sync'
    text = sync.read_text()
    text, users = re.subn(r'(?m)^user_name=.*$', f'user_name={user}', text)
    text, homes = re.subn(r'(?m)^homebrew=.*$', 'homebrew="/home/${user_name}/homebrew"', text)
    if users != 1 or homes != 1:
        raise RuntimeError('unrecognized armada-decky-sync account/path declarations')
    sync.write_text(text)

    dropin = root / 'etc/systemd/system/plugin_loader.service.d/zz-armada-container.conf'
    dropin.parent.mkdir(parents=True, exist_ok=True)
    dropin.write_text(f'''[Unit]
After=armada-decky-sync.service
Requires=armada-decky-sync.service
[Service]
ExecStart=
ExecStart={user_home}/homebrew/services/PluginLoader
WorkingDirectory={user_home}/homebrew/services
Environment=UNPRIVILEGED_PATH={user_home}/homebrew
Environment=PRIVILEGED_PATH={user_home}/homebrew
Environment=DECKY_USER={user}
Environment=DECKY_USER_HOME={user_home}
Environment=ARMADA_SESSION_USER={user}
''')
    print(f'armada: native ARM64 Decky configured for {user_home}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('user')
    parser.add_argument('--root', type=Path, default=Path('/'))
    args = parser.parse_args()
    configure(args.user, args.root)
