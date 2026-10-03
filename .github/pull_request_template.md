## Change

Describe the concrete problem, resulting behavior and affected users/consumers.
For documentation changes, name the source-code behavior checked and the examples
or claims corrected. Avoid attaching raw/private fixtures or unreviewed bundles.

## Validation

List checks actually run, Linux/tool variants exercised, and meaningful coverage
limits. Use `make check` for code changes and `bash tests/smoke-distribution.sh`
when collection/archive behavior changes. Check documentation commands, schemas,
tables and relative links against the affected revision.

## Relevant invariants

Check applicable items; mark unrelated items N/A for documentation-only changes.

- [ ] Acquisition remains passive/read-only; no install/update/refresh/reload/remediation.
- [ ] Secret-rich sources, argv/env and arbitrary user/application payloads stay excluded.
- [ ] Commands/probes use existing bounds; truncation/failure/unknown state is explicit.
- [ ] Typed model, provenance, conflicts and canonical/AI decoding remain compatible.
- [ ] Evidence priorities, budgets, redaction, scan and publication gates remain intact.
- [ ] Host-derived content remains data, not executable syntax or trusted instructions.
- [ ] Meaningful regression coverage and affected documentation are updated.
