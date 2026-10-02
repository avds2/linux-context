# Security policy

`linux-context` may inspect privileged state and export it outside the machine.
The collector, private staging and final bundle are security-sensitive even
though diagnostic acquisition is passive/read-only.

## Reporting a vulnerability

Do not publish exploitable details, real credentials, raw staging or unreviewed
bundles in a public issue. Use the repository's private GitHub security reporting
mechanism **if enabled**. Otherwise, arrange a private channel with the maintainer
before disclosing sensitive details. The repository does not currently publish a
separate security contact or guaranteed response deadline.

Useful reports include version and Git commit, privilege/profile/target,
environment/tool variants, minimal reproduction, expected/actual behavior and
impact. Supply a sanitized proof of concept with synthetic secrets. Ordinary
non-sensitive bugs can use the public issue form with minimal reviewed excerpts.
There is no documented supported-version/backport matrix; report the exact
revision, and verify whether current main still reproduces the issue.

## Security contract

- **Avoid risky sources:** no intentional password-database/private-key/process
  environment/full argv/Docker environment/user-document/application-payload dumps.
  Use selected state, counts and topology instead.
- **Passive acquisition:** no package installation/repository refresh, service
  remediation, sysctl/network mutation, mounts, active Wi-Fi scans or external
  network checks. This describes first-party command selection; vendor tools are
  not sandboxed or proven side-effect-free.
- **Bounded execution:** runner commands/probes have time and byte limits,
  detection/metadata have deadlines and acquisition has an outer watchdog.
  Final retained evidence and canonical entrypoint have hard byte ceilings.
- **Private staging:** privileged acquisition ignores inherited TMPDIR and uses
  a private `/tmp` tree. Raw evidence is pruned, redacted and scanned before
  sanitized material is publishable.
- **Mandatory sanitization:** Python structural/text redaction uses fresh per-run
  randomness for supported correlation-preserving pseudonyms. Known
  high-confidence residuals and malformed/unsafe data block publication.
- **Ordered publication:** final redaction, byte/graph validation, lossless AI
  round trip, scan/reports and hashing precede directory handoff/publication.
  Archiving follows directory publication and has its own failure boundary.
- **Untrusted content:** host strings remain data for both shell and AI consumers.
  Local Docker endpoints are explicit; remote inherited contexts are ignored.

See the [threat model](docs/THREAT-MODEL.md) for trust assumptions and boundaries,
and [troubleshooting](docs/TROUBLESHOOTING.md) for failure/coverage details.

## Before running and sharing

Run trusted source only, especially under sudo. Protect executable scripts and
parent paths from other users' edits. Use normal invoker identity for sudo
handoff; the source version/commit and schema versions are separate.

Normal directory/file/archive modes are `0700`/`0600`/`0600`. These modes protect
local access; archives are not encrypted. SHA-256 manifests detect file changes
but do not authenticate the producer. Output can be edited after publication.

A zero residual count means no **known high-confidence patterns** remained in
the scanned content. It is not proof that arbitrary diagnostic output is
secret-free. Hostnames, usernames, IPs, package/service names, paths, policy and
topology may intentionally remain. Focused targets/all can include more personal
or remote diagnostic detail than auto. Review entrypoint, graph and evidence
before sharing across a trust boundary.

Do not set deterministic test-mode redaction controls in production. Interrupted
or failed cleanup may leave private temporary material; treat it as sensitive.
Console stdout/stderr are not part of the final bundle sanitization contract;
review logs before sharing them too. The retained-evidence ceiling does not bound
temporary data, the graph/metadata
sidecars or total archive size. Optional per-user probes have a documented
BusyBox setpriv coverage gap; successful publication does not establish complete
host or session inspection.
