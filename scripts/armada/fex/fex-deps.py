#!/usr/bin/env python3
"""Resolve the full dependency closure of a 32-bit Steam guest and report what
the FEX RootFS is missing.

Trial-and-error (start the guest, read the one library it complains about,
install it, repeat) is slow and only ever reveals one name per run. This walks
the ELF graph instead: read NEEDED of the guest and of every library it already
resolves to, recursively, and diff the resulting soname set against what is
actually present. The output is the complete missing set in one shot, which then
maps to packages in a single dnf call.

Only i386 objects are indexed: a 64-bit library of the same name in the RootFS
does not satisfy a 32-bit guest, and counting it as present hides real gaps.
"""
import os
import re
import shutil
import subprocess
import sys

STEAM = os.environ.get('STEAM_DIR', '/home/armada/.local/share/Steam')
ROOTFS = os.environ.get('FEX_ROOTFS', '/usr/lib/fex-emu/rootfs')
WANT_MACHINE = int(os.environ.get('GUEST_MACHINE', '3'))  # 3 = i386, 62 = x86-64

NEEDED_RE = re.compile(r'\(NEEDED\).*?[\[［]([^\]］]+)[\]］]')


def elf_machine(path):
    try:
        with open(path, 'rb') as handle:
            head = handle.read(20)
    except OSError:
        return None
    if len(head) < 20 or head[:4] != b'\x7fELF':
        return None
    return head[18] | (head[19] << 8)


def elfdeps(path):
    # No blanket except: a missing readelf used to make every query return nothing
    # and the whole run reported COMPLETE. readelf is checked once in main().
    try:
        out = subprocess.run(['readelf', '-d', path],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return NEEDED_RE.findall(out)


def build_index():
    """basename -> path for every shared object of the guest architecture."""
    index = {}
    for base in (STEAM, ROOTFS):
        for dirpath, _, files in os.walk(base):
            for name in files:
                if '.so' not in name:
                    continue
                full = os.path.join(dirpath, name)
                if elf_machine(full) == WANT_MACHINE:
                    index.setdefault(name, full)
    return index


def start_points():
    roots = []
    for base in (os.path.join(STEAM, 'ubuntu12_32'), os.path.join(STEAM, 'linux32')):
        for dirpath, _, files in os.walk(base):
            for name in files:
                full = os.path.join(dirpath, name)
                if elf_machine(full) == WANT_MACHINE:
                    roots.append(full)
    return roots


def main():
    if not shutil.which('readelf'):
        print('binutils (readelf) is not installed', file=sys.stderr)
        return 2
    index = build_index()
    pending = start_points()
    seen = set()
    missing = set()
    while pending:
        path = pending.pop()
        real = os.path.realpath(path)
        if real in seen:
            continue
        seen.add(real)
        for name in elfdeps(path):
            local = os.path.join(os.path.dirname(path), name)
            if os.path.exists(local) and elf_machine(local) == WANT_MACHINE:
                pending.append(local)
                continue
            found = index.get(name)
            if found:
                pending.append(found)
            else:
                missing.add(name)
    if not missing:
        print('COMPLETE')
        return 0
    for name in sorted(missing):
        print(name)
    return 0


if __name__ == '__main__':
    sys.exit(main())