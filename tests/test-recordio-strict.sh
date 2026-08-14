#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHONPATH="$ROOT/lib" python3 -B -S - <<'PY'
from pathlib import Path
from tempfile import TemporaryDirectory
from recordio import read_records, write_records

with TemporaryDirectory() as td:
    root=Path(td)
    # Valid typed values survive round trip.
    p=root/'facts.records'
    write_records(p,'facts',[{
        'key':'test.number','value':42,'value_type':'number','source':'test',
        'observation_type':'observed','confidence':1.0,'collector':'test'}])
    assert read_records(p,'facts')[0]['value']==42

    # Internal structural corruption must fail loudly instead of silently becoming
    # zero/false/string data in the canonical graph.
    bad=root/'artifacts.records'
    fields=['id','collector','label','kind','sections/x/y.txt','src','not-an-int','1','0','0','10','10','10','1','50','','0']
    bad.write_bytes(b'\0'.join(x.encode() for x in fields)+b'\0')
    try: read_records(bad,'artifacts')
    except ValueError as e: assert 'invalid integer' in str(e)
    else: raise AssertionError('invalid integer was accepted')

    badbool=root/'probes.records'
    fields=['probe','src','0','maybe','0','0','1','1']
    badbool.write_bytes(b'\0'.join(x.encode() for x in fields)+b'\0')
    try: read_records(badbool,'probes')
    except ValueError as e: assert 'invalid boolean' in str(e)
    else: raise AssertionError('invalid boolean was accepted')

    badconf=root/'entities.records'
    write_records  # keep lint/readability explicit
    fields=['id','thing','label','src','observed','1.5','collector']
    badconf.write_bytes(b'\0'.join(x.encode() for x in fields)+b'\0')
    try: read_records(badconf,'entities')
    except ValueError as e: assert 'confidence outside' in str(e)
    else: raise AssertionError('out-of-range confidence was accepted')
print('strict record parser test: ok')
PY
