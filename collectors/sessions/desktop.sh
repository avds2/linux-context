#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='sessions.desktop'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='sessions desktop workstation'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Login/session/seat topology without user environment variables or application payloads.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() { command_exists loginctl || command_exists who; }

collector_collect() {
    local sid uid user seat leader type state desktop remote
    if command_exists who && { ! command_exists loginctl || target_requested sessions || target_requested desktop || target_requested workstation; }; then
        # `who` appends remote SSH source addresses in parentheses. They describe
        # user activity, not host architecture, so strip them before persistence.
        run_shell_capture who "$LCTX_COMMAND_TIMEOUT" 131072 \
            'who 2>/dev/null | sed -E "s/[[:space:]]+\([^)]*\)[[:space:]]*$//"' || true
    fi
    if command_exists loginctl; then
        while read -r seat _; do
            [[ -n "${seat:-}" ]] || continue
            emit_entity "seat:$seat" seat "$seat" 'loginctl list-seats'
            emit_relation host:local has_seat "seat:$seat" 'loginctl list-seats'
        done < <(LC_ALL=C loginctl list-seats --no-legend --no-pager 2>/dev/null || true)

        while read -r sid uid user seat _; do
            [[ -n "${sid:-}" ]] || continue
            emit_entity "session:$sid" login_session "${user:-session-$sid}" 'loginctl list-sessions'
            emit_entity_attr "session:$sid" uid "${uid:-}" 'loginctl list-sessions'
            [[ -n "${user:-}" ]] && emit_entity_attr "session:$sid" user "$user" 'loginctl list-sessions'
            emit_relation host:local has_session "session:$sid" 'loginctl list-sessions'
            if [[ -n "${seat:-}" && "$seat" != '-' ]]; then
                emit_entity "seat:$seat" seat "$seat" 'loginctl list-sessions'
                emit_relation "session:$sid" uses_seat "seat:$seat" 'loginctl list-sessions'
            fi
            if profile_at_least max; then
                # Read only a compact allowlist of properties, one session at a time.
                while IFS='=' read -r key value; do
                    case "$key" in
                        Leader) [[ "$value" =~ ^[0-9]+$ ]] && { emit_entity_attr "session:$sid" leader_pid "$value" 'loginctl show-session' observed 1.0 number; emit_entity "process:$value" process "session-leader:$user" 'loginctl show-session'; emit_relation "session:$sid" has_leader "process:$value" 'loginctl show-session'; } ;;
                        Type) [[ -n "$value" ]] && emit_entity_attr "session:$sid" type "$value" 'loginctl show-session' ;;
                        State) [[ -n "$value" ]] && emit_entity_attr "session:$sid" state "$value" 'loginctl show-session' ;;
                        Desktop) [[ -n "$value" ]] && emit_entity_attr "session:$sid" desktop "$value" 'loginctl show-session' ;;
                        Remote) [[ -n "$value" ]] && emit_entity_attr "session:$sid" remote "$value" 'loginctl show-session' observed 1.0 boolean ;;
                    esac
                done < <(loginctl show-session "$sid" --no-pager -p Leader -p Type -p State -p Desktop -p Remote 2>/dev/null || true)
            fi
        done < <(LC_ALL=C loginctl list-sessions --no-legend --no-pager 2>/dev/null || true)
    fi
}
collector_main "$@"
