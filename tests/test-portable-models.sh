#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHONPATH="$ROOT/lib" python3 -B -S - <<'PY'
import json
from pathlib import Path
import tempfile
from os_release import parse
from file_inventory import inventory
from manifest import write_manifest
import contextlib
import io
import hashlib
from unittest import mock
from types import SimpleNamespace
import as_owner
calls=mock.Mock()
with mock.patch.object(as_owner.pwd, 'getpwuid', return_value=SimpleNamespace(pw_name='fixture')):
    with mock.patch.multiple(as_owner.os, initgroups=mock.DEFAULT, setgid=mock.DEFAULT, setuid=mock.DEFAULT, execvp=mock.DEFAULT) as actions:
        for name, action in actions.items(): calls.attach_mock(action, name)
        as_owner.execute(65534, 65534, ['env','-i','id'])
assert calls.mock_calls==[mock.call.initgroups('fixture',65534), mock.call.setgid(65534), mock.call.setuid(65534), mock.call.execvp('env',['env','-i','id'])]
try:
    as_owner.execute(0,0,['true'])
except ValueError:
    pass
else:
    raise AssertionError('root target accepted by owner fallback')
assert parse('ID=alpine\nVERSION_ID="3.22"\nPRETTY_NAME=\'Test Linux\'\nID_LIKE="rhel fedora"') == {
    'ID':'alpine', 'VERSION_ID':'3.22', 'PRETTY_NAME':'Test Linux', 'ID_LIKE':'rhel fedora'}
assert parse('ID="$(touch /tmp/should-never-execute)"')['ID'].startswith('$(touch')
assert parse('ID="broken') == {}
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root/'job').write_text('SECRET-JOB-BODY')
    (root/'link').symlink_to(root/'job')
    (root/'sub').mkdir()
    (root/'sub/child').touch()
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        inventory([root], 1, 100, False)
    text = output.getvalue()
    assert 'SECRET-JOB-BODY' not in text and str(root/'link') not in text
    assert str(root/'sub/child') not in text and str(root/'job') in text
    with contextlib.redirect_stdout(output := io.StringIO()):
        inventory([root], 4, 1, False)
    assert 'inventory_limited' in output.getvalue()
    # Check standard manifest rows without depending on coreutils availability.
    (root/'link').unlink()
    write_manifest(root)
    for row in (root/'manifest.sha256').read_text().splitlines():
        digest, name = row.split('  ', 1)
        assert hashlib.sha256((root/name).read_bytes()).hexdigest() == digest
print('safe os-release parsing, portable metadata and manifest: ok')
PY
