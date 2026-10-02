#!/usr/bin/env bash

# Central bounded execution boundary. Evidence is first written to a private
# per-run staging directory (umask 077), then redacted in one batch before it is
# moved into the shareable bundle. This avoids one Python startup per artifact.

_rc_allowed() {
    local rc="$1" spec="${2:-0}" token
    IFS=',' read -ra _lctx_ok_rcs <<< "$spec"
    for token in "${_lctx_ok_rcs[@]}"; do [[ "$rc" == "$token" ]] && return 0; done
    return 1
}

_runner_record() {
    local out="$1"; shift
    printf '%s\0' "$@" >> "$out"
}

register_artifact() {
    local label="$1" kind="$2" source="$3" exit_code="$4" accepted="$5"
    local timeout_seconds="$6" max_bytes="$7" truncated="$8" bytes="$9" timed_out="${10}"
    local duration_ms="${11}" priority="${12:-50}"
    local id rel collector_safe
    id="${COLLECTOR_ID}:${label}"
    safe_name_into collector_safe "$COLLECTOR_ID"
    rel="sections/${collector_safe}/${label}.txt"
    _runner_record "$LCTX_ARTIFACTS_RECORDS" \
        "$id" "$COLLECTOR_ID" "$label" "$kind" "$rel" "$source" "$exit_code" \
        "$accepted" "$timed_out" "$truncated" "$timeout_seconds" "$max_bytes" "$bytes" \
        "$duration_ms" "$priority" '' 0
}

register_probe() {
    local label="$1" source="$2" exit_code="$3" accepted="$4" timed_out="$5" truncated="$6" bytes="$7" duration_ms="$8"
    [[ -n "${LCTX_PROBES_RECORDS:-}" ]] || return 0
    _runner_record "$LCTX_PROBES_RECORDS" \
        "$label" "$source" "$exit_code" "$accepted" "$timed_out" "$truncated" "$bytes" "$duration_ms"
}

shell_join_into() {
    local __dest="$1" __out='' __q __arg; shift
    for __arg in "$@"; do
        printf -v __q '%q' "$__arg"
        __out+="${__out:+ }$__q"
    done
    printf -v "$__dest" '%s' "$__out"
}

shell_join() {
    local __out
    shell_join_into __out "$@"
    printf '%s' "$__out"
}

# _bounded_capture OUT TIMEOUT MAX -- COMMAND...
# Captures at most MAX+1 bytes so truncation is observable and the producer is
# stopped early rather than allowed to generate unbounded output.

# Persistent artifact labels are unique within a collector. Reusing a label
# would overwrite evidence while leaving contradictory metadata, so reject it
# as a collector programming error before executing the second command.
declare -Ag LCTX_PERSISTENT_ARTIFACT_LABELS=()

