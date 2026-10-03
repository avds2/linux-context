# Contributing

Contributions should preserve the contract: useful Linux understanding per token,
passive acquisition, explicit coverage, mandatory redaction and bounded output.

## Development environment

Use Linux, Bash 4.0+, Python 3.9+, `make`, common Linux userland tools and tar/gzip
for archive tests. The regression suite also uses `cmp`; minimal Fedora/Arch
images need `diffutils`. Python third-party packages are not required. GNU
`timeout` is optional at runtime; keep BusyBox paths working.

```bash
make syntax
make check
bash tests/smoke-distribution.sh
```

`make syntax` parses shell sources and compiles Python source in memory without
writing bytecode. `make check` adds every `tests/test-*.sh` script. The smoke script
is separate and exercises all four profiles, archives, manifests, exact decoded
AI data, budgets and residual scans. `make version` reports `VERSION` through the
launcher. `make check` does not invoke ShellCheck, a formatter or a type checker.

CI keeps Python 3.9/3.11/3.13 jobs and distribution containers for Debian 12,
Fedora 43, Arch and Alpine 3.22. Each distribution runs check and smoke. Avoid
installing GNU coreutils/findutils into Alpine simply to make its tests pass.
Containers do not validate real device firmware, a live desktop or every daemon.

Tests must be independent of the host's daemon/socket state. Inject only the
needed fixture boundary and keep production command selection/parsing under test.
Ownership integration uses UID 65534 when mapping/chown is possible; otherwise
it explicitly reports current-user-only coverage. The Python drop order is also
unit-tested. New tests should cover meaningful behavior/failure/privacy, not
mirror implementation details. Documentation-only edits need example/link checks;
full regression results are useful when assertions depend on runtime behavior.

## Code map and lifecycle

| Component | Responsibility |
|---|---|
| `bin/linux-context` | CLI validation, cached catalog, selection, supervised workers and lifecycle orchestration |
| `lib/common.sh`, `lib/profile.sh` | Shared primitives, owner scope, execution backend and profile policy |
| `lib/catalog.py` | Metadata validation and isolated per-collector stage initialization |
| `lib/collector_api.sh`, `lib/runner.sh`, `lib/recordio.py` | Structured emission, bounded captures and strict shell/Python boundary |
| `lib/timeout.py`, `lib/stop_workers.py`, `lib/as_owner.py` | Watchdogs, nested producer termination and privilege fallback |
| `lib/prune.py`, `lib/redact.py`, `lib/redact.sh` | Pre-redaction evidence pruning, structural/text redaction and scans |
| `lib/compile.py`, `lib/validate_bundle.py` | Model merge/deferral, routing, structural checks and final byte reconciliation |
| `lib/ai_view.py`, `lib/manifest.py`, `lib/finalize.py` | Lossless encoding, checksums and final ordered gates |
| `lib/bundle.sh` | Trusted staging, ownership, publication and archives |
| `lib/hardware_model.py`, `lib/os_release.py`, `lib/file_inventory.py` | Specialized parsers and portable observations |
| `collectors/`, `profiles/`, `tests/` | Subsystem implementations, budgets and regression fixtures |

Acquisition is isolated by collector. Prune raw evidence, redact/scan private
staging, install sanitized evidence privately and compile the canonical model.
Then finalize in this order: sanitize generated files, reconcile sizes/graph,
derive/round-trip AI view, residual scan/reports, manifest. Destroy private raw
material and hand off ownership before publishing the directory. Archive after
publication; do not describe archive creation as an atomic directory+archive
transaction.

## Collector API

Collectors live under `collectors/<domain>/`, are executable Bash scripts, define
metadata before sourcing the API and dispatch exactly once at the footer. The
API defines default detect/collect functions, so override them **after** sourcing.
Sourcing the API must not dispatch a collector by itself.

A minimal complete example for `collectors/example/subsystem.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
COLLECTOR_ID='example.subsystem'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='example'
COLLECTOR_PRIVILEGE='user'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Example bounded machine observation.'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/collector_api.sh"

collector_detect() { command_exists uname; }

collector_collect() {
    local architecture
    architecture=$(bounded_command uname -m) || return 1
    emit_entity host:local host host fixture
    emit_fact example.architecture "$architecture" 'uname -m'
    emit_entity example:one example_device one fixture
    emit_entity_attr example:one available true fixture observed 1.0 boolean
    emit_relation host:local has_example example:one fixture
    return 0
}

collector_main "$@"
```

The example target becomes valid only when its metadata is in the catalog. Do
not ship the example unchanged as a real diagnostic collector. Test `--meta`
(one six-field TSV row) and `--detect` separately. `--run` is an internal worker
interface that requires initialized stage/record environment; use the launcher
for end-to-end runs.

IDs must match the catalog's lowercase `[a-z0-9]+([._-][a-z0-9]+)*` pattern and be
unique. Profiles are quick/standard/deep/max, privilege is user/optional-root/root,
and baseline is 0/1. Keep target tokens and descriptions free of tabs/newlines.
A `user` label does not drop root privileges automatically. Use owner helpers
for a sudo invoker's user-service/audio/Flatpak/session state.

### Structured emission

| Function | Positional arguments |
|---|---|
| `emit_fact` | `key value [source [observation_type [confidence [value_type]]]]` |
| `emit_entity` | `id type [label [source [observation_type [confidence]]]]` |
| `emit_entity_attr` | `id key value [source [observation_type [confidence [value_type]]]]` |
| `emit_relation` | `from predicate to [source [observation_type [confidence]]]` |
| `record_collector_note` | `note` |

