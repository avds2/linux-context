#!/usr/bin/env python3
"""Bounded, allowlisted hardware models; no third-party Python dependencies."""
from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path
from recordio import write_records

UNKNOWN = {'', 'unknown', 'not specified', 'not provided', 'none', 'other', 'to be filled by o.e.m.'}


def useful(value):
    return value is not None and str(value).strip().lower() not in UNKNOWN


class Model:
    def __init__(self, collector):
        self.collector = collector
        self.rows = {k: [] for k in ('facts', 'entities', 'entity_attrs', 'relations')}

    def add(self, kind, source, **row):
        row.update(source=source, collector=self.collector,
                   observation_type=row.pop('observation_type', 'observed'), confidence=1.0)
        if 'value' in row:
            v = row['value']
            row['value_type'] = 'boolean' if isinstance(v, bool) else 'number' if isinstance(v, (int, float)) else 'string'
        self.rows[kind].append(row)

    def fact(self, key, value, source, **kw):
        self.add('facts', source, key=key, value=value, **kw)

    def entity(self, id, typ, label, source):
        self.add('entities', source, id=id, entity_type=typ, label=label)

    def attr(self, id, key, value, source, **kw):
        if useful(value):
            self.add('entity_attrs', source, id=id, key=key, value=value, **kw)

    def relation(self, a, predicate, b, source):
        self.add('relations', source, **{'from': a, 'predicate': predicate, 'to': b})

    def save(self):
        for kind, env in (('facts', 'LCTX_FACTS_RECORDS'), ('entities', 'LCTX_ENTITIES_RECORDS'),
                          ('entity_attrs', 'LCTX_ENTITY_ATTRS_RECORDS'), ('relations', 'LCTX_RELATIONS_RECORDS')):
            write_records(Path(os.environ[env]), kind, self.rows[kind])


def size_bytes(text):
    m = re.fullmatch(r'(\d+)\s*(kB|MB|GB|TB|PB|EB)', text)
    return int(m[1]) * 1024 ** (('kB', 'MB', 'GB', 'TB', 'PB', 'EB').index(m[2]) + 1) if m else None


