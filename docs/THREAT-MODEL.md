# Threat model

The primary security problem is unusual: `linux-context` often runs with read access to privileged system state specifically so its output can leave the machine and be consumed by another system/AI.

## Assets to protect

- credentials and private keys;
- reusable authentication material and password hashes;
- user/application payload data;
- persistent device/remote-peer identifiers when they are not diagnostically necessary;
- integrity of the host being inspected;
- bounded host CPU/I/O/time usage;
- the invoking user's filesystem ownership and destination paths;
- the AI consumer's prompt/context budget.

## Main threat classes

### Dangerous acquisition

A command may expose secrets even if it is read-only. The preferred mitigation is not to acquire the source. Prohibited-source tests enforce several high-risk classes.

### Host-derived injection

Hostnames, unit descriptions, labels, package metadata, configuration and logs can contain attacker-controlled strings. They must remain data and must never become shell syntax or trusted AI instructions.

### Privileged filesystem races

When invoked with `sudo`, user-controlled working directories/TMPDIR/output paths must not become privileged write primitives. Raw acquisition and shareable-bundle construction happen in a root-safe private temporary tree; publication occurs only after sanitization and ownership handoff.

### Resource exhaustion/context flooding

Every persistent command is time/byte bounded. Profiles impose an aggregate evidence ceiling and a separate canonical AI-entrypoint ceiling. Large graphs are deferred to a sidecar rather than allowed to consume an unbounded prompt.

### Redaction failure

Redaction is mandatory and structure-aware for internal records/JSON. Per-run HMAC markers preserve within-bundle correlation without stable cross-run hashes. A residual high-confidence finding blocks a successful bundle.

## Out of scope / residual risk

- malicious or buggy third-party utilities can have behavior outside the project's control;
- arbitrary text can contain secret formats the redactor does not recognize;
- diagnostically useful infrastructure data can itself be sensitive;
- root can read more state than an unprivileged run, so root-generated bundles deserve stricter review before sharing.
