#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
stage="$tmp/stage"; bundle="$tmp/bundle"; c="$stage/collectors/evil"
mkdir -p "$c" "$bundle/sections/evil" "$bundle/meta"
printf 'DO-NOT-DELETE\n' > "$tmp/victim"
printf 'evil\tcollected\t1\tok\n' > "$c/status.tsv"
printf '{"id":"evil"}\n' > "$c/collector.json"
: > "$c/notes.tsv"
PYTHONPATH="$ROOT/lib" python3 -B -S - "$c" <<'PY'
from pathlib import Path
import sys
from recordio import write_records
c=Path(sys.argv[1])
for name,kind in [('facts.records','facts'),('entities.records','entities'),('entity-attrs.records','entity_attrs'),('relations.records','relations'),('probes.records','probes')]:
    write_records(c/name,kind,[])
write_records(c/'artifacts.records','artifacts',[{
    'id':'evil:x','collector':'evil','label':'x','kind':'command',
    'path':'sections/evil/../../../victim','source':'test','exit_code':0,'accepted':True,
    'timed_out':False,'truncated':False,'timeout_seconds':1,'max_bytes':1,
    'captured_bytes':0,'duration_ms':1,'priority':50,'omitted_reason':'','omitted_bytes':0,
}])
PY
set +e
PYTHONPATH="$ROOT/lib" python3 -B -S "$ROOT/lib/compile.py" \
  --stage "$stage" --bundle "$bundle" --tool-version 1.0.0 --profile max \
  --profile-semantics test --targets auto --started 2026-08-14T00:00:00Z \
  --finished 2026-08-14T00:00:01Z --duration 1 --evidence-budget 1024 \
  --context-budget 4096 --euid 0 --owner-uid 1000 --owner-gid 1000 --owner-source test \
  --redaction-engine test --redaction-assurance enhanced >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 ))
grep -Fqx 'DO-NOT-DELETE' "$tmp/victim"
python3 -B -S - "$bundle/meta/validation.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])); assert v['status']=='invalid'; assert any('evidence path' in e for e in v['errors']),v
PY
printf 'compiler evidence path safety test: ok\n'
