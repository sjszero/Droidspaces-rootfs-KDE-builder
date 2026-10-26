#!/usr/bin/env python3
"""Install the Anland FIFO wait in the vendor session without replacing its lifecycle."""
from pathlib import Path
import re
import sys


def patch_session(path):
    text = path.read_text()
    if 'armada_wait_gamescope_startup' in text:
        return
    pattern = r'(?m)^if read -r -t (?:5|15) response_x_display response_wl_display <>"\$socket"; then$'
    replacement = (
        'source /usr/libexec/armada/gamescope-startup-wait\n'
        'if armada_wait_gamescope_startup; then'
    )
    updated, count = re.subn(pattern, lambda match: replacement, text)
    if count != 1:
        raise RuntimeError(f'{path}: expected one vendor startup FIFO read, found {count}')
    path.write_text(updated)


if __name__ == '__main__':
    patch_session(Path(sys.argv[1]))
