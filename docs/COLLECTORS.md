# Collector catalog and resource settings

The catalog below describes the shipped code. For a different checkout or release,
run `./bin/linux-context --list-collectors` and `--list-targets` from its root.
Metadata lists eligibility, not a promise that the subsystem was observed.

## Selection rules

The orchestrator evaluates gates in this order:

1. Minimum profile: lower tiers produce `skipped`.
2. Target match: `auto` and `all` consider every eligible collector. Named targets
   retain baseline collectors and matching non-baseline collectors; other
   collectors produce `skipped`.
3. Privilege: a `root` collector without root produces `unavailable`.
4. Detection/access: unsuccessful or timed-out detection produces `unavailable`.
5. Acquisition: exit zero produces `collected`; nonzero produces `partial`.

`optional-root` collectors run without root and can observe less. `user` is a
metadata policy label, not automatic privilege dropping: under sudo these
collectors still start as root and must explicitly use owner-scope helpers for
per-user state. No shipped collector currently has the `root` policy.

A named target only matches metadata or activates a collector's own detail gates;
it is not an arbitrary collector ID. Aliases that select the same collector can
activate different branches. `all` satisfies every `target_requested` check.

## Catalog

| ID | Minimum profile | Targets | Privilege | Baseline |
|---|---|---|---|---|
| `applications.web` | `deep` | `web`, `apache`, `nginx`, `caddy`, `haproxy` | `optional-root` | no |
| `boot.chain` | `deep` | `boot`, `firmware` | `optional-root` | no |
| `containers.docker` | `deep` | `docker`, `containers` | `optional-root` | no |
| `core.capabilities` | `deep` | `system` | `user` | yes |
| `core.identity` | `quick` | `system` | `user` | yes |
| `core.kernel` | `standard` | `system`, `kernel` | `user` | yes |
| `core.os` | `quick` | `system` | `user` | yes |
| `hardware.inventory` | `standard` | `system`, `hardware`, `cpu`, `gpu`, `memory` | `optional-root` | yes |
| `hardware.memory` | `standard` | `system`, `hardware`, `memory` | `optional-root` | yes |
| `hardware.platform` | `standard` | `system`, `hardware`, `cpu`, `gpu`, `display`, `power` | `user` | yes |
| `logs.journal` | `max` | `systemd`, `logs` | `optional-root` | no |
| `network.manager` | `deep` | `network`, `wifi` | `user` | no |
| `network.topology` | `standard` | `network`, `docker`, `containers`, `vpn`, `web`, `security` | `optional-root` | no |
| `network.vpn` | `deep` | `network`, `vpn`, `wireguard`, `tailscale`, `zerotier` | `optional-root` | no |
| `packages.inventory` | `deep` | `packages` | `user` | no |
| `runtime.processes` | `deep` | `runtime`, `processes`, `systemd`, `docker`, `containers` | `user` | no |
| `security.posture` | `deep` | `security` | `optional-root` | no |
| `security.ssh` | `deep` | `ssh`, `security` | `optional-root` | no |
| `services.scheduled` | `deep` | `services`, `scheduler`, `cron`, `scheduled` | `optional-root` | no |
| `services.systemd` | `standard` | `systemd`, `services`, `docker`, `containers`, `web` | `user` | no |
| `sessions.desktop` | `deep` | `sessions`, `desktop`, `workstation` | `user` | no |
| `storage.health` | `max` | `storage`, `health` | `optional-root` | no |
| `storage.topology` | `standard` | `storage` | `optional-root` | no |
| `virtualization.host` | `deep` | `virtualization`, `kvm`, `libvirt`, `qemu` | `optional-root` | no |
| `workstation.devices` | `max` | `workstation`, `desktop`, `audio`, `bluetooth`, `display`, `power` | `optional-root` | no |

There are 25 collectors: 2 begin at quick, 7 at standard, 13 at deep and 3 at max.
Higher profiles remain subject to detection/access and target selection.

## Resource settings

These values are read from `profiles/*.conf`, not inferred from a target name.

| Setting | quick | standard | deep | max |
|---|---:|---:|---:|---:|
| Default command timeout | 5 s | 10 s | 15 s | 30 s |
| Default capture cap | 128 KiB | 512 KiB | 1 MiB | 2 MiB |
| Retained evidence ceiling | 512 KiB | 1.5 MiB | 4 MiB | 6 MiB |
| Canonical entrypoint ceiling | 32 KiB | 64 KiB | 96 KiB | 128 KiB |
| Default concurrent collectors | 1 | 2 | 3 | 3 |
| Item limit used by collectors | 100 | 500 | 2,000 | 10,000 |
| Journal window | `2h` | `24h` | `3 days ago` | `7 days ago` |
| Log sample items | 40 | 80 | 120 | 200 |
| Signature items | 40 | 80 | 120 | 200 |
| Per-collector acquisition deadline | 60 s | 120 s | 180 s | 360 s |

Metadata and detection each have a five-second timeout. Acquisition has an outer
watchdog of 12 times the profile command timeout, in addition to individual
command limits. Termination/cleanup grace and final processing add time; these
are not whole-run deadlines. Metadata is loaded sequentially; collectors use
bounded parallelism with `--jobs 1..8`.

Collectors can pass explicit command timeouts/caps instead of the defaults. The
item/log settings are consumed only by relevant collector branches; they are not
a universal entity limit. `bounded_command` provides a timeout only; persistent
and ephemeral runner captures also cap bytes. Direct file captures cap bytes and
remain inside the outer collector watchdog.

Budget pruning occurs after acquisition and again during compilation. Final
sanitized canonical/evidence sizes are checked before publication. Temporary
raw output, typed graph, operational metadata and archive size are not capped by
the retained-evidence ceiling. Graph overflow routes full state to a sidecar.

