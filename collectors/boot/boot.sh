#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='boot.chain'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='boot firmware'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Boot mode, loader, secure-boot state, kernel/initramfs inventory, and boot source configuration.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    local mode loader line key value
    [[ -d /sys/firmware/efi ]] && mode=uefi || mode=bios; emit_fact boot.mode "$mode" /sys/firmware/efi
    loader=unknown
    [[ -r /boot/loader/loader.conf || -d /boot/loader/entries ]] && loader=systemd-boot
    [[ -r /boot/grub/grub.cfg || -r /etc/default/grub ]] && loader=grub
    emit_fact boot.loader "$loader" filesystem-detection inferred 0.9

    [[ -r /sys/firmware/efi/fw_platform_size ]] && capture_file_if_readable efi_platform_size /sys/firmware/efi/fw_platform_size 4096 70 || true
    if command_exists bootctl; then
        # bootctl status is useful but verbose and includes stable partition IDs
        # plus a non-secret field literally named "token", which is easy for a
        # generic secret filter to over-redact. Broad scans use it as an
        # ephemeral structured probe; an explicit boot target may retain the
        # sanitized raw status as supporting evidence.
        if probe_capture bootctl_status 15 262144 --ok-exit 0,1 -- bootctl status --no-pager; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                case "$line" in
                    *"Secure Boot:"*)
                        value=${line#*Secure Boot:}; value=$(normalize_one_line "$value")
                        [[ -n "$value" ]] && emit_fact boot.secure_boot_state "$value" 'bootctl status'
                        ;;
                    *"Setup Mode:"*)
                        value=${line#*Setup Mode:}; value=$(normalize_one_line "$value")
                        [[ -n "$value" ]] && emit_fact boot.setup_mode "$value" 'bootctl status'
                        ;;
                esac
            done < "$LCTX_PROBE_FILE"
            if target_requested boot || target_requested firmware; then
                run_capture bootctl_status 15 262144 --ok-exit 0,1 --priority 90 -- cat "$LCTX_PROBE_FILE" || true
            fi
        fi
        release_probe
    fi
    command_exists efibootmgr && [[ "$mode" == uefi ]] && run_capture efi_entries 15 262144 --priority 85 -- efibootmgr -v || true

    # mokutil returns non-zero on perfectly normal BIOS guests (and on some UEFI
    # environments where efivars are intentionally unavailable). Treat Secure
    # Boot as a structured capability/state, not a command-success test. Broad
    # BIOS scans do not run mokutil at all.
    if command_exists mokutil && [[ "$mode" == uefi ]]; then
        if probe_capture mokutil_secure_boot 10 131072 --ok-exit 0,1 -- mokutil --sb-state; then
            value=$(LC_ALL=C head -n1 "$LCTX_PROBE_FILE" 2>/dev/null || true)
            case "${value,,}" in
                *enabled*) emit_fact boot.secure_boot_state enabled 'mokutil --sb-state' ;;
                *disabled*) emit_fact boot.secure_boot_state disabled 'mokutil --sb-state' ;;
                *not\ supported*|*not\ available*) record_collector_note 'Secure Boot state unavailable through EFI variables.' ;;
            esac
            if target_requested boot || target_requested firmware; then
                run_capture secure_boot 5 131072 --ok-exit 0,1 --source 'mokutil --sb-state' --priority 95 -- cat "$LCTX_PROBE_FILE" || true
            fi
        fi
        release_probe
    fi

    capture_active_config_if_readable grub_defaults /etc/default/grub 131072 80 || true
    capture_file_if_readable kernel_cmdline /etc/kernel/cmdline 65536 90 || true
    capture_file_if_readable kernel_install /etc/kernel/install.conf 65536 60 || true
    run_shell_capture initramfs_config 8 131072 '
        for f in /etc/mkinitcpio.conf /etc/dracut.conf; do [ -r "$f" ] || continue; echo "@@ $f"; sed -E "/^[[:space:]]*(#|$)/d" "$f"; done' || true

    if profile_at_least max; then
        # The generated GRUB program is mostly duplicate/derived data. Keep it
        # only for a boot-focused investigation; broad max already captures the
        # source defaults, kernel command line and compact boot inventory.
        if target_requested boot || target_requested firmware; then
            [[ -r /boot/grub/grub.cfg ]] && capture_file_if_readable grub_cfg /boot/grub/grub.cfg 524288 75 || true
        fi
        # Avoid GRUB modules/locales and other irrelevant boot-tree bulk.
        run_capture boot_inventory 10 262144 --source 'boot file metadata (same filesystem, no contents)' -- \
            python3 -B -S "$COLLECTOR_LIB_DIR/file_inventory.py" --depth 4 --boot --max-items "$LCTX_MAX_ITEMS" /boot /boot/efi /efi || true
    fi
}
collector_main "$@"
