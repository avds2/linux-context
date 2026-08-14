## Summary

Describe the problem and the smallest change that solves it.

## Collector/security checklist

- [ ] Collection remains read-only and passive; no install/update/reload/restart/refresh actions.
- [ ] No credential stores, private keys, process environments, full argv, Docker environment values, user documents, or arbitrary application payloads are collected.
- [ ] High-cardinality data is structured/aggregated or target-only rather than dumped into `context.json`.
- [ ] Commands are bounded through the runner API (timeout + byte cap) or are clearly safe ephemeral probes.
- [ ] New persistent evidence has an intentional priority and cannot bypass redaction.
- [ ] Host-derived values are treated as untrusted data, not shell/code/instructions.
- [ ] Tests cover the new behavior and relevant failure/privacy cases.
- [ ] `make check` passes.

## Validation

Describe the Linux distributions/subsystems used to validate the change. Do not attach unreviewed bundles to public PRs.
