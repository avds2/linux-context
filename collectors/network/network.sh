#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='network.topology'
COLLECTOR_MIN_PROFILE='standard'
COLLECTOR_TARGETS='network docker containers vpn web security'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Interfaces, addressing, routes, listening sockets, DNS, and firewall topology; remote peers only for explicit network/security targets.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    local line idx name family addr default_route state mtu master
    local proc_re='users:\(\("([^"]+)"[^)]*pid=([0-9]+)' unit_re='/system\.slice/([^/]+\.service)(/|$)'
    local focused=0 veth_count=0
    declare -A modeled_if=()
    { target_requested network || target_requested docker || target_requested containers || target_requested security; } && focused=1 || true

    if command_exists ip; then
        while IFS= read -r line; do
            idx=${line%%:*}; line=${line#*: }; name=${line%%:*}; name=${name%%@*}; [[ -n "$name" ]] || continue
            # veth peers are ephemeral implementation detail and explode the graph
            # on container hosts. Broad scans keep a count; focused network/docker
            # targets model each peer explicitly.
            if [[ "$name" == veth* && "$focused" -eq 0 ]]; then
                veth_count=$((veth_count+1))
                continue
            fi
            modeled_if["$name"]=1
            emit_entity "netif:$name" network_interface "$name" 'ip -o link'
            emit_entity_attr "netif:$name" ifindex "$idx" 'ip -o link' observed 1.0 number
            if [[ "$line" =~ [[:space:]]mtu[[:space:]]+([0-9]+) ]]; then
                mtu=${BASH_REMATCH[1]}; emit_entity_attr "netif:$name" mtu "$mtu" 'ip -o link' observed 1.0 number
            fi
            if [[ "$line" =~ [[:space:]]state[[:space:]]+([^[:space:]]+) ]]; then
                state=${BASH_REMATCH[1]}; emit_entity_attr "netif:$name" state "$state" 'ip -o link'
            fi
            if [[ "$line" =~ [[:space:]]master[[:space:]]+([^[:space:]]+) ]]; then
                master=${BASH_REMATCH[1]}; emit_relation "netif:$name" enslaved_to "netif:$master" 'ip -o link'
            fi
            emit_relation host:local has_interface "netif:$name" 'ip -o link'
        done < <(LC_ALL=C ip -o link show 2>/dev/null || true)
        (( veth_count > 0 )) && emit_fact network.ephemeral_veth_count "$veth_count" 'ip -o link' observed 1.0 number

        while read -r idx name family addr _; do
            [[ -n "${name:-}" && -n "${addr:-}" ]] || continue
            name=${name%%@*}
            [[ -n "${modeled_if[$name]:-}" ]] || continue
            emit_entity "ip:$addr" ip_address "$addr" 'ip -o addr'
            emit_entity_attr "ip:$addr" family "$family" 'ip -o addr'
            emit_relation "netif:$name" has_address "ip:$addr" 'ip -o addr'
        done < <(LC_ALL=C ip -o addr show 2>/dev/null | awk '{print $1,$2,$3,$4}' || true)

        default_route=$(LC_ALL=C ip route show default 2>/dev/null | head -n1 || true)
        [[ -n "$default_route" ]] && emit_fact network.default_route "$default_route" 'ip route show default'
        default_route=$(bounded_command ip -6 route show default 2>/dev/null | head -n1 || true)
        [[ -n "$default_route" ]] && emit_fact network.default_route_ipv6 "$default_route" 'ip -6 route show default'

        # Canonical state above is enough for broad machine understanding. Large
        # per-link dumps are retained only for a focused network/container
        # investigation; routing policy remains high-value in broad max.
        if (( focused )); then
            run_capture addresses "$LCTX_COMMAND_TIMEOUT" 524288 --priority 90 -- ip -details -statistics address show || true
            run_capture links "$LCTX_COMMAND_TIMEOUT" 524288 --priority 80 -- ip -details link show || true
            run_capture netns "$LCTX_COMMAND_TIMEOUT" 131072 --priority 60 -- ip netns list || true
        fi
        run_capture routes "$LCTX_COMMAND_TIMEOUT" 524288 --priority 95 -- ip -details route show table all || true
        run_capture routes_ipv6 "$LCTX_COMMAND_TIMEOUT" 524288 --priority 90 -- ip -6 -details route show table all || true
        run_capture rules "$LCTX_COMMAND_TIMEOUT" 131072 --priority 75 -- ip rule show || true
        if target_requested network || target_requested security; then
            run_capture neighbors "$LCTX_COMMAND_TIMEOUT" 262144 --priority 35 -- ip neigh show || true
        fi
    fi

    if command_exists ss; then
        if probe_capture listening_sockets 12 524288 -- ss -H -lntup; then
            local proto state recvq sendq local_ep peer_ep rest endpoint port pname pid socket_id
            declare -A seen_socket=() seen_process=()
            while read -r proto state recvq sendq local_ep peer_ep rest; do
                [[ -n "${proto:-}" && -n "${local_ep:-}" ]] || continue
                # A wildcard from ss does not prove IPv6. Preserve its literal
                # endpoint instead of inventing an address family.
                endpoint="$local_ep"
                socket_id="socket:${proto}:${endpoint}"
                if [[ -z "${seen_socket[$socket_id]:-}" ]]; then
                    seen_socket[$socket_id]=1
                    emit_entity "$socket_id" listening_socket "$endpoint" 'ss -H -lntup'
                    emit_entity_attr "$socket_id" state "$state" 'ss -H -lntup'
                    emit_entity_attr "$socket_id" protocol "$proto" 'ss -H -lntup'
                    emit_relation host:local listens_on "$socket_id" 'ss -H -lntup'
                fi
                pname=''; pid=''
                local proc_re='users:\(\("([^"]+)"[^)]*pid=([0-9]+)'
                if [[ "${rest:-}" =~ $proc_re ]]; then
                    pname=${BASH_REMATCH[1]}; pid=${BASH_REMATCH[2]}
                fi
                if [[ "$pid" =~ ^[0-9]+$ ]]; then
                    [[ -n "${seen_process[$pid]:-}" ]] || { seen_process[$pid]=1; emit_entity "process:$pid" process "${pname:-pid-$pid}" 'ss -H -lntup'; }
                    emit_relation "$socket_id" owned_by "process:$pid" 'ss -H -lntup'
                    # cgroup v2/legacy paths let us attach worker/socket PIDs to
                    # their owning systemd service without reading argv/env.
                    local cg_path service
                    if [[ -r "/proc/$pid/cgroup" ]]; then
                        while IFS=: read -r _ _ cg_path; do
                            if [[ "$cg_path" =~ $unit_re ]]; then
                                service=${BASH_REMATCH[1]}
                                emit_entity "systemd-unit:$service" service "$service" '/proc/PID/cgroup'
                                emit_relation "process:$pid" member_of "systemd-unit:$service" '/proc/PID/cgroup'
                                emit_relation "$socket_id" served_by "systemd-unit:$service" '/proc/PID/cgroup' inferred 0.99
                                break
                            fi
                        done < "/proc/$pid/cgroup"
                    fi
                fi
            done < "$LCTX_PROBE_FILE"
            run_capture listening_sockets 5 524288 --source 'ss -H -lntup' --priority 100 -- cat "$LCTX_PROBE_FILE" || true
        fi
        release_probe
        run_capture socket_summary "$LCTX_COMMAND_TIMEOUT" 131072 --priority 70 -- ss -s || true
        if profile_at_least deep && { target_requested network || target_requested security; }; then
            run_capture established_sockets "$LCTX_COMMAND_TIMEOUT" 524288 --priority 30 -- ss -H -ntup state established || true
        fi
    fi

    capture_file_if_readable resolv_conf /etc/resolv.conf 131072 95 || true
    capture_file_if_readable hosts /etc/hosts 262144 70 || true
    capture_file_if_readable nsswitch_conf /etc/nsswitch.conf 131072 75 || true
    if command_exists resolvectl; then
        if bounded_command resolvectl status >/dev/null 2>&1; then
            emit_fact network.dns.systemd_resolved true resolvectl observed 1.0 boolean
            run_capture resolvectl "$LCTX_COMMAND_TIMEOUT" 524288 --priority 90 -- resolvectl status || true
        else
            emit_fact network.dns.systemd_resolved false resolvectl observed 1.0 boolean
        fi
    fi

    command_exists nft && run_capture nft_ruleset 15 786432 --priority 100 -- nft list ruleset || true
    # nft being installed says nothing about whether legacy iptables rules are
    # active. Coexisting tooling must not hide the other firewall's state.
    command_exists iptables-save && run_capture iptables "$LCTX_COMMAND_TIMEOUT" 786432 --priority 95 -- iptables-save || true
    command_exists ip6tables-save && run_capture ip6tables "$LCTX_COMMAND_TIMEOUT" 786432 --priority 90 -- ip6tables-save || true
    if command_exists firewall-cmd; then
        run_capture firewalld_state 10 131072 --priority 90 -- firewall-cmd --state || true
        run_capture firewalld_zones 15 524288 --priority 85 -- firewall-cmd --list-all-zones || true
    fi
    command_exists ufw && run_capture ufw_status 15 524288 --priority 90 -- ufw status verbose || true
}
collector_main "$@"
