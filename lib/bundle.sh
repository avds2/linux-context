#!/usr/bin/env bash

# Bundle lifecycle. Collector outputs remain in private staging until one batched
# redaction pass succeeds. Only sanitized evidence and the compact canonical graph
# are installed into the shareable bundle.

init_bundle() {
    local stamp host requested parent
    stamp=$(utc_stamp)
    host=$(safe_name "$(host_name)")
    [[ -n "$host" ]] || host='unknown'
    detect_output_owner

    requested=${LCTX_OUTPUT_DIR:-}
    [[ -n "$requested" ]] || requested="$PWD/linux-context-${host}-${stamp}"
    # Python is already a mandatory dependency and provides lexical absolute-path
    # normalization without creating/traversing the destination.
    LCTX_FINAL_OUTPUT_DIR=$(lctx_python - "$requested" <<'PYABS'
import os,sys
print(os.path.abspath(sys.argv[1]))
PYABS
)
    parent=$(dirname -- "$LCTX_FINAL_OUTPUT_DIR")
    [[ -d "$parent" ]] || fatal "Output parent directory does not exist: $parent"
    [[ ! -e "$LCTX_FINAL_OUTPUT_DIR" ]] || fatal "Refusing to overwrite existing output path: $LCTX_FINAL_OUTPUT_DIR"
    if (( ${LCTX_ARCHIVE:-1} )) && [[ -e "$LCTX_FINAL_OUTPUT_DIR.tar.gz" ]]; then
        fatal "Refusing to overwrite existing archive: $LCTX_FINAL_OUTPUT_DIR.tar.gz"
    fi

    local tmp_parent
    tmp_parent=$(secure_tmp_parent)
    LCTX_TMP_DIR=$(mktemp -d "$tmp_parent/linux-context.XXXXXX")
    LCTX_PRIVATE_TMP="$LCTX_TMP_DIR/private"
    LCTX_STAGE_ROOT="$LCTX_TMP_DIR/stage"
    # All privileged writes stay in this private trusted tree. Publication to the
    # caller-selected path happens only after redaction/validation and privilege handoff.
    LCTX_OUTPUT_DIR="$LCTX_TMP_DIR/bundle"
    mkdir -p "$LCTX_OUTPUT_DIR/meta" "$LCTX_OUTPUT_DIR/sections" \
        "$LCTX_PRIVATE_TMP" "$LCTX_STAGE_ROOT/collectors" "$LCTX_STAGE_ROOT/evidence" "$LCTX_STAGE_ROOT/meta"
    chmod 700 "$LCTX_OUTPUT_DIR" "$LCTX_OUTPUT_DIR/meta" "$LCTX_OUTPUT_DIR/sections" \
        "$LCTX_TMP_DIR" "$LCTX_PRIVATE_TMP" "$LCTX_STAGE_ROOT" 2>/dev/null || true

    LCTX_STARTED_UTC=$(utc_now)
    LCTX_STARTED_EPOCH=$(epoch_now)
    LCTX_STARTED_MS=$(epoch_millis)
    export LCTX_FINAL_OUTPUT_DIR LCTX_OUTPUT_DIR LCTX_TMP_DIR LCTX_PRIVATE_TMP LCTX_STAGE_ROOT
    export LCTX_STARTED_UTC LCTX_STARTED_EPOCH LCTX_STARTED_MS
}

cleanup_tmp() {
    if [[ -n "${LCTX_TMP_DIR:-}" && -d "$LCTX_TMP_DIR" ]]; then
        rm -rf -- "$LCTX_TMP_DIR"
    fi
    return 0
}

prune_staging_evidence() {
    lctx_python "$LCTX_PROJECT_ROOT/lib/prune.py" --stage "$LCTX_STAGE_ROOT" --budget "$LCTX_EVIDENCE_BUDGET_BYTES"
}

# Redact and scan all collector-produced material in a single Python process.
# Nothing from the raw staging tree is copied into the bundle unless this passes.
secure_staging() {
    redaction_python_available || return 70
    lctx_python "$LCTX_PROJECT_ROOT/lib/redact.py" secure-tree "$LCTX_STAGE_ROOT"
}

install_sanitized_stage() {
    local src
    src="$LCTX_STAGE_ROOT/evidence"
    if [[ -d "$src" ]]; then
        find "$src" -mindepth 1 -maxdepth 1 -type d -print0 | while IFS= read -r -d '' d; do
            mv -- "$d" "$LCTX_OUTPUT_DIR/sections/"
        done
    fi
    # The stage report is useful provenance for compilation. The final bundle is
    # scanned again after context.json is generated.
    [[ -r "$LCTX_STAGE_ROOT/meta/redaction.json" ]] && cp -- "$LCTX_STAGE_ROOT/meta/redaction.json" "$LCTX_OUTPUT_DIR/meta/stage-redaction.json"
}

