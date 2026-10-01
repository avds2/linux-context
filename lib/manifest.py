#!/usr/bin/env python3
"""Hash a sanitized bundle without spawning several processes per artifact."""
import hashlib
from pathlib import Path
import sys


def write_manifest(root: Path) -> None:
    manifest = root / 'manifest.sha256'
    with manifest.open('w', encoding='utf-8') as output:
        for path in sorted(root.rglob('*')):
            if path == manifest or not path.is_file():
                continue
            digest = hashlib.sha256()
            with path.open('rb') as source:
                for block in iter(lambda: source.read(1024 * 1024), b''):
                    digest.update(block)
            name = path.relative_to(root).as_posix()
            # Preserve GNU sha256sum's filename escaping contract.
            escaped = '\\' in name or '\n' in name
            name = name.replace('\\', '\\\\').replace('\n', '\\n')
            output.write(f'{chr(92) if escaped else ""}{digest.hexdigest()}  {name}\n')


if __name__ == '__main__':
    write_manifest(Path(sys.argv[1]))
