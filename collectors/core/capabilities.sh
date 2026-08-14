#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='core.capabilities'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='system'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=1
COLLECTOR_DESCRIPTION='Probe/tool availability inventory so an AI can distinguish absent technology from unavailable inspection capability.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    local cmd present
    local commands='systemctl journalctl ip ss nft iptables-save nmcli networkctl iw rfkill docker podman containerd nerdctl lscpu lsblk lspci lsusb dmidecode smartctl nvme btrfs zpool zfs pvs vgs lvs cryptsetup dmsetup bootctl efibootmgr mokutil grub-install mkinitcpio dracut virsh qemu-system-x86_64 getenforce sestatus aa-status auditctl systemd-analyze sensors nvidia-smi apachectl apache2ctl httpd nginx caddy haproxy wg tailscale zerotier-cli wpctl pactl bluetoothctl flatpak firewall-cmd ufw crontab atq runuser setpriv'
    # Capability booleans are already canonical structured state; persisting a
    # second command/path table only duplicates tokens. Exact binary paths are
    # rarely diagnostic and can be recovered from package state when needed.
    for cmd in $commands; do
        if command_exists "$cmd"; then present=true; else present=false; fi
        emit_fact "capability.command.$cmd" "$present" 'command -v' observed 1.0 boolean
    done
}
collector_main "$@"
