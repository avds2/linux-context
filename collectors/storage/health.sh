#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='storage.health'
COLLECTOR_MIN_PROFILE='max'
COLLECTOR_TARGETS='storage health'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='SMART/NVMe/filesystem health without waking sleeping media or exposing unique hardware identifiers.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() { command_exists smartctl || command_exists nvme || command_exists btrfs || command_exists dmsetup || command_exists cryptsetup; }

collector_collect() {
    local count=0 line before_comment dev opt dtype sid qdev qdtype rc
    local smart_health_rcs='0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60,64,68,72,76,80,84,88,92,96,100,104,108,112,116,120,124,128,132,136,140,144,148,152,156,160,164,168,172,176,180,184,188,192,196,200,204,208,212,216,220,224,228,232,236,240,244,248,252'
    if command_exists smartctl; then
        if probe_capture smart_scan 10 262144 -- smartctl --scan; then
            run_capture smart_scan 5 262144 --source 'smartctl --scan' --priority 65 -- cat "$LCTX_PROBE_FILE" || true
            if (( EUID == 0 )); then
                while IFS= read -r line; do
                    before_comment=${line%%#*}; read -r dev opt dtype _ <<< "$before_comment"
                    [[ "$dev" == /dev/* ]] || continue
                    count=$((count+1)); (( count <= LCTX_MAX_ITEMS )) || break
                    sid=$(safe_name "$dev"); emit_entity "block:$dev" block_device "$dev" 'smartctl --scan'
                    printf -v qdev '%q' "$dev"; qdtype=''
                    if [[ "$opt" == '-d' && "$dtype" =~ ^[A-Za-z0-9_,.+:-]+$ ]]; then printf -v qdtype '%q' "$dtype"; fi
                    if [[ -n "$qdtype" ]]; then
                        run_capture "smart_${sid}" 20 524288 --ok-exit "$smart_health_rcs" --priority 100 --source "smartctl health $dev type=$dtype" -- \
                            bash -o pipefail -c "smartctl -x -n standby,0 -d $qdtype $qdev 2>&1 | sed -E '/^[[:space:]]*(Serial [Nn]umber|LU WWN Device Id|Logical Unit id|World Wide Name|WWN):/ s#(:).*#\\1 [OMITTED-UNIQUE-ID]#'" || true
                    else
                        run_capture "smart_${sid}" 20 524288 --ok-exit "$smart_health_rcs" --priority 100 --source "smartctl health $dev" -- \
                            bash -o pipefail -c "smartctl -x -n standby,0 $qdev 2>&1 | sed -E '/^[[:space:]]*(Serial [Nn]umber|LU WWN Device Id|Logical Unit id|World Wide Name|WWN):/ s#(:).*#\\1 [OMITTED-UNIQUE-ID]#'" || true
                    fi
                    rc=${LCTX_CAPTURE_RC:-0}
                    (( rc >= 8 )) && emit_entity_attr "block:$dev" smart_health_status_bits "$rc" smartctl observed 1.0 number
                done < "$LCTX_PROBE_FILE"
            else
                record_collector_note 'SMART detail requires root on many devices; scan inventory only.'
            fi
        fi
        release_probe
        emit_fact storage.smart.scanned_devices "$count" 'smartctl --scan' observed 1.0 number
    fi

    if command_exists nvme; then
        run_shell_capture nvme_devices 5 131072 'for d in /dev/nvme[0-9]; do [ -e "$d" ] && echo "$d"; done' || true
        if (( EUID == 0 )); then
            run_shell_capture nvme_health 20 786432 'for d in /dev/nvme[0-9]; do [ -e "$d" ] || continue; echo "@@ $d"; nvme smart-log "$d" 2>/dev/null || true; done' || true
        fi
    fi
    if command_exists btrfs && findmnt -n -t btrfs / >/dev/null 2>&1; then
        run_capture btrfs_device_stats 15 262144 --priority 100 -- btrfs device stats / || true
        run_capture btrfs_scrub_status 15 262144 --priority 90 -- btrfs scrub status / || true
        run_capture btrfs_balance_status 15 131072 --priority 75 -- btrfs balance status / || true
        run_capture btrfs_filesystem_df 15 262144 --priority 80 -- btrfs filesystem df / || true
    fi
    command_exists dmsetup && run_capture device_mapper 10 262144 --priority 75 -- dmsetup ls --tree || true
    command_exists cryptsetup && [[ -d /dev/mapper ]] && run_shell_capture luks_mappings 15 262144 'for d in /dev/mapper/*; do [ -e "$d" ] || continue; n=${d##*/}; [ "$n" = control ] && continue; cryptsetup status "$n" 2>/dev/null && echo || true; done' || true
}
collector_main "$@"
