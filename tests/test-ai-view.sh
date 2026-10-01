#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
PYTHONPATH="$ROOT/lib" python3 -B -S - <<'PY'
from ai_view import encode, decode, compact
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
assert original['entities'][0][1]=='memory_device' # no caller mutation
assert len(compact(view)) < len(compact(original))
assert decode({'schema':{'version':5},'entities':[]})=={'schema':{'version':5},'entities':[]}
assert decode(encode({'entities':[],'relations':[]}))=={'entities':[],'relations':[]}
assert decode(encode({'indexes':{'graph':'meta/graph.json'},'coverage':{'graph_deferred':True}}))=={'indexes':{'graph':'meta/graph.json'},'coverage':{'graph_deferred':True}}
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
