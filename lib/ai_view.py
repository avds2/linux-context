#!/usr/bin/env python3
"""Lossless dictionary-coded AI view of the canonical compact host model.

Hardware inventories repeat attribute keys/types/predicates. Intern these names
without omitting any facts, provenance, coverage or routing information. Existing
context.json consumers remain compatible; decode() restores the exact document.
"""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path


def encode(context):
    doc = copy.deepcopy(context)
    # Deferred graphs keep their existing retrieval route; don't chase sidecars.
    entities = doc.get('entities', [])
    relations = doc.get('relations', [])
    types = sorted({e[1] for e in entities})
    keys = sorted({k for e in entities for k in e[3]})
    predicates = sorted({r[1] for r in relations})
    ti, ki, pi = ({v:i for i,v in enumerate(values)} for values in (types,keys,predicates))
    templates = {}
    for typ in types:
        group = [e for e in entities if e[1] == typ]
        if len(group) < 2:
            continue
        shared = {key:value for key,value in group[0][3].items()
                  if all(key in e[3] and e[3][key] == value for e in group[1:])}
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


def decode(view):
    doc = copy.deepcopy(view)
    if 'encoding' not in doc:
        return doc
    encoding = doc.pop('encoding')
    if encoding.get('name') != 'linux-context-ai' or encoding.get('version') != 1:
        raise ValueError('unsupported AI view encoding')
    for entity in doc.get('entities', []):
        pairs = encoding.get('type_attributes', {}).get(str(entity[1]), []) + entity[3]
        entity[1] = encoding['entity_types'][entity[1]]
        entity[3] = {encoding['attribute_keys'][key]: value for key,value in pairs}
    for relation in doc.get('relations', []):
        relation[1] = encoding['relation_predicates'][relation[1]]
    return doc


def compact(doc):
    return json.dumps(doc,ensure_ascii=False,separators=(',', ':'),allow_nan=False)+'\n'


if __name__ == '__main__':
    mode, source, dest = sys.argv[1:]
    data=json.loads(Path(source).read_text(encoding='utf-8'))
    if mode == 'encode':
        result=encode(data)
        if decode(result) != data:
            raise ValueError('AI view failed lossless round-trip validation')
        # Sparse contexts can cost more to dictionary-code. In that case keep
        # the canonical encoding, so this entrypoint never grows the byte budget.
        if len(compact(result).encode('utf-8')) >= len(Path(source).read_bytes()):
            Path(dest).write_bytes(Path(source).read_bytes())
            raise SystemExit(0)
    elif mode == 'decode':
        result=decode(data)
    else:
        raise SystemExit('expected encode or decode')
    Path(dest).write_text(compact(result),encoding='utf-8')
