#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='core.os'
COLLECTOR_MIN_PROFILE='quick'
COLLECTOR_TARGETS='system'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=1
COLLECTOR_DESCRIPTION='Distribution, locale, timezone, and basic OS release information.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    local value key release_file='' init_name='' init_exe=''
    if [[ -r /etc/os-release ]]; then release_file=/etc/os-release
    elif [[ -r /usr/lib/os-release ]]; then release_file=/usr/lib/os-release; fi
    if [[ -n "$release_file" ]]; then
        while IFS= read -r -d '' key && IFS= read -r -d '' value; do
            emit_fact "system.os.$key" "$value" "$release_file"
        done < <(lctx_python "$COLLECTOR_LIB_DIR/os_release.py" "$release_file")
        capture_file_if_readable os_release "$release_file" || true
    fi
    if [[ -r /proc/1/comm ]]; then IFS= read -r init_name < /proc/1/comm || true; fi
    [[ -n "$init_name" ]] && emit_fact init.pid1.name "$init_name" /proc/1/comm
    init_exe=$(readlink /proc/1/exe 2>/dev/null || true)
    [[ -n "$init_exe" ]] && emit_fact init.pid1.executable "$init_exe" /proc/1/exe
    case "$init_name" in
        systemd|runit|s6-svscan|dinit) emit_fact init.system "$init_name" /proc/1/comm ;;
        *) [[ -d /run/openrc ]] && emit_fact init.system openrc /run/openrc inferred 0.95 || true ;;
    esac
    [[ -r /etc/debian_version ]] && capture_file_if_readable debian_version /etc/debian_version 16384 || true
    [[ -r /etc/redhat-release ]] && capture_file_if_readable redhat_release /etc/redhat-release 16384 || true
    if command_exists localectl && probe_capture locale_state 3 262144 -- localectl status; then
        run_capture localectl 3 262144 --source 'localectl status' --priority 55 -- cat "$LCTX_PROBE_FILE" || true
    fi
    release_probe
    command_exists locale && run_capture locale "$LCTX_COMMAND_TIMEOUT" 262144 --priority 65 -- locale || true
    if command_exists timedatectl && probe_capture time_state 3 262144 -- timedatectl status; then
        run_capture time 3 262144 --source 'timedatectl status' --priority 70 -- cat "$LCTX_PROBE_FILE" || true
    elif [[ -r /etc/timezone ]]; then
        capture_file_if_readable timezone /etc/timezone 16384 70 || true
    fi
    release_probe
}
collector_main "$@"
