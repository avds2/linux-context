#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
src="$t/source"
cp -a "$ROOT" "$src"
find "$src" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$src" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
before="$t/before.sha256"; after="$t/after.sha256"
(
    cd "$src"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
) > "$before"
"$src/bin/linux-context" --profile quick --output "$t/out" --no-archive >/dev/null 2>&1
[[ -z "$(find "$src" -type d -name '__pycache__' -print -quit)" ]]
[[ -z "$(find "$src" -type f \( -name '*.pyc' -o -name '*.pyo' \) -print -quit)" ]]
(
    cd "$src"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
) > "$after"
cmp -s "$before" "$after"
printf 'source immutability / no bytecode cache test: ok\n'
