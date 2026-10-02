#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='virtualization.host'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='virtualization kvm libvirt qemu'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='KVM/QEMU/libvirt capabilities and inventory, probing only reachable libvirt URIs.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() { [[ -e /dev/kvm ]] || command_exists virsh || command_exists qemu-system-x86_64 || command_exists qemu-kvm; }

collector_collect() {
    [[ -e /dev/kvm ]] && { emit_fact virtualization.kvm.device_present true /dev/kvm observed 1.0 boolean; emit_entity virtualization:kvm virtualization_host KVM /dev/kvm; emit_relation host:local supports virtualization:kvm /dev/kvm; } || emit_fact virtualization.kvm.device_present false /dev/kvm observed 1.0 boolean
    command_exists lsmod && run_shell_capture kvm_modules 5 131072 'lsmod | grep -E "^kvm(_|[[:space:]])" || true' || true
    if command_exists qemu-system-x86_64; then
        run_capture qemu_version 5 131072 --priority 55 -- qemu-system-x86_64 --version || true
    elif command_exists qemu-kvm; then
        run_capture qemu_version 5 131072 --priority 55 -- qemu-kvm --version || true
    fi

    if command_exists virsh; then
        local system_socket=0 session_socket=0 sock
        emit_fact virtualization.libvirt.client_present true virsh observed 1.0 boolean
        run_capture virsh_version 5 65536 --priority 45 -- virsh --version || true

        # Avoid multi-second connection attempts when only the virsh client is
        # installed. Modern libvirt may expose monolithic, proxy, or modular QEMU
        # sockets; any local socket is enough to justify an actual URI probe.
        for sock in /run/libvirt/libvirt-sock /run/libvirt/virtproxyd-sock /run/libvirt/virtqemud-sock /var/run/libvirt/libvirt-sock; do
            [[ -S "$sock" ]] && { system_socket=1; break; }
        done
        if (( system_socket )) && bounded_command virsh -c qemu:///system uri >/dev/null 2>&1; then
            emit_fact virtualization.libvirt.system_accessible true 'local libvirt socket + virsh qemu:///system' observed 1.0 boolean
            run_capture virtual_machines_system 10 262144 --priority 90 -- virsh -c qemu:///system list --all || true
            run_capture libvirt_networks_system 10 262144 --priority 75 -- virsh -c qemu:///system net-list --all || true
            run_capture libvirt_pools_system 10 262144 --priority 75 -- virsh -c qemu:///system pool-list --all || true
            profile_at_least max && run_capture libvirt_nodeinfo 10 131072 --priority 70 -- virsh -c qemu:///system nodeinfo || true
        else
            emit_fact virtualization.libvirt.system_accessible false 'local libvirt socket availability' observed 1.0 boolean
        fi

        if [[ -n "${LCTX_OWNER_RUNTIME_DIR:-}" ]]; then
            for sock in "$LCTX_OWNER_RUNTIME_DIR/libvirt/libvirt-sock" "$LCTX_OWNER_RUNTIME_DIR/libvirt/virtproxyd-sock" "$LCTX_OWNER_RUNTIME_DIR/libvirt/virtqemud-sock"; do
                [[ -S "$sock" ]] && { session_socket=1; break; }
            done
        fi
        if (( session_socket )) && run_as_output_owner virsh -c qemu:///session uri >/dev/null 2>&1; then
            emit_fact virtualization.libvirt.session_accessible true 'owner local libvirt socket + virsh qemu:///session' observed 1.0 boolean
            run_owner_capture virtual_machines_user 10 262144 --priority 90 -- virsh -c qemu:///session list --all || true
            run_owner_capture libvirt_networks_user 10 262144 --priority 75 -- virsh -c qemu:///session net-list --all || true
            run_owner_capture libvirt_pools_user 10 262144 --priority 75 -- virsh -c qemu:///session pool-list --all || true
        else
            emit_fact virtualization.libvirt.session_accessible false 'owner local libvirt socket availability' observed 1.0 boolean
        fi
    fi
}
collector_main "$@"
