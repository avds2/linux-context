#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='network.manager'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='network wifi'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Network manager and current radio/link state without credentials, stable radio identifiers, saved-profile names, or active scans.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() { command_exists nmcli || command_exists iw || { command_exists networkctl && LC_ALL=C networkctl list --no-pager >/dev/null 2>&1; }; }

collector_collect() {
    local value focused=0
    { target_requested wifi || target_requested network; } && focused=1

    if command_exists nmcli; then
        emit_fact network.manager NetworkManager nmcli
        value=$(LC_ALL=C nmcli -t -f RUNNING general 2>/dev/null || true)
        [[ -n "$value" ]] && emit_fact network.manager.running "$value" 'nmcli general'
        run_capture nm_general "$LCTX_COMMAND_TIMEOUT" 131072 --priority 80 -- nmcli -f STATE,CONNECTIVITY,WIFI-HW,WIFI,WWAN-HW,WWAN general status || true
        # CONNECTION names are user-chosen privacy data and not needed to model
        # device state. UUIDs and secrets are never requested.
        run_capture nm_devices "$LCTX_COMMAND_TIMEOUT" 262144 --priority 90 -- nmcli -f DEVICE,TYPE,STATE device status || true
        run_shell_capture nm_device_details "$LCTX_COMMAND_TIMEOUT" 524288 \
            'nmcli -f GENERAL,IP4,IP6 device show 2>/dev/null | sed -E "/^GENERAL\.(CONNECTION|HWADDR|PERM-HWADDR):/d"' || true

        if (( focused )); then
            # Profile names/UUIDs/SSIDs are deliberately omitted. The AI needs
            # connection types, binding and policy—not the user's chosen names.
            run_capture nm_connections "$LCTX_COMMAND_TIMEOUT" 262144 --priority 70 -- \
                nmcli -f TYPE,DEVICE,AUTOCONNECT connection show || true
            # Cached list only; never force a radio scan, and do not retain SSIDs.
            run_capture wifi_cache "$LCTX_COMMAND_TIMEOUT" 262144 --priority 35 -- \
                nmcli -f IN-USE,MODE,CHAN,RATE,SIGNAL,SECURITY device wifi list --rescan no || true
        fi
    elif command_exists networkctl && LC_ALL=C networkctl list --no-pager >/dev/null 2>&1; then
        emit_fact network.manager systemd-networkd networkctl
        if command_exists systemctl; then
            value=$(LC_ALL=C systemctl is-active systemd-networkd.service 2>/dev/null || true)
            [[ -n "$value" ]] && emit_fact network.manager.running "$value" 'systemctl is-active systemd-networkd.service'
        fi
        run_capture networkctl_list "$LCTX_COMMAND_TIMEOUT" 262144 --priority 80 -- networkctl list --no-pager || true
        # status --all performs per-link queries and was >1.8s on the Debian
        # regression VPS. Canonical ip/networkctl-list/resolver state is enough
        # for broad max; retain the verbose effective view only when networking
        # is the actual investigation target.
        if (( focused )); then
            run_capture networkctl_status "$LCTX_COMMAND_TIMEOUT" 524288 --priority 80 -- networkctl status --all --no-pager || true
        fi
    fi

    # Identify the configuration framework without dumping potentially secret
    # Wi-Fi/WireGuard source files. Explicit network diagnostics can inspect
    # sanitized effective state; broad AI context only needs to know what owns
    # configuration and how many source units exist.
    local -a netplan_files=() networkd_files=()
    shopt -s nullglob
    netplan_files=(/etc/netplan/*.yaml /etc/netplan/*.yml)
    networkd_files=(/etc/systemd/network/*.network /etc/systemd/network/*.netdev /etc/systemd/network/*.link)
    shopt -u nullglob
    if (( ${#netplan_files[@]} )); then
        emit_fact network.config.framework netplan /etc/netplan
        emit_fact network.config.netplan_file_count "${#netplan_files[@]}" /etc/netplan observed 1.0 number
    elif (( ${#networkd_files[@]} )); then
        emit_fact network.config.framework systemd-networkd /etc/systemd/network
    fi
    (( ${#networkd_files[@]} )) && emit_fact network.config.networkd_unit_count "${#networkd_files[@]}" /etc/systemd/network observed 1.0 number

    if command_exists iw; then
        run_capture iw_dev "$LCTX_COMMAND_TIMEOUT" 262144 --priority 80 -- iw dev || true
        run_capture iw_reg "$LCTX_COMMAND_TIMEOUT" 131072 --priority 45 -- iw reg get || true
        if profile_at_least max && (( focused )); then
            # Link metrics are useful for focused Wi-Fi diagnosis; SSID names are not.
            run_shell_capture wifi_links "$LCTX_COMMAND_TIMEOUT" 262144 \
                'iw dev 2>/dev/null | sed -n "s/^[[:space:]]*Interface[[:space:]]\+//p" | while IFS= read -r i; do [ -n "$i" ] || continue; echo "@@ $i"; iw dev "$i" link 2>/dev/null | sed -E "/^[[:space:]]*SSID:/ s#(:).*#\\1 [OMITTED-WIFI-NAME]#" || true; done' || true
        fi
    fi
    command_exists rfkill && run_capture rfkill "$LCTX_COMMAND_TIMEOUT" 131072 --priority 60 -- rfkill list || true
}
collector_main "$@"
