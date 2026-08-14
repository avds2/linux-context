#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Caller-controlled legacy salt is intentionally ignored in production. Every
# profile uses the same enhanced Python redaction boundary and receives fresh
# cryptographic per-run correlation randomness.
LCTX_REDACTION_SALT='predictable-external-value' \
    "$ROOT/bin/linux-context" --profile quick --output "$tmp/out" --no-archive \
    >"$tmp/stdout" 2>"$tmp/stderr"
python3 -B -S - "$tmp/out/context.json" "$tmp/out/meta/redaction.json" <<'PYTEST'
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
r=json.load(open(sys.argv[2],encoding='utf-8'))
assert c['security']['redaction_assurance']=='enhanced',c
assert c['security']['redaction_engine']=='python-enhanced',c
assert r['assurance']=='enhanced' and r['engine']=='python-enhanced',r
PYTEST
# The predictable caller value must never be copied into output metadata/evidence.
! grep -RFa -- 'predictable-external-value' "$tmp/out" >/dev/null
printf 'mandatory redaction contract test: ok\n'
