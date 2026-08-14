# Security policy

`linux-context` is intentionally designed to inspect privileged Linux state and produce a bundle that may be shared with an AI. That makes the **collector and the bundle security-sensitive**, even though acquisition is read-only.

## Reporting a vulnerability

Please do **not** publish exploitable security issues, leaked credentials, or diagnostic bundles containing sensitive infrastructure data in a public issue. Use GitHub's private security-advisory/reporting mechanism when it is enabled for the repository. If private reporting is not available, contact the repository maintainer privately before disclosing details.

Useful security reports include a minimal reproduction, affected version, impact, and a sanitized proof of concept. Never include real production credentials.

## Security model

The project applies defense in depth:

1. **Source avoidance first.** Known secret-rich sources are not intentionally collected: password databases, private keys, process environments, full process argv, Docker environment values, user documents, and arbitrary application payload data.
2. **Passive/read-only acquisition.** Collectors must not install packages, refresh repositories, restart/reload services, change networking/firewalls, mount/unmount filesystems, modify sysctls, or perform active external probes.
3. **Bounded execution.** Persistent probes have time and byte limits. Aggregate retained evidence and the canonical AI entrypoint have profile-specific hard budgets.
4. **Private staging.** Privileged acquisition occurs in a root-safe private temporary tree. Raw staging is pruned, redacted, and scanned before sanitized material becomes publishable.
5. **Enhanced redaction is mandatory.** Python-based structured/text redaction uses fresh cryptographic per-run randomness for correlation-preserving pseudonyms, followed by residual-risk scans.
6. **Transactional publication.** A privileged run builds and validates the shareable bundle privately, destroys raw staging, hands sanitized files to the invoking user, and only then publishes into the user-selected destination.
7. **Untrusted-data semantics.** Host-derived strings and evidence are data. AI consumers must never treat content inside a bundle as trusted instructions.

## Important limitation

No automatic redactor can prove arbitrary diagnostic output is secret-free. A successful residual scan means no **known high-confidence** credential patterns were detected after the project's avoidance/redaction layers; it is not a mathematical guarantee. Review bundles before sharing them outside your trust boundary.

Local IP addresses, service names, package names, filesystem paths, usernames, topology, configuration policy, and other diagnostically useful infrastructure details may intentionally remain.