_claim_artifact_label() {
    local label="$1"
    if [[ -n "${LCTX_PERSISTENT_ARTIFACT_LABELS[$label]+x}" ]]; then
        record_collector_note "duplicate-artifact-label:$label"
        return 70
    fi
    LCTX_PERSISTENT_ARTIFACT_LABELS[$label]=1
}
_bounded_capture() {
    local out="$1" timeout_seconds="$2" max_bytes="$3"; shift 3
    [[ "${1:-}" == -- ]] || return 64
    shift
    local cap=$(( max_bytes + 1 )) cmd_rc head_rc bytes truncated=0 timed_out=0 start_ms end_ms
    epoch_millis_into start_ms
    # Do not change the caller's errexit setting. The pipeline is conditional so
    # both statuses remain inspectable under set -e/pipefail.
    local -a pipeline_status=()
    if LC_ALL=C LANG=C TZ=UTC TERM=dumb lctx_timeout "$timeout_seconds" \
        "$@" </dev/null 2>&1 | head -c "$cap" > "$out"; then
        pipeline_status=("${PIPESTATUS[@]}")
    else
        pipeline_status=("${PIPESTATUS[@]}")
    fi
    cmd_rc=${pipeline_status[0]:-1}; head_rc=${pipeline_status[1]:-1}
    epoch_millis_into end_ms

    bytes=$(file_size_bytes "$out")
    if (( bytes > max_bytes )); then
        truncated=1
        head -c "$max_bytes" "$out" > "$out.trimmed"
        mv "$out.trimmed" "$out"
        bytes=$max_bytes
    fi
    # SIGPIPE is expected when our byte cap intentionally stops a producer.
    if (( cmd_rc == 141 && truncated == 1 )); then cmd_rc=0; fi
    # A failed sink is a collection failure too. `head` normally returns zero; a
    # non-zero status means evidence could not be bounded/written reliably.
    if (( head_rc != 0 && cmd_rc == 0 )); then cmd_rc=$head_rc; fi
    if (( cmd_rc == 124 || cmd_rc == 137 )); then timed_out=1; fi

    LCTX_CAPTURE_RC=$cmd_rc
    LCTX_CAPTURE_TRUNCATED=$truncated
    LCTX_CAPTURE_TIMED_OUT=$timed_out
    LCTX_CAPTURE_BYTES=$bytes
    LCTX_CAPTURE_DURATION_MS=$(( end_ms - start_ms ))
    export LCTX_CAPTURE_RC LCTX_CAPTURE_TRUNCATED LCTX_CAPTURE_TIMED_OUT LCTX_CAPTURE_BYTES LCTX_CAPTURE_DURATION_MS
    return 0
}

run_capture() {
    local label="$1"; shift
    local timeout_seconds="$1"; shift
    local max_bytes="$1"; shift
    local source_override='' priority=50 ok_exit='0'
    while [[ "${1:-}" != -- ]]; do
        case "${1:-}" in
            --source) source_override="${2:-}"; shift 2 ;;
            --priority) priority="${2:-50}"; shift 2 ;;
            --ok-exit) ok_exit="${2:-0}"; shift 2 ;;
            *) return 64 ;;
        esac
    done
    shift

    local name staged source accepted=0
    safe_name_into name "$label"
    _claim_artifact_label "$name" || return $?
    mkdir -p "$LCTX_SECTION_DIR"
    staged="$LCTX_SECTION_DIR/${name}.txt"
    if [[ -n "$source_override" ]]; then source=$source_override; else shell_join_into source "$@"; fi
    _bounded_capture "$staged" "$timeout_seconds" "$max_bytes" -- "$@"
    _rc_allowed "$LCTX_CAPTURE_RC" "$ok_exit" && accepted=1
    register_artifact "$name" command "$source" "$LCTX_CAPTURE_RC" "$accepted" "$timeout_seconds" "$max_bytes" \
        "$LCTX_CAPTURE_TRUNCATED" "$LCTX_CAPTURE_BYTES" "$LCTX_CAPTURE_TIMED_OUT" "$LCTX_CAPTURE_DURATION_MS" "$priority"

    if (( LCTX_CAPTURE_TIMED_OUT )); then
        record_collector_note "timeout:$label"
        return 124
    fi
    (( accepted )) && return 0
    return "$LCTX_CAPTURE_RC"
}

run_shell_capture() {
    local label="$1"; shift
    local timeout_seconds="$1"; shift
    local max_bytes="$1"; shift
    local script="$1"
    run_capture "$label" "$timeout_seconds" "$max_bytes" --source "shell:$label" -- bash -o pipefail -c "$script"
}

