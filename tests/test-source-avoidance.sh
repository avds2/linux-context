#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B -S - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root=Path(sys.argv[1])
viol=[]
for p in (root/'collectors').rglob('*.sh'):
    for n,line in enumerate(p.read_text(errors='replace').splitlines(),1):
        code=line.split('#',1)[0]
        checks={
            'password database': r'/etc/(?:shadow|gshadow)\b',
            'process environment': r'/proc/[^\s"\']*/environ\b',
            'docker environment values': r'\.Config\.Env\b',
            'full process argv via ps aux': r'\bps\s+(?:aux|auxww)\b',
            'full process argv via ps -ef': r'\bps\s+-ef\b',
            'full pstree argv': r'\bpstree\s+[^\n]*-a\b',
            'user manager environment': r'\bsystemctl\s+--user\s+show-environment\b',
            'active tailscale network probe': r'--\s+tailscale\s+netcheck\b',
            'active wifi rescan': r'\bnmcli\b[^\n]*--rescan[ =]+yes\b',
            'systemd environment dump': r'\bsystemctl\b[^\n]*\bshow-environment\b',
            'package repository network probe': r'\b(?:dnf|yum)\b[^\n]*\brepolist\b',
        }
        for why,pat in checks.items():
            if re.search(pat, code):
                viol.append(f'{p.relative_to(root)}:{n}: {why}: {line.strip()}')
if viol:
    print('\n'.join(viol), file=sys.stderr)
    raise SystemExit(1)
# Broad automatic systemd evidence must not persist arbitrary unit command
# bodies (Exec*/Environment* may contain positional credentials). Running binary
# identity is represented safely through /proc/PID/exe instead.
svc=(root/'collectors/services/systemd.sh').read_text()
assert 'cat "$1"' not in svc
assert 'executable_path' in svc

# Docker evidence captures must explicitly format ps output so COMMAND is never
# persisted by Docker's default table renderer.
d=(root/'collectors/containers/docker.sh').read_text()
assert "ps -a --no-trunc --size --format" in d
assert '.Config.Env' not in '\n'.join(line.split('#',1)[0] for line in d.splitlines())

# VPN collectors may use privacy-heavy peer/status commands only ephemerally; raw
# Tailscale/ZeroTier peer identity dumps and WireGuard public-key/endpoint tables
# must never be persisted with run_capture.
v=(root/'collectors/network/vpn.sh').read_text()
for forbidden in (
    'run_capture tailscale_status',
    'run_capture zerotier_peers',
    'run_capture zerotier_networks',
    'run_capture wireguard_public-key',
    'run_capture wireguard_endpoints',
):
    assert forbidden not in v, forbidden
assert 'zerotier' in v.split("COLLECTOR_TARGETS=",1)[1].splitlines()[0]

# Docker collector must pin every daemon command to an explicit local Unix
# endpoint; inherited remote Docker context is not a collection source.
d=(root/'collectors/containers/docker.sh').read_text()
assert 'docker --host "$DOCKER_ENDPOINT"' in d
assert 'run_as_output_owner docker --host "$DOCKER_ENDPOINT"' in d

print('source avoidance test: ok')
PY
