#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
for profile in quick standard deep max; do
    "$ROOT/bin/linux-context" --profile "$profile" --output "$t/$profile" >/dev/null
    (cd "$t/$profile" && sha256sum -c manifest.sha256 >/dev/null)
    PYTHONPATH="$ROOT/lib" python3 -B -S - "$t/$profile" <<'PY'
import json
from pathlib import Path
import sys
from ai_view import decode
root = Path(sys.argv[1])
context = json.loads((root/'context.json').read_text())
assert context == decode(json.loads((root/'context.ai.json').read_text()))
report = json.loads((root/'meta/validation.json').read_text())
assert report['status'] == 'valid' and report['errors'] == []
assert report['context_bytes'] == (root/'context.json').stat().st_size
assert report['context_bytes'] <= report['context_budget_bytes']
assert json.loads((root/'meta/redaction.json').read_text())['high_confidence_residual_count'] == 0
if not Path('/run/systemd/system').is_dir():
    assert not any(f[0] == 'init.system' and f[1] == 'systemd' for f in context.get('facts', []))
assert root.with_suffix('.tar.gz').is_file()
PY
done
printf 'all-profile distribution archive/AI/privacy smoke tests: ok\n'
