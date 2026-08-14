#!/usr/bin/env bash

# Dependency-light primitives shared by the orchestrator and collectors.

: "${LCTX_VERSION:=dev}"

utc_now() {
    LC_ALL=C LANG=C TZ=UTC date -u +'%Y-%m-%dT%H:%M:%SZ'
}

utc_stamp() {
    LC_ALL=C LANG=C TZ=UTC date -u +'%Y%m%dT%H%M%SZ'
}

epoch_now() {
    # Bash exposes EPOCHSECONDS/EPOCHREALTIME on modern versions. Prefer those
    # hot-path builtins and keep GNU date only as a portability fallback.
    if [[ "${EPOCHSECONDS:-}" =~ ^[0-9]+$ ]]; then
        printf '%s' "$EPOCHSECONDS"
    else
        LC_ALL=C LANG=C TZ=UTC date -u +'%s'
    fi
}

epoch_millis_into() {
    local __dest="$1" __sec __frac __v
    if [[ "${EPOCHREALTIME:-}" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        __sec=${BASH_REMATCH[1]}; __frac=${BASH_REMATCH[2]}000
        printf -v "$__dest" '%s%s' "$__sec" "${__frac:0:3}"
        return 0
    fi
    __v=$(LC_ALL=C LANG=C TZ=UTC date -u +'%s%3N' 2>/dev/null || true)
    if [[ "$__v" =~ ^[0-9]+$ ]]; then
        printf -v "$__dest" '%s' "$__v"
    else
        __v=$(epoch_now)
        printf -v "$__dest" '%s000' "$__v"
    fi
}

epoch_millis() {
    local __out
    epoch_millis_into __out
    printf '%s' "$__out"
}

file_size_bytes() {
    local path="$1" v
    if command_exists stat; then
        v=$(stat -c %s -- "$path" 2>/dev/null || true)
        [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
    fi
    wc -c < "$path" 2>/dev/null | tr -d ' '
}

target_is_auto() {
    [[ "${LCTX_TARGETS:-auto}" == auto ]]
}

target_is_all() {
    [[ "${LCTX_TARGETS:-auto}" == all ]]
}

target_requested() {
    local wanted="$1" token normalized
    local -a requested=()
    target_is_all && return 0
    target_is_auto && return 1
    IFS=',' read -ra requested <<< "${LCTX_TARGETS:-}"
    for token in "${requested[@]}"; do
        normalize_one_line_into normalized "$token"
        [[ "$normalized" == "$wanted" ]] && return 0
    done
    return 1
}

log() {
    local level="$1"; shift
    printf '[%s] %-5s %s\n' "$(utc_now)" "$level" "$*" >&2
}

fatal() {
    log ERROR "$*"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Central Python entrypoint: no site initialization and, critically, no bytecode
# writes into the project tree. -B is defense in depth for callers that source
# library files outside the normal launcher environment.
lctx_python() {
    PYTHONDONTWRITEBYTECODE=1 python3 -B -S "$@"
}

normalize_one_line_into() {
    local __dest="$1" __s="${2:-}"
    local -a __words=()
    __s=${__s//$'\t'/ }
    __s=${__s//$'\r'/ }
    __s=${__s//$'\n'/ }
    # read/printf are shell builtins: this path is hot for every structured
    # record, so avoid spawning tr+sed hundreds or thousands of times.
    read -r -a __words <<< "$__s" || true
    if (( ${#__words[@]} )); then
        printf -v "$__dest" '%s' "${__words[*]}"
    else
        printf -v "$__dest" '%s' ''
    fi
}

normalize_one_line() {
    local __out
    normalize_one_line_into __out "${1:-}"
    printf '%s' "$__out"
}

safe_name_into() {
    local __dest="$1" __s="${2:-}"
    __s=${__s,,}
    __s=${__s//[^a-z0-9._-]/_}
    while [[ "$__s" == *__* ]]; do __s=${__s//__/_}; done
    while [[ "$__s" == _* ]]; do __s=${__s#_}; done
    while [[ "$__s" == *_ ]]; do __s=${__s%_}; done
    printf -v "$__dest" '%s' "$__s"
}

safe_name() {
    local __out
    safe_name_into __out "${1:-}"
    printf '%s' "$__out"
}

sha256_file() {
    local file="$1"
    if command_exists sha256sum; then
        sha256sum -- "$file" | awk '{print $1}'
    elif command_exists shasum; then
        shasum -a 256 -- "$file" | awk '{print $1}'
    else
        # Python is a required runtime dependency for successful collections, so
        # integrity manifests never degrade to a literal "unavailable" checksum.
        lctx_python - "$file" <<'PYHASH'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as fh:
    for block in iter(lambda: fh.read(1024 * 1024), b""):
        h.update(block)
print(h.hexdigest())
PYHASH
    fi
}

secure_tmp_parent() {
    # Never trust an inherited TMPDIR while privileged. A sudo-invoking user can
    # own/rename entries in a custom TMPDIR; /tmp's sticky-bit semantics avoid
    # that privileged path-substitution class. Unprivileged runs may respect a
    # caller-provided writable TMPDIR.
    if (( EUID == 0 )); then
        printf '%s' /tmp
        return 0
    fi
    if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" && -w "$TMPDIR" ]]; then
        printf '%s' "$TMPDIR"
    else
        printf '%s' /tmp
    fi
}

host_name() {
    local value=''
    if [[ -r /proc/sys/kernel/hostname ]]; then
        IFS= read -r value < /proc/sys/kernel/hostname || true
    fi
    if [[ -z "$value" ]]; then
        value=$(LC_ALL=C uname -n 2>/dev/null || true)
    fi
    if [[ -z "$value" ]] && command_exists hostnamectl; then
        value=$(LC_ALL=C hostnamectl --static 2>/dev/null || true)
    fi
    [[ -n "$value" ]] || value='unknown'
    printf '%s' "$value"
}


detect_output_owner() {
    LCTX_OWNER_UID=$(id -u)
    LCTX_OWNER_GID=$(id -g)
    LCTX_OWNER_SOURCE='current-user'

    if (( EUID == 0 )) && [[ "${SUDO_UID:-}" =~ ^[0-9]+$ ]] && [[ "${SUDO_GID:-}" =~ ^[0-9]+$ ]] && (( SUDO_UID != 0 )); then
        LCTX_OWNER_UID="$SUDO_UID"
        LCTX_OWNER_GID="$SUDO_GID"
        LCTX_OWNER_SOURCE='sudo-invoker'
    elif (( EUID == 0 )) && [[ "${PKEXEC_UID:-}" =~ ^[0-9]+$ ]] && (( PKEXEC_UID != 0 )); then
        LCTX_OWNER_UID="$PKEXEC_UID"
        if command_exists getent; then
            LCTX_OWNER_GID=$(getent passwd "$PKEXEC_UID" 2>/dev/null | awk -F: 'NR==1{print $4}')
        fi
        [[ "$LCTX_OWNER_GID" =~ ^[0-9]+$ ]] || LCTX_OWNER_GID="$LCTX_OWNER_UID"
        LCTX_OWNER_SOURCE='pkexec-invoker'
    fi
    LCTX_OWNER_NAME=''
    LCTX_OWNER_HOME=''
    if command_exists getent; then
        local pw
        pw=$(getent passwd "$LCTX_OWNER_UID" 2>/dev/null | head -n1 || true)
        if [[ -n "$pw" ]]; then
            LCTX_OWNER_NAME=$(printf '%s' "$pw" | awk -F: '{print $1}')
            LCTX_OWNER_HOME=$(printf '%s' "$pw" | awk -F: '{print $6}')
        fi
    fi
    if [[ -z "$LCTX_OWNER_NAME" && "$LCTX_OWNER_UID" == "$(id -u)" ]]; then
        LCTX_OWNER_NAME=$(id -un 2>/dev/null || true)
        LCTX_OWNER_HOME=${HOME:-}
    fi
    LCTX_OWNER_RUNTIME_DIR=''
    [[ -d "/run/user/$LCTX_OWNER_UID" ]] && LCTX_OWNER_RUNTIME_DIR="/run/user/$LCTX_OWNER_UID"
    export LCTX_OWNER_UID LCTX_OWNER_GID LCTX_OWNER_SOURCE LCTX_OWNER_NAME LCTX_OWNER_HOME LCTX_OWNER_RUNTIME_DIR
}

run_as_output_owner() {
    # Execute a read-only probe in the invoking user's scope when the collector
    # itself is running under sudo. This is important for rootless containers,
    # user systemd services, per-user Flatpaks, and session-bus state.
    if (( EUID == 0 )) && [[ "${LCTX_OWNER_UID:-0}" =~ ^[0-9]+$ ]] && (( LCTX_OWNER_UID != 0 )); then
        local runtime=${LCTX_OWNER_RUNTIME_DIR:-}
        local home=${LCTX_OWNER_HOME:-/}
        local name=${LCTX_OWNER_NAME:-}
        local -a envv=(env -i
            "HOME=$home"
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            "LANG=C" "LC_ALL=C" "TZ=UTC")
        [[ -n "$name" ]] && envv+=("USER=$name" "LOGNAME=$name")
        if [[ -n "$runtime" ]]; then
            envv+=("XDG_RUNTIME_DIR=$runtime" "DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus")
        fi
        if command_exists runuser && [[ -n "$name" ]]; then
            runuser -u "$name" -- "${envv[@]}" "$@"
        elif command_exists setpriv; then
            setpriv --reuid "$LCTX_OWNER_UID" --regid "$LCTX_OWNER_GID" --init-groups "${envv[@]}" "$@"
        else
            return 69
        fi
    else
        "$@"
    fi
}
