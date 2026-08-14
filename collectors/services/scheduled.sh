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
    run_shell_capture cron_inventory 10 524288 '
        for p in /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/anacrontab; do
            [ -e "$p" ] || continue
            if [ -f "$p" ]; then
                stat -c "%A\t%U\t%G\t%s\t%y\t%n" -- "$p" 2>/dev/null || true
            elif [ -d "$p" ]; then
                find "$p" -maxdepth 1 -type f -printf "%M\t%u\t%g\t%s\t%TY-%Tm-%TdT%TH:%TM:%TS\t%p\n" 2>/dev/null | LC_ALL=C sort
            fi
        done' || true

    if (( EUID == 0 )); then
        run_shell_capture user_crontab_inventory 10 262144 '
            for d in /var/spool/cron /var/spool/cron/crontabs; do
                [ -d "$d" ] || continue
                find "$d" -maxdepth 1 -type f -printf "%M\t%u\t%g\t%s\t%TY-%Tm-%TdT%TH:%TM:%TS\t%p\n" 2>/dev/null | LC_ALL=C sort
            done' || true
    fi

    command_exists atq && run_capture at_queue 10 262144 -- atq || true
    command_exists anacron && run_capture anacron_version 10 131072 -- anacron -V || true
    record_collector_note 'Scheduled command bodies are deliberately not persisted because arbitrary shell arguments can carry credentials; systemd timer definitions are covered by services.systemd.'
}
collector_main "$@"
