#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
PYTHONPATH="$ROOT/lib" python3 -B -S - <<'PY'
from ai_view import encode, encode_v1, decode, compact, same_value
original={'schema':{'version':5},'facts':[['hardware.memory.total_bytes',17179869184,0]],
          'provenance':[['hardware.memory','fixture','observed',1.0]],
          'entities':[], 'relations':[], 'indexes':{'evidence':'meta/evidence.json'},
          'coverage':{'graph_deferred':False}}
for i in range(32):
    original['entities'].append([f'memory-device:{i}','memory_device',f'DIMM {i}',{
      'capacity_bytes':[8589934592,0], 'memory_type':['DDR4',0],
      'manufacturer':['Test "manufacturer"\nUntrusted host text',0],
      'configured_speed':[['2666 MT/s',0],['3200 MT/s',1]],
      'form_factor':['DIMM',0], 'populated':[True,0]}, [0], ['conflicting_type']])
    original['relations'].append(['host:local','has_memory_device',f'memory-device:{i}',[0]])
view=encode(original)
assert decode(view)==original
assert decode(encode_v1(original))==original
assert view["encoding"]["version"]==2
assert original['entities'][0][1]=='memory_device' # no caller mutation
assert len(compact(view)) < len(compact(original))
assert decode({'schema':{'version':5},'entities':[]})=={'schema':{'version':5},'entities':[]}
assert decode(encode({'entities':[],'relations':[]}))=={'entities':[],'relations':[]}
assert decode(encode({'indexes':{'graph':'meta/graph.json'},'coverage':{'graph_deferred':True}}))=={'indexes':{'graph':'meta/graph.json'},'coverage':{'graph_deferred':True}}
# Mixed IDs, duplicate values, conflicting observations and optional type rows
# survive both generations. Labels that equal IDs/suffixes exercise v2 defaults.
import random, copy
rng=random.Random(42)
for _ in range(50):
    doc={'entities':[], 'relations':[], 'facts':[['literal',None,0]]}
    for i in range(rng.randint(1,80)):
        label=rng.choice([f'node:{i}',str(i),f'label-{i}'])
        attrs={f'key-{j}':rng.choice([[False,0],["UP",0],[i,1],[["old",0],["new",1]]]) for j in range(rng.randint(0,8))}
        doc['entities'].append([f'node:{i}',rng.choice(['service','device']),label,attrs,[0]])
        doc['relations'].append(['node:0','owns',f'node:{i}',[1]])
    doc['relations'].append(['literal-external-id','other','node:0',[]])
    assert same_value(decode(encode(doc)),doc)
typed={'entities':[['n:0','thing','0',{'state':[True,0]},[0]],
                   ['n:1','thing','1',{'state':[1,0]},[0]],
                   ['n:2','thing','2',{'state':[1.0,0]},[0]]], 'relations':[]}
assert same_value(decode(encode(typed)),typed)
assert same_value(decode(encode_v1(typed)),typed)
from compile import merge_value
assert merge_value([True,0],1,0)==[[True,0],[1,0]]
bad=copy.deepcopy(view); bad['relations'][0][0]=-1
try:
    decode(bad)
except ValueError:
    pass
else:
    raise AssertionError('negative endpoint reference was accepted')
PY
"$ROOT/bin/linux-context" --profile standard --no-archive --output "$t/bundle" > "$t/stdout" 2> "$t/stderr"
python3 -B -S "$ROOT/lib/ai_view.py" decode "$t/bundle/context.ai.json" "$t/decoded.json"
python3 -B -S - "$t" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
assert (root/'bundle/context.ai.json').stat().st_size <= (root/'bundle/context.json').stat().st_size
assert json.loads((root/'decoded.json').read_text())==json.loads((root/'bundle/context.json').read_text())
assert 'context.ai.json' in (root/'bundle/manifest.sha256').read_text()
assert json.loads((root/'bundle/meta/redaction.json').read_text())['high_confidence_residual_count']==0
PY
printf 'lossless AI view and publication tests: ok\n'
