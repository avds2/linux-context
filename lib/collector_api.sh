#!/usr/bin/env bash

COLLECTOR_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$COLLECTOR_LIB_DIR/common.sh"
source "$COLLECTOR_LIB_DIR/runner.sh"

: "${COLLECTOR_ID:?collector must define COLLECTOR_ID before collector_main}"
: "${COLLECTOR_MIN_PROFILE:=quick}"
: "${COLLECTOR_TARGETS:=system}"
: "${COLLECTOR_PRIVILEGE:=user}"
: "${COLLECTOR_BASELINE:=0}"
: "${COLLECTOR_DESCRIPTION:=No description}"

record_collector_note() {
    local note
    normalize_one_line_into note "$1"
    printf '%s\t%s\n' "$COLLECTOR_ID" "$note" >> "$LCTX_NOTES_FILE"
}

_emit_record() {
    # Bash variables cannot contain NUL. NUL-delimited fixed-arity staging is
    # therefore unambiguous for every host-derived value Bash can represent.
    # Python alone owns JSON serialization later in the pipeline.
    #
    # Structured collectors can emit hundreds of records. Keep their staging
    # files open for the lifetime of --run instead of reopening a path for every
    # fact/entity/attribute/relation; this materially reduces syscall overhead on
    # small VPSes while preserving the same on-disk record format.
    local out="$1" fd=''; shift
    case "$out" in
        "$LCTX_FACTS_RECORDS") fd=${_LCTX_FACTS_FD:-} ;;
        "$LCTX_ENTITIES_RECORDS") fd=${_LCTX_ENTITIES_FD:-} ;;
        "$LCTX_ENTITY_ATTRS_RECORDS") fd=${_LCTX_ENTITY_ATTRS_FD:-} ;;
        "$LCTX_RELATIONS_RECORDS") fd=${_LCTX_RELATIONS_FD:-} ;;
    esac
    if [[ "$fd" =~ ^[0-9]+$ ]]; then
        printf '%s\0' "$@" >&"$fd"
    else
        printf '%s\0' "$@" >> "$out"
    fi
}

_open_structured_record_fds() {
    exec {_LCTX_FACTS_FD}>>"$LCTX_FACTS_RECORDS"
    exec {_LCTX_ENTITIES_FD}>>"$LCTX_ENTITIES_RECORDS"
    exec {_LCTX_ENTITY_ATTRS_FD}>>"$LCTX_ENTITY_ATTRS_RECORDS"
    exec {_LCTX_RELATIONS_FD}>>"$LCTX_RELATIONS_RECORDS"
}

_close_structured_record_fds() {
    [[ "${_LCTX_FACTS_FD:-}" =~ ^[0-9]+$ ]] && exec {_LCTX_FACTS_FD}>&- || true
    [[ "${_LCTX_ENTITIES_FD:-}" =~ ^[0-9]+$ ]] && exec {_LCTX_ENTITIES_FD}>&- || true
    [[ "${_LCTX_ENTITY_ATTRS_FD:-}" =~ ^[0-9]+$ ]] && exec {_LCTX_ENTITY_ATTRS_FD}>&- || true
    [[ "${_LCTX_RELATIONS_FD:-}" =~ ^[0-9]+$ ]] && exec {_LCTX_RELATIONS_FD}>&- || true
    unset _LCTX_FACTS_FD _LCTX_ENTITIES_FD _LCTX_ENTITY_ATTRS_FD _LCTX_RELATIONS_FD
}

emit_fact() {
    local key value source observation_type confidence value_type
    normalize_one_line_into key "$1"
    normalize_one_line_into value "$2"
    normalize_one_line_into source "${3:-$COLLECTOR_ID}"
    normalize_one_line_into observation_type "${4:-observed}"
    normalize_one_line_into confidence "${5:-1.0}"
    normalize_one_line_into value_type "${6:-string}"
    _emit_record "$LCTX_FACTS_RECORDS" \
        "$key" "$value" "$value_type" "$source" "$observation_type" "$confidence" "$COLLECTOR_ID"
}

