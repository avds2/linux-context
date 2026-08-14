#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='packages.inventory'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='packages'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Installed package inventory and concise configured repository state.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_collect() {
    local count
    if command_exists dpkg-query; then
        if command_exists apt-get || command_exists apt-cache; then
            emit_fact packages.manager apt apt
            emit_fact packages.database dpkg dpkg-query
        else
            emit_fact packages.manager dpkg dpkg-query
        fi
        count=$(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | wc -l | tr -d ' ' || true)
        [[ "$count" =~ ^[0-9]+$ ]] && emit_fact packages.installed_count "$count" dpkg-query observed 1.0 number
        run_capture installed_packages 20 "$LCTX_COMMAND_MAX_BYTES" --priority 90 -- dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\n' || true
        command_exists apt-cache && run_capture apt_policy "$LCTX_COMMAND_TIMEOUT" 524288 --priority 65 -- apt-cache policy || true
        run_shell_capture apt_sources "$LCTX_COMMAND_TIMEOUT" 524288 'for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do [ -r "$f" ] || continue; echo "@@ $f"; sed -E "/^[[:space:]]*(#|$)/d" "$f"; done' || true
    elif command_exists rpm; then
        if command_exists dnf; then
            emit_fact packages.manager dnf dnf
        elif command_exists yum; then
            emit_fact packages.manager yum yum
        elif command_exists zypper; then
            emit_fact packages.manager zypper zypper
        else
            emit_fact packages.manager rpm rpm
        fi
        emit_fact packages.database rpm rpm
        count=$(rpm -qa 2>/dev/null | wc -l | tr -d ' ' || true)
        [[ "$count" =~ ^[0-9]+$ ]] && emit_fact packages.installed_count "$count" rpm observed 1.0 number
        run_capture installed_packages 20 "$LCTX_COMMAND_MAX_BYTES" --priority 90 -- rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n' || true
        # Repository *source configuration* is passive and deterministic. Avoid
        # `dnf/yum repolist` here: depending on cache state/plugins those clients can
        # perform metadata/network work, violating the exporter's passive contract.
        run_shell_capture rpm_repositories "$LCTX_COMMAND_TIMEOUT" 524288 '
            for f in /etc/yum.repos.d/*.repo /etc/zypp/repos.d/*.repo; do
                [ -r "$f" ] || continue
                echo "@@ $f"
                sed -E "/^[[:space:]]*(#|$)/d" "$f"
            done
        ' || true
    elif command_exists pacman; then
        emit_fact packages.manager pacman pacman
        count=$(pacman -Qq 2>/dev/null | wc -l | tr -d ' ' || true)
        [[ "$count" =~ ^[0-9]+$ ]] && emit_fact packages.installed_count "$count" pacman observed 1.0 number
        run_capture installed_packages 20 "$LCTX_COMMAND_MAX_BYTES" --priority 90 -- pacman -Q || true
        local kp kv ksafe
        for kp in linux linux-lts linux-zen linux-hardened; do
            kv=$(pacman -Q "$kp" 2>/dev/null | awk '{print $2}' || true); [[ -n "$kv" ]] || continue
            ksafe=$(safe_name "$kp"); emit_fact "packages.kernel.${ksafe}.installed_version" "$kv" "pacman -Q $kp"
            emit_entity "package:$kp" package "$kp" pacman; emit_relation host:local has_package "package:$kp" pacman
        done
        run_shell_capture pacman_conf 5 131072 'sed -E "/^[[:space:]]*(#|$)/d" /etc/pacman.conf 2>/dev/null || true' || true
        run_shell_capture pacman_mirrorlist 5 131072 'sed -E "/^[[:space:]]*(#|$)/d" /etc/pacman.d/mirrorlist 2>/dev/null || true' || true
        if profile_at_least max; then
            run_capture pacman_foreign 20 "$LCTX_COMMAND_MAX_BYTES" --priority 80 -- pacman -Qm || true
            run_capture pacman_orphans 20 524288 --ok-exit 0,1 --priority 80 -- pacman -Qdt || true
            run_capture pacman_cached_upgrades 20 524288 --ok-exit 0,1 --priority 75 -- pacman -Qu || true
            target_requested packages && run_capture pacman_explicit 20 "$LCTX_COMMAND_MAX_BYTES" --priority 55 -- pacman -Qe || true
        fi
    elif command_exists apk; then
        emit_fact packages.manager apk apk
        count=$(apk info 2>/dev/null | wc -l | tr -d ' ' || true)
        [[ "$count" =~ ^[0-9]+$ ]] && emit_fact packages.installed_count "$count" apk observed 1.0 number
        run_capture installed_packages 20 "$LCTX_COMMAND_MAX_BYTES" --priority 90 -- apk info -vv || true
        capture_file_if_readable repositories /etc/apk/repositories 262144 70 || true
    else
        record_collector_note 'No supported package manager detected'
    fi

    if profile_at_least max; then
        # Capability discovery already tells broad max whether Flatpak/Snap are
        # installed. Enumerating desktop/user application databases can cost more
        # than the rest of package collection on workstations and adds little to a
        # generic machine model, so counts/inventories are package-target detail.
        if command_exists flatpak && target_requested packages; then
            count=$(flatpak list --system --app --columns=application 2>/dev/null | awk 'NF {n++} END {print n+0}' || true)
            [[ "$count" =~ ^[0-9]+$ ]] && emit_fact packages.flatpak.system_app_count "$count" 'flatpak list --system' observed 1.0 number
            count=$(run_as_output_owner flatpak list --user --app --columns=application 2>/dev/null | awk 'NF {n++} END {print n+0}' || true)
            [[ "$count" =~ ^[0-9]+$ ]] && emit_fact packages.flatpak.user_app_count "$count" 'flatpak list --user (owner)' observed 1.0 number
            run_capture flatpak_system_apps 20 524288 --priority 60 -- flatpak list --system --app --columns=application,ref,version,branch,origin,installation || true
            run_owner_capture flatpak_user_apps 20 524288 --priority 60 -- flatpak list --user --app --columns=application,ref,version,branch,origin,installation || true
        fi
        if command_exists snap && target_requested packages; then
            count=$(snap list 2>/dev/null | awk 'NR>1 && NF {n++} END {print n+0}' || true)
            [[ "$count" =~ ^[0-9]+$ ]] && emit_fact packages.snap.package_count "$count" 'snap list' observed 1.0 number
            run_capture snap_packages 20 524288 --priority 60 -- snap list || true
        fi
    fi
}
collector_main "$@"
