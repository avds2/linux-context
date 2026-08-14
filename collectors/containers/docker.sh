#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='containers.docker'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='docker containers'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Local Docker daemon and compact container/network/port/mount topology without environment values or arbitrary labels.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

_docker_local_socket_exists() {
    local path
    for path in /run/docker.sock /var/run/docker.sock "${LCTX_OWNER_RUNTIME_DIR:-}/docker.sock"; do
        [[ -n "$path" && -S "$path" ]] && return 0
    done
    # A caller may intentionally use a nonstandard *local Unix* socket. Remote
    # tcp/ssh Docker endpoints and DOCKER_CONTEXT are never honored.
    if [[ "${DOCKER_HOST:-}" == unix://* ]]; then
        path=${DOCKER_HOST#unix://}
        [[ -S "$path" ]] && return 0
    fi
    return 1
}

collector_detect() {
    command_exists docker || return 1
    _docker_local_socket_exists
}

collector_collect() {
    local value server_version storage_driver cgroup_driver container_count running_count
    local id name image state short ceid rec objid a b c d e bridge_id network_id
    local DOCKER_SCOPE='' DOCKER_ENDPOINT='' i path
    local -a ids=() batch=() system_sockets=() owner_sockets=()
    declare -A network_ids=() seen_socket=()

    [[ -S /run/docker.sock ]] && system_sockets+=(/run/docker.sock)
    [[ -S /var/run/docker.sock ]] && system_sockets+=(/var/run/docker.sock)
    if [[ "${DOCKER_HOST:-}" == unix://* && -S "${DOCKER_HOST#unix://}" ]]; then
        system_sockets+=("${DOCKER_HOST#unix://}")
    fi
    [[ -n "${LCTX_OWNER_RUNTIME_DIR:-}" && -S "${LCTX_OWNER_RUNTIME_DIR}/docker.sock" ]] && owner_sockets+=("${LCTX_OWNER_RUNTIME_DIR}/docker.sock")

    # One explicit local-socket daemon round-trip both verifies accessibility and
    # supplies canonical engine state. Passing --host is a security boundary: an
    # inherited DOCKER_CONTEXT/remote DOCKER_HOST can never redirect acquisition.
    local info_template='{{printf "%s\t%s\t%s\t%d\t%d" .ServerVersion .Driver .CgroupDriver .Containers .ContainersRunning}}'
    for path in "${system_sockets[@]}"; do
        [[ -n "${seen_socket[$path]+x}" ]] && continue; seen_socket[$path]=1
        if value=$(docker --host "unix://$path" info --format "$info_template" 2>/dev/null); then
            DOCKER_SCOPE=system; DOCKER_ENDPOINT="unix://$path"; break
        fi
    done
    if [[ -z "$DOCKER_ENDPOINT" ]]; then
        for path in "${owner_sockets[@]}"; do
            if value=$(run_as_output_owner docker --host "unix://$path" info --format "$info_template" 2>/dev/null); then
                DOCKER_SCOPE=owner; DOCKER_ENDPOINT="unix://$path"; break
            fi
        done
    fi
    if [[ -z "$DOCKER_ENDPOINT" ]]; then
        record_collector_note 'A local Docker Unix socket exists, but no local daemon is accessible in system or invoking-user scope.'
        return 1
    fi
    if [[ "$DOCKER_SCOPE" == owner ]]; then
        emit_fact containers.docker.scope invoking_user 'docker info (explicit local Unix socket)'
    else
        emit_fact containers.docker.scope system 'docker info (explicit local Unix socket)'
    fi

    docker_exec() {
        if [[ "$DOCKER_SCOPE" == owner ]]; then
            run_as_output_owner docker --host "$DOCKER_ENDPOINT" "$@"
        else
            docker --host "$DOCKER_ENDPOINT" "$@"
        fi
    }
    docker_capture() {
        local label="$1" timeout_s="$2" max_b="$3"; shift 3
        if [[ "$DOCKER_SCOPE" == owner ]]; then
            run_owner_capture "$label" "$timeout_s" "$max_b" --source "docker(local):$label" -- docker --host "$DOCKER_ENDPOINT" "$@"
        else
            run_capture "$label" "$timeout_s" "$max_b" --source "docker(local):$label" -- docker --host "$DOCKER_ENDPOINT" "$@"
        fi
    }

    IFS=$'\t' read -r server_version storage_driver cgroup_driver container_count running_count <<< "$value"
    # Be defensive against formatter differences: a scalar fact must never carry
    # the entire encoded tuple. Fall back to narrow probes if parsing is suspect.
    if [[ -z "${storage_driver:-}" || "$server_version" == *'\t'* ]]; then
        server_version=''; storage_driver=''; cgroup_driver=''; container_count=''; running_count=''
    fi
    if [[ -z "${server_version:-}" ]]; then server_version=$(docker_exec version --format '{{.Server.Version}}' 2>/dev/null || true); fi
    if [[ -z "${storage_driver:-}" ]]; then storage_driver=$(docker_exec info --format '{{.Driver}}' 2>/dev/null || true); fi
    if [[ -z "${cgroup_driver:-}" ]]; then cgroup_driver=$(docker_exec info --format '{{.CgroupDriver}}' 2>/dev/null || true); fi
    if [[ ! "${container_count:-}" =~ ^[0-9]+$ ]]; then container_count=$(docker_exec ps -aq 2>/dev/null | wc -l | tr -d ' ' || true); fi
    if [[ ! "${running_count:-}" =~ ^[0-9]+$ ]]; then running_count=$(docker_exec ps -q 2>/dev/null | wc -l | tr -d ' ' || true); fi

    emit_fact containers.engine docker 'docker info'
    [[ -n "${server_version:-}" ]] && emit_fact containers.docker.server_version "$server_version" 'docker info'
    [[ -n "${storage_driver:-}" ]] && emit_fact containers.docker.storage_driver "$storage_driver" 'docker info'
    [[ -n "${cgroup_driver:-}" ]] && emit_fact containers.docker.cgroup_driver "$cgroup_driver" 'docker info'
    [[ "${container_count:-}" =~ ^[0-9]+$ ]] && emit_fact containers.docker.container_count "$container_count" 'docker info' observed 1.0 number
    [[ "${running_count:-}" =~ ^[0-9]+$ ]] && emit_fact containers.docker.running_count "$running_count" 'docker info' observed 1.0 number

    emit_entity container-engine:docker container_engine Docker 'docker info'
    emit_relation host:local runs container-engine:docker 'docker info'

    # Basic container inventory in one daemon call. No command, argv, environment,
    # or arbitrary labels are requested.
    local ps_template='{{printf "%s\t%s\t%s\t%s" .ID .Names .Image .State}}'
    while IFS=$'\t' read -r id name image state; do
        [[ -n "${id:-}" ]] || continue
        (( ${#ids[@]} < LCTX_MAX_ITEMS )) || break
        ids+=("$id")
        short=${id:0:12}; ceid="docker-container:$short"
        [[ "$image" == sha256:* && ${#image} -gt 19 ]] && image="sha256:${image:7:12}"
        emit_entity "$ceid" container "$name" 'docker ps'
        emit_relation container-engine:docker manages "$ceid" 'docker ps'
        emit_relation host:local runs "$ceid" 'docker ps'
        emit_entity_attr "$ceid" image "$image" 'docker ps'
        emit_entity_attr "$ceid" state "$state" 'docker ps'
    done < <(docker_exec ps -a --no-trunc --format "$ps_template" 2>/dev/null || true)

    # Network IDs are safe topology metadata and let the AI join Docker networks
    # to Linux bridge interfaces without asking each container for NetworkID.
    local network_template='{{printf "%s\t%s" .Name .ID}}'
    while IFS=$'\t' read -r name id; do
        [[ -n "${name:-}" && -n "${id:-}" ]] || continue
        network_ids["$name"]="$id"
    done < <(docker_exec network ls --no-trunc --format "$network_template" 2>/dev/null || true)

    # Keep the high-value inspect paths independent. A template edge case in one
    # optional field must not abort core state/network topology for later objects
    # in the same batch (a real standalone-container regression in v0.5.2).
    # Keep templates field-isolated. Docker versions differ in how absent optional
    # fields behave in Go templates; if health/labels are missing for one object,
    # that must never suppress core META records for otherwise valid containers.
    local meta_template='{{printf "META\t%s\t%s\t%s\t%d\n" .Id .HostConfig.RestartPolicy.Name .HostConfig.NetworkMode .State.Pid}}'
    local health_template='{{with .State.Health}}{{printf "HEALTH\t%s\t%s\n" $.Id .Status}}{{end}}'
    local compose_template='{{with .Config.Labels}}{{with index . "com.docker.compose.project"}}{{printf "COMPOSE\t%s\t%s\n" $.Id .}}{{end}}{{end}}'
    local net_template='{{$id := .Id}}{{range $n,$cfg := .NetworkSettings.Networks}}{{printf "NET\t%s\t%s\t%s\t%s\n" $id $n $cfg.IPAddress $cfg.Gateway}}{{end}}'
    local io_template='{{$id := .Id}}{{range $p,$bindings := .NetworkSettings.Ports}}{{range $bindings}}{{printf "PORT\t%s\t%s\t%s\t%s\n" $id $p .HostIp .HostPort}}{{end}}{{end}}{{range .Mounts}}{{printf "MOUNT\t%s\t%s\t%s\t%s\t%s\n" $id .Type .Name .Source .Destination}}{{end}}'

    process_inspect_records() {
        while IFS=$'\t' read -r rec objid a b c d e; do
            [[ -n "${objid:-}" ]] || continue
            ceid="docker-container:${objid:0:12}"
            case "$rec" in
                META)
                    [[ -n "${a:-}" ]] && emit_entity_attr "$ceid" restart_policy "$a" 'docker inspect format'
                    [[ -n "${b:-}" ]] && emit_entity_attr "$ceid" network_mode "$b" 'docker inspect format'
                    if [[ "${c:-}" =~ ^[0-9]+$ ]] && (( c > 0 )); then
                        emit_entity_attr "$ceid" main_pid "$c" 'docker inspect format' observed 1.0 number
                        emit_entity "process:$c" process "container-init:${ceid#docker-container:}" 'docker inspect format'
                        emit_relation "$ceid" has_main_process "process:$c" 'docker inspect format'
                    fi
                    ;;
                HEALTH)
                    [[ -n "${a:-}" ]] && emit_entity_attr "$ceid" health "$a" 'docker inspect format'
                    ;;
                COMPOSE)
                    [[ -n "${a:-}" ]] || continue
                    emit_entity "compose-project:$a" compose_project "$a" 'docker inspect compose label'
                    emit_relation "compose-project:$a" contains "$ceid" 'docker inspect compose label'
                    ;;
                NET)
                    [[ -n "${a:-}" ]] || continue
                    emit_entity "docker-network:$a" container_network "$a" 'docker inspect network'
                    emit_relation "$ceid" connected_to "docker-network:$a" 'docker inspect network'
                    if [[ -n "${b:-}" ]]; then
                        emit_entity "ip:${b}" ip_address "$b" 'docker inspect network'
                        emit_relation "$ceid" has_address "ip:${b}" 'docker inspect network'
                    fi
                    if [[ "$a" == bridge ]]; then
                        emit_relation "docker-network:$a" corresponds_to netif:docker0 'docker bridge convention' inferred 0.95
                    else
                        network_id=${network_ids[$a]:-}
                        if [[ "$network_id" =~ ^[0-9a-fA-F]{12,}$ ]]; then
                            bridge_id="br-${network_id:0:12}"
                            emit_relation "docker-network:$a" corresponds_to "netif:$bridge_id" 'docker network id / Linux bridge naming convention' inferred 0.95
                        fi
                    fi
                    ;;
                PORT)
                    [[ -n "${a:-}" && -n "${c:-}" ]] || continue
                    local container_port proto host_ip endpoint
                    container_port=${a%/*}; proto=${a##*/}; host_ip=${b:-0.0.0.0}
                    if [[ "$host_ip" == '::' ]]; then endpoint="[::]:$c"; else endpoint="$host_ip:$c"; fi
                    emit_entity "socket:${proto}:${endpoint}" listening_socket "$endpoint" 'docker inspect port binding'
                    emit_relation "$ceid" publishes "socket:${proto}:${endpoint}" 'docker inspect port binding'
                    emit_entity_attr "socket:${proto}:${endpoint}" container_port "$container_port/$proto" 'docker inspect port binding'
                    ;;
                MOUNT)
                    [[ -n "${a:-}" && -n "${d:-}" ]] || continue
                    if [[ "$a" == volume && -n "${b:-}" ]]; then
                        emit_entity "docker-volume:$b" container_volume "$b" 'docker inspect mount'
                        emit_relation "$ceid" mounts "docker-volume:$b" 'docker inspect mount'
                    elif [[ "$a" == bind && -n "${c:-}" ]]; then
                        emit_entity "host-path:$c" host_path "$c" 'docker inspect mount'
                        emit_relation "$ceid" bind_mounts "host-path:$c" 'docker inspect mount'
                    fi
                    emit_entity_attr "$ceid" "mount.$(safe_name "$d")" "$a:$d" 'docker inspect mount'
                    ;;
            esac
        done
    }

    for (( i=0; i<${#ids[@]}; i+=128 )); do
        batch=("${ids[@]:i:128}")
        docker_exec inspect --format "$meta_template" "${batch[@]}" 2>/dev/null | process_inspect_records || true
        docker_exec inspect --format "$health_template" "${batch[@]}" 2>/dev/null | process_inspect_records || true
        docker_exec inspect --format "$compose_template" "${batch[@]}" 2>/dev/null | process_inspect_records || true
        docker_exec inspect --format "$net_template" "${batch[@]}" 2>/dev/null | process_inspect_records || true
        docker_exec inspect --format "$io_template" "${batch[@]}" 2>/dev/null | process_inspect_records || true
    done

    # Broad auto mode is represented by the canonical graph. Full inventories are
    # supporting evidence only for an explicit Docker/container investigation.
    if target_requested docker || target_requested containers; then
        docker_capture docker_version "$LCTX_COMMAND_TIMEOUT" 262144 version || true
        docker_capture docker_info "$LCTX_COMMAND_TIMEOUT" 786432 info || true
        docker_capture containers "$LCTX_COMMAND_TIMEOUT" 524288 ps -a --no-trunc --size --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Names}}\t{{.Size}}' || true
        docker_capture images "$LCTX_COMMAND_TIMEOUT" 524288 image ls --digests --no-trunc || true
        docker_capture networks "$LCTX_COMMAND_TIMEOUT" 262144 network ls --no-trunc || true
        docker_capture volumes "$LCTX_COMMAND_TIMEOUT" 262144 volume ls || true
        docker_exec compose version >/dev/null 2>&1 && docker_capture compose_projects "$LCTX_COMMAND_TIMEOUT" 262144 compose ls -a || true
    fi
}
collector_main "$@"
