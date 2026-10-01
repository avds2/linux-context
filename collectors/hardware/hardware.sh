#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='hardware.inventory'
COLLECTOR_MIN_PROFILE='standard'
COLLECTOR_TARGETS='system hardware cpu gpu memory'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=1
COLLECTOR_DESCRIPTION='CPU, memory, PCI/USB devices, and safe block-device hardware inventory.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    local value
    if [[ -r /proc/cpuinfo ]]; then
        value=$(awk -F: '/^model name[[:space:]]*:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}' /proc/cpuinfo)
        [[ -n "$value" ]] && emit_fact hardware.cpu.model "$value" /proc/cpuinfo
        value=$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo || true)
        [[ "$value" =~ ^[0-9]+$ ]] && emit_fact hardware.cpu.logical_count "$value" /proc/cpuinfo observed 1.0 number
    fi
    if [[ -r /proc/meminfo ]]; then
        value=$(awk '/^MemTotal:/ {print $2*1024; exit}' /proc/meminfo)
        [[ "$value" =~ ^[0-9]+$ ]] && emit_fact hardware.memory.total_bytes "$value" /proc/meminfo observed 1.0 number
    fi

    { target_requested hardware || target_requested cpu; } && command_exists lscpu && run_capture cpu "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- lscpu || true
    { target_requested hardware || target_requested memory; } && command_exists free && run_capture memory "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- free -h || true
    { target_requested hardware || target_requested storage; } && command_exists lsblk && run_capture block_hardware "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- lsblk -e 7 -o NAME,KNAME,TYPE,SIZE,FSTYPE,FSVER,MOUNTPOINTS,RO,RM,ROTA,TRAN,MODEL || true
    command_exists lspci && run_capture pci "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- lspci -nnk || true
    command_exists lsusb && run_capture usb "$LCTX_COMMAND_TIMEOUT" "$LCTX_COMMAND_MAX_BYTES" -- lsusb || true

    # Sysfs DMI is available on many systems even when dmidecode is not installed.
    target_requested hardware && run_shell_capture firmware_identity 5 262144 '
        for f in sys_vendor product_name product_version board_vendor board_name board_version bios_vendor bios_version bios_date; do
            p="/sys/class/dmi/id/$f"; [ -r "$p" ] || continue; printf "%s=" "$f"; cat "$p"; done
        [ -r /sys/devices/system/cpu/cpu0/microcode/version ] && { printf "microcode="; cat /sys/devices/system/cpu/cpu0/microcode/version; } || true' || true

    if profile_at_least max; then
        command_exists nvidia-smi && run_capture nvidia_gpu 10 524288 -- nvidia-smi --query-gpu=name,driver_version,pstate,memory.total,memory.used,temperature.gpu,utilization.gpu --format=csv,noheader,nounits || true
        command_exists sensors && run_capture sensors 10 524288 -- sensors || true
    fi
    if target_requested hardware && (( EUID == 0 )) && profile_at_least deep && command_exists dmidecode; then
        # dmidecode includes unique Serial Number/UUID/Asset Tag fields by default.
        # Those add negligible diagnostic value and are intentionally excluded at
        # collection time. Keep model/topology/memory characteristics only.
        run_shell_capture dmi 15 "$LCTX_COMMAND_MAX_BYTES" '
            dmidecode -t system -t baseboard 2>/dev/null |
            awk "
              /^(System Information|Base Board Information|Memory Device)$/ {print; next}
              /^[[:space:]]+(Manufacturer|Product Name|Version|Family|Type|Size|Form Factor|Locator|Bank Locator|Type Detail|Speed|Configured Memory Speed|Part Number|Rank|Configured Voltage|Minimum Voltage|Maximum Voltage):/ {print}
            "' || true
    fi
}
collector_main "$@"
