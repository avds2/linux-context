#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

init_stage() {
    local name="$1"
    STAGE="$t/$name"
    mkdir -p "$STAGE/collector" "$STAGE/evidence" "$STAGE/tmp"
    for f in facts entities entity-attrs relations artifacts probes; do : > "$STAGE/collector/$f.records"; done
    : > "$STAGE/collector/notes.tsv"
    export LCTX_FACTS_RECORDS="$STAGE/collector/facts.records"
    export LCTX_ENTITIES_RECORDS="$STAGE/collector/entities.records"
    export LCTX_ENTITY_ATTRS_RECORDS="$STAGE/collector/entity-attrs.records"
    export LCTX_RELATIONS_RECORDS="$STAGE/collector/relations.records"
    export LCTX_ARTIFACTS_RECORDS="$STAGE/collector/artifacts.records"
    export LCTX_PROBES_RECORDS="$STAGE/collector/probes.records"
    export LCTX_NOTES_FILE="$STAGE/collector/notes.tsv"
    export LCTX_SECTION_DIR="$STAGE/evidence"
    export LCTX_PRIVATE_TMP="$STAGE/tmp"
    export LCTX_PROFILE=max LCTX_TARGETS=auto LCTX_COMMAND_TIMEOUT=5 LCTX_COMMAND_MAX_BYTES=1048576 LCTX_MAX_ITEMS=10000
    export LCTX_LOG_SINCE='7 days ago' LCTX_LOG_SAMPLE_ITEMS=200 LCTX_SIGNATURE_ITEMS=100
    export LCTX_OWNER_UID="$(id -u)" LCTX_OWNER_GID="$(id -g)" LCTX_OWNER_NAME="$(id -un)" LCTX_OWNER_HOME="${HOME:-/}" LCTX_OWNER_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
}

# Debian regression: label-less standalone Docker containers must not make the
# inspect template fail, and inspect is batched rather than one daemon call per
# container.
init_stage docker
fake="$t/fake-docker"; mkdir -p "$fake"
# Expose a fake *local Unix* Docker socket while poisoning inherited Docker
# endpoint/context variables. The collector must always pass an explicit local
# --host and must never honor the remote inherited endpoint.
mkdir -p "$t/runtime-docker"
export LCTX_OWNER_RUNTIME_DIR="$t/runtime-docker"
python3 -B -S - "$LCTX_OWNER_RUNTIME_DIR/docker.sock" <<'PYSOCK' &
import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(120)
PYSOCK
docker_sock_pid=$!
for _ in {1..50}; do [[ -S "$LCTX_OWNER_RUNTIME_DIR/docker.sock" ]] && break; sleep 0.02; done
export DOCKER_HOST='tcp://203.0.113.99:2375' DOCKER_CONTEXT='remote-production'
cat > "$fake/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
host=''
if [[ "${1:-}" == --host ]]; then host=${2:-}; shift 2; fi
printf 'host=%s cmd=%s\n' "$host" "${1:-}" >> "$DOCKER_HOST_LOG"
id1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
id2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
case "${1:-}" in
  info)
    if [[ "${2:-}" == --format ]]; then printf '26.1.5\toverlay2\tsystemd\t2\t2\n'; fi
    ;;
  ps)
    if [[ "${2:-}" == -a ]]; then
      printf '%s\tstandalone\tnginx:latest\trunning\n' "$id1"
      printf '%s\tstack-db\tpostgres:16\trunning\n' "$id2"
    fi
    ;;
  network)
    if [[ "${2:-}" == ls ]]; then
      printf 'bridge\t111111111111111111111111\n'
      printf 'stack_default\t222222222222222222222222\n'
    fi
    ;;
  inspect)
    printf 'inspect\n' >> "$DOCKER_MOCK_LOG"
    fmt=${3:-}
    case "$fmt" in
      *'META'*)
        printf 'META\t%s\tunless-stopped\tbridge\t111\n' "$id1"
        printf 'META\t%s\talways\tstack_default\t222\n' "$id2"
        ;;
      *'HEALTH'*)
        # Simulate the real Debian shape: standalone id1 has no health object.
        printf 'HEALTH\t%s\thealthy\n' "$id2"
        ;;
      *'COMPOSE'*) printf 'COMPOSE\t%s\tstack\n' "$id2" ;;
      *'NET'*)
        printf 'NET\t%s\tbridge\t172.17.0.2\t172.17.0.1\n' "$id1"
        printf 'NET\t%s\tstack_default\t172.20.0.2\t172.20.0.1\n' "$id2"
        ;;
      *'PORT'*|*'MOUNT'*) printf 'PORT\t%s\t80/tcp\t127.0.0.1\t8080\n' "$id1" ;;
    esac
    ;;
  *) ;;
