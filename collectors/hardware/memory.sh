#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='hardware.memory'
COLLECTOR_MIN_PROFILE='standard'
COLLECTOR_TARGETS='system hardware memory'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=1
COLLECTOR_DESCRIPTION='Typed RAM modules, firmware-reported slots/capacity/ECC, and explicit discovery gaps.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    local status='tool_missing' input=''
    if command_exists dmidecode; then
        status='access_or_firmware_unavailable'
        # Filter identifiers BEFORE persistence. Headers retain local DMI handles
        # for array/module links; serial numbers, UUIDs and asset tags are omitted.
        if run_shell_capture memory_dmi 15 "$LCTX_COMMAND_MAX_BYTES" '
            dmidecode --type 16,17 |
            awk '\''
              /^Handle 0x[0-9A-Fa-f]+, DMI type (16|17),/ { print; next }
              /^(Physical Memory Array|Memory Device)$/ { print; next }
              /^[[:space:]]+(Location|Use|Error Correction Type|Maximum Capacity|Number Of Devices|Array Handle|Size|Form Factor|Locator|Bank Locator|Type|Type Detail|Speed|Configured Memory Speed|Configured Clock Speed|Manufacturer|Part Number|Rank|Total Width|Data Width|Configured Voltage|Minimum Voltage|Maximum Voltage|Memory Technology):/ { print }
            '\'''; then
            if (( LCTX_CAPTURE_TRUNCATED == 0 )); then
                input="$LCTX_SECTION_DIR/memory_dmi.txt"
                status='no_records'
            else
                status='truncated'
            fi
        fi
    fi
    lctx_python "$COLLECTOR_LIB_DIR/hardware_model.py" memory "$input" "$status"
}
collector_main "$@"