compile_context() {
    local finished_utc duration_s
    finished_utc=$(utc_now)
    duration_s=$(( $(epoch_now) - LCTX_STARTED_EPOCH ))
    lctx_python "$LCTX_PROJECT_ROOT/lib/compile.py" \
        --stage "$LCTX_STAGE_ROOT" \
        --bundle "$LCTX_OUTPUT_DIR" \
        --tool-version "$LCTX_VERSION" \
        --profile "$LCTX_PROFILE" \
        --profile-semantics "$(profile_semantics "$LCTX_PROFILE")" \
        --targets "$LCTX_TARGETS" \
        --started "$LCTX_STARTED_UTC" \
        --finished "$finished_utc" \
        --duration "$duration_s" \
        --evidence-budget "$LCTX_EVIDENCE_BUDGET_BYTES" \
        --context-budget "$LCTX_CONTEXT_BUDGET_BYTES" \
        --euid "$EUID" \
        --owner-uid "$LCTX_OWNER_UID" \
        --owner-gid "$LCTX_OWNER_GID" \
        --owner-source "$LCTX_OWNER_SOURCE" \
        --redaction-engine "$LCTX_REDACTION_ENGINE" \
        --redaction-assurance "$LCTX_REDACTION_ASSURANCE"
}

final_scan() {
    lctx_python "$LCTX_PROJECT_ROOT/lib/redact.py" scan "$LCTX_OUTPUT_DIR"
}

write_manifest() {
    local manifest="$LCTX_OUTPUT_DIR/manifest.sha256"
    : > "$manifest"
    while IFS= read -r -d '' file; do
        [[ "$file" == "$manifest" ]] && continue
        printf '%s  %s\n' "$(sha256_file "$file")" "${file#"$LCTX_OUTPUT_DIR/"}" >> "$manifest"
    done < <(find "$LCTX_OUTPUT_DIR" -type f -print0 | LC_ALL=C sort -z)
}

secure_and_handoff_bundle() {
    find "$LCTX_OUTPUT_DIR" -type d -exec chmod 700 {} + 2>/dev/null || true
    find "$LCTX_OUTPUT_DIR" -type d -exec chmod g-s {} + 2>/dev/null || true
    find "$LCTX_OUTPUT_DIR" -type f -exec chmod 600 {} + 2>/dev/null || true
    if (( EUID == 0 )) && [[ "$LCTX_OWNER_UID:$LCTX_OWNER_GID" != "0:0" ]]; then
        chown -R "$LCTX_OWNER_UID:$LCTX_OWNER_GID" "$LCTX_OUTPUT_DIR"
    elif (( EUID != 0 )); then
        chgrp -R "$LCTX_OWNER_GID" "$LCTX_OUTPUT_DIR" 2>/dev/null || true
    fi
}

publish_bundle() {
    local work="$LCTX_OUTPUT_DIR" final="$LCTX_FINAL_OUTPUT_DIR"
    [[ -d "$work" ]] || fatal 'Internal bundle directory disappeared before publication.'
    # Raw/private staging is destroyed before the temporary parent becomes
    # traversable by the invoking user.
    rm -rf -- "$LCTX_STAGE_ROOT" "$LCTX_PRIVATE_TMP"
    secure_and_handoff_bundle

    if (( EUID == 0 )) && [[ "$LCTX_OWNER_UID:$LCTX_OWNER_GID" != "0:0" ]]; then
        chown "$LCTX_OWNER_UID:$LCTX_OWNER_GID" "$LCTX_TMP_DIR"
        chmod 700 "$LCTX_TMP_DIR"
        run_as_output_owner bash -c '
            set -e
            src=$1; dst=$2
            [ ! -e "$dst" ] || { printf "destination appeared during collection: %s\n" "$dst" >&2; exit 73; }
            mv -T -- "$src" "$dst"
        ' _ "$work" "$final" || fatal "Unable to publish bundle as invoking user: $final"
    else
        [[ ! -e "$final" ]] || fatal "Destination appeared during collection: $final"
        mv -T -- "$work" "$final"
    fi
    LCTX_OUTPUT_DIR="$final"
    export LCTX_OUTPUT_DIR
}

remove_published_bundle() {
    [[ -n "${LCTX_OUTPUT_DIR:-}" && -d "$LCTX_OUTPUT_DIR" ]] || return 0
    if (( EUID == 0 )) && [[ "$LCTX_OWNER_UID:$LCTX_OWNER_GID" != "0:0" ]]; then
        run_as_output_owner rm -rf -- "$LCTX_OUTPUT_DIR"
    else
        rm -rf -- "$LCTX_OUTPUT_DIR"
    fi
}

archive_bundle() {
    local parent base archive
    parent=$(dirname -- "$LCTX_OUTPUT_DIR")
    base=$(basename -- "$LCTX_OUTPUT_DIR")
    archive="$parent/$base.tar.gz"
    [[ ! -e "$archive" ]] || fatal "Refusing to overwrite existing archive: $archive"
    if (( EUID == 0 )) && [[ "$LCTX_OWNER_UID:$LCTX_OWNER_GID" != "0:0" ]]; then
        run_as_output_owner tar -C "$parent" -czf "$archive" -- "$base" || fatal 'Archive creation failed as invoking user.'
        run_as_output_owner chmod 600 "$archive" || true
    else
        tar -C "$parent" -czf "$archive" -- "$base"
        chmod 600 "$archive" 2>/dev/null || true
    fi
    printf '%s\n' "$archive"
}