emit_entity() {
    local entity_id entity_type label source observation_type confidence
    normalize_one_line_into entity_id "$1"
    normalize_one_line_into entity_type "$2"
    normalize_one_line_into label "${3:-$1}"
    normalize_one_line_into source "${4:-$COLLECTOR_ID}"
    normalize_one_line_into observation_type "${5:-observed}"
    normalize_one_line_into confidence "${6:-1.0}"
    _emit_record "$LCTX_ENTITIES_RECORDS" \
        "$entity_id" "$entity_type" "$label" "$source" "$observation_type" "$confidence" "$COLLECTOR_ID"
}

# Attach typed state directly to an entity instead of repeating high-cardinality
# object state as global facts. This is the primary anti-context-bloat primitive.
emit_entity_attr() {
    local entity_id key value source observation_type confidence value_type
    normalize_one_line_into entity_id "$1"
    normalize_one_line_into key "$2"
    normalize_one_line_into value "$3"
    normalize_one_line_into source "${4:-$COLLECTOR_ID}"
    normalize_one_line_into observation_type "${5:-observed}"
    normalize_one_line_into confidence "${6:-1.0}"
    normalize_one_line_into value_type "${7:-string}"
    _emit_record "$LCTX_ENTITY_ATTRS_RECORDS" \
        "$entity_id" "$key" "$value" "$value_type" "$source" "$observation_type" "$confidence" "$COLLECTOR_ID"
}

emit_relation() {
    local from predicate to source observation_type confidence
    normalize_one_line_into from "$1"
    normalize_one_line_into predicate "$2"
    normalize_one_line_into to "$3"
    normalize_one_line_into source "${4:-$COLLECTOR_ID}"
    normalize_one_line_into observation_type "${5:-observed}"
    normalize_one_line_into confidence "${6:-1.0}"
    _emit_record "$LCTX_RELATIONS_RECORDS" \
        "$from" "$predicate" "$to" "$source" "$observation_type" "$confidence" "$COLLECTOR_ID"
}

fact_from_command() {
    local key="$1"; shift
    local source="$1"; shift
    local value
    value=$(LC_ALL=C LANG=C "$@" 2>/dev/null | head -n 1 || true)
    [[ -n "$value" ]] && emit_fact "$key" "$value" "$source"
}

profile_at_least() {
    local requested minimum
    case "${LCTX_PROFILE:-standard}" in quick) requested=10;; standard) requested=20;; deep) requested=30;; max) requested=40;; *) requested=0;; esac
    case "$1" in quick) minimum=10;; standard) minimum=20;; deep) minimum=30;; max) minimum=40;; *) minimum=999;; esac
    (( requested >= minimum ))
}

collector_detect() { return 0; }
collector_collect() { return 0; }

collector_main() {
    case "${1:-}" in
        --meta)
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$COLLECTOR_ID" "$COLLECTOR_MIN_PROFILE" "$COLLECTOR_TARGETS" \
                "$COLLECTOR_PRIVILEGE" "$COLLECTOR_BASELINE" "$COLLECTOR_DESCRIPTION"
            ;;
        --detect)
            collector_detect
            ;;
        --run)
            : "${LCTX_SECTION_DIR:?}"
            : "${LCTX_PRIVATE_TMP:?}"
            : "${LCTX_FACTS_RECORDS:?}"
            : "${LCTX_ENTITIES_RECORDS:?}"
            : "${LCTX_ENTITY_ATTRS_RECORDS:?}"
            : "${LCTX_RELATIONS_RECORDS:?}"
            : "${LCTX_ARTIFACTS_RECORDS:?}"
            : "${LCTX_PROBES_RECORDS:?}"
            : "${LCTX_NOTES_FILE:?}"
            mkdir -p "$LCTX_SECTION_DIR"
            _open_structured_record_fds
            collector_collect
            local rc=$?
            _close_structured_record_fds
            return "$rc"
            ;;
        *)
            printf 'Usage: %s --meta|--detect|--run\n' "$0" >&2
            return 64
            ;;
    esac
}