capture_file_if_readable() {
    local label="$1" path="$2" max_bytes="${3:-$LCTX_COMMAND_MAX_BYTES}" priority="${4:-50}"
    local name staged bytes truncated=0 start_ms end_ms rc=0 accepted=0
    [[ -r "$path" && -f "$path" ]] || return 1
    safe_name_into name "$label"
    _claim_artifact_label "$name" || return $?
    mkdir -p "$LCTX_SECTION_DIR"
    staged="$LCTX_SECTION_DIR/${name}.txt"
    epoch_millis_into start_ms
    if head -c "$((max_bytes+1))" -- "$path" > "$staged" 2>/dev/null; then rc=0; else rc=$?; fi
    epoch_millis_into end_ms
    (( rc == 0 )) && accepted=1
    bytes=$(file_size_bytes "$staged")
    # procfs/sysfs commonly report stat size zero despite readable content.
    # Observe the actual extra byte instead of trusting st_size.
    if (( bytes > max_bytes )); then
        truncated=1
        head -c "$max_bytes" "$staged" > "$staged.trimmed"
        mv -- "$staged.trimmed" "$staged"
        bytes=$max_bytes
    fi
    register_artifact "$name" file "$path" "$rc" "$accepted" 0 "$max_bytes" "$truncated" "$bytes" 0 "$((end_ms-start_ms))" "$priority"
    (( accepted )) || return "$rc"
}

# Capture only effective/source configuration lines. Distribution-shipped
# comments are documentation, not machine state; omitting them improves signal
# density and also avoids retaining example credentials from commented samples.
capture_active_config_if_readable() {
    local label="$1" path="$2" max_bytes="${3:-$LCTX_COMMAND_MAX_BYTES}" priority="${4:-70}"
    [[ -r "$path" && -f "$path" ]] || return 1
    run_capture "$label" "$LCTX_COMMAND_TIMEOUT" "$max_bytes" \
        --source "$path (active non-comment configuration)" --priority "$priority" -- \
        sed -E '/^[[:space:]]*(#|$)/d' -- "$path"
}

# Ephemeral bounded probe. The caller may parse $LCTX_PROBE_FILE, then call
# release_probe. Probe output never enters the shareable bundle.
probe_capture() {
    local label="$1"; shift
    local timeout_seconds="$1"; shift
    local max_bytes="$1"; shift
    local source_override='' ok_exit='0'
    while [[ "${1:-}" != -- ]]; do
        case "${1:-}" in
            --source) source_override="${2:-}"; shift 2 ;;
            --ok-exit) ok_exit="${2:-0}"; shift 2 ;;
            *) return 64 ;;
        esac
    done
    shift
    local source accepted=0
    LCTX_PROBE_FILE=$(mktemp "$LCTX_PRIVATE_TMP/probe.XXXXXX")
    if [[ -n "$source_override" ]]; then source=$source_override; else shell_join_into source "$@"; fi
    _bounded_capture "$LCTX_PROBE_FILE" "$timeout_seconds" "$max_bytes" -- "$@"
    _rc_allowed "$LCTX_CAPTURE_RC" "$ok_exit" && accepted=1
    register_probe "$label" "$source" "$LCTX_CAPTURE_RC" "$accepted" "$LCTX_CAPTURE_TIMED_OUT" \
        "$LCTX_CAPTURE_TRUNCATED" "$LCTX_CAPTURE_BYTES" "$LCTX_CAPTURE_DURATION_MS"
    export LCTX_PROBE_FILE
    (( accepted )) && return 0
    return "$LCTX_CAPTURE_RC"
}

release_probe() {
    [[ -n "${LCTX_PROBE_FILE:-}" && -f "$LCTX_PROBE_FILE" ]] && rm -f -- "$LCTX_PROBE_FILE"
    LCTX_PROBE_FILE=''
}

