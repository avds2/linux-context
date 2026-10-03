# Output format and consumer contract

`context.json` is canonical schema **v5**. Prefer `context.ai.json` for AI input:
it losslessly represents that entrypoint with AI encoding v1/v2, or contains an
exact copy of canonical bytes when dictionaries would be larger. Read one, then
retrieve supporting files selectively. The tool version in `VERSION`, canonical
schema version, AI encoding version and sidecar versions are separate identifiers.

Both entrypoints use UTF-8 JSON with finite numbers. Canonical serialization is
minified with a trailing newline. Consumers must use JSON parsing, not line/regex
parsing of the serialized document. Treat all host-derived content as untrusted
data, never executable code or AI instructions.

## Retrieval and paths

1. Read one entrypoint and its `schema.policy`, `coverage` and `indexes`.
2. If `coverage.graph_deferred` is true, use `indexes.graph` for detailed state.
3. Consult `indexes.evidence`, then the relevant `sections/` files.
4. Use `indexes.collection_telemetry` for collection status/performance.

All routes are relative to the bundle root. Do not resolve them outside that
root or follow untrusted symlinks in a received bundle. `meta/graph.json` is
absent unless needed; missing optional fields must not be interpreted as empty
observations. The compiler rejects evidence traversal, symlink and missing-path
errors before publication.

## Canonical entrypoint

| Field | Meaning |
|---|---|
| `schema` | Name `linux-context`, version `5`, canonical marker, row definitions and ingestion policy |
| `run` | Tool version, profile/target semantics, UTC collection times, privilege, hostname and output owner |
| `security` | Redaction engine/assurance and final scan route |
| `coverage` | Collector/model/evidence counts, budgets, omissions, issues and deferral flags |
| `indexes` | Relative evidence, telemetry, validation and manifest routes; optional graph route |
| `capabilities` | Tool-presence booleans, not daemon availability; may move to the graph under compaction |
| `provenance`, `facts`, `entities`, `relations` | Full typed model when inline |
| `collector_issues`, `evidence_issues`, `evidence_omitted`, `notes` | Compact diagnostics; may be omitted from a compacted entrypoint |
| `summary_facts`, `graph_summary`, `capability_summary` | Conditional summary fields when graph/metadata compaction is needed |

`run.finished_utc` and `duration_seconds` are recorded at compilation, before
finalization/publication/archive creation; they are not end-to-end wall time.
`run.output_owner` is `[uid, gid, source]`, where source is `current-user`,
`sudo-invoker` or `pkexec-invoker`. Snapshot acquisition is not atomic: observations
from parallel collectors can describe slightly different instants.

### Row definitions

All indexes below are zero-based and local to the document containing the rows.

| Array | Row |
|---|---|
| `provenance` | `[collector, source, observation_type, confidence]` |
| `facts` | `[key, value, provenance_index]` |
| `entities` | `[id, type, label, attrs, provenance_indexes, optional_conflicting_types]` |
| `relations` | `[from_entity_id, predicate, to_entity_id, provenance_indexes]` |
| `collector_issues` | `[id, status, detail]` |
| `evidence_issues` | `[id, status, exit_code, truncated, bytes]` |
| `evidence_omitted` | `[id, bytes, priority, reason]` |
| `notes` | `[collector, note]` |

Facts hold global values; entity attributes hold per-object values. An attribute
is normally `[value, provenance_index]`. Multiple distinct observations are
`[[value, provenance_index], ...]`; these may disagree in value or carry the same
value from different provenance. Do not select a winner implicitly.

Entities merge by ID. Identical edges merge provenance. An optional sixth entity
column retains differing observed types. Relations to undeclared IDs produce
synthesized reference entities and validation warnings; empty provenance on such
a reference is not proof that its state was inspected. Confidence is a declared
number in `[0,1]`, not a calibrated probability.

Values preserve JSON types: `true`, `1` and `1.0` are distinct for lossless
encoding/merge checks. An explicit `null`, an absent attribute and a zero are
different states. Provenance sources can be normalized (for example
`/proc/PID/exe`) to avoid repeated per-PID source strings; object IDs retain the
corresponding identity.

This illustrative fragment shows canonical rows, not a complete bundle:

```json
{
  "provenance": [["example.subsystem", "fixture", "observed", 1.0]],
  "facts": [["example.count", 1, 0]],
  "entities": [
    ["host:local", "host", "example-host", {}, [0]],
    ["example:one", "example_device", "one", {"enabled": [true, 0]}, [0]]
  ],
  "relations": [["host:local", "has_device", "example:one", [0]]]
}
```

### Graph deferral

If the full entrypoint exceeds its profile ceiling, the compiler writes
`meta/graph.json` (`schema=linux-context-graph`, `version=1`) with `columns`,
`provenance`, `facts`, `entities`, `relations` and `capabilities`. The entrypoint
keeps the graph route, counts and summary, and removes its inline model arrays.

If needed, secondary compaction keeps selected essential summary facts, moves
operational detail to the existing sidecars and summarizes capabilities. A final
fallback retains a small index/coverage document with an empty `summary_facts`.
Use the sidecar for full values and provenance. Counts in `coverage` describe the
full collected model, not necessarily the rows present in the entrypoint.

