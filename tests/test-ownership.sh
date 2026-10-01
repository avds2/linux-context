#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export LCTX_PROJECT_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/redact.sh"
source "$ROOT/lib/bundle.sh"
LCTX_VERSION=1.0.0 LCTX_PROFILE=max LCTX_TARGETS=auto LCTX_ARCHIVE=1
init_redaction
parent=$(mktemp -d); trap 'rm -rf "$parent"' EXIT
requested="$parent/out"

if (( EUID == 0 )) && getent passwd 65534 >/dev/null 2>&1 && \
    chown "65534:$(getent passwd 65534 | awk -F: 'NR==1{print $4}')" "$parent" 2>/dev/null; then
    export SUDO_UID=65534 SUDO_GID=65534
    expected_uid=65534 expected_gid=65534
    chown "$expected_uid:$expected_gid" "$parent"
else
    printf 'sudo handoff fixture unavailable; checking current-user ownership\n' >&2
    expected_uid=$(id -u); expected_gid=$(id -g)
fi
LCTX_OUTPUT_DIR="$requested"
init_bundle
printf 'test\n' > "$LCTX_OUTPUT_DIR/test.txt"
publish_bundle
[[ "$LCTX_OUTPUT_DIR" == "$requested" ]]
archive=$(archive_bundle)
actual_uid=$(stat -c %u "$LCTX_OUTPUT_DIR")
actual_gid=$(stat -c %g "$LCTX_OUTPUT_DIR")
file_uid=$(stat -c %u "$LCTX_OUTPUT_DIR/test.txt")
archive_uid=$(stat -c %u "$archive")
extract="$parent/extracted"; mkdir -p "$extract"; tar -xzf "$archive" -C "$extract"
member_root="$extract/$(basename "$LCTX_OUTPUT_DIR")"
[[ "$actual_uid:$actual_gid" == "$expected_uid:$expected_gid" ]]
[[ "$file_uid" == "$expected_uid" ]]
[[ "$archive_uid" == "$expected_uid" ]]
[[ "$(stat -c %u "$member_root")" == "$expected_uid" ]]
[[ "$(stat -c %u "$member_root/test.txt")" == "$expected_uid" ]]
[[ "$(stat -c %a "$LCTX_OUTPUT_DIR")" == 700 ]]
[[ "$(stat -c %a "$LCTX_OUTPUT_DIR/test.txt")" == 600 ]]
[[ "$(stat -c %a "$archive")" == 600 ]]
cleanup_tmp
printf 'ownership/publish test: ok (%s:%s)\n' "$expected_uid" "$expected_gid"