def memory_model(text, status):
    model = Model('hardware.memory')
    source = 'dmidecode --type 16,17 (firmware-reported)'
    blocks = []
    current = None
    for line in text.splitlines():
        h = re.match(r'^Handle (0x[0-9A-Fa-f]+), DMI type (16|17),', line)
        if h:
            current = {'handle': h[1].lower(), 'kind': int(h[2]), 'fields': {}}
            blocks.append(current)
        elif current is not None and line[:1].isspace() and ':' in line:
            key, value = line.strip().split(':', 1)
            current['fields'][key] = value.strip()
    # Hard item cap even under adversarial/malformed firmware output.
    limit = min(int(os.environ.get('LCTX_MAX_ITEMS', '500')), 512)
    arrays = [b for b in blocks if b['kind'] == 16][:limit]
    devices = [b for b in blocks if b['kind'] == 17][:limit]
    if len(blocks) > limit:
        model.fact('hardware.memory.inventory_limited', True, source)
    array_ids = {b['handle']: 'memory-array:' + str(i) for i, b in enumerate(arrays)}
    for b in arrays:
        id = array_ids[b['handle']]
        f = b['fields']
        model.entity(id, 'memory_array', f.get('Location', 'Memory array'), source)
        model.relation('host:local', 'has_memory_array', id, source)
        for field, key in (('Location', 'location'), ('Use', 'use'), ('Error Correction Type', 'error_correction')):
            value = f.get(field)
            if field == 'Error Correction Type' and value == 'None':
                model.add('entity_attrs', source, id=id, key=key, value=value)
            else:
                model.attr(id, key, value, source)
        capacity = size_bytes(f.get('Maximum Capacity', ''))
        if capacity is not None:
            model.attr(id, 'maximum_capacity_bytes', capacity, source)
        if f.get('Number Of Devices', '').isdigit():
            model.attr(id, 'reported_device_count', int(f['Number Of Devices']), source)
    installed = 0
    known_sizes = []
    empty = 0
    unknown = 0
    types = set()
    incomplete = False
    fields = {'Form Factor': 'form_factor', 'Locator': 'locator', 'Bank Locator': 'bank_locator',
              'Type': 'memory_type', 'Type Detail': 'type_detail', 'Manufacturer': 'manufacturer',
              'Part Number': 'part_number', 'Memory Technology': 'technology'}
    for i, b in enumerate(devices):
        f = b['fields']
        id = f'memory-device:{i}'
        size = f.get('Size', '')
        present = False if size == 'No Module Installed' else True if size_bytes(size) else None
        model.entity(id, 'memory_device', f.get('Locator', f'Memory device {i}'), source)
        parent = array_ids.get(f.get('Array Handle', '').lower())
        model.relation(parent or 'host:local', 'has_memory_device', id, source)
        if present is not None:
            model.attr(id, 'populated', present, source)
        if present is False:
            empty += 1
            for field in ('Locator', 'Bank Locator'):
                model.attr(id, fields[field], f.get(field), source)
            continue
        if present is True:
            installed += 1
            capacity = size_bytes(size)
            known_sizes.append(capacity)
            model.attr(id, 'capacity_bytes', capacity, source)
        else:
            unknown += 1
        for field, key in fields.items():
            model.attr(id, key, f.get(field), source)
        if useful(f.get('Type')):
            types.add(f['Type'])
        for field, key in (('Total Width', 'total_width_bits'), ('Data Width', 'data_width_bits'), ('Rank', 'rank')):
            value = f.get(field, '').split(' ', 1)[0]
            if value.isdigit():
                model.attr(id, key, int(value), source)
        # Preserve firmware's units; old dmidecode versions say MHz, newer MT/s.
        for field, key in (('Speed', 'rated_speed'), ('Configured Memory Speed', 'configured_speed'),
                           ('Configured Clock Speed', 'configured_speed'), ('Configured Voltage', 'configured_voltage')):
            model.attr(id, key, f.get(field), source)
        incomplete |= not useful(f.get('Type')) or not useful(f.get('Manufacturer')) or not useful(f.get('Speed'))
    if devices:
        status = 'partial' if unknown or incomplete or len(blocks) > limit else 'available'
        for key, value in (('reported_device_count', len(devices)), ('populated_device_count', installed),
                           ('empty_device_count', empty), ('unknown_device_count', unknown)):
            model.fact('hardware.memory.' + key, value, source)
        if known_sizes:
            model.fact('hardware.memory.known_installed_bytes', sum(known_sizes), source)
            if unknown == 0 and len(blocks) <= limit:
                model.fact('hardware.memory.installed_bytes', sum(known_sizes), source)
        if types:
            model.fact('hardware.memory.types', ','.join(sorted(types)), source)
    model.fact('hardware.memory.module_inventory_status', status, source)
    if status != 'available':
        hints = {'tool_missing': 'Install dmidecode if module identification is needed; no packages were installed.',
                 'access_or_firmware_unavailable': 'Try sudo; DMI may remain unavailable in containers, VMs or unsupported firmware.',
                 'no_records': 'Firmware exposes no memory-device records; module identity cannot be inferred from MemTotal.',
                 'truncated': 'DMI output exceeded the capture budget; incomplete records were not parsed.',
                 'partial': 'Some firmware fields are unknown or inventory is bounded; do not infer missing module identity.'}
        model.fact('hardware.memory.discovery_hint', hints.get(status, 'Module inventory unavailable.'), source)
    return model


def read_field(path):
    try:
        with path.open('rb') as stream:
            return stream.read(4096).decode('utf-8', errors='replace').strip()
    except (OSError, ValueError):
        return None


