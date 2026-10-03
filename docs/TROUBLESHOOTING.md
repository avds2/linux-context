# Troubleshooting

Use this guide for missing coverage, failed publication or slow runs. Start with
the version/commit and the exact profile/target. A successful process exit does
not imply complete subsystem coverage.

## Identify what ran

From the source root:

```bash
./bin/linux-context --version
./bin/linux-context --list-collectors
./bin/linux-context --list-targets
# Repository checkouts also have a commit identity:
git rev-parse HEAD
```

`VERSION` may match a tagged release (for example `1.1.0`) even when a checkout
contains newer Unreleased changes.
List commands inspect metadata, not actual host support. The launcher expects
Linux, Bash 4+, Python 3.9+, executable collectors, common utilities and archive
tooling unless `--no-archive` is used. Use the entire trusted project directory,
not a copied launcher alone. If a symlink stops working, check that its original
checkout still exists.

## Input and destination errors

| Symptom | Action |
|---|---|
| Unknown profile/target | Use a listed lowercase profile/target; collector IDs are not automatically target names |
| Empty target or ambiguous auto/all | Use one standalone `auto`/`all` or a nonempty comma-separated named list |
| Target collector skipped | Raise the profile to its minimum; targets never bypass profile gates |
| Invalid jobs | Supply one integer from 1 through 8 |
| Existing output/archive | Choose a new path; the exporter refuses overwrite |
| Missing output parent | Create the parent first as the invoking user |
| Unable to publish as invoking user | Check parent write/traverse access for that user; do not grant broad permissions to make the error disappear |
| No-archive/remove-dir conflict | Choose directory-only or archive-only; do not combine both flags |

For example:

```bash
mkdir -p "$HOME/support"
sudo ./bin/linux-context --profile max --target network \
  --output "$HOME/support/network-run-1"
```

Do not reuse this destination until you deliberately move the previous result or
choose another new name. The default timestamp name can also collide if runs
start in the same second.

## Understand status and warnings

Read these JSON files with a JSON viewer/editor, or run:

```bash
python3 -m json.tool /path/to/bundle/meta/validation.json
python3 -m json.tool /path/to/bundle/meta/collection.json
```

| State | Meaning |
|---|---|
| Collector `skipped` | Profile or target policy excluded it |
| Collector `unavailable` | Root policy, detection, tool/access or detection timeout prevented acquisition |
| Collector `collected` | Its function exited zero; optional probes can still fail or be limited |
| Collector `partial` | Acquisition returned nonzero, including its outer timeout; valid observations can survive |
| Evidence `error`/`timeout` | Unexpected command exit or timeout; inspect catalog issues/source |
| Evidence truncation | Byte cap hit; accepted status can still be `ok` |
| Budget omission | Capture was discarded to fit retained-evidence limits; use catalog `omitted` |
| Validation warning | Structurally publishable result with collection/model caveats |
| Structural/privacy failure | No successful pre-publication directory; inspect reviewed stderr, not raw staging |

Synthesized relation endpoints are references, not fully observed objects. Unknown
values are not proof that a service/device is absent or disabled. Counts may be
incomplete when an inventory is limited. The collection telemetry's `probe_stats`
counts runner ephemeral probes, not every helper or persistent artifact.

## Missing hardware, service or network details

- **RAM/GPU/battery:** firmware access, sysfs exposure and optional tools vary.
  Standard or higher enables typed hardware. Use the discovery/status facts;
  sudo and existing `dmidecode` can provide SMBIOS detail, but cannot create
  unavailable firmware/VRAM counters. Do not infer zero from missing fields.
- **Systemd:** a client installed inside a container is insufficient. The
  collector requires `/run/systemd/system`; PID 1 remains separately visible.
  Non-systemd init identification does not provide native service inventories.
- **Network managers:** nmcli/networkctl presence is not an active manager.
  Query failures leave state unknown. Container namespaces expose their own
  visible links/routes, which may differ from the host's.
- **Packages:** deep or higher is required. Supported native databases are dpkg,
  rpm, pacman and apk. Failed/truncated inventories cannot give an exact count.
  Flatpak/Snap application enumeration also needs max and packages/all targeting.
- **Bluetooth/audio:** max-tier detection must succeed. Automatic Bluetooth
  adapter count is a sysfs observation; BlueZ controller detail needs
  bluetooth/workstation/all. Session audio APIs need an accessible user session.
