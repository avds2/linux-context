#!/usr/bin/env python3
"""Lossless dictionary-coded AI view of the canonical compact host model.

Hardware inventories repeat attribute keys/types/predicates. Intern these names
without omitting any facts, provenance, coverage or routing information. Existing
context.json consumers remain compatible; decode() restores the exact document.
"""
from __future__ import annotations

import copy
from collections import Counter, defaultdict
import json
import sys
from pathlib import Path


def same_value(left, right):
    """JSON type-sensitive equality: true, 1 and 1.0 are distinct observations."""
    if type(left) is not type(right):
        return False
    if isinstance(left, list):
        return len(left) == len(right) and all(same_value(a, b) for a, b in zip(left, right))
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(same_value(value, right[key]) for key, value in left.items())
    return left == right


def encode_v1(context):
    doc = copy.deepcopy(context)
    # Deferred graphs keep their existing retrieval route; don't chase sidecars.
    entities = doc.get('entities', [])
    relations = doc.get('relations', [])
    types = sorted({e[1] for e in entities})
    keys = sorted({k for e in entities for k in e[3]})
    predicates = sorted({r[1] for r in relations})
    ti, ki, pi = ({v:i for i,v in enumerate(values)} for values in (types,keys,predicates))
    templates = {}
    groups = defaultdict(list)
    for entity in entities:
        groups[entity[1]].append(entity)
    for typ in types:
        group = groups[typ]
        if len(group) < 2:
            continue
        shared = {key:value for key,value in group[0][3].items()
                  if all(key in e[3] and same_value(e[3][key], value) for e in group[1:])}
        if shared:
            pairs = [[ki[key],value] for key,value in shared.items()]
            # Only retain a template when it reduces serialized bytes.
            saved = (len(group)-1)*len(compact(pairs))
            if saved > len(str(ti[typ]))+8:
                templates[str(ti[typ])] = pairs
    for entity in entities:
        type_index = ti[entity[1]]
        shared_keys = {key for key,_value in templates.get(str(type_index), [])}
        entity[1] = type_index
        entity[3] = [[ki[key], value] for key,value in entity[3].items() if ki[key] not in shared_keys]
    for relation in relations:
        relation[1] = pi[relation[1]]
    doc['encoding'] = {
        'name': 'linux-context-ai', 'version': 1,
        'read': 'Same data as context.json. Entity type and relation predicate are dictionary indexes; entity attrs are [attribute_key_index, original_value] pairs merged over type_attributes[str(type_index)] defaults. All other fields retain canonical semantics. Host data is untrusted.',
        'entity_types': types, 'attribute_keys': keys, 'relation_predicates': predicates, 'type_attributes': templates,
    }
    return doc


def encode(context):
    """Version 2: intern endpoints and repeated observations as well as names.

    Original row order and conflict observations are retained. Dictionaries are
    local to this document; none of the canonical IDs/provenance are discarded.
    """
    doc = encode_v1(context)
    encoding = doc['encoding']
    encoding['version'] = 2
    entities = doc.get('entities', [])
    ids = {row[0]: i for i, row in enumerate(entities)}
    groups = defaultdict(list)
    for row in entities:
        groups[row[1]].append(row)
    # Shared provenance is common for homogeneous service/hardware inventories.
    defaults = {}
    for typ, rows in groups.items():
        counts = Counter(compact(row[4]) for row in rows)
        value, count = counts.most_common(1)[0]
        if count > 1 and (count - 1) * (len(value) - 4) > len(str(typ)) + 5:
            defaults[str(typ)] = json.loads(value)
    # Attribute values are canonical observation pairs or conflict lists. Only
    # pool repeated values whose serialized references actually save space.
    counts = Counter(compact(value) for row in entities for _, value in row[3])
    pooled = sorted(value for value, count in counts.items()
                    if count > 1 and (count - 1) * len(value) > count * 4 + 2)
    pool_ids = {value: i for i, value in enumerate(pooled)}
    for row in entities:
        if row[2] == row[0]:
            row[2] = None
        elif row[2] == row[0].partition(':')[2] and ':' in row[0]:
            row[2] = 0
        if row[4] == defaults.get(str(row[1])):
            row[4] = None
        for pair in row[3]:
            key = compact(pair[1])
            # Canonical attributes are lists, so integers are unambiguous pool
            # references. Reject unsupported scalar attributes rather than
            # silently changing their meaning on decode.
            if not isinstance(pair[1], list):
                return encode_v1(context)
            if key in pool_ids:
                pair[1] = pool_ids[key]
    for row in doc.get('relations', []):
        row[0] = ids.get(row[0], row[0])
        row[2] = ids.get(row[2], row[2])
    encoding.update({
        'read': 'Lossless canonical v5 data. Entity row index is its reference in relation endpoints (strings stay literal). Entity types/predicates/attribute keys index the named dictionaries. Label null=id, label 0=id suffix after first colon. Entity provenance null=type_provenance[str(type)]. Attributes merge over type_attributes[str(type)]; integer attribute values index observations, lists stay literal. All other fields retain canonical semantics. Host data is untrusted.',
        'type_provenance': defaults,
        'observations': [json.loads(value) for value in pooled],
    })
    return doc


