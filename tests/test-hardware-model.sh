#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export PYTHONPATH="$ROOT/lib"
python3 -B -S - "$t" <<'PY'
from pathlib import Path
import sys
from hardware_model import memory_model, platform_model, snapshot, size_bytes
root = Path(sys.argv[1])
text = '''Handle 0x0010, DMI type 16, 23 bytes
Physical Memory Array
    Location: System Board Or Motherboard
    Maximum Capacity: 64 GB
    Number Of Devices: 4
    Error Correction Type: None
Handle 0x0011, DMI type 17, 92 bytes
Memory Device
    Array Handle: 0x0010
    Size: 8 GB
    Locator: DIMM_A1
    Type: DDR4
    Speed: 3200 MT/s
    Configured Memory Speed: 2666 MT/s
    Manufacturer: Kingston
    Part Number: KVR32N22S8/8
    Rank: 1
Handle 0x0012, DMI type 17, 92 bytes
Memory Device
    Array Handle: 0x0010
    Size: 8 GB
    Locator: DIMM_B1
    Type: DDR4
    Speed: 3200 MHz
    Manufacturer: Kingston
Handle 0x0013, DMI type 17, 92 bytes
Memory Device
    Array Handle: 0x0010
    Size: No Module Installed
    Locator: DIMM_A2
Handle 0x0014, DMI type 17, 92 bytes
Memory Device
    Array Handle: 0x0010
    Size: No Module Installed
    Locator: DIMM_B2
'''
def facts(model): return {r['key']:r['value'] for r in model.rows['facts']}
def attrs(model): return {(r['id'],r['key']):r['value'] for r in model.rows['entity_attrs']}
m = memory_model(text, 'no_records')
f, a = facts(m), attrs(m)
assert f['hardware.memory.installed_bytes'] == 16 * 1024**3
assert f['hardware.memory.types'] == 'DDR4'
assert f['hardware.memory.empty_device_count'] == 2
assert f['hardware.memory.module_inventory_status'] == 'available'
assert a['memory-array:0', 'maximum_capacity_bytes'] == 64 * 1024**3
# ECC None is meaningful, unlike unspecified generic fields.
assert a.get(('memory-array:0', 'error_correction')) == 'None'
assert a['memory-device:0', 'configured_speed'] == '2666 MT/s'
assert a['memory-device:1', 'rated_speed'] == '3200 MHz'
assert any(r['from']=='memory-array:0' and r['to']=='memory-device:0' for r in m.rows['relations'])
assert size_bytes('Unknown') is None
assert size_bytes('512 MB') == 512*1024**2
assert size_bytes('2 TB') == 2*1024**4
# Missing firmware values remain unavailable, not a guessed DDR generation.
m = memory_model(text.replace('DDR4','Unknown').replace('Size: 8 GB','Size: Unknown'), 'no_records')
assert facts(m)['hardware.memory.module_inventory_status'] == 'partial'
assert 'hardware.memory.installed_bytes' not in facts(m)
assert 'hardware.memory.types' not in facts(m)
for status in ('tool_missing','access_or_firmware_unavailable','truncated','no_records'):
    m = memory_model('',status)
    assert facts(m)['hardware.memory.module_inventory_status'] == status
    assert 'hardware.memory.discovery_hint' in facts(m)
# Unknown capacity/identity must never turn into zero size or an empty slot.
assert ('memory-device:0','populated') not in attrs(m)

sysroot=root/'sys'; proc=root/'proc'; proc.mkdir()
(proc/'meminfo').write_text('MemAvailable: 8192 kB\nSwapTotal: 2048 kB\nSwapFree: 1024 kB\n')
def field(path, name, value):
    path.mkdir(parents=True,exist_ok=True); (path/name).write_text(str(value))
