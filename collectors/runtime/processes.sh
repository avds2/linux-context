#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='runtime.processes'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='runtime processes systemd docker containers'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Process/runtime pressure and hotspots without argv or environment values.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() { command_exists ps; }

collector_collect() {
    local value
    value=$(ps -e --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
    [[ "$value" =~ ^[0-9]+$ ]] && emit_fact runtime.process_count "$value" 'ps -e' observed 1.0 number

    if [[ -r /proc/loadavg ]]; then
        value=$(awk '{print $1}' /proc/loadavg 2>/dev/null || true)
        [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && emit_fact runtime.load_1m "$value" /proc/loadavg observed 1.0 number
        value=$(awk '{print $2}' /proc/loadavg 2>/dev/null || true)
        [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && emit_fact runtime.load_5m "$value" /proc/loadavg observed 1.0 number
        value=$(awk '{print $3}' /proc/loadavg 2>/dev/null || true)
        [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && emit_fact runtime.load_15m "$value" /proc/loadavg observed 1.0 number
    fi

    # Safe fields only. argv and /proc/*/environ are intentionally excluded.
    # Automatic max keeps a small hotspot view; explicit process/runtime targets
    # may request the complete safe table when investigating process topology.
    run_capture process_hotspots "$LCTX_COMMAND_TIMEOUT" 131072 --priority 85 -- \
        bash -o pipefail -c 'ps -e -o pid=,ppid=,uid=,stat=,etimes=,pcpu=,pmem=,rss=,comm=,cgroup= --sort=-pcpu,-pmem | head -n 80' || true
    run_capture process_name_counts "$LCTX_COMMAND_TIMEOUT" 65536 --priority 60 -- \
        bash -o pipefail -c 'ps -e -o comm= | LC_ALL=C sort | uniq -c | sort -nr | head -n 80' || true

    if target_requested processes || target_requested runtime; then
        run_capture processes "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" --priority 55 -- \
            ps -e -o pid=,ppid=,uid=,gid=,user=,stat=,ni=,etimes=,pcpu=,pmem=,rss=,vsz=,comm=,cgroup= --sort=pid || true
    fi

    if profile_at_least max; then
        [[ -r /proc/pressure/cpu ]] && capture_file_if_readable psi_cpu /proc/pressure/cpu 16384 90 || true
        [[ -r /proc/pressure/memory ]] && capture_file_if_readable psi_memory /proc/pressure/memory 16384 90 || true
        [[ -r /proc/pressure/io ]] && capture_file_if_readable psi_io /proc/pressure/io 16384 90 || true
    fi
}
collector_main "$@"
