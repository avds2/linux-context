#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
parent=$(mktemp -d)
trap 'rm -rf "$parent"' EXIT

out_no_archive="$parent/no-archive"
"$ROOT/bin/linux-context" --profile quick --no-archive --output "$out_no_archive" >/dev/null 2>"$parent/no-archive.stderr"
[[ -d "$out_no_archive" ]]
[[ -f "$out_no_archive/context.json" ]]
[[ ! -e "$out_no_archive.tar.gz" ]]

out_remove="$parent/remove-after"
"$ROOT/bin/linux-context" --profile quick --remove-dir-after-archive --output "$out_remove" >/dev/null 2>"$parent/remove.stderr"
[[ ! -e "$out_remove" ]]
[[ -f "$out_remove.tar.gz" ]]
mkdir "$parent/extracted"
tar -xzf "$out_remove.tar.gz" -C "$parent/extracted"
[[ -f "$parent/extracted/$(basename "$out_remove")/context.json" ]]

printf 'CLI archive mode test: ok\n'
