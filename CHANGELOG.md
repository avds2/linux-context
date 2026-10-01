# Changelog


## Unreleased

- Bound Bluetooth controller discovery to five seconds with probe telemetry;
  failed/truncated discovery leaves the controller count unknown instead of zero.
- Stop and reap collector process trees before private staging cleanup on INT/TERM
  or early failure, including producers in GNU timeout's separate process groups.
- Add hanging/failed/empty/successful Bluetooth and INT/TERM cleanup regressions.
- Add standard-profile typed SMBIOS RAM arrays/modules with capacity, DDR type,
  manufacturer/part number, slot/bank, rank, ECC, rated/configured speeds and
  explicit missing-tool/access/firmware/truncation coverage. Keep serial/asset
  identifiers out of acquisition output.
- Add typed CPU topology/cache/selected ISA features, firmware models, GPU PCI
  name/driver/available VRAM, disk models/transport/capacity, system
  battery full/design capacity health, available RAM and swap counters.
- Reduce duplicate hardware text in automatic snapshots; retain focused evidence
  under named hardware targets and `all`, without changing the schema or budgets.
- Add a lossless dictionary-coded `context.ai.json` AI view with round-trip
  validation, residual scanning and manifest/archive coverage.
- Add hardware parser/sysfs/privacy fixtures and memory-collector integration tests.

## 1.0.0

- Fixed the Docker local-socket regression fixture so it validates the security invariant (explicit local Unix-socket pinning) without assuming a rootless socket wins over a real `/run/docker.sock` on developer workstations.

Production-readiness release focused on hardening the established AI-first architecture rather than expanding collection breadth.

### Security / correctness

- Made enhanced Python redaction mandatory for every successful profile; removed the degraded production fallback and ignore caller-provided legacy redaction salts so pseudonyms remain fresh per run.
- Added transactional privileged publication: acquisition, redaction, compilation, validation, and manifest generation stay in a root-safe private temporary tree; sanitized output is handed to the invoking user before publication to the requested destination.
- Privileged runs ignore inherited `TMPDIR`; failed runs no longer leave half-built final bundles.
- Pinned Docker acquisition to explicitly discovered local Unix sockets, preventing inherited remote `DOCKER_HOST`/`DOCKER_CONTEXT` from redirecting whole-host inspection.
- Minimized VPN privacy surface: Tailscale/ZeroTier raw peer/status identity dumps are no longer persisted; WireGuard peer keys/endpoints are omitted and focused runtime evidence strips peer keys.
- Broad journal signatures now sample the system journal by default; arbitrary user/application journal scope is logs-target detail.
- RPM-family repository collection now reads passive source configuration instead of running potentially network-refreshing repository commands.
- Added compiler evidence-path containment checks before any evidence read/delete operation.
- Made internal typed-record parsing strict for booleans/numbers/value types/confidence instead of silently coercing malformed records.
- Fixed runner handling for output-sink failures and direct file-read errors.

### AI/context robustness

- Strengthened pathological-host context budgeting: after lossless graph deferral, secondary entrypoint compaction can route full facts/capabilities to `meta/graph.json` while preserving the hard `context.json` ceiling.
- Added collection notes to operational sidecar metadata so overflow compaction can omit them from the default prompt without losing them.
- JSON serialization now rejects non-finite numeric values.

### Public repository

- Added canonical `VERSION` source plus `--version` and symlink-safe launcher resolution.
- Added MIT license, `.gitignore`, `.gitattributes`, `.editorconfig`, Makefile, GitHub Actions CI, issue/PR templates, `SECURITY.md`, `CONTRIBUTING.md`, and format/collector/threat-model documentation.
- Rewrote README as a complete public user/developer/security guide.
- Expanded regression coverage for local-only Docker, privileged temp/publication safety, path traversal, strict staging, pathological context cardinality, and privacy/source-avoidance invariants.

## 0.5.5

Profile-semantics documentation and exhaustive-sysctl status cleanup driven by a real Arch `max --target all` snapshot.

