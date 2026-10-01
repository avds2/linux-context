#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='hardware.platform'
COLLECTOR_MIN_PROFILE='standard'
COLLECTOR_TARGETS='system hardware cpu gpu display power'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=1
COLLECTOR_DESCRIPTION='Typed CPU topology, firmware models, GPU drivers/VRAM, and battery capacity health.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    local cpu_file='' pci_file='' block_file=''
    if command_exists lscpu; then
        if probe_capture cpu_json 5 262144 -- lscpu --json; then
            (( LCTX_CAPTURE_TRUNCATED == 0 )) && cpu_file=$LCTX_PROBE_FILE
        fi
    fi
    if command_exists lspci; then
        if probe_capture pci_models 5 262144 -- lspci -Dmm -nn; then
            (( LCTX_CAPTURE_TRUNCATED == 0 )) && pci_file=$LCTX_PROBE_FILE
        fi
    fi
    if command_exists lsblk; then
        if probe_capture block_models 5 262144 -- lsblk --json --bytes -e 1,7 -o NAME,KNAME,TYPE,SIZE,RO,RM,ROTA,TRAN,MODEL; then
            (( LCTX_CAPTURE_TRUNCATED == 0 )) && block_file=$LCTX_PROBE_FILE
        fi
    fi
    # The helper reads only bounded allowlisted sysfs fields; no EDID, serials,
    # arbitrary device properties, or writes to power-management controls.
    local snapshot_file
    if probe_capture platform_snapshot 10 "$LCTX_COMMAND_MAX_BYTES" -- \
        python3 -B -S "$COLLECTOR_LIB_DIR/hardware_model.py" snapshot "$cpu_file" "$pci_file" "$block_file"; then
        snapshot_file=$LCTX_PROBE_FILE
        if (( LCTX_CAPTURE_TRUNCATED == 0 )); then
            lctx_python "$COLLECTOR_LIB_DIR/hardware_model.py" platform "$snapshot_file"
        else
            record_collector_note 'platform-snapshot-truncated'
        fi
    fi
    release_probe
    local file
    for file in "$cpu_file" "$pci_file" "$block_file"; do
        [[ -z "$file" ]] || rm -f -- "$file"
    done
}
collector_main "$@"
