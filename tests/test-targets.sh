#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$ROOT/bin/linux-context" --profile max --target docker --output "$tmp/out" --no-archive >/dev/null 2>"$tmp/err"
python3 -B -S - "$tmp/out/context.json" "$tmp/out/meta/collection.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
m=json.load(open(sys.argv[2],encoding='utf-8'))
st={x[0]:x[1] for x in m['collectors']}
# Baseline always runs/is considered; Docker dependencies match explicit docker.
for cid in ('core.identity','core.os','core.kernel','core.capabilities','hardware.inventory'):
    assert st[cid] != 'skipped', (cid,st[cid])
for cid in ('network.topology','runtime.processes','services.systemd','containers.docker'):
    assert st[cid] != 'skipped', (cid,st[cid])
# Unrelated optional collectors are actually excluded.
for cid in ('applications.web','logs.journal','packages.inventory','storage.health','sessions.desktop'):
    assert st[cid] == 'skipped', (cid,st[cid])
assert c['run']['targets']==['docker']
PY
printf 'target semantics test: ok\n'
