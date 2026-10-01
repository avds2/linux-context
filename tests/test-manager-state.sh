#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir "$t/bin"
cat > "$t/bin/nmcli" <<'SH'
#!/usr/bin/env bash
case "$NM_MODE" in
  running) echo running ;;
  stopped) echo 'not running' ;;
  failed) exit 1 ;;
esac
SH
cat > "$t/bin/networkctl" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$t/bin/systemctl" <<'SH'
#!/bin/sh
echo "$NETWORKD_STATE"
SH
chmod +x "$t/bin"/*
export PATH="$t/bin:$PATH" LCTX_COMMAND_TIMEOUT=1 LCTX_TIMEOUT_BACKEND=python LCTX_TARGETS=auto
for mode in running stopped failed; do
    (
        export NM_MODE="$mode" NETWORKD_STATE=active
        [[ "$mode" == failed ]] && NETWORKD_STATE=inactive
        for name in FACTS ENTITIES ENTITY_ATTRS RELATIONS ARTIFACTS PROBES; do
            export "LCTX_${name}_RECORDS=$t/$mode-$name.records"
            : > "$t/$mode-$name.records"
        done
        export LCTX_NOTES_FILE="$t/$mode-notes.tsv"
        source "$ROOT/collectors/network/manager.sh" --meta >/dev/null
        command_exists() { [[ "$1" == nmcli || "$1" == networkctl || "$1" == systemctl ]]; }
        run_capture() { :; }
        run_shell_capture() { :; }
        collector_collect
        PYTHONPATH="$ROOT/lib" python3 -B -S - "$LCTX_FACTS_RECORDS" "$mode" <<'PY'
from pathlib import Path
import sys
from recordio import read_records
facts=read_records(Path(sys.argv[1]),'facts')
managers=[f['value'] for f in facts if f['key']=='network.manager']
expected={'running':['NetworkManager','systemd-networkd'], 'stopped':['systemd-networkd'], 'failed':[]}
assert managers==expected[sys.argv[2]], facts
running=[f['value'] for f in facts if f['key']=='network.manager.NetworkManager.running']
assert running=={'running':[True], 'stopped':[False], 'failed':[]}[sys.argv[2]]
PY
    )
done
printf 'installed versus running network managers and unknown access: ok\n'
