#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
cat > "$t/bin/sysctl" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == -a ]]; then
    printf 'kernel.fixture = 1\nnet.fixture = 2\n'
    exit 1
fi
printf '%s = 1\n' "${1:-fixture.key}"
exit 0
SH
chmod +x "$t/bin/sysctl"
PATH="$t/bin:$PATH" "$ROOT/bin/linux-context" --profile max --target kernel --output "$t/out" --no-archive >/dev/null 2>"$t/err"
python3 -B -S - "$t/out/meta/evidence.json" "$t/out/meta/validation.json" <<'PY'
import json,sys
e=json.load(open(sys.argv[1],encoding='utf-8'))
v=json.load(open(sys.argv[2],encoding='utf-8'))
assert not any(row[0]=='core.kernel:sysctl_all' for row in e.get('issues',[])), e.get('issues')
assert v['status']=='valid',v
assert not any('unexpected exit' in w for w in v.get('warnings',[])),v
row=next(row for row in e['evidence'] if row[0]=='core.kernel:sysctl_all')
assert row[2]=='ok',row
PY
printf 'sysctl exhaustive-status test: ok\n'
