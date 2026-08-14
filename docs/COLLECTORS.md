# Collector catalog and design rules

Run `./bin/linux-context --list-collectors` for the authoritative runtime catalog. Collectors are modular and capability-detected; absence of a subsystem is represented explicitly rather than assumed.

Current domains include:

- core identity, OS, capabilities and kernel;
- hardware inventory;
- storage topology and health;
- network topology, managers/Wi-Fi, VPN overlays;
- systemd and scheduled jobs;
- runtime/process pressure;
- security posture and SSH;
- packages/repositories;
- Docker and container topology;
- web/reverse-proxy engines;
- boot/firmware chain;
- virtualization host capability;
- login/session topology;
- workstation display/audio/Bluetooth/power state;
- high-priority journal/kernel diagnostics.

## Profile gate

`COLLECTOR_MIN_PROFILE` controls when a collector becomes eligible. A target does not bypass the profile gate.

## Target gate

Targets tell eligible collectors where high-cardinality or expensive diagnostic detail is worthwhile. `auto` keeps the broad machine model compact. `all` satisfies every target-specific depth gate but remains subject to the same read-only, redaction, per-probe, aggregate evidence and AI-entrypoint bounds.

## Collector output priorities

Prefer structured observations over raw text. Persistent evidence should answer a likely follow-up question that cannot be represented economically in the graph. Bulk default configuration, transient user activity and exhaustive inventories should generally be target-only.
