#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='storage.topology'
COLLECTOR_MIN_PROFILE='standard'
COLLECTOR_TARGETS='storage'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Filesystems, mounts, capacity, swap, LVM/RAID, ZFS, and Btrfs topology.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    local value
    if command_exists findmnt; then
        value=$(LC_ALL=C findmnt -n -o SOURCE / 2>/dev/null || true); [[ -n "$value" ]] && emit_fact storage.root.source "$value" 'findmnt /'
        value=$(LC_ALL=C findmnt -n -o FSTYPE / 2>/dev/null || true); [[ -n "$value" ]] && emit_fact storage.root.fstype "$value" 'findmnt /'
    fi
    if command_exists df; then
        value=$(LC_ALL=C df -B1 --output=size / 2>/dev/null | tail -n1 | tr -d ' ' || true)
        [[ "$value" =~ ^[0-9]+$ ]] && emit_fact storage.root.size_bytes "$value" 'df -B1 /' observed 1.0 number
        value=$(LC_ALL=C df -B1 --output=used / 2>/dev/null | tail -n1 | tr -d ' ' || true)
        [[ "$value" =~ ^[0-9]+$ ]] && emit_fact storage.root.used_bytes "$value" 'df -B1 /' observed 1.0 number
    fi

    command_exists df && run_capture filesystems "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- df -hT || true
    command_exists df && run_capture inodes "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- df -hi || true
    command_exists findmnt && run_capture mounts "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- findmnt -A -o TARGET,SOURCE,FSTYPE,OPTIONS || true
    capture_active_config_if_readable fstab /etc/fstab 524288 90 || true
    capture_active_config_if_readable crypttab /etc/crypttab 524288 85 || true
    capture_active_config_if_readable mdadm_conf /etc/mdadm.conf 524288 80 || capture_active_config_if_readable mdadm_conf /etc/mdadm/mdadm.conf 524288 80 || true
    command_exists swapon && run_capture swap "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- swapon --show --bytes || true
    command_exists pvs && run_capture lvm_pvs "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- pvs -a -o +devices || true
    command_exists vgs && run_capture lvm_vgs "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- vgs -a || true
    command_exists lvs && run_capture lvm_lvs "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- lvs -a -o +devices || true
    [[ -r /proc/mdstat ]] && capture_file_if_readable mdraid /proc/mdstat || true
    command_exists zpool && run_capture zpool "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- zpool status -v || true
    command_exists zfs && run_capture zfs "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- zfs list -o name,used,avail,refer,mountpoint || true
    command_exists btrfs && run_capture btrfs_filesystems "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- btrfs filesystem show || true
    if profile_at_least max && command_exists btrfs; then
        run_capture btrfs_usage "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- btrfs filesystem usage -T / || true
        run_capture btrfs_subvolumes "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- btrfs subvolume list -t / || true
    fi
}
collector_main "$@"
