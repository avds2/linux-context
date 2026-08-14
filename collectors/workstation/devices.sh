#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='workstation.devices'
COLLECTOR_MIN_PROFILE='max'
COLLECTOR_TARGETS='workstation desktop audio bluetooth display power'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Desktop hardware/session-adjacent state with personal device/application names omitted from broad automatic scans.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() {
    local d
    for d in /sys/class/drm/card*-*; do [[ -d "$d" ]] && return 0; done
    for d in /sys/class/power_supply/*; do [[ -d "$d" ]] && return 0; done
    command_exists wpctl || command_exists pactl || command_exists bluetoothctl
}

collector_collect() {
    local audio_focused=0 bluetooth_focused=0
    { target_requested audio || target_requested workstation || target_requested desktop; } && audio_focused=1
    { target_requested bluetooth || target_requested workstation; } && bluetooth_focused=1

    if [[ -d /sys/class/drm ]]; then
        run_shell_capture drm_connectors 10 524288 '
            for d in /sys/class/drm/card*-*; do
                [ -d "$d" ] || continue
                echo "@@ ${d##*/}"
                for f in status enabled modes; do
                    [ -r "$d/$f" ] || continue
                    printf "%s=" "$f"
                    if [ "$f" = modes ]; then head -n 50 "$d/$f" | paste -sd, -; else cat "$d/$f"; fi
                done
                printf "\n"
            done' || true
    fi

    # Presence of the session audio stack is machine state; the full graph can
    # expose application/client names, so retain it only for an explicit target.
    if command_exists wpctl; then
        emit_fact workstation.audio.control wpctl 'command -v wpctl'
        (( audio_focused )) && run_owner_capture pipewire_status 15 1048576 --priority 55 -- wpctl status || true
    elif command_exists pactl; then
        emit_fact workstation.audio.control pactl 'command -v pactl'
        if (( audio_focused )); then
            run_owner_capture pulse_info 10 262144 --priority 55 -- pactl info || true
            run_owner_capture pulse_sinks 10 524288 --priority 50 -- pactl list short sinks || true
            run_owner_capture pulse_sources 10 524288 --priority 50 -- pactl list short sources || true
            run_owner_capture pulse_cards 10 524288 --priority 50 -- pactl list short cards || true
        fi
    fi

    if command_exists bluetoothctl; then
        local bt_list bt_count=0
        emit_fact workstation.bluetooth.client_present true 'command -v bluetoothctl' observed 1.0 boolean
        bt_list=$(LC_ALL=C bluetoothctl list 2>/dev/null || true)
        if [[ -n "$bt_list" ]]; then
            while IFS= read -r _; do bt_count=$((bt_count+1)); done <<< "$bt_list"
        fi
        emit_fact workstation.bluetooth.controller_count "$bt_count" 'bluetoothctl list' observed 1.0 number
        # No controller is a normal state (for example bluez tools installed on a
        # desktop with Bluetooth disabled/absent), not an evidence failure.
        if (( bluetooth_focused && bt_count > 0 )); then
            run_capture bluetooth_controller 10 524288 --priority 65 -- bluetoothctl show || true
            run_capture bluetooth_devices 10 524288 --priority 45 -- bluetoothctl devices || true
            run_capture bluetooth_connected 10 524288 --priority 60 -- bluetoothctl devices Connected || true
        fi
    fi

    if [[ -d /sys/class/power_supply ]]; then
        run_shell_capture power_supplies 10 524288 '
            for d in /sys/class/power_supply/*; do
                [ -d "$d" ] || continue
                echo "@@ ${d##*/}"
                for f in type status capacity health technology cycle_count energy_now energy_full energy_full_design charge_now charge_full charge_full_design power_now current_now voltage_now online; do
                    [ -r "$d/$f" ] || continue
                    printf "%s=" "$f"; cat "$d/$f"
                done
                echo
            done' || true
    fi
}
collector_main "$@"
