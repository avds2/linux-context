#!/usr/bin/env python3
"""Validate the collector catalog and initialize isolated staging in one pass."""
import json
from pathlib import Path
import re
import sys


def initialize(stage: Path, rows: list[str]) -> None:
    seen = set()
    names = ('id', 'min_profile', 'targets', 'privilege', 'baseline', 'description')
    for row in rows:
        fields = row.split('\t')
        if len(fields) != len(names):
            raise ValueError('collector metadata must contain exactly six fields')
        meta = dict(zip(names, fields))
        cid = meta['id']
        if not re.fullmatch(r'[a-z0-9]+(?:[._-][a-z0-9]+)*', cid) or cid in seen:
            raise ValueError(f'invalid or duplicate collector ID: {cid!r}')
        if meta['min_profile'] not in ('quick', 'standard', 'deep', 'max'):
            raise ValueError(f'invalid collector profile: {cid}')
        if meta['privilege'] not in ('user', 'optional-root', 'root') or meta['baseline'] not in ('0', '1'):
            raise ValueError(f'invalid collector policy: {cid}')
        seen.add(cid)
        cdir = stage / 'collectors' / cid
        cdir.mkdir()
        (stage / 'evidence' / cid).mkdir()
        (cdir / 'collector.json').write_text(json.dumps(meta, separators=(',', ':')) + '\n', encoding='utf-8')
        for filename in ('facts.records', 'entities.records', 'entity-attrs.records',
                         'relations.records', 'artifacts.records', 'probes.records', 'notes.tsv'):
            (cdir / filename).touch()


if __name__ == '__main__':
    initialize(Path(sys.argv[1]), sys.argv[2:])