- Documented the intended operational role of `quick`, `standard`, `deep`, and `max`: profiles are budget/depth tiers, while targets determine where extra diagnostic depth is spent.
- A real Arch `max --target all` run produced ~77 KiB of useful `sysctl -a` output but `sysctl` returned exit 1 because one or more dynamic procfs keys were unreadable. The exhaustive listing is supporting evidence; the curated selected-sysctl probe remains the canonical health check. `sysctl_all` now tolerates per-key read failures without reporting a false evidence error.
- Added a regression using a synthetic `sysctl` that emits valid `-a` output and exits 1, proving exhaustive kernel collection remains valid and warning-free.

## 0.5.4

Exhaustive-target semantics and Docker standalone-topology correctness release, driven by fresh v0.5.3 `max` snapshots from both the Arch workstation and Debian Docker server.

### `--target all`

- Added `--target all` as the explicit exhaustive diagnostic mode. `max --target auto` remains the recommended compact whole-machine AI snapshot; `max --target all` enables every target-specific deep branch across every applicable collector while retaining the same read-only, redaction, timeout, evidence-budget and AI-entrypoint bounds.
- `target_requested()` now treats `all` as focused for every target name, so existing subsystem-specific depth gates (full safe process tables, full sysctl state, exhaustive systemd detail, deeper network/log/package/web/Docker evidence, etc.) activate without hard-coding a second exhaustive path in each collector.
- The orchestrator treats `all` as matching every collector. `auto` and `all` are standalone target modes; ambiguous forms such as `all,network` and `auto,network` fail fast.
- Added explicit `run.target_semantics` to canonical context so an AI can distinguish broad-auto, focused, and exhaustive-all bundles without inferring behavior from CLI strings.
- Added regression coverage proving `all` is listed, activates arbitrary target gates, never causes target-mismatch skips under `max`, and remains bounded by the normal max compiler/evidence limits.

### Docker topology correctness

- Fresh Debian v0.5.3 output showed all seven containers were discovered, but four standalone/no-health containers still lacked restart/network/PID topology while health-checked/Compose containers were fully described.
- Root cause: the supposedly independent core inspect template still mixed mandatory META state with optional health/Compose fields. On Docker versions/objects where an optional field cannot be evaluated, that object can lose its entire formatted record, including the preceding META state.
- Split Docker inspect into field-isolated batched passes for mandatory core META, optional health, optional Compose project, network topology, and optional port/mount detail. Failure/absence in one optional class can no longer suppress core state for otherwise valid containers.
- Strengthened the Debian Docker regression fixture so a standalone container deliberately lacks health/Compose metadata while still being required to receive restart/network topology. The fixture now verifies all five bounded batched inspect classes independently.

### Fresh v0.5.3 cross-host audit

- Arch `max`: ~3 s wall time, 32.5 KiB canonical context, 140.8 KiB retained evidence, zero evidence issues/timeouts/truncations and zero high-confidence credential residuals.
- Debian `max`: ~9 s wall time, 46.7 KiB canonical context, 153.8 KiB retained evidence, zero evidence issues/timeouts/truncations and zero high-confidence credential residuals.
- Both bundles remained well below the 128 KiB max AI-entrypoint ceiling and showed zero literal MAC, RFC UUID, or short FAT/MBR UUID patterns after privacy pseudonymization.

## 0.5.3

Source-immutability, Docker topology, privacy and cross-host cleanup release driven by fresh v0.5.2 `max` snapshots from the Arch workstation and Debian 13 Docker VPS.

### Source-tree immutability / ownership

- Fixed root-owned `lib/__pycache__` directories created when the exporter was executed through `sudo`.
- Normal runtime now exports `PYTHONDONTWRITEBYTECODE=1` and routes internal Python through one `python3 -B -S` wrapper. A collection run no longer writes bytecode or any other runtime state into its extracted source directory.
- Added a regression that copies the project, hashes every source file, runs a real collection, and asserts that the source tree is byte-for-byte unchanged with no `.pyc`/`__pycache__` artifacts.
- Test-side Python invocations also use `-B`, keeping development/test runs source-clean.

### Docker correctness / performance

