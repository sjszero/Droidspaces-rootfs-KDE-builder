#!/usr/bin/env python3
"""Let the selected container account update Armada's Steam startup splash."""
import argparse
from pathlib import Path
import re
import shlex


def configure(user, root=Path('/')):
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]{0,31}', user):
        raise ValueError('invalid build username')
    root = Path(root)
    progress = root / 'usr/libexec/armada/armada-splash-progress'
    text = progress.read_text()
    patterns = [
        (r'(?m)^(    install -d -m 0755 -o )[^ ]+( -g )[^ ]+( .*dirname .*STATUS.*)$',
         lambda m: m[1] + user + m[2] + user + m[3]),
        (r'(?m)^(    id -u )[^ ]+( >/dev/null.*)$',
         lambda m: m[1] + user + m[2]),
        (r'(?m)^(    exec setpriv --reuid )[^ ]+( --regid )[^ ]+( --init-groups .*)$',
         lambda m: m[1] + user + m[2] + user + m[3]),
    ]
    for pattern, replacement in patterns:
        text, count = re.subn(pattern, replacement, text)
        if count != 1:
            raise RuntimeError('unrecognized armada-splash-progress account declarations')

    vendor = root / 'usr/lib/tmpfiles.d/armada-run.conf'
    lines = vendor.read_text().splitlines(keepends=True)
    count = 0
    for i, line in enumerate(lines):
        if line.lstrip().startswith('#') or not line.strip():
            continue
        fields = shlex.split(line)
        if len(fields) >= 2 and fields[1] == '/run/armada/splash':
            if fields[0] != 'd' or len(fields) < 6:
                raise RuntimeError('unrecognized Armada splash tmpfiles rule')
            # Preserve all other rules, especially root-owned /run/armada.
            fields[3:5] = [user, user]
            lines[i] = ' '.join(fields) + '\n'
            count += 1
    if count != 1:
        raise RuntimeError('missing or ambiguous Armada splash tmpfiles rule')

    override = root / 'etc/tmpfiles.d/armada-run.conf'
    override.parent.mkdir(parents=True, exist_ok=True)
    # The same filename overrides the vendor rules instead of duplicating them.
    override.write_text(''.join(lines))
    progress.write_text(text)
    print(f'armada: splash status writer configured for {user}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('user')
    parser.add_argument('--root', type=Path, default=Path('/'))
    args = parser.parse_args()
    configure(args.user, args.root)