esac
SH
chmod +x "$fake/docker"
export DOCKER_MOCK_LOG="$t/docker.log" DOCKER_HOST_LOG="$t/docker-host.log"
PATH="$fake:$PATH" "$ROOT/collectors/containers/docker.sh" --run
kill "$docker_sock_pid" 2>/dev/null || true; wait "$docker_sock_pid" 2>/dev/null || true
PYTHONPATH="$ROOT/lib" python3 -B -S - "$STAGE/collector" "$DOCKER_MOCK_LOG" "$DOCKER_HOST_LOG" "$LCTX_OWNER_RUNTIME_DIR/docker.sock" <<'PY'
from pathlib import Path
import sys
from recordio import read_records
root=Path(sys.argv[1])
ents=read_records(root/'entities.records','entities')
attrs=read_records(root/'entity-attrs.records','entity_attrs')
rels=read_records(root/'relations.records','relations')
facts=read_records(root/'facts.records','facts')
ids={x['id'] for x in ents}
assert 'docker-container:aaaaaaaaaaaa' in ids
assert 'docker-container:bbbbbbbbbbbb' in ids
by={(x['id'],x['key']):x['value'] for x in attrs}
assert by[('docker-container:aaaaaaaaaaaa','network_mode')]=='bridge',by
assert by[('docker-container:bbbbbbbbbbbb','network_mode')]=='stack_default',by
assert by[('docker-container:bbbbbbbbbbbb','health')]=='healthy',by
server=[x['value'] for x in facts if x['key']=='containers.docker.server_version']
assert server==['26.1.5'],server
assert any(x['from']=='compose-project:stack' and x['to']=='docker-container:bbbbbbbbbbbb' for x in rels)
assert Path(sys.argv[2]).read_text().count('inspect')==5
host_lines=Path(sys.argv[3]).read_text().splitlines()
assert host_lines,host_lines
# The collector intentionally prefers an available system Docker socket over an
# invoking-user socket. A developer workstation may therefore select
# /run/docker.sock while an isolated CI fixture selects the fake owner socket.
# The security invariant is local Unix-socket pinning, not a particular socket's
# precedence in the host environment.
hosts=[]
for line in host_lines:
    prefix=line.split(' cmd=',1)[0]
    assert prefix.startswith('host=unix://'),host_lines
    hosts.append(prefix.removeprefix('host='))
assert len(set(hosts)) == 1,host_lines
selected=hosts[0].removeprefix('unix://')
allowed={'/run/docker.sock','/var/run/docker.sock',sys.argv[4]}
assert selected in allowed,(selected,allowed,host_lines)
assert all('203.0.113.99' not in line for line in host_lines),host_lines
assert all('remote-production' not in line for line in host_lines),host_lines
PY

# Container-heavy hosts can expose dozens/hundreds of ephemeral veth peers.
# Broad auto keeps their count but not one graph node per peer.
init_stage network
fake2="$t/fake-net"; mkdir -p "$fake2"
cat > "$fake2/ip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "$args" in
  '-o link show')
    printf '1: lo: <LOOPBACK,UP> mtu 65536 state UNKNOWN mode DEFAULT group default qlen 1000\n'
    printf '2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500 state UP mode DEFAULT group default qlen 1000\n'
    printf '3: vethabc@if4: <BROADCAST,MULTICAST,UP> mtu 1500 master br-test state UP mode DEFAULT group default\n'
    printf '4: br-test: <BROADCAST,MULTICAST,UP> mtu 1500 state UP mode DEFAULT group default\n'
    ;;
  '-o addr show')
    printf '1 lo inet 127.0.0.1/8 scope host lo\n'
    printf '2 eth0 inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0\n'
    printf '3 vethabc@if4 inet6 fe80::1/64 scope link\n'
    printf '4 br-test inet 172.20.0.1/16 scope global br-test\n'
    ;;
  'route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
  '-details route show table all') printf 'default via 192.0.2.1 dev eth0\n192.0.2.0/24 dev eth0 proto kernel scope link\n' ;;
  'rule show') printf '0: from all lookup local\n32766: from all lookup main\n' ;;
  *) ;;