- Fixed `containers.docker.server_version` incorrectly containing the full literal `\t`-encoded engine tuple on Docker 26/29. The info template now emits real TAB separators and scalar parsing is validated before facts are emitted.
- Docker daemon accessibility and engine metadata are obtained in one formatted info round-trip; cheap local socket detection avoids an extra daemon probe during collector detection.
- Split batched Docker inspect into independent core-state, network and optional I/O-detail passes. An unusual field/container can no longer abort topology collection for every later container in the batch.
- Added one safe batched network-name/ID map so custom Docker networks can still correlate to Linux `br-<id>` interfaces without requesting arbitrary labels or environment values.

### Cross-host robustness / privacy

- Treat an installed BlueZ client with zero controllers as a normal `controller_count=0` state instead of persisting `bluetoothctl show` as failed evidence.
- Added contextual pseudonymization for non-RFC filesystem identifiers such as FAT `UUID=XXXX-XXXX`, MBR-style `PARTUUID`, and `/dev/disk/by-{uuid,partuuid}/...` paths. Correlation is retained via per-run HMAC markers.
- Avoid slow libvirt connection attempts when only the `virsh` client is installed by checking local monolithic/proxy/modular libvirt sockets before probing system/session URIs.
- Flatpak/Snap app enumeration and counts are now package-target-only; broad `max` already knows those runtimes exist from capability discovery and no longer pays their user-database startup cost.

### Real v0.5.2 audit results

- Arch `max`: valid 31 KiB canonical entrypoint, 147 KiB evidence, ~4 s wall time, zero credential residuals; one normal no-Bluetooth-controller state was previously misclassified as an evidence error.
- Debian `max`: valid 43 KiB canonical entrypoint, 154 KiB evidence, ~9 s wall time, zero warnings/timeouts/truncations and zero credential residuals.
- Both snapshots exposed the Docker server-version tuple bug and one unpseudonymized short filesystem UUID in fstab evidence; both are covered by v0.5.3 regressions.

## 0.5.2

Cross-distribution server hardening release driven by side-by-side v0.5.1 `max` snapshots from an Arch workstation and a Debian 13 KVM/Docker server.

### Portability / correctness

- Treat Secure Boot as unavailable/not applicable on BIOS guests without EFI variables instead of recording `mokutil --sb-state` as an evidence failure. EFI-specific probes now run only on UEFI systems.
- Distinguish virtualization role explicitly: guests are modeled as `system.virtualization.role=guest`; non-virtualized hosts as `bare_metal`. Presence of KVM guest tooling no longer implies virtualization-host capability.
- Debian package state now identifies APT as the package manager while retaining dpkg as the package database.
- Fixed Docker detail collection for containers whose `.Config.Labels` is nil. Label-less standalone containers now receive the same safe network/restart/PID/mount/health topology as Compose containers.
- Docker inspect is batched and keyed by object ID, avoiding order assumptions and one daemon round-trip per container.

### Performance / AI signal density

- Added persistent per-collector structured-record file descriptors so high-cardinality collectors do not reopen staging files for every fact/entity/relation.
- Reworked broad network topology to keep structured interface/address/socket topology while suppressing raw high-volume link/address dumps unless network detail is explicitly targeted. Ephemeral Docker `veth*` devices are summarized by count in broad auto mode rather than modeled individually.
- Replaced per-socket `sed` parsing with Bash-native parsing and added safe cgroup-based socket→service correlation without argv/environment collection.
- Broad systemd-networkd collection keeps compact link state; expensive `networkctl status --all` is target-only.
- Broad security posture no longer runs the expensive exhaustive `systemd-analyze security` table; explicit `--target security` restores it.
- Broad systemd state omits inactive/static one-shot noise while retaining active-running, failed, enabled, masked, custom and overridden units.
- Broad Apache evidence avoids default module configuration bulk; explicit web/Apache targets retain diagnostic-depth module config.
- Hot-path name normalization and millisecond timing use Bash builtins where available, reducing shell subprocess overhead.

### Privacy / source minimization

