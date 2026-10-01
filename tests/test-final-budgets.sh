#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHONPATH="$ROOT/lib" python3 -B -S - <<'PY'
import json
from pathlib import Path
import tempfile
from validate_bundle import validate
with tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp)
    (root/'meta').mkdir()
    (root/'sections/c').mkdir(parents=True)
    evidence=root/'sections/c/e.txt'
    evidence.write_text('redacted')
    (root/'meta/evidence.json').write_text(json.dumps({'evidence':[['c:e','sections/c/e.txt','ok',1,0,90,'fixture']]}))
    (root/'meta/validation.json').write_text(json.dumps({'status':'valid','errors':[]}))
    context={'coverage':{'evidence_bytes':1,'evidence_budget_bytes':10,'context_budget_bytes':4096,'graph_deferred':False},'entities':[], 'relations':[]}
    (root/'context.json').write_text(json.dumps(context))
    validate(root)
    report=json.loads((root/'meta/validation.json').read_text())
    assert report['context_bytes']==(root/'context.json').stat().st_size
    assert report['evidence_bytes']==8
    assert json.loads((root/'meta/evidence.json').read_text())['evidence'][0][3]==8
    for change in ('evidence_growth','context_growth','missing_endpoint','duplicate_entity'):
        evidence.write_text('redacted')
        context['entities']=[]; context['relations']=[]
        context['coverage']['context_budget_bytes']=4096
        if change=='evidence_growth': evidence.write_text('x'*11)
        if change=='context_growth': context['coverage']['context_budget_bytes']=1
        if change=='missing_endpoint': context['relations']=[['absent','owns','other',[]]]
        if change=='duplicate_entity': context['entities']=[['same'],['same']]
        (root/'context.json').write_text(json.dumps(context))
        try:
            validate(root)
        except ValueError:
            pass
        else:
            raise AssertionError(change)
print('final redacted sizes, budgets and graph integrity: ok')
PY
