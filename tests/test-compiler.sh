#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
stage="$tmp/stage"; bundle="$tmp/bundle"; c="$stage/collectors/test.collector"
mkdir -p "$c" "$bundle/sections/test.collector" "$bundle/meta"
printf '%s' '{"id":"test.collector"}' > "$c/collector.json"
printf 'test.collector\tcollected\t12\tok\n' > "$c/status.tsv"
: > "$c/notes.tsv"
python3 -B - <<'PY' "$ROOT" "$c"
from pathlib import Path
import sys
sys.path.insert(0,str(Path(sys.argv[1])/'lib'))
from recordio import write_records
c=Path(sys.argv[2]); col='test.collector'
write_records(c/'facts.records','facts',[{'key':'system.hostname','value':'fixture','value_type':'string','source':'fixture','observation_type':'observed','confidence':1.0,'collector':col}])
write_records(c/'entities.records','entities',[
 {'id':'host:local','entity_type':'host','label':'fixture','source':'a','observation_type':'observed','confidence':1.0,'collector':col},
 {'id':'thing:x','entity_type':'thing','label':'x','source':'a','observation_type':'observed','confidence':1.0,'collector':col},
 {'id':'thing:x','entity_type':'thing','label':'x','source':'b','observation_type':'observed','confidence':1.0,'collector':col},])
write_records(c/'entity-attrs.records','entity_attrs',[
 {'id':'thing:x','key':'state','value':'up','value_type':'string','source':'a','observation_type':'observed','confidence':1.0,'collector':col},
 {'id':'thing:x','key':'exe_a','value':'/usr/bin/a','value_type':'string','source':'/proc/123/exe','observation_type':'observed','confidence':1.0,'collector':col},
 {'id':'thing:x','key':'exe_b','value':'/usr/bin/b','value_type':'string','source':'/proc/456/exe','observation_type':'observed','confidence':1.0,'collector':col},])
write_records(c/'relations.records','relations',[
 {'from':'host:local','predicate':'has','to':'thing:x','source':'a','observation_type':'observed','confidence':1.0,'collector':col},
 {'from':'host:local','predicate':'has','to':'thing:x','source':'b','observation_type':'observed','confidence':1.0,'collector':col},])
write_records(c/'probes.records','probes',[])
PY
python3 -B - <<'PY' "$bundle"
from pathlib import Path
import sys
b=Path(sys.argv[1])/'sections'/'test.collector'
(b/'high.txt').write_bytes(b'H'*80)
(b/'low.txt').write_bytes(b'L'*60)
(b/'tiny.txt').write_bytes(b'T'*20)
PY
python3 -B - <<'PY' "$ROOT" "$c"
from pathlib import Path
import sys
sys.path.insert(0,str(Path(sys.argv[1])/'lib'))
from recordio import write_records
c=Path(sys.argv[2]); col='test.collector'
def a(label,pri):
 return {'id':f'{col}:{label}','collector':col,'label':label,'kind':'command','path':f'sections/{col}/{label}.txt','source':label,'exit_code':0,'accepted':True,'timed_out':False,'truncated':False,'timeout_seconds':1,'max_bytes':1000,'captured_bytes':0,'duration_ms':1,'priority':pri}
write_records(c/'artifacts.records','artifacts',[a('high',100),a('low',10),a('tiny',20)])
PY
python3 -B -S "$ROOT/lib/compile.py" \
  --stage "$stage" --bundle "$bundle" --tool-version 0.5.1 --profile max \
  --profile-semantics test --targets auto --started 2026-08-12T00:00:00Z \
  --finished 2026-08-12T00:00:01Z --duration 1 --evidence-budget 100 \
  --context-budget 65536 \
  --euid 0 --owner-uid 1000 --owner-gid 1000 --owner-source test \
  --redaction-engine test --redaction-assurance enhanced
python3 -B -S - "$bundle/context.json" "$bundle/meta/validation.json" "$bundle/meta/evidence.json" <<'PY'
import json,sys,os
c=json.load(open(sys.argv[1])); v=json.load(open(sys.argv[2])); ev=json.load(open(sys.argv[3]))
assert v['status']=='valid',v
assert c['coverage']['evidence_bytes']==100,c['coverage']
assert c['coverage']['evidence_bytes_before_budget']==160
assert c['coverage']['evidence_omitted']==1
assert c['evidence_omitted'][0][0]=='test.collector:low'
assert 'evidence' not in c
assert {x[0] for x in ev['evidence']}=={'test.collector:high','test.collector:tiny'}
assert not os.path.exists(os.path.join(os.path.dirname(sys.argv[1]),'sections/test.collector/low.txt'))
ents=[e for e in c['entities'] if e[0]=='thing:x']
assert len(ents)==1,ents
rels=[r for r in c['relations'] if r[:3]==['host:local','has','thing:x']]
assert len(rels)==1 and len(rels[0][3])==2,rels
proc_sources=[p for p in c['provenance'] if p[1]=='/proc/PID/exe']
assert len(proc_sources)==1,proc_sources
PY
printf 'compiler/budget test: ok\n'
