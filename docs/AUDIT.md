# Review and validation

Reviewed baseline: `2615be74c2670ac7de4ccd1c52a0b882a5d16aff` (2026-10-01).
The supplied bundle was inspected locally; its contents are not checked into
this public repository. Measurements below describe this revision, not a
performance guarantee for every Linux host.

## Findings and changes

| Problem | Resulting behavior |
|---|---|
| Daemon/direct detection calls could hang outside the runner | Bounded direct calls, a five-second detection deadline, and a collector acquisition deadline of 12 times the profile command timeout. Watchdogs stop the full nested process tree before returning. |
| GNU timeout/find/df/ps and owner tools assumed | Python timeout/UID-GID fallbacks, statvfs root capacity, bounded Python boot/cron metadata and procfs process counts. GNU tools remain optional fast paths. |
| Repeated metadata/process startup and checksums | Collector metadata is read once; stages and manifests are batched. Detection/run share one supervisor. Final sanitization, validation, AI derivation, scanning and hashing share one Python interpreter. |
| Slow automatic Bluetooth daemon query | Automatic sysfs adapter count; BlueZ controller/device queries are explicit-target detail with a three-second discovery limit. Adapter count and daemon controller count remain separate facts. |
| Debian residual conffile packages counted as installed | Filter actual installed state, query once, reuse the bounded inventory. Failed/truncated inventories cannot establish exact or zero counts. |
| Clients mistaken for running managers, empty detection mistaken for bare metal | PID 1 is explicit; systemd requires runtime presence, network managers require observed running state, and unknown detection stays unknown. |
| Missing module trees implied a reboot in containers | Check both module locations. Only a non-container with other installed trees gets a qualified inferred recommendation. |
| AppArmor query failure implied disabled protection | Read the kernel enable flag; inaccessible/failed tooling does not establish disabled state. |
| IPv6 routes and legacy firewall state could be omitted | Preserve IPv6 defaults/routes and coexisting nft/iptables/ip6tables evidence. A wildcard socket no longer invents an IPv6 family. |
| procfs size zero masked truncation | Observe the extra captured byte; preserve caller shell flags. |
| Metadata validation and final byte sizes incomplete | Invalid catalogs/missing worker status block publication. Recompute sanitized context/evidence sizes and graph endpoints before AI generation and publication. |
| Repeated graph strings and typed-value ambiguity | Lossless AI v2 dictionaries for endpoints, observations, labels and provenance. Retain v1 decoding, canonical v5 and type-sensitive boolean/number/conflict observations. |

## Output size

Re-encoding the exact supplied canonical JSON, without removing facts/entities,
relations/conflicts/provenance/evidence routes:

| Encoding | Bytes |
|---|---:|
| Canonical v5 | 114,586 |
| Previous AI v1 | 96,592 |
| New AI v2 | 74,134 |

This is **35.3% smaller than canonical** and **23.3% smaller than the previous AI
entrypoint**. A type-sensitive round trip reconstructs the original document.
The exporter selects the smallest canonical/v1/v2 encoding. Actual token savings
were not measured and depend on the tokenizer. Send `context.ai.json` first;
retrieve evidence only as needed. Archive compression cannot itself reduce
prompt tokens. Large deferred graphs keep the existing sidecar retrieval route.

## Local timing

Five before/after pairs per profile, alternating execution order, same Ubuntu
container and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, default jobs, automatic targets,
`--no-archive`. Wall-clock medians include collection and final publication.
System load, warm caches and container visibility affect the result. The sample
workstation was not available for rerunning hardware/desktop probes.

| Profile | Baseline median | New median | Reduced elapsed time |
|---|---:|---:|---:|
| `quick` | 1.656 s | 0.952 s | 42.5% |
| `standard` | 1.497 s | 1.232 s | 17.7% |
| `max` | 1.750 s | 1.681 s | 3.9% |

The main low-latency gains come from batching startup/hashing and avoiding
unnecessary daemon round trips. Full-tree termination and additional integrity
checks have a cost; safety gates remain enabled in these measurements.

## Validation and limits

- `make check`: 31 executable regression scripts, including randomized and
  type-sensitive AI round trips, four package families, forced Python timeout,
  nested timeout cleanup, shell flags, manager state, final budgets and all
  pre-existing privacy/ownership/path/target checks.
- `tests/smoke-distribution.sh`: all four profiles, archive creation, SHA-256,
  exact AI decoding, reported byte sizes and residual scanning on the local host.
- CI adds Debian 12, Fedora 43, Arch and Alpine 3.22 containers; Alpine deliberately
  keeps BusyBox tools. Existing Python 3.9/3.11/3.13 jobs remain.
- This local namespace maps only UID 0. Sudo ownership fixtures therefore report
  current-user-only coverage; the fallback's drop/exec order is unit-tested, and
  full mapped ownership is exercised by capable CI hosts.
- Docker endpoint fixtures inject only the filesystem socket predicate. Command
  selection, local endpoint pinning, templates and parsing run unchanged without
  requiring sockets or a host daemon in restricted execution environments.
- Container CI validates userlands, not every live init manager, firmware, vendor
  daemon or desktop. Gentoo/Nix/Slackware native package inventories are not added
  by this change. Unsupported optional tools remain explicit coverage gaps.

Reference semantics: [os-release specification](https://www.freedesktop.org/software/systemd/man/latest/os-release.html)
and [BusyBox applet documentation](https://busybox.net/BusyBox.html).