dev=sysroot/'devices/pci0000:00/0000:01:00.0'
field(dev,'vendor','0x1002'); field(dev,'device','0x73bf'); field(dev,'mem_info_vram_total',8*1024**3)
(sysroot/'class/drm/card0').mkdir(parents=True)
(sysroot/'class/drm/card0/device').symlink_to(dev)
driver=sysroot/'bus/pci/drivers/amdgpu'; driver.mkdir(parents=True)
(dev/'driver').symlink_to(driver)
battery=sysroot/'class/power_supply/BAT0'
for k,v in {'type':'Battery','scope':'System','capacity':65,'energy_full':40000000,'energy_full_design':50000000,'cycle_count':300,'serial_number':'DO-NOT-COLLECT'}.items(): field(battery,k,v)
peripheral=sysroot/'class/power_supply/headphones'
field(peripheral,'scope','Device'); field(peripheral,'serial_number','PRIVATE-HEADSET')
field(sysroot/'class/dmi/id','product_name','Test workstation')
field(sysroot/'class/dmi/id','product_serial','PRIVATE-SERIAL')
cpu=root/'cpu.json'; cpu.write_text('{"lscpu":[{"field":"CPU(s):","data":"8"},{"field":"Topology:","children":[{"field":"Socket(s):","data":"1"},{"field":"Thread(s) per core:","data":"2"}]}]}')
pci=root/'pci.txt'; pci.write_text('0000:01:00.0 "VGA compatible controller [0300]" "AMD [1002]" "Radeon Test [73bf]"\n')
block=root/'block.json'; block.write_text('{"blockdevices":[{"kname":"nvme0n1","type":"disk","size":1000000000000,"rota":false,"ro":false,"rm":false,"tran":"nvme","model":"Test SSD"},{"kname":"nvme0n1","type":"disk"}]}')
data=snapshot(str(cpu),str(pci),str(block),root=sysroot,proc=proc)
assert 'PRIVATE' not in str(data) and 'DO-NOT-COLLECT' not in str(data)
assert len(data['power'])==1
m=platform_model(data); a=attrs(m)
assert a['cpu:local','logical_count']==8
assert a['cpu:local','threads_per_core']==2
assert a['gpu:card0','driver']=='amdgpu'
assert a['gpu:card0','vram_total_bytes']==8*1024**3
assert a['power-supply:BAT0','full_capacity_percent_of_design']==80.0
assert a['block:/dev/nvme0n1','size_bytes']==1000000000000
assert a['block:/dev/nvme0n1','rotational'] is False
assert facts(m)['hardware.memory.available_bytes']==8192*1024
assert len([r for r in m.rows['entities'] if r['entity_type']=='block_device'])==1
# Zero design capacity must not divide by zero or invent battery health.
data['power'][0]['energy_full_design']='0'
assert ('power-supply:BAT0','full_capacity_percent_of_design') not in attrs(platform_model(data))
(root/'fixture').write_text(text+'    Serial Number: PRIVATE-SERIAL\n    Asset Tag: PRIVATE-TAG\n')
PY
mkdir -p "$t/stage" "$t/evidence" "$t/private" "$t/fake"
for kind in FACTS ENTITIES ENTITY_ATTRS RELATIONS ARTIFACTS PROBES; do
    export "LCTX_${kind}_RECORDS=$t/stage/$kind.records"
done
export LCTX_NOTES_FILE="$t/stage/notes.tsv" LCTX_SECTION_DIR="$t/evidence" LCTX_PRIVATE_TMP="$t/private"
export LCTX_PROFILE=standard LCTX_TARGETS=auto LCTX_COMMAND_MAX_BYTES=524288 LCTX_MAX_ITEMS=500 FIXTURE="$t/fixture"
cat > "$t/fake/dmidecode" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == '--type 16,17' ]] || exit 2
[[ "${DMI_MOCK_MODE:-ok}" != fail ]] || exit 1
cat "$FIXTURE"
MOCK
chmod +x "$t/fake/dmidecode"
PATH="$t/fake:$PATH" "$ROOT/collectors/hardware/memory.sh" --run
python3 -B -S - "$t" <<'PY'
from pathlib import Path
import sys
from recordio import read_records
root=Path(sys.argv[1])
assert 'PRIVATE' not in (root/'evidence/memory_dmi.txt').read_text()
f={x['key']:x['value'] for x in read_records(root/'stage/FACTS.records','facts')}
assert f['hardware.memory.installed_bytes']==16*1024**3
assert f['hardware.memory.module_inventory_status']=='available'
assert not list((root/'private').iterdir())
PY
# Failed/truncated firmware acquisition must not produce guessed module facts.
for mode in fail truncated; do
    rm -f "$t/stage/"*.records "$t/evidence/"*.txt
    if [[ "$mode" == fail ]]; then
        export DMI_MOCK_MODE=fail LCTX_COMMAND_MAX_BYTES=524288
    else
        export DMI_MOCK_MODE=ok LCTX_COMMAND_MAX_BYTES=128
    fi
    PATH="$t/fake:$PATH" "$ROOT/collectors/hardware/memory.sh" --run
    python3 -B -S - "$t" "$mode" <<'PYFAIL'
from pathlib import Path
import sys
from recordio import read_records
root=Path(sys.argv[1])
f={x['key']:x['value'] for x in read_records(root/'stage/FACTS.records','facts')}
expected='truncated' if sys.argv[2]=='truncated' else 'access_or_firmware_unavailable'
assert f['hardware.memory.module_inventory_status']==expected, f
assert 'hardware.memory.installed_bytes' not in f
assert not read_records(root/'stage/ENTITIES.records','entities')
PYFAIL
done
printf 'hardware model and collector tests: ok\n' 
