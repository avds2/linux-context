#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='security.ssh'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='ssh security'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='SSH server effective configuration and configuration sources, excluding private host keys.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() { command_exists sshd || [[ -d /etc/ssh ]]; }

collector_collect() {
    if command_exists sshd; then
        run_capture sshd_effective "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- sshd -T || true
    fi
    capture_active_config_if_readable sshd_config /etc/ssh/sshd_config 524288 95 || true
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        run_shell_capture sshd_dropins "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" \
            'for f in /etc/ssh/sshd_config.d/*.conf; do [ -f "$f" ] || continue; echo "--- $f"; sed -E '"'"'/^[[:space:]]*(#|$)/d'"'"' "$f"; done' || true
    fi
    # Host-key fingerprints are persistent machine identifiers and add almost no
    # troubleshooting value. Retain only filename/key size/algorithm; private
    # keys and literal public-key fingerprints are never requested.
    if command_exists ssh-keygen && (( EUID == 0 )); then
        run_shell_capture host_key_inventory "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" \
            'for f in /etc/ssh/ssh_host_*_key.pub; do
                [ -f "$f" ] || continue
                line=$(ssh-keygen -lf "$f" 2>/dev/null) || continue
                set -- $line; bits=${1:-}; algo=${!#:-}; algo=${algo#(}; algo=${algo%)}
                printf "%s\t%s\t%s\n" "${f##*/}" "$bits" "$algo"
            done' || true
    fi
}
collector_main "$@"
