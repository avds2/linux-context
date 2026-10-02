#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='security.posture'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='security'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='LSM/audit/account policy/sudo/PAM/service sandbox posture without password databases.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    [[ -r /sys/kernel/security/lsm ]] && capture_file_if_readable lsm /sys/kernel/security/lsm 16384 95 || true
    [[ -r /sys/kernel/security/lockdown ]] && capture_file_if_readable lockdown /sys/kernel/security/lockdown 16384 95 || true
    command_exists getenforce && run_capture selinux_getenforce 10 65536 --priority 90 -- getenforce || true
    command_exists sestatus && run_capture selinux_status 10 131072 --priority 90 -- sestatus || true
    local apparmor_enabled=''
    if [[ -r /sys/module/apparmor/parameters/enabled ]]; then
        IFS= read -r apparmor_enabled < /sys/module/apparmor/parameters/enabled || true
        case "$apparmor_enabled" in
            Y) emit_fact security.apparmor.active true /sys/module/apparmor/parameters/enabled observed 1.0 boolean ;;
            N) emit_fact security.apparmor.active false /sys/module/apparmor/parameters/enabled observed 1.0 boolean ;;
        esac
    fi
    if command_exists aa-status; then
        run_capture apparmor_status 10 262144 --priority 90 -- aa-status || true
    elif command_exists apparmor_status; then
        run_capture apparmor_status 10 262144 --priority 90 -- apparmor_status || true
    fi
    (( EUID == 0 )) && command_exists auditctl && run_capture audit_status 10 131072 --priority 85 -- auditctl -s || true

    # Account topology without password placeholders/GECOS comments. Names, IDs,
    # homes and shells are enough for permissions/service reasoning.
    run_shell_capture local_users 5 262144 'awk -F: '"'"'{print $1 ":" $3 ":" $4 ":" $6 ":" $7}'"'"' /etc/passwd 2>/dev/null || true' || true
    run_shell_capture local_groups 5 262144 'awk -F: '"'"'{print $1 ":" $3 ":" $4}'"'"' /etc/group 2>/dev/null || true' || true
    run_shell_capture login_defs 5 131072 'sed -E "/^[[:space:]]*(#|$)/d" /etc/login.defs 2>/dev/null || true' || true

    if (( EUID == 0 )); then
        run_shell_capture sudoers 10 262144 '
            for f in /etc/sudoers /etc/sudoers.d/*; do [ -r "$f" ] || continue; out=$(sed -E "/^[[:space:]]*(#|$)/d" "$f"); [ -n "$out" ] || continue; echo "@@ $f"; printf "%s\n" "$out"; done' || true
        [[ -d /etc/pam.d ]] && run_shell_capture pam_config 15 524288 '
            find /etc/pam.d -maxdepth 1 -type f -print | sort | while IFS= read -r f; do out=$(sed -E "/^[[:space:]]*(#|$)/d" "$f"); [ -n "$out" ] || continue; echo "@@ $f"; printf "%s\n" "$out"; done' || true
    fi
    # Per-unit systemd sandbox scoring can be surprisingly expensive on small
    # VPSes and duplicates much of the service model. Keep it for an explicit
    # security investigation, not broad automatic max.
    if profile_at_least max && target_requested security && [[ -d /run/systemd/system ]] && command_exists systemd-analyze && command_exists systemctl && bounded_command systemctl list-units --no-pager >/dev/null 2>&1; then
        run_capture systemd_security 25 786432 --priority 90 -- systemd-analyze security --no-pager || true
    fi
}
collector_main "$@"
