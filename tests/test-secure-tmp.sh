#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/common.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TMPDIR="$tmp"
if (( EUID == 0 )); then
    [[ "$(secure_tmp_parent)" == /tmp ]]
else
    [[ "$(secure_tmp_parent)" == "$tmp" ]]
fi
printf 'secure temporary parent test: ok\n'
