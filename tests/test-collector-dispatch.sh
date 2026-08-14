#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for collector in "$ROOT"/collectors/*/*.sh; do
    out=$("$collector" --meta)
    lines=$(printf '%s\n' "$out" | awk 'NF{n++} END{print n+0}')
    [[ "$lines" == 1 ]] || { printf 'duplicate metadata dispatch: %s (%s lines)\n' "$collector" "$lines" >&2; exit 1; }
done
# The API library itself is side-effect free when sourced.
out=$(COLLECTOR_ID=fixture bash -c 'source "$1"' _ "$ROOT/lib/collector_api.sh")
[[ -z "$out" ]]
printf 'collector single-dispatch test: ok\n'
