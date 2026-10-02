#!/usr/bin/env python3
"""Bounded portable file metadata inventories; never read scheduled job bodies."""
import argparse
import fnmatch
import json
from pathlib import Path
import stat


def inventory(roots: list[Path], depth: int, limit: int, boot: bool) -> None:
    print(json.dumps({'columns': ['path', 'bytes', 'mode', 'uid', 'gid', 'mtime_seconds']}))
    seen = set()
    examined = 0

    def visit(path: Path, remaining: int, device: int):
        nonlocal examined
        if examined >= limit:
            return
        examined += 1
        try:
            info = path.lstat()
        except OSError:
            return
        if stat.S_ISLNK(info.st_mode) or info.st_dev != device:
            return
        if stat.S_ISDIR(info.st_mode) and remaining > 0:
            try:
                # Traversal and retained rows both have a hard item ceiling.
                for child in path.iterdir():
                    visit(child, remaining - 1, device)
                    if examined >= limit:
                        break
            except OSError:
                pass
        elif stat.S_ISREG(info.st_mode) and path not in seen:
            if boot and not (any(fnmatch.fnmatchcase(path.name, pattern) for pattern in
                                 ('vmlinuz*', 'linux*', 'initramfs*', 'initrd*', '*.efi', '*.conf', 'grub.cfg'))
                             or '/loader/entries/' in str(path)):
                return
            seen.add(path)
            print(json.dumps([str(path), info.st_size, stat.filemode(info.st_mode),
                              info.st_uid, info.st_gid, int(info.st_mtime)], separators=(',', ':')))

    for root in roots:
        try:
            visit(root, depth, root.stat().st_dev)
        except OSError:
            continue
    if examined >= limit:
        print('{"inventory_limited":true}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--depth', type=int, default=1)
    parser.add_argument('--max-items', type=int, default=10000)
    parser.add_argument('--boot', action='store_true')
    parser.add_argument('roots', nargs='+', type=Path)
    args = parser.parse_args()
    inventory(args.roots, args.depth, args.max_items, args.boot)
