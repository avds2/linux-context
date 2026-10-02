#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for test in "$ROOT"/tests/test-*.sh; do
    printf 'Running %s\n' "${test##*/}"
    "$test"
done
