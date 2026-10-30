#!/usr/bin/env python3
"""Patch the vendor session for Anland startup and optional fullscreen mode."""
from pathlib import Path
import re
import sys

def patch_fullscreen_option(text, path):
    marker = '# Add socket and stats read\n'
    if 'GAMESCOPECMD+=" -f"' in text:
        return text
    injection = (
        'if [[ "${BACKEND:-}" == "anland" ]]; then\n'
        '\tGAMESCOPECMD+=" -f"\n'
        'fi\n'
    )
    count = text.count(marker)
    if count != 1:
        raise RuntimeError(f'{path}: expected one gamescope socket marker, found {count}')
    return text.replace(marker, injection + marker, 1)


def patch_startup_wait(text, path):
    if 'armada_wait_gamescope_startup' in text:
        return text
    pattern = r'(?m)^if read -r -t (?:5|15) response_x_display response_wl_display <>"\$socket"; then$'
    replacement = (
        'source /usr/libexec/armada/gamescope-startup-wait\n'
        'if armada_wait_gamescope_startup; then'
    )
    updated, count = re.subn(pattern, lambda match: replacement, text)
    if count != 1:
        raise RuntimeError(f'{path}: expected one vendor startup FIFO read, found {count}')
    return updated


def patch_session(path):
    text = path.read_text()
    updated = patch_fullscreen_option(text, path)
    updated = patch_startup_wait(updated, path)
    path.write_text(updated)



if __name__ == '__main__':
    patch_session(Path(sys.argv[1]))