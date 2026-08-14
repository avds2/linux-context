#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='core.kernel'
COLLECTOR_MIN_PROFILE='standard'
COLLECTOR_TARGETS='system kernel'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=1
COLLECTOR_DESCRIPTION='Kernel identity, modules, taint, effective high-value sysctls, and source configuration.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    local release modules_tree present taint
    release=$(LC_ALL=C uname -r 2>/dev/null || true)
    if [[ -n "$release" ]]; then
        modules_tree="/usr/lib/modules/$release"
        [[ -d "$modules_tree" ]] && present=true || present=false
        emit_fact system.kernel.running_modules_tree_present "$present" "$modules_tree" observed 1.0 boolean
        if [[ "$present" == false ]]; then
            emit_fact system.kernel.reboot_recommended true "$modules_tree missing for running kernel" inferred 0.95 boolean
            record_collector_note 'Running kernel module tree is absent; the host may have upgraded its kernel since the last boot.'
        fi
    fi
    if [[ -r /proc/sys/kernel/tainted ]]; then
        taint=$(cat /proc/sys/kernel/tainted 2>/dev/null || true)
        [[ "$taint" =~ ^[0-9]+$ ]] && emit_fact system.kernel.taint_value "$taint" /proc/sys/kernel/tainted observed 1.0 number
    fi

    capture_file_if_readable kernel_cmdline /proc/cmdline 131072 100 || true
    capture_file_if_readable kernel_version /proc/version 131072 80 || true
    [[ -r /proc/modules ]] && run_capture modules "$LCTX_COMMAND_TIMEOUT" 524288 --priority 65 -- cat /proc/modules || true

    if profile_at_least deep; then
        [[ -d /usr/lib/modules ]] && run_shell_capture available_module_trees 5 131072 'find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort -V' || true
        # Strip comments/blank lines: source semantics matter; packaging commentary does not.
        run_shell_capture kernel_config_sources 10 524288 '
            for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /etc/modprobe.d/*.conf /usr/local/lib/modprobe.d/*.conf /etc/modules-load.d/*.conf /usr/local/lib/modules-load.d/*.conf; do
                [ -r "$f" ] || continue
                out=$(sed -E "s/[[:space:]]+#.*$//; /^[[:space:]]*(#|;|$)/d" "$f" 2>/dev/null || true)
                [ -n "$out" ] || continue
                echo "@@ $f"; printf "%s\n" "$out"
            done' || true
    fi

    if command_exists sysctl; then
        # Curated effective state is much higher signal/token than sysctl -a.
        run_shell_capture sysctl_selected "$LCTX_COMMAND_TIMEOUT" 262144 '
            keys="
              kernel.dmesg_restrict kernel.kptr_restrict kernel.unprivileged_bpf_disabled kernel.yama.ptrace_scope
              fs.protected_hardlinks fs.protected_symlinks fs.protected_fifos fs.protected_regular fs.inotify.max_user_watches
              vm.swappiness vm.overcommit_memory vm.max_map_count
              net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter
              net.ipv4.tcp_syncookies net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.send_redirects
              net.ipv6.conf.all.forwarding net.ipv6.conf.all.accept_redirects
            "
            for k in $keys; do sysctl "$k" 2>/dev/null || true; done' || true
        if profile_at_least max && { target_requested kernel || target_requested system; }; then
            # `sysctl -a` can return non-zero when one or more dynamic/procfs keys are
            # unreadable even while producing a complete, useful listing. The curated
            # selected-sysctl probe above remains the canonical health check; exhaustive
            # output is supporting evidence only, so individual key failures are ignored.
            run_capture sysctl_all 20 "$LCTX_COMMAND_MAX_BYTES" --source 'sysctl -a (individual unreadable keys tolerated)' --priority 25 -- bash -o pipefail -c 'sysctl -a 2>/dev/null || true' || true
        fi
    fi
}
collector_main "$@"