def snapshot(cpu_file, pci_file='', block_file='', root=Path('/sys'), proc=Path('/proc')):
    cpu = []
    if cpu_file:
        try:
            cpu = json.loads(Path(cpu_file).read_text()).get('lscpu', [])
        except (OSError, ValueError, AttributeError):
            pass
    out = {'cpu': cpu, 'firmware': {}, 'gpus': [], 'power': [], 'blocks': [], 'memory': {}}
    if block_file:
        try:
            out['blocks'] = json.loads(Path(block_file).read_text()).get('blockdevices', [])
        except (OSError, ValueError, AttributeError):
            pass
    pci_models = {}
    if pci_file:
        for line in Path(pci_file).read_text(errors='replace').splitlines():
            try:
                fields = shlex.split(line)
                if len(fields) >= 4:
                    pci_models[fields[0]] = fields[2] + ' ' + fields[3]
            except ValueError:
                continue
    for line in (read_field(proc / 'meminfo') or '').splitlines():
        match = re.fullmatch(r'(MemAvailable|SwapTotal|SwapFree):\s+(\d+) kB', line)
        if match:
            out['memory'][match[1]] = int(match[2]) * 1024
    dmi = root / 'class/dmi/id'
    for key in ('sys_vendor', 'product_name', 'product_version', 'board_vendor', 'board_name', 'board_version', 'bios_vendor', 'bios_version', 'bios_date'):
        value = read_field(dmi / key)
        if useful(value):
            out['firmware'][key] = value
    out['microcode_version'] = read_field(root / 'devices/system/cpu/cpu0/microcode/version')
    for card in sorted((root / 'class/drm').glob('card*'))[:128]:
        if not re.fullmatch(r'card\d+', card.name):
            continue
        dev = card / 'device'
        item = {'name': card.name}
        try:
            pci_slot = dev.resolve().name
            if pci_slot in pci_models:
                item['model'] = pci_models[pci_slot]
        except OSError:
            pass
        for key in ('vendor', 'device', 'subsystem_vendor', 'subsystem_device', 'mem_info_vram_total', 'mem_info_vram_used'):
            value = read_field(dev / key)
            if value is not None:
                item[key] = value
        if (dev / 'driver').is_symlink():
            try:
                item['driver'] = (dev / 'driver').resolve().name
            except OSError:
                pass
        out['gpus'].append(item)
    for supply in sorted((root / 'class/power_supply').glob('*'))[:128]:
        # Exclude peripheral batteries (e.g. paired headphones) and identifiers.
        if read_field(supply / 'scope') == 'Device':
            continue
        item = {'name': supply.name}
        for key in ('type', 'status', 'capacity', 'health', 'technology', 'cycle_count', 'energy_full', 'energy_full_design', 'charge_full', 'charge_full_design', 'online'):
            value = read_field(supply / key)
            if value is not None:
                item[key] = value
        out['power'].append(item)
    return out