Profiles are project-owned Bash configuration. There is no public CLI to set
arbitrary budgets/log windows, and environment variables are not a supported
replacement for profile files: loading a profile assigns its values. `--jobs` is
the documented override.

## Observation semantics

- **OS/init/kernel:** os-release is parsed as data, with `/usr/lib/os-release`
  fallback. PID 1 is explicit. Missing module trees in containers do not establish
  a reboot requirement; the non-container heuristic remains an inference.
- **Network:** addresses/routes include IPv6. Client presence does not establish
  an active NetworkManager/networkd daemon. Coexisting nft/iptables/ip6tables
  evidence is retained when accessible. Automatic mode limits remote-peer detail
  and summarizes Docker veth devices; focused network/security paths can disclose
  more addressing data.
- **Systemd:** detection requires `systemctl` and `/run/systemd/system`. Service
  counts refer to observed inventory; truncation makes them incomplete.
  `modeled_service_count` counts retained service entities;
  `relevant_service_count` includes eligible units beyond the item cap. Automatic
  user-scope modeling favors persistent/custom/unhealthy units, while focused
  systemd/services targets expand it. PID 1 identification is not native support
  for non-systemd service inventories.
- **Packages:** successful bounded inventories supply counts. Debian filters
  installed database state, excluding residual conffile-only records. Failed
  inventories do not establish zero; truncated native/Flatpak inventories expose
  a `*_limited` flag instead of an exact count. Snap's truncated listing omits its
  count. Flatpak/Snap app enumeration is max-tier packages-target detail.
- **Scheduling/boot:** bounded metadata traversal does not follow symlinks or
  cross filesystem devices. Scheduled command bodies are not read. Focused boot
  diagnostics can retain sanitized loader configuration.
- **Applications/Docker:** installed web engines remain modeled separately from
  running state; active/focused paths add configuration. Docker pins a discovered
  local Unix socket and excludes environment values/arbitrary label dumps.
- **VPN/logs:** VPN queries retain aggregate/filter-selected state, not raw peer
  identity dumps. Journal acquisition is max-tier and bounded; automatic issue
  signatures reduce repetition, while logs targets can retain raw samples.
- **Security:** kernel AppArmor enablement and query availability are distinct.
  Failed optional queries are not proof of disabled protection. SSH source and
  effective configuration are selected without private-key contents.
- **Workstation:** automatic Bluetooth adapter count comes from sysfs; it is not
  the BlueZ controller count. Explicit bluetooth/workstation/all paths additionally
  query BlueZ with a three-second discovery limit. A failed/truncated discovery
  leaves controller count unknown. Audio/device evidence can contain personal
  names in focused runs; automatic mode avoids those inventories.

## Hardware semantics

From standard onward, `hardware.memory` uses allowlisted SMBIOS type 16/17 fields
through optional `dmidecode`. It does not install tools, read SPD EEPROMs, or
persist module serial/asset identifiers.

| Model element | Interpretation |
|---|---|
| `memory_array` | Firmware maximum capacity, device count and ECC policy |
| `memory_device` | Slot/bank, population, known capacity, DDR type, manufacturer/part number, form factor, rank, widths, rated/configured speeds and voltage |
| `hardware.memory.installed_bytes` | Sum of known populated capacities only when the module inventory is complete |
| `hardware.memory.known_installed_bytes` | Known capacity sum when the inventory may be partial |
| `hardware.memory.module_inventory_status` and `hardware.memory.discovery_hint` | Missing tooling/access/firmware, unknown or truncated inventory |
| `hardware.memory.total_bytes`, `hardware.memory.available_bytes`, swap counters | Point-in-time Linux-visible memory, not physical module identity |

Firmware slots/capacity/ECC claims do not prove physical upgradeability, supported
upgrades or active channel mode. Unknown-size devices are not empty slots. Speeds
retain dmidecode's emitted units; no DDR generation or dual-channel state is
inferred from capacity, speed or slot naming.

`hardware.platform` adds bounded CPU topology/cache/selected features, microcode,
vulnerability/mitigation reports, safe motherboard/BIOS identity, PCI GPU
model/driver and available VRAM, disk model/transport/capacity/flags, and system
power-supply counters. Virtual disks can have model strings; they do not prove
physical media. Kernel loop/RAM disks are excluded. Missing GPU VRAM counters do
not mean zero; shared-memory GPUs may expose none.

Battery full/design percentage uses matching energy or charge counters and a
nonzero denominator. Energy is in micro-watt-hours; charge in micro-amp-hours.
The result is a firmware/kernel estimate, not a measured battery test. Supplies
with `scope=Device` are omitted from the platform battery model.

Automatic runs retain typed hardware while omitting duplicate CPU/free/block/DMI
text. Hardware/cpu/memory/storage/all targets enable corresponding extra evidence
according to each collector's gates. PCI/USB evidence supports devices outside
the typed model.

Reference interfaces: [dmidecode](https://www.nongnu.org/dmidecode/) and the
[kernel power-supply ABI](https://www.kernel.org/doc/html/latest/power/power_supply_class.html).

## Authoring rules

Prefer global facts for global state, attributes for per-object state and edges
for relationships. Omit unspecified values rather than guessing. Preserve
provenance, distinct observations and limited/unknown coverage.

Use bounded ephemeral probes when raw output is unnecessary; register persistent
evidence only for useful follow-up questions. Avoid duplicate text, unsafe secret
sources and expensive automatic detail. See [the collector API and development
workflow](../CONTRIBUTING.md#collector-api) before adding a collector.
