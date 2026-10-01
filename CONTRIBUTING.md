# Contributing

Contributions are welcome when they preserve the project's core contract: **maximum useful Linux understanding per token, under strict read-only, privacy, safety, and resource bounds.**

## Development requirements

- Linux
- Bash 4+
- Python 3.9+
- Common Linux utilities (GNU/coreutils timeout is optional; Python fallback exists)
- `tar` for archive integration tests
- Standard Linux utilities used by individual collectors are optional and feature-detected

Run the full local gate before submitting a change:

```bash
make check
```

The suite includes profile/target semantics, redaction regressions, prohibited-source checks, evidence/path safety, context/evidence budgeting, sudo ownership, source-tree immutability, cross-distribution fixtures, and collector-specific regressions.

## Adding or changing a collector

Collectors live under `collectors/<domain>/` and define metadata before sourcing `lib/collector_api.sh`:

```bash
COLLECTOR_ID='example.subsystem'
COLLECTOR_MIN_PROFILE='deep'
COLLECTOR_TARGETS='example subsystem'
COLLECTOR_PRIVILEGE='optional-root'
COLLECTOR_BASELINE=0
COLLECTOR_DESCRIPTION='Short description.'
```

A collector implements `collector_detect` and/or `collector_collect`, then ends with exactly one `collector_main "$@"`.

Prefer, in order:

1. compact typed facts/entities/relations;
2. ephemeral bounded probes parsed into structured state;
3. bounded persistent evidence only when an AI may genuinely need the raw supporting detail;
4. verbose/high-cardinality evidence only behind an explicit target.

Use `run_capture`, `probe_capture`, `capture_file_if_readable`, or owner-scope equivalents. Do not invent a second execution/redaction boundary.

### Security rules for collectors

Do not intentionally collect:

- `/etc/shadow`, `/etc/gshadow`, or equivalent credential databases;
- private key material;
- `/proc/*/environ` or user/session environment dumps;
- full process command lines/argv when they can contain secrets;
- Docker `.Config.Env`;
- arbitrary home-directory/user-document content;
- database/application payload data;
- unbounded logs;
- active external network probes.

Avoid collecting persistent hardware/remote/user identifiers when aggregate state or a per-run pseudonym gives the same diagnostic value.

If a source can contain secrets, first ask whether the same question can be answered without collecting the value at all. Redaction is a defense layer, not permission to acquire dangerous sources.

## Data model

See [`docs/FORMAT.md`](docs/FORMAT.md). New high-cardinality object state belongs on entities; relationships belong in graph edges; global facts should remain truly global. Provenance is mandatory for structured observations.

## Compatibility

Avoid distro-specific assumptions in the core. Feature-detect optional tools. A missing command/subsystem should normally make a collector `unavailable` or a probe absent—not make the whole run fail. Do not hide actual structural/programming errors behind `|| true` when they invalidate canonical data.

Run `tests/smoke-distribution.sh` for all-profile archive/manifest/AI/privacy
checks. CI runs `make check` and this smoke test in Debian, Fedora, Arch and
Alpine containers; keep Alpine's BusyBox tools in place to exercise the minimal
userland path. Ownership fixtures use sudo handoff when the environment can map
the test UID; otherwise they explicitly report current-user-only coverage.
