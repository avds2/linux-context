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

Automatic Bluetooth discovery reports `workstation.bluetooth.adapter_count`
from `/sys/class/bluetooth`, when readable. This is the kernel adapter inventory,
not a claim about BlueZ connectivity or paired devices. Explicit
`bluetooth`/`workstation`/`all` targets additionally query the bounded daemon
controller inventory; failures leave that count unknown. Desktop device names
remain excluded from the automatic model.

Package counts reuse a successful bounded inventory; Debian entries must be in
the `installed` state. A truncated inventory exposes a `*_limited` flag rather
than an exact count, and a failed command never establishes a zero count.
Systemd `modeled_service_count` counts retained entities; `relevant_service_count`
also includes relevant units that exceeded the item cap.

## Collector output priorities

Prefer structured observations over raw text. Persistent evidence should answer a likely follow-up question that cannot be represented economically in the graph. Bulk default configuration, transient user activity and exhaustive inventories should generally be target-only.

## Hardware model (standard and above)

`hardware.memory` reads allowlisted SMBIOS type 16/17 fields through `dmidecode`
when available, at every profile from `standard` onward. Module and array facts
are firmware reports, not direct electrical/SPD measurements. The collector
never installs packages, reads SPD EEPROMs, or persists serial/asset identifiers.

- `memory_array`: firmware-reported maximum capacity, device count and ECC policy.
- `memory_device`: slot/bank, populated state, capacity, DDR type, manufacturer,
  part number, form factor, rank, widths, rated and configured speeds/voltage.
- `hardware.memory.installed_bytes`: sum of known populated devices only when
  the inventory is complete; distinct from existing OS-visible `total_bytes`.
- `known_installed_bytes`: sum of known capacities when inventory may be partial.
- `module_inventory_status` and `discovery_hint`: missing tools, permission or
  firmware gaps, unknown values and truncation stay explicit.

Speeds retain the units emitted by the installed dmidecode version. Empty slots
are not modules; unknown-size devices are not treated as empty. Slot counts and
maximum capacity are firmware claims and may not indicate user-upgradeable slots
(e.g. soldered RAM) or a guaranteed supported upgrade. No dual-channel state or
DDR generation is inferred from slot names, capacity or speed alone.

`hardware.platform` adds bounded typed CPU topology/cache/selected instruction
features, microcode and CPU vulnerability/mitigation reports, safe motherboard/BIOS identity, GPU PCI model/driver and available VRAM,
disks (model, transport, capacity, rotational/removable/read-only flags),
and system power supplies. Battery full capacity as a percentage of design
capacity is derived only from matching energy or charge counters, with a nonzero
design denominator. Energy is in micro-watt-hours; charge is in micro-amp-hours,
as defined by the kernel power-supply ABI. This estimate is not a battery test.
Peripheral power supplies with `scope=Device` are omitted. Missing GPU VRAM
counters do not imply zero VRAM; shared-memory GPUs often do not expose them.

`hardware.memory.available_bytes`, `swap_total_bytes`, and `swap_free_bytes` are
point-in-time kernel counters. They do not identify the installed modules.

## Hardware context economy

Automatic runs keep typed hardware facts and omit duplicate textual CPU/free/
block-hardware/firmware inventories. PCI and USB evidence remain available for
less common devices. Explicit `--target hardware`, `cpu`, `memory`, `storage` or
`all` retain relevant raw detail on demand. The model uses one entity per device,
shared interned provenance, bounded counts, and omits unspecified attributes.
No output schema changes or lower context/evidence ceilings are required.

Reference interfaces: [dmidecode](https://www.nongnu.org/dmidecode/) and the
[kernel power-supply ABI](https://www.kernel.org/doc/html/latest/power/power_supply_class.html).

Disk identity follows lsblk and can describe virtual disks; it is not proof of
physical media. Loop devices and kernel RAM disks (major 7 and 1) are excluded.
