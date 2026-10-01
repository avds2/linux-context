#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='services.scheduled'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='services scheduler cron scheduled'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Cron/anacron/at scheduler presence and job-file metadata without persisting arbitrary scheduled command bodies.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() {
    command_exists crontab || command_exists atq || command_exists anacron || \
        [[ -e /etc/crontab || -d /etc/cron.d || -d /var/spool/cron || -d /var/spool/cron/crontabs ]]
}

collector_collect() {
    local present=false
    command_exists crontab && present=true
    emit_fact scheduler.cron.cli_present "$present" 'command -v crontab' observed 1.0 boolean

    # Cron command bodies are shell code and can contain positional credentials.
    # Inventory ownership/mode/time/path instead of reading arbitrary job contents.
    run_capture cron_inventory 10 524288 --source 'cron file metadata (no contents)' -- \
        python3 -B -S "$COLLECTOR_LIB_DIR/file_inventory.py" --max-items "$LCTX_MAX_ITEMS" \
        /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/anacrontab || true

    if (( EUID == 0 )); then
        run_capture user_crontab_inventory 10 262144 --source 'user cron file metadata (no contents)' -- \
            python3 -B -S "$COLLECTOR_LIB_DIR/file_inventory.py" --max-items "$LCTX_MAX_ITEMS" /var/spool/cron /var/spool/cron/crontabs || true
    fi

    command_exists atq && run_capture at_queue 10 262144 -- atq || true
    command_exists anacron && run_capture anacron_version 10 131072 -- anacron -V || true
    record_collector_note 'Scheduled command bodies are deliberately not persisted because arbitrary shell arguments can carry credentials; systemd timer definitions are covered by services.systemd.'
}
collector_main "$@"
