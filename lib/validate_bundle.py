#!/usr/bin/env python3
"""Reconcile final redacted byte sizes and enforce the publication budgets."""
import json
from pathlib import Path
import sys


def dump(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False) + '\n'


def validate(root: Path) -> None:
    context_path = root / 'context.json'
    context = json.loads(context_path.read_text(encoding='utf-8'))
    report_path = root / 'meta/validation.json'
    report = json.loads(report_path.read_text(encoding='utf-8'))
    if report['status'] != 'valid' or report['errors']:
        raise ValueError('compiler validation failed')
    evidence_path = root / 'meta/evidence.json'
    evidence = json.loads(evidence_path.read_text(encoding='utf-8'))
    # Reuse the compiler's traversal/symlink boundary rather than inventing one.
    from compile import evidence_path_under_sections
    total = 0
    for row in evidence['evidence']:
        path = evidence_path_under_sections(root, row[1])
        row[3] = path.stat().st_size
        total += row[3]
    coverage = context['coverage']
    coverage['evidence_bytes'] = total
    encoded = dump(context)
    context_bytes = len(encoded.encode('utf-8'))
    if context_bytes > coverage['context_budget_bytes']:
        raise ValueError('redacted canonical context exceeds its hard byte budget')
    if total > coverage['evidence_budget_bytes']:
        raise ValueError('redacted evidence exceeds its hard byte budget')
    graph = context
    if coverage['graph_deferred']:
        graph = json.loads((root / 'meta/graph.json').read_text(encoding='utf-8'))
    ids = [row[0] for row in graph.get('entities', [])]
    if len(ids) != len(set(ids)):
        raise ValueError('duplicate entity IDs after redaction')
    known = set(ids)
    if any(row[0] not in known or row[2] not in known for row in graph.get('relations', [])):
        raise ValueError('missing relation endpoint after redaction')
    context_path.write_text(encoded, encoding='utf-8')
    evidence_path.write_text(dump(evidence), encoding='utf-8')
    report.update(context_bytes=context_bytes, evidence_bytes=total)
    report_path.write_text(dump(report), encoding='utf-8')


if __name__ == '__main__':
    validate(Path(sys.argv[1]))
