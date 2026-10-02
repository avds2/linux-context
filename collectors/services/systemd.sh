#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='services.systemd'
COLLECTOR_MIN_PROFILE='standard'
COLLECTOR_TARGETS='systemd services docker containers web'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Compact effective systemd state: active/enabled/failed/custom units are canonical; exhaustive unit detail is target-only.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() {
    # Installed clients/wrapper scripts do not prove this PID namespace runs a
    # systemd manager. In containers they can even return success with prose.
    [[ -d /run/systemd/system ]] || return 1
    command_exists systemctl && bounded_command systemctl list-units --no-legend --no-pager >/dev/null 2>&1
}

_systemd_explicit() { target_requested systemd || target_requested services; }

_emit_service_block() {
    local prefix="$1" entity_type="$2" run_predicate="$3" source="$4" scope="$5"
    local id='' description='' load='' active='' sub='' unit_file='' fragment='' dropins=''
    local main_pid='' cgroup='' result='' restart='' memory='' tasks='' cpu=''
    local line key value eid count=0 total=0 active_count=0 enabled_count=0 relevant_count=0 custom=false keep=false exhaustive=false
    _systemd_explicit && exhaustive=true || true

    _reset_service() {
        id=''; description=''; load=''; active=''; sub=''; unit_file=''; fragment=''; dropins=''
        main_pid=''; cgroup=''; result=''; restart=''; memory=''; tasks=''; cpu=''
    }

    _flush_service() {
        [[ -n "$id" ]] || return 0
        total=$((total+1))
        if [[ "$active" == active ]]; then active_count=$((active_count+1)); fi
        case "$unit_file" in enabled|enabled-runtime|linked|linked-runtime) enabled_count=$((enabled_count+1));; esac
        custom=false
        if [[ "$fragment" == /etc/systemd/* || "$fragment" == /usr/local/* ]]; then custom=true; fi
        if [[ "$scope" == user && -n "${LCTX_OWNER_HOME:-}" && "$fragment" == "$LCTX_OWNER_HOME/.config/systemd/user/"* ]]; then custom=true; fi

        # Broad auto scans model services that define the current machine:
        # active, enabled/masked, failed/non-success, overridden or locally
        # authored. Inactive static vendor units are inventory noise. An explicit
        # systemd/services target deliberately switches to exhaustive unit state.
        keep=$exhaustive
        # System services define host behavior, so active units are useful in a
        # broad scan. User managers are different: a desktop session can spawn
        # dozens of transient/vendor helpers whose individual graph nodes add a
        # lot of context but very little machine understanding. In broad max,
        # user-scope canonical state is therefore limited to persistent,
        # overridden/custom or unhealthy services. Counts still describe the
        # complete user manager. Explicit --target systemd/services remains
        # exhaustive.
        # Long-running/transitioning active services define current behavior.
        # Static one-shot units that are merely "active (exited)" are boot-history
        # noise unless they are enabled/custom/overridden (handled below).
        if [[ "$scope" == system && "$active" == active && "$sub" != exited ]]; then keep=true; fi
        if [[ "$active" == failed ]]; then keep=true; fi
        if [[ -n "$result" && "$result" != success ]]; then keep=true; fi
        case "$unit_file" in enabled|enabled-runtime|linked|linked-runtime|masked|masked-runtime) keep=true;; esac
        if [[ -n "$dropins" || "$custom" == true ]]; then keep=true; fi
        if [[ "$keep" != true ]]; then _reset_service; return 0; fi

        count=$((count+1)); relevant_count=$((relevant_count+1))
        if (( count > LCTX_MAX_ITEMS )); then _reset_service; return 0; fi
        eid="${prefix}${id}"
        emit_entity "$eid" "$entity_type" "$id" "$source"
        if [[ -n "$description" && "$exhaustive" == true ]]; then emit_entity_attr "$eid" description "$description" "$source"; fi
        if [[ -n "$load" && "$load" != loaded ]]; then emit_entity_attr "$eid" load_state "$load" "$source"; fi
        if [[ -n "$active" ]]; then emit_entity_attr "$eid" active_state "$active" "$source"; fi
        if [[ -n "$sub" ]]; then emit_entity_attr "$eid" sub_state "$sub" "$source"; fi
        if [[ -n "$unit_file" && "$unit_file" != static ]]; then emit_entity_attr "$eid" unit_file_state "$unit_file" "$source"; fi
        if [[ "$exhaustive" == true || "$custom" == true || -n "$dropins" ]]; then
            if [[ -n "$fragment" ]]; then emit_entity_attr "$eid" fragment_path "$fragment" "$source"; fi
            if [[ -n "$dropins" ]]; then emit_entity_attr "$eid" dropins "$dropins" "$source"; fi
        fi
        if [[ -n "$result" && "$result" != success ]]; then emit_entity_attr "$eid" result "$result" "$source"; fi
        if [[ -n "$restart" && "$restart" != no ]]; then emit_entity_attr "$eid" restart "$restart" "$source"; fi
        if [[ "$main_pid" =~ ^[0-9]+$ ]] && (( main_pid > 0 )); then
            emit_entity "process:$main_pid" process "$id" "$source"
            emit_relation "$eid" has_main_process "process:$main_pid" "$source"
            # Executable path is high-value topology without argv/environment risk.
            local exe_path=''
            exe_path=$(readlink -e "/proc/$main_pid/exe" 2>/dev/null || true)
            if [[ -n "$exe_path" ]]; then emit_entity_attr "$eid" executable_path "$exe_path" '/proc/PID/exe'; fi
        fi
        # Cgroup paths are long, volatile and largely redundant with the
        # service->process relation. Keep them only for an explicit systemd
        # investigation where cgroup placement itself is diagnostically useful.
        if [[ "$exhaustive" == true && "$active" == active && -n "$cgroup" ]]; then
            emit_entity_attr "$eid" control_group "$cgroup" "$source"
        fi
        if [[ "$active" == active ]]; then
            emit_relation host:local "$run_predicate" "$eid" "$source"
            # Per-service counters are volatile and high-cardinality. Keep them
            # only when systemd itself is the investigation target.
            if [[ "$exhaustive" == true ]]; then
                if [[ "$memory" =~ ^[0-9]+$ ]]; then emit_entity_attr "$eid" memory_current "$memory" "$source" observed 1.0 number; fi
                if [[ "$tasks" =~ ^[0-9]+$ ]]; then emit_entity_attr "$eid" tasks_current "$tasks" "$source" observed 1.0 number; fi
                if [[ "$cpu" =~ ^[0-9]+$ ]]; then emit_entity_attr "$eid" cpu_usage_nsec "$cpu" "$source" observed 1.0 number; fi
            fi
        fi
        _reset_service
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then _flush_service; continue; fi
        key=${line%%=*}; value=${line#*=}
        case "$key" in
            Id) id=$value ;; Description) description=$value ;; LoadState) load=$value ;;
            ActiveState) active=$value ;; SubState) sub=$value ;; UnitFileState) unit_file=$value ;;
            FragmentPath) fragment=$value ;; DropInPaths) dropins=$value ;; MainPID) main_pid=$value ;;
            ControlGroup) cgroup=$value ;; Result) result=$value ;; Restart) restart=$value ;;
            MemoryCurrent) memory=$value ;; TasksCurrent) tasks=$value ;; CPUUsageNSec) cpu=$value ;;
        esac
    done
    _flush_service
    emit_fact "systemd.${scope}.service_count" "$total" "$source" observed 1.0 number
    emit_fact "systemd.${scope}.active_service_count" "$active_count" "$source" observed 1.0 number
    emit_fact "systemd.${scope}.enabled_service_count" "$enabled_count" "$source" observed 1.0 number
    emit_fact "systemd.${scope}.modeled_service_count" "$((count < LCTX_MAX_ITEMS ? count : LCTX_MAX_ITEMS))" "$source" observed 1.0 number
    emit_fact "systemd.${scope}.relevant_service_count" "$relevant_count" "$source" observed 1.0 number
    if [[ "$scope" == user && "$exhaustive" != true && "$relevant_count" -lt "$total" ]]; then
        record_collector_note 'Broad max summarizes transient/vendor user services by counts; explicit --target systemd/services models the full user manager.'
    fi
    (( count > LCTX_MAX_ITEMS )) && record_collector_note "service entity limit reached: $LCTX_MAX_ITEMS"
    unset -f _flush_service _reset_service
}

_collect_system_services() {
    if probe_capture system_service_state 25 "$LCTX_COMMAND_MAX_BYTES" -- systemctl show --type=service --all --no-pager \
        -p Id -p Description -p LoadState -p ActiveState -p SubState -p UnitFileState \
        -p FragmentPath -p DropInPaths -p MainPID -p ControlGroup -p Result -p Restart \
        -p MemoryCurrent -p TasksCurrent -p CPUUsageNSec; then
        if (( LCTX_CAPTURE_TRUNCATED )); then
            emit_fact systemd.system.inventory_limited true 'systemctl show --type=service' observed 1.0 boolean
            record_collector_note 'Service inventory was truncated; observed counts are lower bounds.'
        fi
        _emit_service_block 'systemd-unit:' service runs 'systemctl show --type=service' system < "$LCTX_PROBE_FILE"
        release_probe
        return 0
    fi
    release_probe
    record_collector_note 'bulk systemctl show failed; falling back to list-units state only.'
    local unit load active sub total=0 active_count=0
    while read -r unit load active sub _; do
        [[ -n "${unit:-}" ]] || continue
        total=$((total+1)); if [[ "$active" == active ]]; then active_count=$((active_count+1)); fi
        (( total <= LCTX_MAX_ITEMS )) || continue
        emit_entity "systemd-unit:$unit" service "$unit" 'systemctl list-units --type=service'
        if [[ "$load" != loaded ]]; then emit_entity_attr "systemd-unit:$unit" load_state "$load" 'systemctl list-units --type=service'; fi
        emit_entity_attr "systemd-unit:$unit" active_state "$active" 'systemctl list-units --type=service'
        emit_entity_attr "systemd-unit:$unit" sub_state "$sub" 'systemctl list-units --type=service'
        if [[ "$active" == active ]]; then emit_relation host:local runs "systemd-unit:$unit" 'systemctl list-units --type=service'; fi
    done < <(bounded_command systemctl list-units --type=service --all --no-legend --plain 2>/dev/null || true)
    emit_fact systemd.system.service_count "$total" 'systemctl list-units --type=service' observed 1.0 number
    emit_fact systemd.system.active_service_count "$active_count" 'systemctl list-units --type=service' observed 1.0 number
    (( total > LCTX_MAX_ITEMS )) && record_collector_note "fallback service entity limit reached: $LCTX_MAX_ITEMS"
    return 0
}

_collect_user_services() {
    if probe_owner_capture user_service_state 20 "$LCTX_COMMAND_MAX_BYTES" -- systemctl --user show --type=service --all --no-pager \
        -p Id -p Description -p LoadState -p ActiveState -p SubState -p UnitFileState \
        -p FragmentPath -p DropInPaths -p MainPID -p ControlGroup -p Result -p Restart \
        -p MemoryCurrent -p TasksCurrent -p CPUUsageNSec; then
        _emit_service_block 'user-systemd-unit:' user_service runs_user_service 'systemctl --user show --type=service' user < "$LCTX_PROBE_FILE"
        release_probe
        return 0
    fi
    release_probe
    record_collector_note 'Invoking-user systemd manager/session bus was unavailable.'
}

collector_collect() {
    local failed_count
    emit_fact init.system systemd systemctl
    failed_count=$(bounded_command systemctl --failed --no-legend --plain 2>/dev/null | awk 'NF {n++} END {print n+0}')
    emit_fact systemd.failed_unit_count "$failed_count" 'systemctl --failed' observed 1.0 number

    _collect_system_services

    run_capture failed_units "$LCTX_COMMAND_TIMEOUT" 262144 --priority 100 -- systemctl --failed --no-pager --plain || true
    run_capture timers "$LCTX_COMMAND_TIMEOUT" 524288 --priority 80 -- systemctl list-timers --all --no-pager --plain || true
    run_capture sockets "$LCTX_COMMAND_TIMEOUT" 524288 --priority 80 -- systemctl list-sockets --all --no-pager --plain || true

    if profile_at_least max; then
        _collect_user_services
        if run_as_output_owner systemctl --user list-units --no-legend --no-pager >/dev/null 2>&1; then
            run_owner_capture user_failed_units 15 262144 --priority 90 -- systemctl --user --failed --no-pager --plain || true
            run_owner_capture user_timers 15 262144 --priority 70 -- systemctl --user list-timers --all --no-pager --plain || true
            run_owner_capture user_sockets 15 262144 --priority 70 -- systemctl --user list-sockets --all --no-pager --plain || true
        fi
        # Never persist arbitrary unit command bodies: Exec*= and Environment*= can
        # contain positional credentials. Keep only machine-shaping, non-secret
        # directives; running executable paths are represented structurally above.
        run_shell_capture custom_units 20 524288 \
            'for d in /etc/systemd/system /usr/local/lib/systemd/system; do
                [ -d "$d" ] || continue
                find "$d" -maxdepth 3 -type f -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
                    echo "--- $f"
                    sed -En "
                      /^[[:space:]]*(#|;|$)/d
                      /^\[[^]]+\][[:space:]]*$/p
                      /^[[:space:]]*(Description|Documentation|Requires|Wants|After|Before|Conflicts|PartOf|BindsTo|Type|User|Group|WorkingDirectory|Restart|RestartSec|TimeoutStartSec|TimeoutStopSec|Limit[A-Za-z]+|Memory(Max|High|Low)|CPUQuota|TasksMax|NoNewPrivileges|PrivateTmp|PrivateDevices|Protect[A-Za-z]+|Restrict[A-Za-z]+|CapabilityBoundingSet|AmbientCapabilities|ReadOnlyPaths|ReadWritePaths|StateDirectory|CacheDirectory|RuntimeDirectory)[[:space:]]*=/p
                    " "$f"
                done
            done' || true
    fi
}
collector_main "$@"
