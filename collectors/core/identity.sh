#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='core.identity'
COLLECTOR_MIN_PROFILE='quick'
COLLECTOR_TARGETS='system'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=1
COLLECTOR_DESCRIPTION='Host identity, architecture, uptime, and virtualization context.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    local value hostname_value
    hostname_value=$(host_name); [[ -n "$hostname_value" ]] && emit_fact system.hostname "$hostname_value" kernel-hostname
    value=$(LC_ALL=C uname -m 2>/dev/null || true); [[ -n "$value" ]] && emit_fact system.architecture "$value" 'uname -m'
    value=$(LC_ALL=C uname -r 2>/dev/null || true); [[ -n "$value" ]] && emit_fact system.kernel.release "$value" 'uname -r'

    if command_exists systemd-detect-virt; then
        value=$(bounded_command systemd-detect-virt 2>/dev/null || true)
        # Empty/failed detection is unknown, never proof of bare metal.
        if [[ -n "$value" ]]; then
            emit_fact system.virtualization.guest_type "$value" systemd-detect-virt
            emit_fact system.virtualization "$value" systemd-detect-virt
            if [[ "$value" == none ]]; then
                emit_fact system.virtualization.role bare_metal systemd-detect-virt inferred 0.95
            else
                emit_fact system.virtualization.role guest systemd-detect-virt inferred 1.0
            fi
        fi
    fi

    emit_entity host:local host "$hostname_value" core.identity
    run_capture uname_all "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- uname -a || true
    run_capture uptime "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- uptime || true
    if command_exists hostnamectl && bounded_command hostnamectl status >/dev/null 2>&1; then
        # Whitelist diagnostic identity fields. Raw hostnamectl includes stable
        # machine/product identifiers that are unnecessary for troubleshooting.
        run_shell_capture hostnamectl "$LCTX_COMMAND_TIMEOUT" 262144 '
            hostnamectl 2>/dev/null |
              grep -E "^[[:space:]]*(Static hostname|Icon name|Chassis|Operating System|Kernel|Architecture|Hardware Vendor|Hardware Model|Firmware Version|Firmware Date|Firmware Age):"
        ' || true
    fi
}
collector_main "$@"
