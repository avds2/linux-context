#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
parent=$(mktemp -d)
trap 'rm -rf "$parent"' EXIT
out="$parent/bundle"

if (( EUID == 0 )) && getent passwd 65534 >/dev/null 2>&1; then
    expected_uid=65534
    expected_gid=$(getent passwd 65534 | awk -F: 'NR==1{print $4}')
    # Simulate the normal sudo case: destination parent belongs to the invoking user.
    chown "$expected_uid:$expected_gid" "$parent"
    SUDO_UID="$expected_uid" SUDO_GID="$expected_gid" \
        "$ROOT/bin/linux-context" --profile quick --output "$out" >/dev/null 2>"$parent/stderr"
else
    expected_uid=$(id -u)
    expected_gid=$(id -g)
    "$ROOT/bin/linux-context" --profile quick --output "$out" >/dev/null 2>"$parent/stderr"
fi
archive="$out.tar.gz"
[[ "$(stat -c %u "$out")" == "$expected_uid" ]]
[[ "$(stat -c %g "$out")" == "$expected_gid" ]]
[[ "$(stat -c %a "$out")" == 700 ]]
[[ "$(stat -c %u "$out/context.json")" == "$expected_uid" ]]
[[ "$(stat -c %a "$out/context.json")" == 600 ]]
[[ "$(stat -c %u "$archive")" == "$expected_uid" ]]
[[ "$(stat -c %a "$archive")" == 600 ]]
mkdir "$parent/extracted"
tar -xzf "$archive" -C "$parent/extracted"
member="$parent/extracted/$(basename "$out")"
[[ "$(stat -c %u "$member")" == "$expected_uid" ]]
[[ "$(stat -c %u "$member/context.json")" == "$expected_uid" ]]
printf 'CLI ownership integration test: ok (%s:%s)\n' "$expected_uid" "$expected_gid"
