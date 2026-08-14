#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='applications.web'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='web apache nginx caddy haproxy'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Installed/active web engines; deep configuration only for active engines or explicit web targets.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() {
    command_exists httpd || command_exists apachectl || command_exists apache2ctl || command_exists nginx || command_exists caddy || command_exists haproxy || \
    [[ -d /etc/httpd || -d /etc/apache2 || -d /etc/nginx || -d /etc/caddy || -d /etc/haproxy ]]
}

_process_active() { local p; for p in "$@"; do pgrep -x "$p" >/dev/null 2>&1 && return 0; done; return 1; }
_deep_for() { local t="$1" active="$2"; [[ "$active" == true ]] || target_requested web || target_requested "$t"; }

capture_config_set() {
    local label="$1"; shift
    local quoted='' p
    for p in "$@"; do printf -v p '%q' "$p"; quoted+="${quoted:+ }$p"; done
    run_shell_capture "$label" 15 786432 "
        for pattern in $quoted; do
            for f in \$pattern; do
                [ -f \"\$f\" ] || continue
                echo \"@@FILE \$f\"
                sed -E '/^[[:space:]]*(#|;|$)/d' -- \"\$f\"; echo
            done
        done" || true
}

_web_entity() {
    local id="$1" label="$2" source="$3" active="$4"
    emit_entity "webserver:$id" web_server "$label" "$source"
    emit_entity_attr "webserver:$id" installed true "$source" observed 1.0 boolean
    emit_entity_attr "webserver:$id" running "$active" process-detection observed 0.95 boolean
    emit_relation host:local has_web_software "webserver:$id" "$source"
    [[ "$active" == true ]] && emit_relation host:local runs "webserver:$id" process-detection
    return 0
}

collector_collect() {
    local apache_cmd='' active=false
    if command_exists apachectl; then apache_cmd=apachectl; elif command_exists apache2ctl; then apache_cmd=apache2ctl; elif command_exists httpd; then apache_cmd=httpd; fi
    if [[ -n "$apache_cmd" || -d /etc/httpd || -d /etc/apache2 ]]; then
        _process_active httpd apache2 && active=true || active=false
        _web_entity apache Apache "${apache_cmd:-filesystem}" "$active"
        [[ -n "$apache_cmd" ]] && run_capture apache_version 8 131072 --priority 60 -- "$apache_cmd" -v || true
        if _deep_for apache "$active" && [[ -n "$apache_cmd" ]]; then
            run_capture apache_vhosts 15 262144 --priority 95 -- "$apache_cmd" -S || true
            run_capture apache_modules 15 262144 --priority 55 -- "$apache_cmd" -M || true
            run_capture apache_runtime_config 15 262144 --priority 80 -- "$apache_cmd" -t -D DUMP_RUN_CFG || true
            capture_config_set apache_config '/etc/httpd/conf/httpd.conf' '/etc/httpd/conf/extra/*.conf' '/etc/apache2/apache2.conf' '/etc/apache2/ports.conf' '/etc/apache2/sites-enabled/*' '/etc/apache2/conf-enabled/*'
            if target_requested web || target_requested apache; then
                capture_config_set apache_module_config '/etc/apache2/mods-enabled/*.conf'
            fi
        fi
    fi

    active=false
    if command_exists nginx || [[ -d /etc/nginx ]]; then
        _process_active nginx && active=true || active=false
        _web_entity nginx Nginx nginx "$active"
        command_exists nginx && run_capture nginx_version 8 131072 --priority 60 -- nginx -V || true
        if _deep_for nginx "$active"; then
            command_exists nginx && run_capture nginx_effective_config 20 786432 --priority 95 -- nginx -T || capture_config_set nginx_config '/etc/nginx/nginx.conf' '/etc/nginx/conf.d/*.conf' '/etc/nginx/sites-enabled/*'
        fi
    fi

    active=false
    if command_exists caddy || [[ -d /etc/caddy ]]; then
        _process_active caddy && active=true || active=false
        _web_entity caddy Caddy caddy "$active"
        command_exists caddy && run_capture caddy_version 8 131072 --priority 60 -- caddy version || true
        if _deep_for caddy "$active"; then
            command_exists caddy && run_capture caddy_modules 12 524288 --priority 40 -- caddy list-modules || true
            capture_config_set caddy_config '/etc/caddy/Caddyfile' '/usr/local/etc/caddy/Caddyfile'
        fi
    fi

    active=false
    if command_exists haproxy || [[ -d /etc/haproxy ]]; then
        _process_active haproxy && active=true || active=false
        _web_entity haproxy HAProxy haproxy "$active"
        command_exists haproxy && run_capture haproxy_version 8 262144 --priority 60 -- haproxy -vv || true
        _deep_for haproxy "$active" && capture_config_set haproxy_config '/etc/haproxy/haproxy.cfg' '/etc/haproxy/conf.d/*.cfg'
    fi
}
collector_main "$@"
