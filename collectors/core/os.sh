#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='core.os'
COLLECTOR_MIN_PROFILE='quick'
COLLECTOR_TARGETS='system'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=1
COLLECTOR_DESCRIPTION='Distribution, locale, timezone, and basic OS release information.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

os_release_value() {
    local key="$1"
    awk -F= -v k="$key" '$1==k {v=substr($0,index($0,"=")+1); gsub(/^"|"$/,"",v); print v; exit}' /etc/os-release 2>/dev/null || true
}

collector_collect() {
    local value
    if [[ -r /etc/os-release ]]; then
        value=$(os_release_value PRETTY_NAME); [[ -n "$value" ]] && emit_fact system.os.pretty_name "$value" /etc/os-release
        value=$(os_release_value ID); [[ -n "$value" ]] && emit_fact system.os.id "$value" /etc/os-release
        value=$(os_release_value VERSION_ID); [[ -n "$value" ]] && emit_fact system.os.version_id "$value" /etc/os-release
        capture_file_if_readable os_release /etc/os-release || true
    fi
    [[ -r /etc/debian_version ]] && capture_file_if_readable debian_version /etc/debian_version 16384 || true
    [[ -r /etc/redhat-release ]] && capture_file_if_readable redhat_release /etc/redhat-release 16384 || true
    if command_exists localectl && LC_ALL=C localectl status >/dev/null 2>&1; then
        run_capture localectl "$LCTX_COMMAND_TIMEOUT" 262144 --priority 55 -- localectl status || true
    fi
    command_exists locale && run_capture locale "$LCTX_COMMAND_TIMEOUT" 262144 --priority 65 -- locale || true
    if command_exists timedatectl && LC_ALL=C timedatectl status >/dev/null 2>&1; then
        run_capture time "$LCTX_COMMAND_TIMEOUT" 262144 --priority 70 -- timedatectl status || true
    elif [[ -r /etc/timezone ]]; then
        capture_file_if_readable timezone /etc/timezone 16384 70 || true
    fi
}
collector_main "$@"
