#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B -S - "$ROOT" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
sys.path.insert(0, str(root/'lib'))
from stop_workers import worker_paths
with tempfile.TemporaryDirectory() as tmp:
    project = Path(tmp)/'project'
    project.mkdir()
    for name in ('bin', 'lib', 'profiles'):
        shutil.copytree(root/name, project/name)
    shutil.copyfile(root/'VERSION', project/'VERSION')
    (project/'collectors').mkdir()
    fixture = project/'collectors/fixture.sh'
    fixture.write_text('''#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID=fixture
source "$(dirname "$0")/../lib/collector_api.sh"
collector_collect() {
    printf '%s' "$LCTX_TMP_DIR" > "$TEST_STATE/tmp"
    run_capture stubborn 120 1048576 -- bash -c '
        trap "" INT TERM
        printf "%s" "$BASHPID" > "$TEST_STATE/producer"
        while :; do mkdir -p "$LCTX_SECTION_DIR/recreated"; sleep 0.05; done
    '
}
collector_main "$@"
''')
    fixture.chmod(0o755)
    for sig, jobs in ((signal.SIGINT, 1), (signal.SIGTERM, 4)):
        state = Path(tmp)/f'state-{jobs}'
        state.mkdir()
        output = state/'output'
        env = dict(os.environ, TEST_STATE=str(state))
        p = subprocess.Popen([str(project/'bin/linux-context'), '--profile', 'max',
                              '--jobs', str(jobs), '--output', str(output), '--no-archive'],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                             preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
        producer = None
        staging = None
        try:
            deadline = time.monotonic()+10
            while not (state/'producer').exists():
                if p.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError('fixture did not start')
                time.sleep(0.02)
            producer = int((state/'producer').read_text())
            staging = Path((state/'tmp').read_text())
            p.send_signal(sig)
            try:
                stdout, stderr = p.communicate(timeout=10)
            except subprocess.TimeoutExpired as exc:
                print('timeout stderr:', exc.stderr, 'poll:', p.poll(), file=sys.stderr)
                raise
            assert p.returncode == 128+sig, (p.returncode, stderr)
            assert not staging.exists(), (staging, stderr)
            assert not output.exists()
            assert b'cannot remove' not in stderr, stderr
            # A reparented zombie may await PID 1; no producer may still run.
            proc = worker_paths([producer]).get(producer)
            status = proc/'status' if proc else None
            if status is not None and status.exists():
                assert '\nState:\tZ' in status.read_text(), status.read_text()
            time.sleep(0.1)
            assert not staging.exists(), 'staging recreated after cleanup'
        finally:
            if p.poll() is None:
                p.kill()
                p.wait()
            if producer is not None:
                try:
                    os.kill(producer, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if staging is not None and staging.exists():
                shutil.rmtree(staging)
print('INT/TERM stop producer trees before private cleanup: ok')
PY