def platform_model(data):
    model = Model('hardware.platform')
    source = 'lscpu --json'
    cpu_fields = {'Architecture': ('architecture', False), 'Vendor ID': ('vendor', False),
                  'Model name': ('model', False), 'CPU(s)': ('logical_count', True),
                  'Socket(s)': ('socket_count', True), 'Core(s) per socket': ('cores_per_socket', True),
                  'Thread(s) per core': ('threads_per_core', True), 'NUMA node(s)': ('numa_node_count', True),
                  'Virtualization': ('virtualization_extension', False),
                  'L1d cache': ('l1d_cache', False), 'L1i cache': ('l1i_cache', False),
                  'L2 cache': ('l2_cache', False), 'L3 cache': ('l3_cache', False),
                  'Flags': ('instruction_features', False)}
    cpu = {}
    vulnerabilities = {}
    def visit(rows):
        for row in rows:
            if not isinstance(row, dict):
                continue
            key = str(row.get('field', '')).rstrip(':')
            if key.startswith('Vulnerability ') and useful(row.get('data')):
                vulnerabilities[key.removeprefix('Vulnerability ')] = str(row['data'])
            if key in cpu_fields and useful(row.get('data')):
                cpu[key] = row['data']
            if isinstance(row.get('children'), list):
                visit(row['children'])
    visit(data.get('cpu', []))
    if cpu:
        model.entity('cpu:local', 'cpu', str(cpu.get('Model name', 'CPU')), source)
        model.relation('host:local', 'has_cpu', 'cpu:local', source)
        for field, (key, numeric) in cpu_fields.items():
            value = cpu.get(field)
            if field == 'Flags':
                value = ','.join(sorted(set(str(value).split()) & {'vmx','svm','avx','avx2','avx512f','aes','sha_ni','neon','sse4_2'}))
            if numeric:
                value = int(value) if str(value).isdigit() else None
            model.attr('cpu:local', key, value, source)
    if useful(data.get('microcode_version')):
        model.fact('hardware.cpu.microcode_version', data['microcode_version'], '/sys/devices/system/cpu/cpu0/microcode/version')
    if cpu and vulnerabilities:
        unaffected = sorted(k for k,v in vulnerabilities.items() if v == 'Not affected')
        if unaffected:
            model.attr('cpu:local', 'vulnerabilities_not_affected', ','.join(unaffected), 'lscpu --json')
        for key,value in vulnerabilities.items():
            if value != 'Not affected':
                model.attr('cpu:local', 'vulnerability.' + key, value, 'lscpu --json')
    for key, value in data.get('firmware', {}).items():
        model.fact('hardware.firmware.' + key, value, '/sys/class/dmi/id')
    for gpu in data.get('gpus', []):
        id = 'gpu:' + gpu['name']
        source = '/sys/class/drm/' + gpu['name'] + '/device'
        model.entity(id, 'gpu', gpu.get('model', gpu['name']), 'lspci -Dmm -nn' if gpu.get('model') else source)
        model.relation('host:local', 'has_gpu', id, source)
        for key in ('vendor', 'device', 'subsystem_vendor', 'subsystem_device', 'driver'):
            model.attr(id, key, gpu.get(key), source)
        for key, attr in (('mem_info_vram_total', 'vram_total_bytes'), ('mem_info_vram_used', 'vram_used_bytes')):
            if str(gpu.get(key, '')).isdigit():
                model.attr(id, attr, int(gpu[key]), source)
    block_count = 0
    seen = set()
    def blocks(rows):
        nonlocal block_count
        for block in rows:
            if block_count >= 256:
                model.fact('hardware.storage.inventory_limited', True, 'lsblk --json')
                return
            if block.get('type') == 'disk' and block.get('kname') not in seen:
                name = block.get('kname')
                if not name:
                    continue
                seen.add(name)
                block_count += 1
                id = 'block:/dev/' + name
                src = 'lsblk --json --bytes (safe hardware fields)'
                model.entity(id, 'block_device', str(block.get('model') or name).strip(), src)
                model.relation('host:local', 'has_block_device', id, src)
                model.attr(id, 'path', '/dev/' + name, src)
                model.attr(id, 'transport', block.get('tran'), src)
                if str(block.get('size', '')).isdigit():
                    model.attr(id, 'size_bytes', int(block['size']), src)
                for key, attr in (('rota', 'rotational'), ('ro', 'read_only'), ('rm', 'removable')):
                    value = block.get(key)
                    if value in (True, False, 0, 1, '0', '1'):
                        model.attr(id, attr, value in (True, 1, '1'), src)
            if isinstance(block.get('children'), list):
                blocks(block['children'])
    blocks(data.get('blocks', []))
    for key, attr in (('MemAvailable', 'available_bytes'), ('SwapTotal', 'swap_total_bytes'), ('SwapFree', 'swap_free_bytes')):
        if key in data.get('memory', {}):
            model.fact('hardware.memory.' + attr, data['memory'][key], '/proc/meminfo')
    for supply in data.get('power', []):
        id = 'power-supply:' + supply['name']
        source = '/sys/class/power_supply/' + supply['name']
        model.entity(id, 'power_supply', supply['name'], source)
        model.relation('host:local', 'has_power_supply', id, source)
        for key in ('type', 'status', 'health', 'technology'):
            model.attr(id, key, supply.get(key), source)
        for key in ('capacity', 'cycle_count', 'energy_full', 'energy_full_design', 'charge_full', 'charge_full_design', 'online'):
            if str(supply.get(key, '')).isdigit():
                model.attr(id, key, int(supply[key]), source)
        for prefix in ('energy', 'charge'):
            full = supply.get(prefix + '_full', '')
            design = supply.get(prefix + '_full_design', '')
            if str(full).isdigit() and str(design).isdigit() and int(design) > 0:
                model.attr(id, 'full_capacity_percent_of_design', round(100 * int(full) / int(design), 1), source, observation_type='inferred')
                break
    return model


if __name__ == '__main__':
    mode, *args = sys.argv[1:]
    if mode == 'memory':
        path, status = args
        memory_model(Path(path).read_text(errors='replace') if path else '', status).save()
    elif mode == 'snapshot':
        print(json.dumps(snapshot(*args), separators=(',', ':')))
    elif mode == 'platform':
        platform_model(json.loads(Path(args[0]).read_text())).save()
    else:
        raise SystemExit('unknown hardware model mode')
