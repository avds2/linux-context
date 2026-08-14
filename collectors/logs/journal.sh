#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='logs.journal'
COLLECTOR_MIN_PROFILE='max'
COLLECTOR_TARGETS='systemd logs'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Token-budgeted high-severity journal signatures, samples, boot history, and kernel warnings.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() { command_exists journalctl; }

collector_collect() {
    local sample_items="$LCTX_LOG_SAMPLE_ITEMS" signature_items="$LCTX_SIGNATURE_ITEMS" sample_bytes=262144 boot_items=20 value
    if target_requested logs; then
        sample_items=$(( sample_items * 5 ))
        signature_items=$(( signature_items * 2 ))
        (( sample_items > 2000 )) && sample_items=2000
        (( signature_items > 500 )) && signature_items=500
        sample_bytes=524288
        boot_items=100
    fi

    run_capture journal_disk_usage "$LCTX_COMMAND_TIMEOUT" 65536 --priority 40 -- journalctl --disk-usage || true
    # Boot IDs are random per-boot identifiers. The index and time range are the
    # diagnostic signal; the literal 128-bit IDs add fingerprinting surface.
    run_capture journal_boots "$LCTX_COMMAND_TIMEOUT" 65536 --ok-exit 0,1 --priority 50 \
        --source 'journalctl --list-boots (boot IDs omitted)' -- \
        bash -o pipefail -c '
            journalctl --list-boots -n "$1" --no-pager |
              sed -E "s/^([[:space:]]*-?[0-9]+)[[:space:]]+[0-9A-Fa-f]{32}[[:space:]]+/\\1\\t/"
        ' _ "$boot_items" || true

    # Acquire the high-severity stream once. Reuse that bounded sample for both
    # representative evidence and normalized issue signatures rather than reading
    # the journal multiple times and persisting a megabyte of repetitive errors.
    local -a journal_scope=(--system)
    target_requested logs && journal_scope=()
    if probe_capture high_priority_sample 20 "$sample_bytes" -- journalctl "${journal_scope[@]}" --reverse --since "$LCTX_LOG_SINCE" -p 0..4 -n "$sample_items" --no-pager -o short-iso; then
        value=$(wc -l < "$LCTX_PROBE_FILE" | tr -d ' ')
        [[ "$value" =~ ^[0-9]+$ ]] && emit_fact logs.journal.sampled_high_priority_entries "$value" "journalctl --since $LCTX_LOG_SINCE -p 0..4" observed 1.0 number

        # Raw journal messages can contain incidental user/application data.
        # Broad max keeps their normalized frequency signatures; verbatim
        # samples are retained only when logs are the explicit investigation
        # target.
        if target_requested logs; then
            run_capture recent_error_samples 5 "$sample_bytes" --source "journalctl sampled high-priority entries ($LCTX_LOG_SINCE)" --priority 85 -- cat "$LCTX_PROBE_FILE" || true
        fi
        run_capture issue_signatures 8 262144 --source 'normalized frequencies from sampled high-priority journal entries' --priority 100 -- \
            bash -o pipefail -c '
                sed -E \
                  -e "s/^[^ ]+[[:space:]]+[^ ]+[[:space:]]+//" \
                  -e "s/\\[[0-9]+\\]/[PID]/g" \
                  -e "s/0x[0-9A-Fa-f]+/0xHEX/g" \
                  -e "s/[0-9A-Fa-f]{24,}/<LONG_HEX>/g" \
                  -e "s/from ([0-9]{1,3}\.){3}[0-9]{1,3} port [0-9]+/from <REMOTE_IPV4> port <REMOTE_PORT>/g" \
                  -e "s/([0-9]{1,3}\.){3}[0-9]{1,3}/<IPV4>/g" \
                  -e "s/[[:space:]]+/ /g" "$1" |
                awk "NF {count[\$0]++} END {for (s in count) printf \"%8d\\t%s\\n\", count[s], s}" |
                sort -nr | head -n "$2"' _ "$LCTX_PROBE_FILE" "$signature_items" || true
    else
        record_collector_note 'high-priority journal sample could not be read.'
    fi
    release_probe

    run_capture kernel_warnings 15 "$sample_bytes" --priority 95 -- journalctl --reverse -k --since "$LCTX_LOG_SINCE" -p 0..4 -n "$sample_items" --no-pager -o short-iso || true
}
collector_main "$@"
