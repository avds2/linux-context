#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/private"
export LCTX_PROJECT_ROOT="$ROOT" LCTX_PRIVATE_TMP="$t/private"
export LCTX_PROFILE=deep LCTX_TARGETS=auto LCTX_COMMAND_TIMEOUT=2 LCTX_COMMAND_MAX_BYTES=4096 LCTX_MAX_ITEMS=100
export LCTX_TIMEOUT_BACKEND=python
for cmd in dpkg-query rpm pacman apk; do
    cat > "$t/bin/$cmd" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${0##*/} $*" >> "$PACKAGE_CALLS"
case "$PACKAGE_MODE" in
  fail) exit 1 ;;
  huge) for i in {1..200}; do printf 'installed\tpackage-%s\t1.0\tamd64\n' "$i"; done; exit 0 ;;
esac
case "${0##*/}" in
  dpkg-query) printf 'installed\talpha\t1.0\tamd64\nconfig-files\tremoved\t2.0\tamd64\nnot-installed\tabsent\t0\tamd64\ninstalled\tbeta\t3.0\tarm64\n' ;;
  rpm) printf 'alpha\t1.0-1\tx86_64\nbeta\t3.0-1\taarch64\n' ;;
  pacman) printf 'alpha 1.0\nlinux 6.1\n' ;;
  apk) printf 'alpha-1.0 description\nbeta-3.0 description\n' ;;
esac
SH
    chmod +x "$t/bin/$cmd"
done
export PATH="$t/bin:$PATH"
for pm in dpkg-query rpm pacman apk; do
    for mode in normal fail; do
        (
            export PACKAGE_MODE="$mode" PACKAGE_CALLS="$t/$pm-$mode.calls"
            export LCTX_SECTION_DIR="$t/$pm-$mode"
            mkdir "$LCTX_SECTION_DIR"
            for name in FACTS ENTITIES ENTITY_ATTRS RELATIONS ARTIFACTS PROBES; do
                export "LCTX_${name}_RECORDS=$LCTX_SECTION_DIR/$name.records"
                : > "$LCTX_SECTION_DIR/$name.records"
            done
            export LCTX_NOTES_FILE="$LCTX_SECTION_DIR/notes.tsv"
            : > "$LCTX_NOTES_FILE"
            source "$ROOT/collectors/packages/packages.sh" --meta >/dev/null
            command_exists() { [[ "$1" == "$pm" ]]; }
            run_shell_capture() { :; }
            capture_file_if_readable() { :; }
            collector_collect
            PYTHONPATH="$ROOT/lib" python3 -B -S - "$LCTX_FACTS_RECORDS" "$mode" "$PACKAGE_CALLS" <<'PY'
from pathlib import Path
import sys
from recordio import read_records
facts = read_records(Path(sys.argv[1]), 'facts')
counts = [f['value'] for f in facts if f['key'] == 'packages.installed_count']
assert counts == ([2] if sys.argv[2] == 'normal' else []), facts
assert len(Path(sys.argv[3]).read_text().splitlines()) == 1
PY
        )
    done
done
printf 'Debian/RPM/pacman/apk single-query counts and failures: ok\n'
