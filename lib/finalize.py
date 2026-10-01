#!/usr/bin/env python3
"""Finalize a sanitized bundle in one interpreter, preserving all safety gates."""
from pathlib import Path
import sys

from ai_view import write_view
from manifest import write_manifest
from redact import redact_tree, scan_tree, write_reports
from validate_bundle import validate


def finalize(root: Path) -> None:
    # Ordering is a privacy contract: validate actual sanitized sizes, derive
    # only from sanitized canonical JSON, then scan every shareable artifact.
    redact_tree(root)
    validate(root)
    write_view(root / 'context.json', root / 'context.ai.json')
    report = scan_tree(root)
    write_reports(root, report)
    if report['high_confidence_residual_count']:
        raise ValueError('final bundle contains high-confidence residual secret patterns')
    write_manifest(root)


if __name__ == '__main__':
    finalize(Path(sys.argv[1]))
