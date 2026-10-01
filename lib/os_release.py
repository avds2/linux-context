#!/usr/bin/env python3
"""Read os-release as data, including shell quoting, without executing it."""
from pathlib import Path
import shlex
import sys


FIELDS = {'PRETTY_NAME': 'pretty_name', 'ID': 'id', 'ID_LIKE': 'id_like', 'VERSION_ID': 'version_id'}


def parse(text: str) -> dict[str, str]:
    values = {}
    for line in text.splitlines():
        key, separator, raw = line.partition('=')
        if not separator or key not in FIELDS:
            continue
        try:
            words = shlex.split(raw, comments=False, posix=True)
        except ValueError:
            continue
        if len(words) == 1 and '\x00' not in words[0]:
            values[key] = words[0]
    return values


if __name__ == '__main__':
    # os-release is a small vendor-controlled file, still bounded defensively.
    with Path(sys.argv[1]).open('rb') as source:
        values = parse(source.read(65536).decode('utf-8', errors='replace'))
    for key, suffix in FIELDS.items():
        if values.get(key):
            sys.stdout.buffer.write((suffix + '\0' + values[key] + '\0').encode('utf-8'))