run_owner_capture() {
    local label="$1"; shift
    local timeout_seconds="$1"; shift
    local max_bytes="$1"; shift
    local -a opts=()
    while [[ "${1:-}" != -- ]]; do
        case "${1:-}" in
            --source|--priority|--ok-exit) opts+=("$1" "${2:-}"); shift 2 ;;
            *) return 64 ;;
        esac
    done
    shift

    if (( EUID == 0 )) && [[ "${LCTX_OWNER_UID:-0}" =~ ^[0-9]+$ ]] && (( LCTX_OWNER_UID != 0 )); then
        local runtime=${LCTX_OWNER_RUNTIME_DIR:-}
        local home=${LCTX_OWNER_HOME:-/}
        local name=${LCTX_OWNER_NAME:-}
        local -a envv=(env -i
            "HOME=$home"
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            "LANG=C" "LC_ALL=C" "TZ=UTC")
        [[ -n "$name" ]] && envv+=("USER=$name" "LOGNAME=$name")
        if [[ -n "$runtime" ]]; then envv+=("XDG_RUNTIME_DIR=$runtime" "DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus"); fi
        if command_exists runuser && [[ -n "$name" ]]; then
            run_capture "$label" "$timeout_seconds" "$max_bytes" "${opts[@]}" --source "owner:$label" -- runuser -u "$name" -- "${envv[@]}" "$@"
        elif command_exists setpriv; then
            run_capture "$label" "$timeout_seconds" "$max_bytes" "${opts[@]}" --source "owner:$label" -- setpriv --reuid "$LCTX_OWNER_UID" --regid "$LCTX_OWNER_GID" --init-groups "${envv[@]}" "$@"
        else
            run_capture "$label" "$timeout_seconds" "$max_bytes" "${opts[@]}" --source "owner:$label" -- \
                python3 -B -S "${BASH_SOURCE[0]%/*}/as_owner.py" "$LCTX_OWNER_UID" "$LCTX_OWNER_GID" "${envv[@]}" "$@"
        fi
    else
        run_capture "$label" "$timeout_seconds" "$max_bytes" "${opts[@]}" --source "owner:$label" -- "$@"
    fi
}

run_owner_shell_capture() {
    local label="$1"; shift
    local timeout_seconds="$1"; shift
    local max_bytes="$1"; shift
    local script="$1"
    run_owner_capture "$label" "$timeout_seconds" "$max_bytes" -- bash -o pipefail -c "$script"
}

probe_owner_capture() {
    local label="$1"; shift
    local timeout_seconds="$1"; shift
    local max_bytes="$1"; shift
    [[ "${1:-}" == -- ]] || return 64
    shift
    if (( EUID == 0 )) && [[ "${LCTX_OWNER_UID:-0}" =~ ^[0-9]+$ ]] && (( LCTX_OWNER_UID != 0 )); then
        local runtime=${LCTX_OWNER_RUNTIME_DIR:-}
        local home=${LCTX_OWNER_HOME:-/}
        local name=${LCTX_OWNER_NAME:-}
        local -a envv=(env -i "HOME=$home" "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "LANG=C" "LC_ALL=C" "TZ=UTC")
        [[ -n "$name" ]] && envv+=("USER=$name" "LOGNAME=$name")
        [[ -n "$runtime" ]] && envv+=("XDG_RUNTIME_DIR=$runtime" "DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus")
        if command_exists runuser && [[ -n "$name" ]]; then
            probe_capture "$label" "$timeout_seconds" "$max_bytes" --source "owner:$label" -- runuser -u "$name" -- "${envv[@]}" "$@"
        elif command_exists setpriv; then
            probe_capture "$label" "$timeout_seconds" "$max_bytes" --source "owner:$label" -- setpriv --reuid "$LCTX_OWNER_UID" --regid "$LCTX_OWNER_GID" --init-groups "${envv[@]}" "$@"
        else
            probe_capture "$label" "$timeout_seconds" "$max_bytes" --source "owner:$label" -- \
                python3 -B -S "${BASH_SOURCE[0]%/*}/as_owner.py" "$LCTX_OWNER_UID" "$LCTX_OWNER_GID" "${envv[@]}" "$@"
        fi
    else
        probe_capture "$label" "$timeout_seconds" "$max_bytes" --source "owner:$label" -- "$@"
    fi
}
