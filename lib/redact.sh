#!/usr/bin/env bash

# Enhanced redaction boundary. Python is already required by the compiler, so
# production collection never degrades to a weaker text-only fallback.

LCTX_REDACT_ROOT=${LCTX_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}

redaction_python_available() {
    command -v python3 >/dev/null 2>&1 && [[ -r "$LCTX_REDACT_ROOT/lib/redact.py" ]]
}

init_redaction() {
    redaction_python_available || fatal 'Python 3 and lib/redact.py are required for secure collection.'

    # Tests may request a deterministic salt explicitly. Normal runtime ignores
    # caller-provided LCTX_REDACTION_SALT so correlation markers cannot become
    # stable across runs by accident or environment inheritance.
    if [[ "${LCTX_TESTING:-0}" == 1 && -n "${LCTX_TEST_REDACTION_SALT:-}" ]]; then
        LCTX_REDACTION_SALT="$LCTX_TEST_REDACTION_SALT"
    else
        LCTX_REDACTION_SALT=$(lctx_python -c 'import secrets; print(secrets.token_hex(32))') || \
            fatal 'Unable to obtain cryptographically secure per-run redaction randomness.'
    fi
    [[ "$LCTX_REDACTION_SALT" =~ ^[0-9a-fA-F]{64}$ || "${LCTX_TESTING:-0}" == 1 ]] || \
        fatal 'Redaction salt generation failed validation.'

    LCTX_REDACTION_ENGINE='python-enhanced'
    LCTX_REDACTION_ASSURANCE='enhanced'
    export LCTX_REDACTION_SALT LCTX_REDACTION_ENGINE LCTX_REDACTION_ASSURANCE
}

redact_file() {
    local input="$1" output="$2"
    lctx_python "$LCTX_REDACT_ROOT/lib/redact.py" redact "$input" "$output"
}

sanitize_bundle_text_in_place() {
    local root="${1:-${LCTX_OUTPUT_DIR:-}}"
    [[ -n "$root" ]] || return 64
    lctx_python "$LCTX_REDACT_ROOT/lib/redact.py" tree "$root"
}

scan_bundle_for_secret_risk() {
    local root="${1:-${LCTX_OUTPUT_DIR:-}}"
    [[ -n "$root" ]] || return 64
    lctx_python "$LCTX_REDACT_ROOT/lib/redact.py" scan "$root"
}
