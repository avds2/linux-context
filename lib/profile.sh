#!/usr/bin/env bash

profile_rank() {
    case "$1" in
        quick) printf 10 ;;
        standard) printf 20 ;;
        deep) printf 30 ;;
        max) printf 40 ;;
        *) return 1 ;;
    esac
}

profile_semantics() {
    case "$1" in
        quick) printf '%s' 'small bounded host fingerprint' ;;
        standard) printf '%s' 'core bounded operating-system and topology snapshot' ;;
        deep) printf '%s' 'detailed bounded runtime and configuration inventory' ;;
        max) printf '%s' 'maximum useful safe bounded read-only understanding under an AI evidence budget' ;;
        *) printf '%s' 'unknown profile semantics' ;;
    esac
}

load_profile() {
    local profile="$1"
    local file="$LCTX_PROJECT_ROOT/profiles/$profile.conf"
    [[ -r "$file" ]] || fatal "Unknown profile: $profile"
    # shellcheck disable=SC1090
    source "$file"
    : "${LCTX_JOBS:=1}"
    : "${LCTX_EVIDENCE_BUDGET_BYTES:=1048576}"
    : "${LCTX_LOG_SAMPLE_ITEMS:=100}"
    : "${LCTX_SIGNATURE_ITEMS:=100}"
    export LCTX_PROFILE="$profile" LCTX_COMMAND_TIMEOUT LCTX_COMMAND_MAX_BYTES LCTX_LOG_SINCE LCTX_MAX_ITEMS
    export LCTX_JOBS LCTX_LOG_SAMPLE_ITEMS LCTX_SIGNATURE_ITEMS LCTX_EVIDENCE_BUDGET_BYTES
}

profile_allows() {
    local requested minimum
    requested=$(profile_rank "$1") || return 1
    minimum=$(profile_rank "$2") || return 1
    (( requested >= minimum ))
}
