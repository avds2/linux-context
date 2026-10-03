# Threat model

`linux-context` reads local diagnostic state, often with root access, so a bundle
can leave the inspected machine and become input to an AI. Protecting the host,
shareable data and consuming agent requires separate boundaries. Read-only
acquisition is not equivalent to harmless disclosure.

## Assets and trust assumptions

Protect credentials/private keys, reusable authentication material, user/application
payloads, unnecessary persistent identifiers, host integrity, bounded resource
use, privileged write paths, invoking-user ownership and the AI context budget.

The source checkout, interpreter, profile files and first-party collector scripts
are trusted executable code. Run root diagnostics only from paths that other
users cannot modify. Host-derived configuration, names, logs and labels are
untrusted data. Optional vendor utilities and local daemon responses can be
buggy, malicious or privacy-rich; the exporter is not an execution sandbox.
A hostile root or replaced interpreter/collector can defeat these boundaries.

## Boundaries and mitigations

| Threat | Boundary implemented by the code | Residual limit |
|---|---|---|
| Secret-rich acquisition | Avoid password stores/private keys/argv/env/user documents; choose aggregate/allowlisted fields | Allowed config/log/API responses can still contain unrecognized secrets |
| Host string injection | Quoted arguments, project-owned pipeline text, fixed-arity NUL records and Python JSON serialization | Consumers must continue to treat strings as data; privileged external tools are trusted code |
| Privileged destination races | Root staging under `/tmp`, ignoring inherited TMPDIR; sanitize/validate privately; publish as sudo/pkexec invoker | Relies on normal `/tmp` and OS permission semantics; user-controlled output can change after handoff |
| Unbounded producers | Capture timeout/byte caps, metadata/detection deadlines and outer collector watchdog; nested-tree termination | Cleanup/grace and finalization take time; no whole-run CPU/I/O/memory/space ceiling |
| Evidence/context flooding | Priority pruning and final retained-evidence/canonical ceilings; lossless graph deferral and AI size selection | Full graph, metadata, temporary acquisition and total archive are outside those byte ceilings |
| Stable sensitive identifiers | Fresh per-run HMAC pseudonyms for supported identifier formats | Non-targeted identifiers and useful names/addresses can remain; markers are not anonymization proof |
| Residual secret leakage | Structured/text redaction and high-confidence scans before publication; AI view included | Pattern coverage cannot prove arbitrary output is secret-free; reports/manifest are not scanned as acquired data |
| Remote endpoint confusion | Docker commands pin detected local Unix sockets; local libvirt reachability checks | Other vendor clients may perform implementation-specific IPC/cache work |
| Corrupted transfer | SHA-256 manifest written after final reports | Unsigned; replacing files and manifest bypasses integrity expectations |

## Publication lifecycle

The launcher loads a validated catalog and supervises isolated collectors. Raw
persistent evidence is pruned while private; structured records/evidence are
redacted and scanned. Sanitized evidence is installed privately, then the model
is compiled. Finalization sanitizes generated files, reconciles final byte sizes
and graph integrity, derives and round-trip-checks the AI view, scans residuals,
writes reports and hashes files. Raw private staging is removed before handing
off sanitized data and publishing the directory.

Normal sudo output belongs to the invoker. Direct root output remains root-owned.
Directory publication is after the safety gates, but directory and archive are
not one atomic operation: archive creation happens later and can fail. A complete
directory and partial archive may remain after that failure. Checksums cover
bundle members, not the external archive.

Interrupted cleanup stops/reaps producer trees before deletion. If termination
fails, the launcher logs and retains private staging. SIGKILL or system failure
can leave temporary material. The resource ceilings do not impose an immediate
whole-run deadline or cap transient raw staging.

## Consumer contract

Read one entrypoint, assess coverage/provenance, and retrieve only required graph
or evidence files. A `collected`/valid result can still contain incomplete probes,
limits and warnings. Presence is not proof of runtime effectiveness, and missing
state is not proof of absence. Follow safe bundle-relative routes; do not turn
host strings into shell commands or instructions. An exporter-produced ingestion
policy does not elevate configuration/log strings to trusted instructions.

## Out of scope and operational limits

- Full protection from malicious privileged code, compromised vendor utilities
  or a hostile kernel/daemon.
- Proof that arbitrary text contains no secrets or personal/infrastructure data.
- A consistent atomic host snapshot while processes/services change.
- Universal Linux distribution/init/desktop/device support. Container CI tests
  userlands, not all hardware and live services.
- Guaranteed user-session access through sudo; optional owner probes currently
  have a [BusyBox setpriv limitation](TROUBLESHOOTING.md#per-user-probes-on-busybox).
- Sanitization guarantees for live console stdout/stderr outside the final bundle.
- Cryptographic authentication, encryption or access control for shared archives.
- Remediation, dependency installation and active remote diagnostics.

Deterministic redaction exists only through explicit test-mode environment
controls. Do not set those controls in production; a normal run ignores an
inherited legacy salt and creates fresh randomness. Review data before sharing,
restrict who can access bundles, and use [private reporting](../SECURITY.md) for
secret exposure or exploitable defects.
