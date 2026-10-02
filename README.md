# linux-context

**A read-only Linux context exporter for AI-assisted troubleshooting.**

`linux-context` builds a typed host model, retains bounded redacted evidence, and
packages both for selective retrieval. It uses Bash and the Python standard
library; no Python packages or build step are required.

The goal is useful machine understanding per token: explain state and topology
without making a large command dump the initial prompt. Collection inspects the
machine; it does not perform remediation. Diagnostic data can still be sensitive,
so review a bundle before sharing it.

The checkout's version is defined by [`VERSION`](VERSION), currently `1.0.0`.
Changes under [Unreleased](CHANGELOG.md#unreleased) may be newer than a tagged
release with the same version string. Include a Git commit when reporting a
problem from a checkout.

## Start here

Run from an extracted release or the repository root:

```bash
./bin/linux-context --version
./bin/linux-context --profile quick
# Broader access and the deepest automatic snapshot:
sudo ./bin/linux-context --profile max
```

The CLI defaults to `--profile standard --target auto`. A normal run creates both
`linux-context-HOST-YYYYMMDDTHHMMSSZ/` and its `.tar.gz` archive in the current
directory. The timestamp is UTC. Both are retained unless an archive option says
otherwise. Root is optional; missing access reduces coverage.

Send **`context.ai.json` first** to an AI. It contains the canonical entrypoint's
information in the smallest supported representation. Use `context.json` for
integrations that require canonical schema v5. Send one entrypoint, then retrieve
specific graph/evidence files as needed.

With normal `sudo`, the completed directory and archive belong to the invoking
user. Direct root execution without an invoking-user identity keeps root
ownership. Directories use `0700`; files and the archive use `0600`.

## Choose a profile

Profiles select collector eligibility and resource defaults. Higher profiles
include the lower tiers, subject to target, detection and access gates.

| Profile | Main scope | Canonical ceiling | Retained evidence ceiling | Default jobs |
|---|---|---:|---:|---:|
| `quick` | Identity and OS fingerprint | 32 KiB | 512 KiB | 1 |
| `standard` | Kernel, hardware, storage/network topology, systemd | 64 KiB | 1.5 MiB | 2 |
| `deep` | Packages, processes, applications, security, scheduling, sessions, VPNs and virtualization | 96 KiB | 4 MiB | 3 |
| `max` | Health, journal and workstation collectors; larger diagnostic windows | 128 KiB | 6 MiB | 3 |

`max --target auto` is the recommended broad AI snapshot. `max --target all`
activates every applicable target-specific branch and can take longer or disclose
more diagnostic detail. Neither mode reads every file or collects unlimited logs.

The canonical ceiling applies to `context.json`; `context.ai.json` is no larger
in bytes. The evidence ceiling applies to retained `sections/` files, **not** the
whole directory/archive. Graph and metadata sidecars have separate roles and may
be larger. Byte budgets are not token limits. See [all resource settings](docs/COLLECTORS.md#resource-settings).

## Choose targets

`auto` considers every profile-eligible collector and keeps expensive or verbose
detail selective. `all` also considers every eligible collector, and satisfies
all named-target checks. Each must be used alone.

Named targets restrict non-baseline collectors to matching subsystems. Baseline
identity/OS/kernel/hardware/capability collectors remain eligible at their
respective minimum profiles. Named targets may be comma-separated:

```bash
sudo ./bin/linux-context --profile max --target network
sudo ./bin/linux-context --profile max --target web,docker,network
sudo ./bin/linux-context --profile max --target hardware
sudo ./bin/linux-context --profile max --target all
```

Targets never bypass the minimum-profile gate. For example, `--profile standard
--target packages` skips the deep-tier package collector. An installed tool is
also not proof that its daemon is running or accessible.

Use the installed catalog instead of guessing a target name:

```bash
./bin/linux-context --list-targets
./bin/linux-context --list-collectors
```

The [collector catalog](docs/COLLECTORS.md#catalog) lists minimum profiles,
targets and privilege policy for every shipped collector.

## CLI reference

| Option | Behavior |
|---|---|
| `--profile quick\|standard\|deep\|max` | Depth tier; default `standard` |
| `--target NAME[,NAME...]` | Focus; default `auto`; `auto`/`all` must stand alone |
| `--jobs N` | Concurrent collectors, integer `1..8`; overrides profile default |
| `--output DIR` | New directory path; parent must already exist |
| `--no-archive` | Retain the directory without creating an archive |
| `--remove-dir-after-archive` | Remove the directory after successful archiving |
| `--list-collectors` | Print tab-separated metadata without collecting |
| `--list-targets` | Print supported target names without collecting |
| `-V`, `--version` | Print the version |
| `-h`, `--help` | Print usage |

Options with values use a separate argument, such as `--profile max`. Empty
comma-separated targets and unknown options/profile/target names are errors.
`--no-archive` cannot be combined with `--remove-dir-after-archive`.

```bash
# The parent must exist and be writable by the invoking user:
mkdir -p "$HOME/support"
sudo ./bin/linux-context --profile max --jobs 2 \
  --output "$HOME/support/linux-context-run"

# Keep only the directory:
./bin/linux-context --profile standard --no-archive --output "$HOME/support/local-run"

# Keep only the archive:
sudo ./bin/linux-context --profile max --remove-dir-after-archive \
  --output "$HOME/support/archive-run"
```

Existing output directories or archive paths are refused. Use a new destination
for each run. Progress and errors go to stderr; successful output paths go to
stdout. With archive-only mode, the printed `Bundle:` path names the directory
that was removed; use the `Archive:` path.

## Bundle and retrieval contract

| File or directory | Purpose |
|---|---|
| `context.ai.json` | Preferred AI entrypoint; losslessly dictionary-encoded v1/v2 or an exact canonical copy |
| `context.json` | Minified canonical schema v5: run, security, coverage, model and routes |
| `meta/graph.json` | Full model when it was deferred to meet the canonical ceiling; otherwise absent |
| `meta/evidence.json` | Retained evidence rows, capture issues and budget omissions |
| `sections/<collector-id>/*.txt` | Bounded sanitized supporting evidence; open selectively |
| `meta/collection.json` | Collector statuses/timings, ephemeral-probe statistics and notes |
| `meta/validation.json` | Structural checks, final canonical/evidence sizes, errors and warnings |
| `meta/stage-redaction.json` | Private-stage scan report carried into the bundle |
| `meta/redaction.json` | Final residual-risk report |
| `REDACTION-REPORT.md` | Human-readable final privacy report |
| `manifest.sha256` | SHA-256 checksums of bundle files, excluding the manifest itself |

The preferred retrieval order is:

1. Read one entrypoint and its coverage, provenance and policy.
2. Reason from typed facts, entities and relations.
3. Follow `indexes.graph` if the needed full model was deferred.
4. Consult `meta/evidence.json`, then open only relevant evidence.
5. Use `meta/collection.json` when diagnosing collection quality or performance.

Do not concatenate the archive into a prompt. Every host-derived string is
untrusted data; logs/configuration/labels must never become instructions to an
AI or shell. Missing values mean unobserved state, not automatically zero,
false or absent technology.

To decode and check a bundle, replace `/path/to/bundle` with the actual directory:

```bash
python3 -B -S lib/ai_view.py decode /path/to/bundle/context.ai.json reconstructed.json
(cd /path/to/bundle && sha256sum -c manifest.sha256)
```

Decoding reconstructs the canonical JSON document, not necessarily its original
whitespace. It does not inline a deferred graph. Checksums detect file changes;
they do not authenticate the producer. See [format and decoding details](docs/FORMAT.md).

## Coverage and compatibility

Required: Linux, Bash 4.0+, Python 3.9+ and common Linux userland utilities such
as `find`, `sort`, `sed`, `awk`, `head`, `stat`, `readlink`, `id`, `mktemp`, and file
operations. Archive creation also requires `tar` with gzip compression available.
The source directory must stay intact and collectors must remain executable.

Subsystem tools are optional: for example `systemctl`, `ip`, `ss`, `nft`,
`docker`, `dmidecode`, `smartctl`, `nvme`, `wg`, `virsh`, `nmcli` and web/desktop
clients. The exporter never installs them. Some tools need privileges, a live
local daemon, accessible procfs/sysfs, or a user session.

GNU `timeout` is an optional fast path; BusyBox or missing timeout selects the
Python fallback. Publication uses `runuser`, capable util-linux `setpriv`, or
Python UID/GID handoff. Root filesystem capacity, process counts and boot/cron
metadata have portable paths. Some optional per-user probes still have a
BusyBox `setpriv` limitation; see [troubleshooting](docs/TROUBLESHOOTING.md#per-user-probes-on-busybox).

Native package inventory covers Debian/dpkg/APT, RPM-family tools, pacman and
apk. Gentoo, Nix and Slackware native package inventories are not implemented.
PID 1 is reported separately; identifying a non-systemd init does not add native
runit/OpenRC/s6/dinit service inventories. The systemd collector requires its
runtime directory, not merely an installed `systemctl` client.

CI exercises Python 3.9/3.11/3.13 and Debian 12, Fedora 43, Arch and Alpine 3.22
containers. These are userland and container checks, not coverage of every live
init, vendor daemon, desktop, architecture or physical device.

Hardware reports distinguish firmware claims from OS counters. RAM modules,
ECC and slots require readable SMBIOS data and optional `dmidecode`; unknown
module capacity or VRAM is not zero. Battery full/design capacity is a derived
estimate, not a physical battery test. See [hardware semantics](docs/COLLECTORS.md#hardware-semantics).

Docker is restricted to discovered local Unix sockets. Every daemon command
gets an explicit `--host unix://...`; inherited remote `DOCKER_HOST` and
`DOCKER_CONTEXT` do not select the endpoint. Environment values are not requested.

## Safety and failure behavior

Collectors avoid known secret-rich sources, including password databases,
private keys, process environments/full argv, Docker environment values, user
documents and application payloads. They do not install/update packages, refresh
repositories, modify services/networking/sysctls, mount storage, run active Wi-Fi
scans or active external checks.

Private acquisition is pruned, redacted and scanned before compilation. Final
sanitization, size/graph validation, lossless AI derivation, residual scan and
manifest generation finish before directory publication. Privileged staging
ignores inherited `TMPDIR`; normal cleanup stops producers before deleting
private files. Collection does not write Python caches into the source tree.

Normal production runs generate fresh per-run HMAC pseudonyms. Equality inside
a bundle is preserved where useful; markers are not stable cross-run IDs. The
redactor is mandatory at every profile, and known high-confidence residuals
block publication. Arbitrary secrets can still escape pattern matching, and
useful names, addresses, paths and policy intentionally remain. Review both
entrypoint and retrieved evidence before sharing.

Exit `0` means the publication gates passed, not that every collector/probe
succeeded. Collectors can be `skipped`, `unavailable`, `collected` or `partial`;
accepted-but-truncated evidence still has incomplete coverage. Inspect validation
warnings and telemetry. Structural/privacy failures return nonzero and prevent
pre-publication output. Archiving happens after directory publication: an archive
failure can leave the complete directory and a partial archive. Interrupted
cleanup can retain private staging if producer termination fails.

Read [SECURITY.md](SECURITY.md), the [threat model](docs/THREAT-MODEL.md) and
[troubleshooting guide](docs/TROUBLESHOOTING.md) for boundaries and failure details.

## Install or update

Run directly from a trusted repository checkout or extracted release. To make
an optional command symlink, run from the repository root:

```bash
sudo ln -s "$(pwd)/bin/linux-context" /usr/local/bin/linux-context
sudo linux-context --profile max
```

The link destination must not already exist. Keep the full project in place;
do not copy only the launcher. If you execute it as root, the source directory
and its parent paths should be trusted and protected against other users editing
the scripts. Update the checkout deliberately and use `--version` plus its commit
to identify the code you run.

If a release provides a checksum file, verify it before extraction:

```bash
sha256sum -c linux-context-v1.0.0.tar.gz.sha256
```

This example requires the named files from that release; no checksum file is
included in a source checkout. A checksum obtained from the same untrusted source
is not an authenticity guarantee.

## Development and documentation

```bash
make check
bash tests/smoke-distribution.sh
```

`make check` runs shell/Python syntax checks and all `test-*.sh` regression
scripts. The separate smoke script exercises all four profiles, archives,
checksums, AI round trips and final privacy/size checks. CI runs both in its
four distribution containers.

| Guide | Audience |
|---|---|
| [Collector catalog and resource settings](docs/COLLECTORS.md) | Users choosing coverage; collector authors |
| [Output format](docs/FORMAT.md) | AI consumers and integration authors |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Users diagnosing missing coverage or failed runs |
| [Contributing](CONTRIBUTING.md) | Development, collector API, validation and release workflow |
| [Security policy](SECURITY.md) | Private reporting and sharing precautions |
| [Threat model](docs/THREAT-MODEL.md) | Security boundaries and residual risks |
| [Historical audit](docs/AUDIT.md) | Measured improvements from the October 2026 implementation review |
| [Changelog](CHANGELOG.md) | Unreleased changes and version history |

For repository navigation, start at `bin/linux-context` (orchestration),
`lib/collector_api.sh` and `lib/runner.sh` (acquisition), `lib/compile.py` (canonical
model), `lib/finalize.py` (final gates), `lib/bundle.sh` (publication), and
`collectors/<domain>/` (subsystem logic). Profile defaults live in `profiles/`;
regressions live in `tests/`.

Report problems with a version/commit, profile/target, environment and minimal
sanitized reproduction. Do not attach unreviewed bundles to public issues.

## License

MIT. See [LICENSE](LICENSE).