- Broad login-session evidence no longer retains remote SSH origin addresses. Canonical session state preserves UID/user/session type/leader/seat/TTY and the boolean remote state.
- Normalized journal issue signatures replace remote peer IPv4/port values with semantic placeholders, improving deduplication without retaining attack/client source addresses.
- SSH host-key evidence records key type/size and public-key filename, not persistent host-key fingerprints.
- Broad local-account evidence excludes GECOS fields and password placeholders.
- Headless hosts no longer report workstation-device coverage merely because empty `/sys/class/drm` or `/sys/class/power_supply` directories exist.

### Regression coverage

- Added Debian/cross-distro fixtures for BIOS Secure Boot handling, label-less Docker containers and batched inspect, veth summarization, and SSH remote-origin stripping.
- Added synthetic container-heavy network and Docker benchmarks to exercise the server hot paths discovered in the Debian snapshot.

## 0.5.1

### Correctness / structured staging

- Fixed the Arch `max` crash in `packages.inventory` (`JSONDecodeError: Unterminated string ... column 83`). The exact trigger was the provenance string `flatpak list --user (owner)`: the curl `--user user:password` redaction rule could look past the closing JSON quote, find a colon in the following JSON field, and truncate the JSON record.
- Removed handwritten JSON from the shell collector staging boundary. Facts, entities, attributes, relations, artifacts, and probes now use fixed-arity NUL-delimited records; Python alone owns JSON serialization. This makes host-derived quotes, backslashes, control characters, and Unicode structurally safe without spawning Python once per fact.
- Added `recordio.py` with strict arity/terminator validation. Truncated/corrupt structured staging now fails explicitly instead of being partially interpreted.
- Made the redaction engine record-aware so NUL delimiters are preserved and fact/entity-attribute key/value semantics are still available for secret detection.
- Made first-party JSON redaction structure-aware: JSON is parsed, values are redacted recursively, and Python reserializes it. Regexes can no longer cross JSON field boundaries or corrupt generated JSON syntax.
- Tightened the curl `--user`/`-u` credential regex so credential tokens cannot consume JSON/config punctuation from neighboring fields.

### Collector lifecycle / clean code

- Removed the hidden `collector_main` dispatch from `collector_api.sh`. Every collector already dispatches explicitly at its footer; previously `--meta` was emitted twice and detection code could be invoked twice.
- Added a regression test requiring exactly one metadata record per collector invocation and verifying that sourcing the collector API is side-effect free.
- Removed now-unused shell JSON escaping helpers.

### Regression coverage

- Added hostile structured-field tests covering quotes, trailing backslashes, newlines, tabs, control characters, and Unicode.
- Added an exact regression for the Flatpak `--user (owner)` provenance string that caused the reported v0.5.0 failure.
- The full ownership, redaction, source-avoidance, evidence-budget, context-budget, profile, target, compiler, and CLI integration suites remain green.

## 0.5.0

AI-entrypoint, privacy and profile-density release driven by four same-host Arch Linux snapshots (`quick`, `standard`, `deep`, and `max`) from v0.4.1.

### Real-machine profile results that drove this release

- Verified the intended depth ladder on the same host: roughly 1 s `quick`, 2 s `standard`, 3 s `deep`, and 5 s `max` under v0.4.1.
- Verified sudo ownership/permissions in every uploaded archive (`0700` directories, `0600` files, invoking-user ownership).
- Verified zero high-confidence credential residuals in all four bundles.
- Identified the remaining `max` context concentration: transient desktop/user systemd services, volatile per-PID provenance, evidence/collector telemetry embedded in the canonical entrypoint, and privacy-only UUID/boot identifiers.

### AI-first layered output

- Schema v5 keeps `context.json` as the bounded AI entrypoint and moves operational metadata out of the default prompt surface.
- Added `meta/evidence.json` for raw-evidence routing/metadata and `meta/collection.json` for collector/probe timings and status telemetry.
- Added per-profile hard `context.json` ceilings: 32 KiB quick, 64 KiB standard, 96 KiB deep, 128 KiB max.
- If a very large host exceeds its entrypoint ceiling, the compiler losslessly defers the full provenance/fact/entity/relation graph to `meta/graph.json` and leaves a compact summary/router in `context.json`.
- Added regression coverage proving graph deferral keeps the entrypoint inside budget without losing the full graph.
- Normalized volatile `/proc/<PID>/exe` provenance to `/proc/PID/exe`; the exact PID remains represented by process entities/relations, eliminating dozens of otherwise-identical provenance rows.
- Moved full evidence rows and collector/performance rows out of `context.json`; only collection/evidence issues and compact coverage remain in the default AI context.