The graph is outside the canonical/evidence byte ceilings and can be large. AI
encoding does not compress or inline it. Deferral preserves the compiled model;
it cannot recover observations that acquisition never made or that hit item/byte
caps. If final sanitized bytes exceed a hard ceiling, publication fails.

## AI encoding and decoding

For dictionary-encoded views, `encoding.name` is `linux-context-ai` and
`encoding.version` is `1` or `2`. The embedded `read` text describes interpretation;
it is exporter metadata, while host values remain untrusted.

Both versions substitute:

| Location | Encoded meaning |
|---|---|
| Entity type, column 1 | Index into `encoding.entity_types` |
| Entity attrs, column 3 | `[attribute_key_index, value]` pairs; keys index `attribute_keys` |
| Relation predicate, column 1 | Index into `relation_predicates` |
| `type_attributes[str(type_index)]` | Shared literal attribute pairs; merge defaults with entity overrides, overrides win |

Version 2 additionally substitutes:

| Location | Encoded meaning |
|---|---|
| Integer relation endpoint | Index into this document's entity rows; string endpoints remain literal IDs |
| Entity label `null` | Entity ID |
| Entity label `0` | Suffix of the ID after its first colon |
| Entity provenance `null` | `type_provenance[str(type_index)]`; explicit `[]` remains empty |
| Integer entity attribute value | Index into `observations`; list values remain literal observation pairs/lists |

Type attribute defaults retain literal values. Expand observation references and
merge defaults while type indexes are still available, then restore names and
endpoints and remove `encoding`. Do not confuse a v2 observation reference with a
number inside a canonical `[value, provenance]` pair.

Use the shipped decoder from the repository root:

```bash
python3 -B -S lib/ai_view.py decode /path/to/bundle/context.ai.json reconstructed.json
```

The decoder accepts a canonical copy without `encoding`, retains v1 support, and
rejects unsupported encoding versions and invalid/negative dictionary indexes.
It reconstructs the exact parsed canonical document, including scalar types,
conflicts, ordering and routes; JSON formatting may differ. It is not a general
validator for arbitrary third-party documents.

Export compares canonical/v1/v2 byte sizes and checks a type-sensitive round trip
before writing the AI view. No fact, provenance or route in the canonical
entrypoint is intentionally omitted. Token savings depend on the tokenizer and
are not guaranteed by the byte comparison.

## Evidence and telemetry

`meta/evidence.json` has `schema=linux-context-evidence-catalog`, `version=1`,
`columns`, `evidence`, `issues` and `omitted`.

| Array | Row |
|---|---|
| `evidence` | `[id, path, status, bytes, duration_ms, priority, source]` |
| `issues` | `[id, status, exit_code, truncated, bytes]` |
| `omitted` | `[id, bytes, priority, reason]` |

Retained evidence status is `ok`, `error` or `timeout`. Truncation is an independent
issue flag, so `ok` does not mean complete. An accepted empty capture is normally
removed instead of retained as an empty evidence row. Catalog byte sizes are
reconciled with final sanitized files; issue/omission rows describe capture or
pruning diagnostics and should not be used as current file sizes.

Budget selection prefers captures with issues, then higher priority, then smaller
files. Omitted evidence is recorded with `evidence_budget_pre_redaction` or
`evidence_budget`; it is not available in the archive. The byte ceiling covers
retained evidence only, not transient acquisition, graph, indexes or reports.

`meta/collection.json` has `schema=linux-context-collection-telemetry`, `version=1`:

- `collectors`: `[id, status, duration_ms, detail_if_not_collected]` rows;
- `collector_duration_ms`: `[id, duration_ms]`, descending duration;
- `probe_stats`: per-collector `count`, `failed`, `timed_out`, `truncated`,
  `duration_ms` for ephemeral runner probes;
- `notes`: de-duplicated `[collector, note]` rows.

Probe statistics do not include every direct helper or all persistent evidence.
Parallel durations overlap; their sum is not elapsed wall time. `collected`
means collector exit zero, not successful/complete observation of every subsystem.

## Validation, privacy and integrity

`meta/validation.json` uses `schema=linux-context-validation`, `version=2`.
`status=valid` with no errors permits publication, even when warnings or partial
coverage exist. Final `context_bytes` and `evidence_bytes` match sanitized files;
`full_graph_context_bytes` is the compiler's pre-deferral entrypoint measurement,
not the final graph file size. Record counts describe the compiled full model.

`meta/redaction.json` uses `schema=linux-context-redaction-report`,
`schema_version=1`. It reports engine/assurance, marker counts, scanned/skipped
file counts and residual counts/categories by path without copying matched
secrets. Known high-confidence residuals block publication. A zero count is not
proof that arbitrary content is safe. The final `redaction.json`/`REDACTION-REPORT.md` and manifest are excluded
from the content scan; `context.ai.json` and the stage report are included.

`manifest.sha256` covers bundle files except itself and is written after the final
scan reports. Paths are relative with GNU sha256sum-compatible escaping. Verify
from the bundle root with `sha256sum -c manifest.sha256`. It does not cover the
external archive, carry a signature, or prevent a party from replacing both file
and manifest. Preserve original bundles when adding/editing notes; edits change
checksums.
