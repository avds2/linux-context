#!/usr/bin/env bash
# Archive the committed tree, never incidental working-directory contents.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=${1:?Usage: build-release.sh OUTPUT_DIR}
version=$(git -C "$ROOT" show HEAD:VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'A stable semantic VERSION is required\n' >&2; exit 1; }
mkdir -p -- "$output"
output=$(cd -- "$output" && pwd)
base="linux-context-v$version"
archive="$output/$base.tar.gz"
checksum="$archive.sha256"
[[ ! -e "$archive" && ! -e "$checksum" ]] || { printf 'Release output already exists\n' >&2; exit 1; }
work=$(mktemp -d "$output/.release.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
git -C "$ROOT" -c tar.umask=0022 archive --format=tar --prefix="$base/" HEAD | gzip -n > "$work/$base.tar.gz"
(cd "$work" && sha256sum "$base.tar.gz" > "$base.tar.gz.sha256" && sha256sum -c "$base.tar.gz.sha256")
mv -- "$work/$base.tar.gz" "$archive"
mv -- "$work/$base.tar.gz.sha256" "$checksum"
printf 'Archive: %s\nChecksum: %s\n' "$archive" "$checksum"