- **Docker/libvirt:** installed clients alone are insufficient. Only detected
  local sockets/URIs are queried. Remote Docker context variables are deliberately
  ignored. Rootless/user services require the invoking user's runtime/session
  access; sudo does not guarantee a working user bus.

The exporter never installs missing utilities or modifies service state. Decide
whether the observation is worth enabling access/tooling outside the exporter,
then rerun to a fresh destination.

## Per-user probes on BusyBox

Current publication uses `setpriv_can_switch_owner` and selects Python when
BusyBox `setpriv` lacks `--reuid`, `--regid` and `--init-groups`.

However, `run_owner_capture` and `probe_owner_capture` in `lib/runner.sh` still
select setpriv by binary presence. In a sudo run with BusyBox setpriv and no
runuser, optional per-user probes can report `setpriv: unrecognized option:
reuid`. This can affect user-service, audio, Flatpak, rootless Docker evidence
and session libvirt captures. Directory/archive handoff can succeed despite
those gaps. Inspect probe failures, evidence issues and notes; do not interpret
them as absent technology.

An unprivileged run can inspect the current user's scope without privilege
dropping, with less system-wide access. Environments with a usable runuser or
util-linux setpriv take supported owner paths. This is a known core limitation,
not something the documentation or Alpine container smoke test proves resolved.

## Slow runs or timeouts

Use `meta/collection.json` to find slow collectors and `meta/evidence.json` for
capture durations/status. Parallel durations overlap, so their sum exceeds wall
time on many runs. The entrypoint's run timing stops at compilation; use elapsed
CLI wall time when benchmarking finalization/archive cost.

For a smaller follow-up:

```bash
./bin/linux-context --profile standard --no-archive
sudo ./bin/linux-context --profile max --target network --jobs 2
```

Reduce profile, focus targets or lower concurrency according to the question.
`all` activates more detail. Lower jobs reduces simultaneous host work but can
increase elapsed time. Individual collectors may override default command
limits; outer acquisition watchdogs remain active. There is no single whole-run
timeout or public CLI budget override.

A metadata/detection operation has a five-second limit. Acquisition has a
12-times-profile-timeout watchdog and nested-producer cleanup. Vendor APIs,
filesystems and final redaction can still cost time. Do not bypass watchdogs or
redaction merely to achieve a lower benchmark number.

## Deferred graphs and larger archives

If `coverage.graph_deferred` is true, follow `indexes.graph`. The AI entrypoint
contains summaries, not the full graph. `context.ai.json` preserves that route;
decoding it does not fetch the sidecar.

The evidence budget caps retained `sections/` bytes. It does not cap typed graph,
metadata, transient raw staging or total archive size. Gzip archive compression
also does not reduce tokens after files are unpacked into an AI prompt. Start
with the AI view and retrieve only relevant state.

## Failure cleanup and archive output

Before publication, invalid records, missing worker completion, unsafe evidence
paths, budget/graph errors, AI round-trip failures or high-confidence residuals
block completion. Temporary acquisition is normally removed after producers stop.
On INT/TERM the launcher stops/reaps workers, then cleans up. SIGKILL, host failure
or unsuccessful producer termination can leave private temporary files; a failed
termination logs the private staging path. Treat leftovers as sensitive and
ensure no producer is writing before removing them.

Directory publication happens before archive creation. If tar/gzip, permissions,
space or a concurrent path change prevents archiving, the completed directory may
remain and the archive may be partial. Inspect the reported error before using an
archive. `--remove-dir-after-archive` removes the directory only after successful
archive creation. With archive-only mode, use the printed `Archive:` path.

## Integrity, decoding and safe reports

```bash
(cd /path/to/bundle && sha256sum -c manifest.sha256)
python3 -B -S lib/ai_view.py decode /path/to/bundle/context.ai.json reconstructed.json
```

Run decoding from the repository root. Use a decoder that supports the bundle's
AI encoding version. Failed checksums can indicate edits, corruption or
replacement; they are not a source-authentication mechanism. Preserve the
original bundle and investigate before trusting modified data.

For public bug reports, include tool version/commit, profile/target/jobs,
distribution/kernel/architecture, Bash/Python versions, privilege/container mode,
exact error and minimal sanitized relevant metadata. Do not upload raw/private
staging or unreviewed bundles. For exploitable issues or secret exposure, follow
[private reporting in SECURITY.md](../SECURITY.md#reporting-a-vulnerability).
