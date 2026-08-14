#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Unit semantics: all means every target-specific branch is focused.
export LCTX_PROJECT_ROOT="$ROOT" LCTX_TARGETS=all
source "$ROOT/lib/common.sh"
target_is_all
target_requested network
target_requested docker
target_requested logs
target_requested packages
target_requested systemd
target_requested bluetooth
! target_is_auto

# CLI surface advertises all and keeps auto/all standalone.
targets=$("$ROOT/bin/linux-context" --list-targets)
grep -Fxq all <<< "$targets"
if "$ROOT/bin/linux-context" --profile quick --target all,network --output "$tmp/bad" --no-archive >/dev/null 2>&1; then
    printf 'mixed all,target unexpectedly accepted\n' >&2; exit 1
fi
if "$ROOT/bin/linux-context" --profile quick --target auto,network --output "$tmp/bad2" --no-archive >/dev/null 2>&1; then
    printf 'mixed auto,target unexpectedly accepted\n' >&2; exit 1
fi

# Integration: under max+all, target mismatch must never skip a collector. A
# collector may still be unavailable when its subsystem is absent/inaccessible.
"$ROOT/bin/linux-context" --profile max --target all --output "$tmp/out" --no-archive >/dev/null 2>"$tmp/err"
python3 -B -S - "$tmp/out/context.json" "$tmp/out/meta/collection.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
m=json.load(open(sys.argv[2],encoding='utf-8'))
assert c['run']['targets']==['all'], c['run']
assert c['run']['target_semantics'].startswith('exhaustive target detail'), c['run']
for row in m['collectors']:
    cid,status,_,detail=row
    assert not (status=='skipped' and detail=='target mismatch'), row
PY
printf 'target all semantics test: ok\n'
