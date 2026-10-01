#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/fake" "$t/evidence" "$t/private"
export LCTX_SECTION_DIR="$t/evidence" LCTX_PRIVATE_TMP="$t/private" LCTX_TARGETS=all
for name in FACTS ENTITIES ENTITY_ATTRS RELATIONS ARTIFACTS PROBES; do
    export "LCTX_${name}_RECORDS=$t/$name.records"
    : > "$t/$name.records"
done
export LCTX_NOTES_FILE="$t/notes.tsv"
: > "$LCTX_NOTES_FILE"
cat > "$t/fake/bluetoothctl" <<'BT'
#!/usr/bin/env bash
case "$1" in
 list)
   case "$BT_MODE" in
     hang) printf 'Controller AA:BB:CC:DD:EE:FF Private name\n'; sleep 60 ;;
     fail) printf 'Controller AA:BB:CC:DD:EE:FF Private name\n'; exit 1 ;;
     truncated) printf 'Controller AA:BB:CC:DD:EE:FF Private name\n'; head -c 300000 /dev/zero ;;
     empty) exit 0 ;;
     success) printf 'Controller AA:BB:CC:DD:EE:FF Private name\nController 00:11:22:33:44:55 Other name\n' ;;
   esac ;;
 *) echo "$1" >> "$BT_FOCUSED_LOG" ;;
esac
BT
chmod +x "$t/fake/bluetoothctl"
export PATH="$t/fake:$PATH" BT_FOCUSED_LOG="$t/focused.log"
source "$ROOT/collectors/workstation/devices.sh" --meta >/dev/null
# Isolate discovery from real DRM/audio/power hardware on the test host.
command_exists() { [[ "$1" == bluetoothctl ]]; }
run_shell_capture() { :; }
for mode in hang fail truncated empty success; do
    export BT_MODE="$mode"
    : > "$LCTX_FACTS_RECORDS"; : > "$LCTX_PROBES_RECORDS"
    rm -f "$BT_FOCUSED_LOG"
    start=$SECONDS
    collector_collect
    (( SECONDS-start < 12 ))
    python3 -B -S - "$ROOT" "$LCTX_FACTS_RECORDS" "$LCTX_PROBES_RECORDS" "$mode" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1])/'lib'))
from recordio import read_records
facts = read_records(Path(sys.argv[2]), 'facts')
probes = read_records(Path(sys.argv[3]), 'probes')
count = [x['value'] for x in facts if x['key']=='workstation.bluetooth.controller_count']
mode = sys.argv[4]
assert count == ({'empty':[0], 'success':[2]}.get(mode, [])), (mode, count)
assert probes[0]['accepted'] == (mode in ('empty', 'success', 'truncated')), probes
if mode == 'truncated':
    assert probes[0]['truncated'], probes
if mode == 'hang':
    assert probes[0]['timed_out'], probes
assert b'Private name' not in Path(sys.argv[2]).read_bytes()
PY
    if [[ "$mode" == success ]]; then
        [[ $(wc -l < "$BT_FOCUSED_LOG") == 3 ]]
    else
        [[ ! -e "$BT_FOCUSED_LOG" ]]
    fi
    [[ -z $(find "$LCTX_PRIVATE_TMP" -type f -print -quit) ]]
done
printf 'workstation bounded Bluetooth discovery: ok\n'
