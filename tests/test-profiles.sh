#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export LCTX_PROJECT_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/profile.sh"
profile_allows max quick
profile_allows max max
profile_allows deep standard
! profile_allows standard deep
! profile_allows quick max
printf 'profile test: ok\n'
