#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export LCTX_PROJECT_ROOT="$ROOT" LCTX_TIMEOUT_BACKEND=python
export LCTX_PRIVATE_TMP="$t" LCTX_PROBES_RECORDS="$t/probes.records" LCTX_NOTES_FILE="$t/notes.tsv"
COLLECTOR_ID=fixture
source "$ROOT/lib/common.sh"
source "$ROOT/lib/runner.sh"
# Failure/timeout/truncation are observable; preserve the caller's shell flags.
set +e
_bounded_capture "$t/out" 1 10 -- printf 'abcdefghijklmnop'
[[ $- != *e* ]] || exit 1
set -e
[[ "$LCTX_CAPTURE_RC:$LCTX_CAPTURE_TRUNCATED:$LCTX_CAPTURE_BYTES" == 0:1:10 ]]
_bounded_capture "$t/out" 1 100 -- bash -c 'printf partial; exit 7'
[[ "$LCTX_CAPTURE_RC" == 7 ]]
_bounded_capture "$t/out" 0.1 100 -- bash -c 'trap "" TERM; sleep 30'
[[ "$LCTX_CAPTURE_RC:$LCTX_CAPTURE_TIMED_OUT" == 124:1 ]]
# Descendants may inherit the pipe after their parent exits: they must be killed.
_bounded_capture "$t/out" 1 100 -- bash -c 'sleep 30 & printf done'
[[ "$LCTX_CAPTURE_RC" == 0 && "$(cat "$t/out")" == done ]]
PYTHONPATH="$ROOT/lib" python3 -B -S - "$ROOT" "$t" <<'PY'
import subprocess, sys
from pathlib import Path
from stop_workers import worker_paths
root, temp = map(Path, sys.argv[1:])
code='printf "%s" "$BASHPID" > "$1"; trap "" TERM; while :; do sleep .05; done'
pidfile=temp/'tree-pid'
result=subprocess.run([sys.executable,'-B','-S',str(root/'lib/timeout.py'),'--tree','.5',
                       'timeout','60','bash','-c',code,'_',str(pidfile)],timeout=10)
assert result.returncode==124, result.returncode
pid=int(pidfile.read_text())
proc=worker_paths([pid]).get(pid)
if proc is not None:
    assert '\nState:\tZ' in (proc/'status').read_text()
PY
# procfs st_size is zero even for nonempty content. The extra byte proves truncation.
mkdir "$t/evidence"
export LCTX_SECTION_DIR="$t/evidence" LCTX_ARTIFACTS_RECORDS="$t/artifacts.records"
capture_file_if_readable cmdline /proc/cmdline 1
PYTHONPATH="$ROOT/lib" python3 -B -S - "$t/artifacts.records" <<'PY'
from pathlib import Path
import sys
from recordio import read_records
assert read_records(Path(sys.argv[1]), 'artifacts')[0]['truncated']
PY
mkdir "$t/bin"
cat > "$t/bin/timeout" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$t/bin/timeout"
PATH="$t/bin:$PATH" "$ROOT/bin/linux-context" --profile quick --no-archive --output "$t/bundle" >/dev/null 2>"$t/stderr"
for target in '' 'auto,' ',system' 'system,,network'; do
    if "$ROOT/bin/linux-context" --target "$target" --no-archive --output "$t/bad" >/dev/null 2>&1; then exit 1; fi
done
if "$ROOT/bin/linux-context" --no-archive --remove-dir-after-archive >/dev/null 2>&1; then exit 1; fi
printf 'portable timeout, procfs caps, shell flags and strict CLI: ok\n'
