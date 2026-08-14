#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/stage/collectors/fixture" "$t/stage/evidence/fixture" "$t/stage/meta"
for f in facts entities entity-attrs relations artifacts probes; do : > "$t/stage/collectors/fixture/$f.records"; done
: > "$t/stage/collectors/fixture/notes.tsv"
export COLLECTOR_ID=fixture COLLECTOR_MIN_PROFILE=quick COLLECTOR_TARGETS=fixture COLLECTOR_PRIVILEGE=user COLLECTOR_BASELINE=0
export LCTX_FACTS_RECORDS="$t/stage/collectors/fixture/facts.records"
export LCTX_ENTITIES_RECORDS="$t/stage/collectors/fixture/entities.records"
export LCTX_ENTITY_ATTRS_RECORDS="$t/stage/collectors/fixture/entity-attrs.records"
export LCTX_RELATIONS_RECORDS="$t/stage/collectors/fixture/relations.records"
export LCTX_ARTIFACTS_RECORDS="$t/stage/collectors/fixture/artifacts.records"
export LCTX_PROBES_RECORDS="$t/stage/collectors/fixture/probes.records"
export LCTX_NOTES_FILE="$t/stage/collectors/fixture/notes.tsv"
export LCTX_SECTION_DIR="$t/stage/evidence/fixture" LCTX_PRIVATE_TMP="$t"
export LCTX_PROFILE=max LCTX_COMMAND_MAX_BYTES=1048576 LCTX_COMMAND_TIMEOUT=5
source "$ROOT/lib/collector_api.sh"
# Values that are hazardous to handwritten JSON and common in package metadata.
emit_fact 'packages.fixture.value' $'quote=" backslash=\\ newline=\n tab=\t esc=\x1b unicode=تست' \
  $'source "quoted" \\ trailing\\' observed 1.0 string
emit_fact 'DB_PASSWORD' 'fixture-super-secret' fixture observed 1.0 string
python3 -B -S - "$ROOT" "$LCTX_FACTS_RECORDS" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0,str(Path(sys.argv[1])/'lib'))
from recordio import read_records
rows=read_records(Path(sys.argv[2]),'facts')
assert len(rows)==2,rows
r=rows[0]
assert r['key']=='packages.fixture.value'
assert 'quote="' in r['value'] and 'backslash=\\' in r['value'] and 'unicode=تست' in r['value']
assert '\n' not in r['value'] and '\t' not in r['value']  # normalized to one line
assert r['source'].endswith('trailing\\')
PY
# Structured staging must remain parseable through the redaction boundary and
# key/value context must redact arbitrary secret values.
export LCTX_REDACTION_SALT='fixture-random-looking-test-salt' LCTX_REDACTION_ENGINE=python-enhanced LCTX_REDACTION_ASSURANCE=enhanced
python3 -B -S "$ROOT/lib/redact.py" secure-tree "$t/stage" >/dev/null
python3 -B -S - "$ROOT" "$LCTX_FACTS_RECORDS" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0,str(Path(sys.argv[1])/'lib'))
from recordio import read_records
rows=read_records(Path(sys.argv[2]),'facts')
secret=next(x for x in rows if x['key']=='DB_PASSWORD')
assert str(secret['value']).startswith('[REDACTED-'),secret
assert len(rows)==2
PY
printf 'delimiter-safe staging/redaction test: ok\n'
# Regression for the exact v0.5.0 failure: the curl --user detector must not
# consume the next JSON field after a harmless Flatpak provenance string.
PYTHONPATH="$ROOT/lib" LCTX_REDACTION_SALT='fixture' python3 -B -S - <<'PY'
import json
from redact import redact_text
obj={"key":"packages.flatpak.user_app_count","value":1,"value_type":"number","source":"flatpak list --user (owner)","observation_type":"observed","confidence":1.0,"collector":"packages.inventory"}
raw=json.dumps(obj,separators=(',',':'))
out=redact_text(raw)
parsed=json.loads(out)
assert parsed['source']=='flatpak list --user (owner)',out
PY