### Systemd/context density

- Broad automatic `max` now summarizes transient/vendor user-session services by complete counts but individually models only persistent, custom/overridden, masked or unhealthy user services.
- Explicit `--target systemd`/`services` remains exhaustive, including transient user services and volatile resource/cgroup detail.
- Removed redundant `main_pid` attributes where the service→process graph edge already carries the PID identity.
- Cgroup paths are target-only because they are long/volatile and usually redundant with service/process relationships.
- Running executable identity remains available through safe `/proc/PID/exe` observation without argv/environment collection.

### Privacy/redaction hardening

- Added per-run HMAC pseudonymization for non-Bluetooth UUIDs, covering filesystem UUIDs, PARTUUIDs, connection UUIDs and similar durable identifiers while retaining correlation.
- Preserved standardized Bluetooth SIG capability UUIDs so Bluetooth functionality is not destroyed by privacy filtering.
- Expanded the non-secret `System Token: not set` boot state exception; broad scans now avoid persisting verbose `bootctl status` entirely and extract structured boot state from an ephemeral probe.
- Broad boot scans no longer persist generated `grub.cfg`; explicit boot/firmware targets can retain the sanitized file when needed.
- Journal boot history now strips random 128-bit boot IDs before persistence; boot index/time ranges remain.
- The post-compiler defense-in-depth redaction pass now covers the complete generated bundle, including compiler-created machine-readable metadata, rather than only `context.json`.
- Applying the v0.5 privacy pass to the uploaded v0.4.1 max bundle removed all non-Bluetooth literal UUIDs while retaining zero high-confidence credential residuals.

### Logs and package signal density

- Broad `max` no longer persists verbatim high-priority application/error journal samples; it keeps normalized issue-frequency signatures, boot history and kernel warnings. Explicit `--target logs` restores bounded verbatim samples.
- Full Flatpak/Snap application listings and the explicit-pacman package classification are package-target-only. Broad `max` keeps counts plus high-value distro/foreign/orphan/cached-upgrade state.
- This reduces incidental user-activity/application disclosure and cuts low-value collection work without losing machine-level package understanding.

### Validation

- Added context-budget/graph-deferral tests and updated compact-schema/target tests for sidecar metadata.
- Added UUID pseudonymization and Bluetooth UUID preservation tests.
- Re-ran shell syntax, Python compile, source-avoidance, redaction, ownership, target/profile, evidence-budget and full CLI ownership regressions successfully.

## 0.4.0

AI-first performance/representation release driven by auditing a real Arch Linux `max` bundle from v0.3.1.

### Canonical representation

- Replaced verbose `context.jsonl` with minified schema-v4 `context.json`.
- Interned provenance to avoid repeating collector/source/confidence strings on every record.
- Made entity attributes the canonical home for high-cardinality service/container/session state.
- Merge duplicate entities and graph relations by stable ID while preserving independent provenance and conflicting observations.
- Synthesize missing graph endpoints defensively and validate graph integrity.
- Pack command capabilities into one compact map.
- Removed mandatory human-oriented summary output; evidence remains on-demand behind the canonical index.

### Context/evidence control

- Added hard total retained-evidence budgets per depth profile in addition to per-command byte caps.
- Apply the first priority-based evidence-budget prune while raw output is still private, before redaction; the compiler enforces the budget again after redaction as defense in depth.
- Added evidence priorities and `evidence_omitted` records; low-priority raw files are dropped first when a bundle reaches its budget.
- Reworked `max` journal collection from a 1 MiB repetitive error dump to bounded representative samples plus normalized issue-frequency signatures.
- Automatic `max` now keeps process hotspots and pressure data instead of a full process table/tree; the complete safe table is available on explicit `runtime`/`processes` targets.
- Automatic `max` uses curated high-value sysctls; full `sysctl -a` is explicit `kernel`/`system` target detail.
- Wi-Fi neighborhood cache, neighbor tables and established remote socket evidence are explicit network/security target detail.
- Inactive installed web engines remain represented structurally but no longer dump large default configurations during automatic scans.
- Removed redundant Docker container-topology text because the topology is already represented as structured entities/relations.
- Filtered commented package-manager mirror/config data and login/security configuration where comments add no runtime semantics.
- Replaced broad boot-tree inventory with kernel/initramfs/EFI/loader-relevant files only.