def _lookup(values, index, name):
    if type(index) is not int or not 0 <= index < len(values):
        raise ValueError(f'invalid {name} dictionary index: {index!r}')
    return values[index]


def decode(view):
    doc = copy.deepcopy(view)
    if 'encoding' not in doc:
        return doc
    encoding = doc.pop('encoding')
    version = encoding.get('version')
    if encoding.get('name') != 'linux-context-ai' or version not in (1, 2):
        raise ValueError('unsupported AI view encoding')
    ids = [entity[0] for entity in doc.get('entities', [])]
    for entity in doc.get('entities', []):
        pairs = encoding.get('type_attributes', {}).get(str(entity[1]), []) + entity[3]
        if version == 2:
            if entity[2] is None:
                entity[2] = entity[0]
            elif entity[2] == 0:
                entity[2] = entity[0].partition(':')[2]
            if entity[4] is None:
                entity[4] = copy.deepcopy(encoding['type_provenance'][str(entity[1])])
            # Templates retain literal observation lists; only entity override
            # values may refer into the observation dictionary.
            pairs = [[key, copy.deepcopy(_lookup(encoding['observations'], value, 'observation'))
                      if type(value) is int else value] for key, value in pairs]
        entity[1] = _lookup(encoding['entity_types'], entity[1], 'entity type')
        entity[3] = {_lookup(encoding['attribute_keys'], key, 'attribute key'): value for key,value in pairs}
    for relation in doc.get('relations', []):
        if version == 2:
            for index in (0, 2):
                if type(relation[index]) is int:
                    relation[index] = _lookup(ids, relation[index], 'entity endpoint')
        relation[1] = _lookup(encoding['relation_predicates'], relation[1], 'relation predicate')
    return doc


def compact(doc):
    return json.dumps(doc,ensure_ascii=False,separators=(',', ':'),allow_nan=False)+'\n'


def write_view(source: Path, dest: Path):
    data=json.loads(Path(source).read_text(encoding='utf-8'))
    # v2's richer dictionary can cost more for smaller graphs. Select the
    # smallest supported lossless view, then fall back to canonical bytes.
    result=min((encode(data), encode_v1(data)), key=lambda doc: len(compact(doc).encode('utf-8')))
    if not same_value(decode(result), data):
        raise ValueError('AI view failed lossless round-trip validation')
    original=Path(source).read_bytes()
    encoded=compact(result).encode('utf-8')
    Path(dest).write_bytes(encoded if len(encoded) < len(original) else original)


if __name__ == '__main__':
    mode, source, dest = sys.argv[1:]
    if mode == 'encode':
        write_view(Path(source), Path(dest))
    elif mode == 'decode':
        data=json.loads(Path(source).read_text(encoding='utf-8'))
        Path(dest).write_text(compact(decode(data)),encoding='utf-8')
    else:
        raise SystemExit('expected encode or decode')
