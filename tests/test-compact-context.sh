#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$ROOT/bin/linux-context" --profile quick --output "$tmp/out" --no-archive >/dev/null 2>"$tmp/err"
[[ -f "$tmp/out/context.json" ]]
[[ ! -e "$tmp/out/context.jsonl" ]]
[[ ! -e "$tmp/out/SYSTEM-SUMMARY.md" ]]
[[ -f "$tmp/out/meta/evidence.json" ]]
[[ -f "$tmp/out/meta/collection.json" ]]
python3 -B -S - "$tmp/out/context.json" "$tmp/out/meta/validation.json" "$tmp/out/meta/redaction.json" "$tmp/out/meta/evidence.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
v=json.load(open(sys.argv[2],encoding='utf-8'))
r=json.load(open(sys.argv[3],encoding='utf-8'))
e=json.load(open(sys.argv[4],encoding='utf-8'))
assert c['schema']['version']==5
assert c['schema']['canonical'] is True
assert v['status']=='valid' and not v['errors']
assert r['high_confidence_residual_count']==0
assert c['indexes']['evidence']=='meta/evidence.json'
assert 'evidence' not in c and 'collectors' not in c and 'performance' not in c
assert e['schema']=='linux-context-evidence-catalog'
ids={e[0] for e in c['entities']}
assert len(ids)==len(c['entities'])
assert all(a in ids and b in ids for a,_,b,_ in c['relations'])
# Machine-first canonical file is minified; no pretty-print indentation explosion.
raw=open(sys.argv[1],encoding='utf-8').read()
assert '\n  "' not in raw
PY
printf 'compact context test: ok\n'