### Performance

- Added per-profile bounded collector parallelism (`1/2/3/3`, configurable with `--jobs 1..8`).
- Isolated each collector into independent staging files so parallel execution cannot interleave records.
- Replaced per-artifact Python redactor startups with one enhanced batch redact/scan over private staging.
- Added ephemeral probes: collectors can parse bounded output into structured state without retaining the raw text.
- Reworked systemd service discovery to a bulk service-state probe instead of per-service `systemctl show` subprocesses.
- Removed `tr`/`sed` subprocesses from the hot structured-record normalization path.
- Removed the unused staging `facts.tsv` compatibility stream; structured JSONL staging is now the single collector record path.
- Added collector/probe timing to canonical output for performance regression analysis.

### Target semantics

- Fixed explicit `--target` behavior: unrelated generic collectors no longer run merely because they were tagged `generic`.
- Added an explicit baseline flag to collector metadata. Baseline collectors provide enough machine context to interpret a target; other collectors must match requested targets.
- Added `--list-targets` and target validation.
- Explicit targets can intentionally request deeper evidence while keeping broad automatic scans concise.

### Robustness fixes from the v0.3.1 real-machine fixture

- Fixed SMART parsing of `smartctl --scan` lines containing `-d TYPE`; device type is preserved safely instead of being concatenated into the device path.
- Treat SMART health-status bit exits separately from command/open failures while retaining health evidence.
- Probe libvirt URIs before querying them; an installed `virsh` with no reachable daemon no longer creates five useless failed artifacts.
- Fixed Wi-Fi link interface parsing that produced an `awk` quoting failure on the Arch fixture.
- Treat expected empty pacman orphan/upgrade exit states as non-errors.
- Treat `bootctl status` exit 1 as useful/accepted evidence when another bootloader is active.
- Probe `resolvectl`/network manager APIs rather than assuming an installed binary means a reachable service.
- Added explicit seat entities and compiler entity merging, eliminating duplicate/missing graph endpoint warnings seen in v0.3.1.
- Fixed successful `--no-archive` CLI runs returning exit status 1 because the last optional-print expression was false.

### Security/privacy

- Retained the v0.3.1 enhanced, correlated HMAC redaction engine and fail-closed `max` contract.
- Raw collector evidence remains private until batch redaction and residual scanning succeed.
- Final canonical output is redacted again and the complete public bundle is rescanned before packaging.
- Continued source-level avoidance of argv/environment values, private keys, credential databases and application/user payloads.
- Removed unnecessary NetworkManager UUIDs and Wi-Fi BSSIDs from broad automatic evidence.
- Kept DMI/storage unique serial/WWN identifiers excluded at collection time.

### Validation

- Added compact-context schema/graph tests.
- Added explicit target-isolation regression tests.
- Updated sudo ownership/archive tests for `context.json`.
- Existing redaction and prohibited-source suites remain green.

## 0.3.1

- Fixed sudo output ownership for bundle directories, files, archives and tar members.
- Hardened redaction with enhanced Python scanning and fail-closed `max` requirements.
- Added broad credential pattern coverage and final residual scans.
- Omitted unnecessary DMI/SMART/NVMe unique identifiers.
- Added scheduler, boot, workstation, virtualization, storage-health and security collectors.
- Corrected resolver/service detection and several v0.2 collection defects.

## 0.2.0

- Switched the project toward structured AI-first facts/entities/relations with provenance.
- Fixed locale-sensitive UTC naming and hostname fallback behavior discovered from the first real machine bundle.
- Added process/network/container structured observations.

## 0.1.0

- Initial modular collector architecture with depth profiles, targets, bounded runner, redaction layer, bundle creation and basic Linux collectors.
