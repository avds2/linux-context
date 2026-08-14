#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='network.vpn'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='network vpn wireguard tailscale zerotier'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Privacy-minimized local VPN overlay state for WireGuard, Tailscale, and ZeroTier without secret keys or peer identity dumps.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() { command_exists wg || command_exists tailscale || command_exists zerotier-cli; }

collector_collect() {
    local ifaces iface value count online health peers state version

    if command_exists wg; then
        emit_entity vpn-engine:wireguard vpn_engine WireGuard wg
        emit_relation host:local has_vpn_stack vpn-engine:wireguard wg
        if probe_capture wireguard_interfaces 10 131072 -- wg show all interfaces; then
            ifaces=$(tr '\n' ' ' < "$LCTX_PROBE_FILE" 2>/dev/null || true)
            read -ra _wg_ifaces <<< "$ifaces"
            emit_fact network.wireguard.interface_count "${#_wg_ifaces[@]}" 'wg show all interfaces' observed 1.0 number
            for iface in "${_wg_ifaces[@]}"; do
                [[ -n "$iface" ]] || continue
                emit_entity "netif:$iface" network_interface "$iface" 'wg show all interfaces'
                emit_relation vpn-engine:wireguard manages "netif:$iface" 'wg show all interfaces'
                value=$(wg show "$iface" listen-port 2>/dev/null || true)
                [[ "$value" =~ ^[0-9]+$ ]] && emit_entity_attr "netif:$iface" wireguard_listen_port "$value" 'wg show IFACE listen-port' observed 1.0 number
                value=$(wg show "$iface" fwmark 2>/dev/null || true)
                [[ -n "$value" && "$value" != off ]] && emit_entity_attr "netif:$iface" wireguard_fwmark "$value" 'wg show IFACE fwmark'
            done
        fi
        release_probe

        # Public peer keys and endpoint addresses are persistent remote identifiers,
        # not necessary for a broad machine model. Explicit VPN/network diagnosis may
        # retain peer *runtime metrics* only after the peer-key column is removed.
        if target_requested wireguard || target_requested vpn || target_requested network; then
            for field in allowed-ips latest-handshakes transfer persistent-keepalive; do
                run_shell_capture "wireguard_${field}" 10 524288 "wg show all '$field' 2>/dev/null | awk 'NF {\$1=\"<PEER>\"; print}'" || true
            done
        fi
    fi

    if command_exists tailscale; then
        emit_entity vpn-engine:tailscale vpn_engine Tailscale tailscale
        emit_relation host:local has_vpn_stack vpn-engine:tailscale tailscale
        # Version is safe; raw status JSON is privacy-heavy (peer names, users, keys,
        # addresses). Parse it ephemerally into aggregate machine state only.
        run_capture tailscale_version 10 131072 --priority 45 -- tailscale version || true
        if probe_capture tailscale_status_json 15 1048576 -- tailscale status --json; then
            while IFS=$'\t' read -r state online peers health; do
                [[ -n "$state" ]] && emit_fact network.tailscale.backend_state "$state" 'tailscale status --json (filtered)'
                [[ "$online" =~ ^[01]$ ]] && emit_fact network.tailscale.self_online "$online" 'tailscale status --json (filtered)' observed 1.0 boolean
                [[ "$peers" =~ ^[0-9]+$ ]] && emit_fact network.tailscale.peer_count "$peers" 'tailscale status --json (filtered)' observed 1.0 number
                [[ "$health" =~ ^[0-9]+$ ]] && emit_fact network.tailscale.health_issue_count "$health" 'tailscale status --json (filtered)' observed 1.0 number
            done < <(lctx_python - "$LCTX_PROBE_FILE" <<'PY' 2>/dev/null || true
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:
    raise SystemExit(0)
self_obj=d.get('Self') or {}
peers=d.get('Peer') or {}
health=d.get('Health') or []
print(str(d.get('BackendState','')), '1' if bool(self_obj.get('Online')) else '0', len(peers) if isinstance(peers,dict) else 0, len(health) if isinstance(health,list) else 0, sep='\t')
PY
)
        fi
        release_probe
        record_collector_note 'Skipped tailscale netcheck because it performs active external network probes.'
    fi

    if command_exists zerotier-cli; then
        emit_entity vpn-engine:zerotier vpn_engine ZeroTier zerotier-cli
        emit_relation host:local has_vpn_stack vpn-engine:zerotier zerotier-cli
        # `info` includes a persistent node ID. Parse only version/state. Network and
        # peer lists are used ephemerally for counts; raw IDs/endpoints are not kept.
        if probe_capture zerotier_info 10 131072 -- zerotier-cli info; then
            read -r _zt_code _zt_word _zt_node version state _rest < "$LCTX_PROBE_FILE" || true
            [[ -n "${version:-}" ]] && emit_fact network.zerotier.version "$version" 'zerotier-cli info (node id omitted)'
            [[ -n "${state:-}" ]] && emit_fact network.zerotier.state "$state" 'zerotier-cli info (node id omitted)'
        fi
        release_probe
        if probe_capture zerotier_networks 10 524288 -- zerotier-cli listnetworks; then
            count=$(awk 'NR>1 && NF {n++} END {print n+0}' "$LCTX_PROBE_FILE" 2>/dev/null || printf 0)
            [[ "$count" =~ ^[0-9]+$ ]] && emit_fact network.zerotier.network_count "$count" 'zerotier-cli listnetworks (aggregate only)' observed 1.0 number
        fi
        release_probe
        if target_requested zerotier || target_requested vpn || target_requested network; then
            if probe_capture zerotier_peers 10 1048576 -- zerotier-cli listpeers; then
                count=$(awk 'NR>1 && NF {n++} END {print n+0}' "$LCTX_PROBE_FILE" 2>/dev/null || printf 0)
                [[ "$count" =~ ^[0-9]+$ ]] && emit_fact network.zerotier.peer_count "$count" 'zerotier-cli listpeers (aggregate only)' observed 1.0 number
            fi
            release_probe
        fi
    fi
}
collector_main "$@"