esac
SH
cat > "$fake2/ss" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == '-H -lntup' ]]; then
  printf 'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=999999,fd=3))\n'
elif [[ "$*" == '-s' ]]; then
  printf 'Total: 1\n'
fi
SH
cat > "$fake2/nft" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fake2"/*
PATH="$fake2:$PATH" "$ROOT/collectors/network/network.sh" --run
PYTHONPATH="$ROOT/lib" python3 -B -S - "$STAGE/collector" <<'PY'
from pathlib import Path
import sys
from recordio import read_records
root=Path(sys.argv[1])
ents=read_records(root/'entities.records','entities')
attrs=read_records(root/'entity-attrs.records','entity_attrs')
facts=read_records(root/'facts.records','facts')
ids={x['id'] for x in ents}
assert 'netif:vethabc' not in ids,ids
assert {'netif:lo','netif:eth0','netif:br-test'} <= ids
assert any(x['key']=='network.ephemeral_veth_count' and x['value']==1 for x in facts),facts
by={(x['id'],x['key']):x['value'] for x in attrs}
assert by[('netif:eth0','mtu')]==1500
assert by[('netif:eth0','state')]=='UP'
PY

# Broad session evidence must never retain the remote origin printed by `who`.
init_stage sessions
export LCTX_TARGETS=sessions
fake3="$t/fake-who"; mkdir -p "$fake3"
cat > "$fake3/who" <<'SH'
#!/usr/bin/env bash
printf 'alice    pts/0        2026-08-12 14:25 (203.0.113.42)\n'
SH
chmod +x "$fake3/who"
PATH="$fake3:$PATH" "$ROOT/collectors/sessions/desktop.sh" --run || true
if [[ -f "$STAGE/evidence/who.txt" ]]; then
    ! grep -q '203\.0\.113\.42' "$STAGE/evidence/who.txt"
    ! grep -q '(203\.0\.113\.42)' "$STAGE/evidence/who.txt"
fi

# BIOS hosts must not report normal mokutil/efivar absence as an evidence error.
# This is exercised when the test environment itself is non-UEFI (as CI
# containers normally are).
if [[ ! -d /sys/firmware/efi ]]; then
    init_stage boot
    fake4="$t/fake-mok"; mkdir -p "$fake4"
    cat > "$fake4/mokutil" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$MOKUTIL_MOCK_LOG"
printf 'EFI variables are not supported on this system\n'
exit 1
SH
    chmod +x "$fake4/mokutil"
    export MOKUTIL_MOCK_LOG="$t/mokutil.log"
    PATH="$fake4:$PATH" "$ROOT/collectors/boot/boot.sh" --run
    [[ ! -e "$MOKUTIL_MOCK_LOG" ]]
fi


# BlueZ tools may be installed while no local controller exists. That is a
# normal zero-controller state and must not create failed evidence in broad max.
init_stage bluetooth
fake5="$t/fake-bt"; mkdir -p "$fake5"
cat > "$fake5/bluetoothctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) exit 0 ;;
  show) printf 'No default controller available\n'; exit 1 ;;
esac
SH
chmod +x "$fake5/bluetoothctl"
PATH="$fake5:$PATH" "$ROOT/collectors/workstation/devices.sh" --run
[[ ! -e "$STAGE/evidence/bluetooth_controller.txt" ]]
PYTHONPATH="$ROOT/lib" python3 -B -S - "$STAGE/collector/facts.records" <<'PYBT'
from pathlib import Path
import sys
from recordio import read_records
facts=read_records(Path(sys.argv[1]),'facts')
by={x['key']:x['value'] for x in facts}
assert by['workstation.bluetooth.client_present'] is True,by
assert by['workstation.bluetooth.controller_count']==0,by
PYBT

printf 'Debian/cross-distro regression tests: ok\n'
