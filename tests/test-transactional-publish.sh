#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export LCTX_PROJECT_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/redact.sh"
source "$ROOT/lib/bundle.sh"

parent=$(mktemp -d)
trap 'rm -rf "$parent"' EXIT
expected_uid=$(id -u)
expected_gid=$(id -g)
if (( EUID == 0 )) && getent passwd 65534 >/dev/null 2>&1 && \
    chown "65534:$(getent passwd 65534 | awk -F: 'NR==1{print $4}')" "$parent" 2>/dev/null; then
    export SUDO_UID=65534
    export SUDO_GID
    SUDO_GID=$(getent passwd 65534 | awk -F: 'NR==1{print $4}')
    expected_uid=$SUDO_UID
    expected_gid=$SUDO_GID
    chown "$expected_uid:$expected_gid" "$parent"
fi

new_bundle() {
    local requested=$1
    LCTX_VERSION=1.0.0
    LCTX_PROFILE=quick
    LCTX_TARGETS=auto
    LCTX_ARCHIVE=0
    LCTX_OUTPUT_DIR="$requested"
    init_redaction
    init_bundle
}

# A failed/aborted run must not publish a half-built destination.
requested="$parent/aborted"
new_bundle "$requested"
printf 'private incomplete data\n' > "$LCTX_OUTPUT_DIR/incomplete.txt"
[[ ! -e "$requested" ]]
cleanup_tmp
[[ ! -e "$requested" ]]

# If a destination appears after collection started, publication must fail
# without overwriting it.
requested="$parent/race"
new_bundle "$requested"
printf 'validated bundle\n' > "$LCTX_OUTPUT_DIR/data.txt"
if (( EUID == 0 )) && [[ "$expected_uid" != 0 ]]; then
    run_as_output_owner bash -c 'mkdir "$1"; printf "sentinel\\n" > "$1/sentinel"' bash "$requested"
else
    mkdir "$requested"
    printf 'sentinel\n' > "$requested/sentinel"
fi
set +e
( publish_bundle ) >/dev/null 2>"$parent/publish.stderr"
rc=$?
set -e
[[ $rc -ne 0 ]]
[[ -f "$requested/sentinel" ]]
[[ "$(cat "$requested/sentinel")" == sentinel ]]
cleanup_tmp

printf 'transactional publication test: ok\n'
