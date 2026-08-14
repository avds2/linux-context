#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
stage="$tmp/stage"; bundle="$tmp/bundle"; c="$stage/collectors/many"
mkdir -p "$c" "$bundle/meta" "$bundle/sections/many"
printf '%s' '{"id":"many"}' > "$c/collector.json"
printf 'many\tcollected\t1\tok\n' > "$c/status.tsv"
: > "$c/notes.tsv"
python3 -B - <<'PY' "$ROOT" "$c"
from pathlib import Path
import sys
sys.path.insert(0,str(Path(sys.argv[1])/'lib'))
from recordio import write_records
c=Path(sys.argv[2])
write_records(c/'facts.records','facts',[{'key':'system.hostname','value':'fixture','value_type':'string','source':'fixture','observation_type':'observed','confidence':1.0,'collector':'many'}])
write_records(c/'entities.records','entities',[{'id':f'thing:{i}','entity_type':'thing','label':f'entity-{i}-with-some-longer-label','source':'fixture','observation_type':'observed','confidence':1.0,'collector':'many'} for i in range(1,701)])
for name,kind in [('entity-attrs.records','entity_attrs'),('relations.records','relations'),('artifacts.records','artifacts'),('probes.records','probes')]: write_records(c/name,kind,[])
PY
python3 -B -S "$ROOT/lib/compile.py" \
  --stage "$stage" --bundle "$bundle" --tool-version 0.5.1 --profile max \
  --profile-semantics test --targets auto --started 2026-08-12T00:00:00Z \
  --finished 2026-08-12T00:00:01Z --duration 1 --evidence-budget 1024 \
  --context-budget 4096 --euid 0 --owner-uid 1000 --owner-gid 1000 --owner-source test \
  --redaction-engine test --redaction-assurance enhanced
python3 -B -S - "$bundle/context.json" "$bundle/meta/graph.json" "$bundle/meta/validation.json" <<'PY'
import json,sys,os
c=json.load(open(sys.argv[1])); g=json.load(open(sys.argv[2])); v=json.load(open(sys.argv[3]))
assert os.path.getsize(sys.argv[1]) <= 4096, os.path.getsize(sys.argv[1])
assert c['coverage']['graph_deferred'] is True
assert c['indexes']['graph']=='meta/graph.json'
assert 'entities' not in c and 'relations' not in c and 'provenance' not in c
assert c['graph_summary']['entity_types']['thing']==700
assert len(g['entities'])==700
assert v['graph_deferred'] is True and v['status']=='valid',v
PY
printf 'context budget deferral test: ok\n'

# Pathological fact/capability cardinality must still yield a bounded entrypoint.
stage2="$tmp/stage2"; bundle2="$tmp/bundle2"; c2="$stage2/collectors/many"
mkdir -p "$c2" "$bundle2/sections" "$bundle2/meta"
printf 'many\tcollected\t1\tok\n' > "$c2/status.tsv"
printf '{"id":"many"}\n' > "$c2/collector.json"
: > "$c2/notes.tsv"
PYTHONPATH="$ROOT/lib" python3 -B -S - "$c2" <<'PY'
from pathlib import Path
import sys
from recordio import write_records
c=Path(sys.argv[1])
f=[]
for i in range(1200):
    f.append({'key':f'huge.fact.{i:04d}','value':'x'*80,'value_type':'string','source':'fixture','observation_type':'observed','confidence':1.0,'collector':'many'})
for i in range(500):
    f.append({'key':f'capability.command.tool{i:04d}','value':True,'value_type':'boolean','source':'fixture','observation_type':'observed','confidence':1.0,'collector':'many'})
write_records(c/'facts.records','facts',f)
for name,kind in [('entities.records','entities'),('entity-attrs.records','entity_attrs'),('relations.records','relations'),('artifacts.records','artifacts'),('probes.records','probes')]: write_records(c/name,kind,[])
PY
PYTHONPATH="$ROOT/lib" python3 -B -S "$ROOT/lib/compile.py" \
  --stage "$stage2" --bundle "$bundle2" --tool-version 1.0.0 --profile max \
  --profile-semantics test --targets auto --started 2026-08-14T00:00:00Z \
  --finished 2026-08-14T00:00:01Z --duration 1 --evidence-budget 1024 \
  --context-budget 4096 --euid 0 --owner-uid 1000 --owner-gid 1000 --owner-source test \
  --redaction-engine test --redaction-assurance enhanced
python3 -B -S - "$bundle2/context.json" "$bundle2/meta/graph.json" <<'PY'
import json,os,sys
c=json.load(open(sys.argv[1])); g=json.load(open(sys.argv[2]))
assert os.path.getsize(sys.argv[1]) <= 4096
assert c['coverage']['graph_deferred'] is True
assert len(g['facts'])==1200 and len(g['capabilities'])==500
PY
printf 'context pathological-fact budget test: ok\n'
