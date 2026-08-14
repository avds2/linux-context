#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/stage/collectors/c" "$t/stage/evidence/c" "$t/stage/meta"
python3 -B - <<'PY' "$ROOT" "$t/stage"
from pathlib import Path
import sys
sys.path.insert(0,str(Path(sys.argv[1])/'lib'))
from recordio import write_records
s=Path(sys.argv[2]); c=s/'collectors/c'; e=s/'evidence/c'
rows=[]
for label,size,pri in [('high',80,100),('mid',30,50),('low',60,10)]:
    (e/f'{label}.txt').write_bytes(label[0].encode()*size)
    rows.append({'id':f'c:{label}','collector':'c','label':label,'kind':'command','path':f'sections/c/{label}.txt','source':label,'exit_code':0,'accepted':True,'timed_out':False,'truncated':False,'timeout_seconds':1,'max_bytes':size,'captured_bytes':size,'duration_ms':1,'priority':pri})
write_records(c/'artifacts.records','artifacts',rows)
PY
python3 -B -S "$ROOT/lib/prune.py" --stage "$t/stage" --budget 110
[[ -f "$t/stage/evidence/c/high.txt" && -f "$t/stage/evidence/c/mid.txt" && ! -e "$t/stage/evidence/c/low.txt" ]]
python3 -B - <<'PY' "$ROOT" "$t/stage/collectors/c/artifacts.records" "$t/stage/meta/prune.json"
from pathlib import Path
import json,sys
sys.path.insert(0,str(Path(sys.argv[1])/'lib'))
from recordio import read_records
r=read_records(Path(sys.argv[2]),'artifacts'); p=json.load(open(sys.argv[3]))
low=next(x for x in r if x['label']=='low')
assert low['omitted_reason']=='evidence_budget_pre_redaction' and low['omitted_bytes']==60
assert p['retained_bytes_before_redaction']==110 and p['omitted_files']==1
PY
printf 'pre-redaction prune test: ok\n'
