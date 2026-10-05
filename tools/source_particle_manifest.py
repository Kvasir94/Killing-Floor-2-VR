"""Extract the exact TF2 particle trees and their material dependencies locally."""
from pathlib import Path
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'third_party'))
from SourceIO.library.utils import datamodel
from extract_source_weapons import VPK

source = ROOT / 'extract/source-weapons/sticky'
extraction = json.loads((source / 'manifest.json').read_text())
index = {}
for path in Path(extraction['source_root']).glob('*_dir.vpk'):
    if 'sound_vo' not in path.name:
        archive = VPK(path)
        index.update({name: archive for name in archive.entries})

roots = {'StickyExplosionAir': ('explosion.pcf', 'ExplosionCore_MidAir'),
         'StickyExplosionWall': ('explosion.pcf', 'ExplosionCore_Wall'),
         'StickyTrail': ('stickybomb.pcf', 'stickybombtrail_red'),
         'StickyArm': ('stickybomb.pcf', 'stickybomb_pulse_red'),
         'StickyMuzzle': ('muzzle_flash.pcf', 'muzzle_pipelauncher')}
materials = set()
result = {}

def convert(element):
    obj = {'name': element.name}
    for key, value in element.items():
        if key == 'children':
            obj[key] = [{'delay': c.get('delay', 0), 'child': convert(c['child'])} for c in value if c.get('child')]
        elif key in ('renderers', 'operators', 'initializers', 'emitters', 'forces', 'constraints'):
            obj[key] = [dict(v) for v in value]
        else:
            obj[key] = value
    if obj.get('material') and obj.get('renderers'):
        materials.add('materials/' + obj['material'].replace('\\', '/').lower())
    return obj

for name, (file, effect) in roots.items():
    pcf_path = source / 'particles' / file
    if not pcf_path.exists():
        key = 'particles/' + file
        data = index[key].read(key)
        pcf_path.write_bytes(data)
        extraction['files'][key] = {'sha256': hashlib.sha256(data).hexdigest(), 'archive': str(index[key].path)}
    dm = datamodel.load(path=str(source / 'particles' / file))
    definitions = {e.name.lower(): e for e in dm.elements if e.type == 'DmeParticleSystemDefinition'}
    if effect.lower() not in definitions:
        print(name, 'available:', ', '.join(definitions))
        continue
    result[name] = convert(definitions[effect.lower()])

while materials:
    name = materials.pop()
    if name in extraction['files']:
        continue
    if name not in index:
        raise ValueError(f'Missing particle dependency: {name}')
    data = index[name].read(name)
    path = source / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    extraction['files'][name] = {'sha256': hashlib.sha256(data).hexdigest(), 'archive': str(index[name].path)}
    if name.endswith('.vmt'):
        for token in re.findall(r'"([^"\r\n]+)"', data.decode('utf-8', errors='replace')):
            for suffix in ('.vtf', '.vmt'):
                dependency = 'materials/' + token.lower().replace('\\', '/').removesuffix('.vmt').removesuffix('.vtf') + suffix
                if dependency in index and dependency not in extraction['files']:
                    materials.add(dependency)
(source / 'manifest.json').write_text(json.dumps(extraction, indent=2))
out = ROOT / 'build/source-weapons/particles.json'
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(result, indent=2, default=list))

def flatten(e):
    yield e
    for child in e.get('children', []):
        yield from flatten(child['child'])

for name, tree in result.items():
    print(name, [(e['name'], e.get('material'), [i['functionName'] for i in e['emitters']]) for e in flatten(tree) if e.get('renderers')])