Defaults are source=collector ID, observation_type=observed, confidence=1.0 and
value_type=string. Facts/attributes support string/number/boolean/null; null
requires the literal `null`. Confidence must be finite in `[0,1]`. Give inferred
state explicit provenance/confidence. Do not turn failed access into false/zero.

Shell emission normalizes whitespace into one line. Fixed-arity NUL-delimited
records keep representable shell values unambiguous; Bash cannot represent NUL.
Python parses types and owns JSON serialization. Never construct staging JSON
with shell interpolation. Missing/invalid terminators, arity, typed values or
confidence cause failure, not coercion. Preserve boolean/number distinctions and
multiple observations when changing merge logic.

### Acquisition helpers

| Helper | Signature and purpose |
|---|---|
| `run_capture` | `label seconds max_bytes [--source S] [--priority N] [--ok-exit RC[,RC...]] -- command args...`; retained evidence |
| `probe_capture` | `label seconds max_bytes [--source S] [--ok-exit RC[,RC...]] -- command args...`; private ephemeral output |
| `capture_file_if_readable` | `label path [max_bytes [priority]]`; capped regular-file read |
| `capture_active_config_if_readable` | `label path [max_bytes [priority]]`; timed non-comment configuration capture |
| `run_shell_capture` | `label seconds max_bytes script`; project-owned Bash pipeline with pipefail |
| `run_owner_capture` | Same capture options; command in invoking-user scope when applicable |
| `run_owner_shell_capture` | `label seconds max_bytes script`; owner-scope pipeline |
| `probe_owner_capture` | `label seconds max_bytes -- command args...`; owner-scope ephemeral probe |
| `bounded_command` / `run_as_output_owner` | Timeout-bound direct command; no independent byte cap or probe telemetry |

After `probe_capture`, parse `$LCTX_PROBE_FILE`, then call `release_probe` on every
path. Inspect `LCTX_CAPTURE_RC`, `LCTX_CAPTURE_TRUNCATED`, `LCTX_CAPTURE_TIMED_OUT`,
`LCTX_CAPTURE_BYTES` and `LCTX_CAPTURE_DURATION_MS`. Accepted truncated output can
return success; test completeness before deriving exact counts or parsing JSON.
The runner captures stdout/stderr together. Accepted exit codes describe useful
command output, not necessarily healthy host state.

Persistent labels are normalized and must be unique per collector; reuse is an
error. Default priority is 50; choose a deliberate higher/lower priority for
retained evidence. `run_shell_capture` lacks the capture option list; call
`run_capture ... -- bash -o pipefail -c '...'` when options are needed. Script
text must be project-owned; pass host values as quoted arguments, never splice
them into executable shell syntax.

Use `target_requested NAME` (true for all), `target_is_auto`, and
`profile_at_least TIER` for detail gates. Keep baseline modeling small; gate
expensive/high-cardinality evidence separately. Profile defaults are not a
universal per-command/item cap: explicit helper arguments and branches matter.

For minimal userlands, publication feature-checks setpriv; the current runner's
owner capture/probe helpers still select setpriv by presence. Optional owner
probes can therefore fail on BusyBox even though publication succeeds. Do not
claim complete owner-probe compatibility until those paths are aligned and
covered; see [the known limitation](docs/TROUBLESHOOTING.md#per-user-probes-on-busybox).

## Security and compatibility rules

Do not intentionally acquire credential stores, private keys, process environments,
full argv, Docker environment values, user documents or arbitrary application
payloads. Prefer aggregate state over persistent user/device/remote identifiers.
Ephemeral output is private, but not exempt from source avoidance.

No install/update/refresh/reload/restart, sysctl/config/network mutation, mounts,
active external probes or active Wi-Fi scans. Optional utilities should be
capability-detected; binary presence does not establish runtime state. Keep
locale deterministic, quote values, use exact-source provenance, and distinguish
observed/inferred/unknown. Bind Docker to an explicit local Unix socket.

Use `|| true` only when failure is an expected optional observation and is exposed
appropriately. Structural/catalog/worker errors must fail publication. Do not
add an alternate execution, redaction or publication boundary. Update the threat
model for changes to privileged paths, acquisition scope or resource guarantees.

## Documentation and release changes

Update README usage, profile/collector tables, format semantics and troubleshooting
when behavior changes. Verify examples against the launcher/API/profile files,
relative links against tracked files, and serialized examples with a JSON parser.
Keep historical changelog entries as history; use Unreleased for new behavior.

`VERSION` is the tool version source. Do not infer a new release number from a
schema bump or a merge. When preparing a release, intentionally update VERSION
and current-version examples, move Unreleased entries to the release section and
validate the exact tagged tree. Preserve executable script modes.

`bash scripts/build-release.sh OUTPUT_DIR` creates the versioned source archive
and SHA-256 file from Git HEAD, not uncommitted files. Git and gzip/sha256sum are
build tools, not extra collection dependencies. Gzip timestamps are omitted for
repeatable bytes from the same committed tree. Existing output files are refused.

The Release workflow runs only after successful CI of a trusted main push. It
checks out that exact commit, skips already published versions, refuses conflicting
tags/drafts, builds/tests the extracted archive and verifies downloaded draft
assets before publishing as latest. It never consumes PR artifacts or runs for
PR CI. Main must still point at the tested commit at publication. A failed
same-commit draft can be resumed by rerunning the successful main CI run; a draft
for another commit requires maintainer review. `contents: write` is scoped to the
release job. Version changes on main therefore request a stable release after CI;
do not bump VERSION just to label an unreleased development commit.

PRs should explain the trigger, resulting behavior and validation/limits. Include
version/commit, distribution and relevant tool variants for portability changes.
Do not upload raw/private fixtures or unreviewed bundles. Follow [SECURITY.md](SECURITY.md)
for privately reporting exploitable issues or secret exposure.
