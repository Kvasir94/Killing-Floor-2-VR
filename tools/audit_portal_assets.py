"""Audit the actual saved Portal package, including native asset references."""
from pathlib import Path
import argparse
import collections
import json
import re
import struct

from audit_source_assets import read_package, properties
from ue3.upkg import Reader

def audit(path, config):
    data,names,imports,objects = read_package(path)
    dependencies = sorted(i['name'] for i in imports if i['cls']=='Package' and i['outer']==0)
    assert set(dependencies) <= {'Core','Engine','EngineMaterials'}, f'Editor/external dependency: {dependencies}'
    for entry in imports:
        if entry['outer'] < 0 and imports[-entry['outer']-1]['name']=='EngineMaterials':
            assert entry['name']=='DefaultMaterial', f'Unexpected engine art dependency: {entry}'
    root = {o['name']:o for o in objects if o['outer']==0}
    def require(name,kind):
        assert name in root and root[name]['cls']==kind, f'Missing {kind} {name}'
        return root[name]
    def fields(obj):
        return properties(data[obj['offset']+4:obj['offset']+obj['size']],names)[0]
    def refs(field):
        reader=Reader(field['value'])
        values=[reader.i32() for _ in range(reader.i32())]
        assert reader.p==len(field['value']) and all(0<i<=len(objects) for i in values), 'Null or invalid asset graph reference'
        return [objects[i-1] for i in values]
    for name,kind in [('PortalGun','SkeletalMesh'),('PortalGunWorld','SkeletalMesh'),
                      ('SM_PortalAperture','StaticMesh'),('SM_PortalRim','StaticMesh')]:
        require(name,kind)
    for name in ['VR_PrimaryGrip','VR_SupportGrip','VR_Muzzle','MuzzleFlash']:
        assert name in names, f'Missing attachment {name}'
    text=config.read_text()
    materials=re.findall(r'^Materials=\(AssetName="([^"]+)"',text,re.M)+['M_PortalSurface','M_PortalRim']
    for name in materials:
        obj=require(name,'Material'); f=fields(obj)
        assert refs(f['Expressions']), f'Empty material {name}'
        assert obj['archetype']==0 or (obj['archetype']<0 and imports[-obj['archetype']-1]['name']=='Default__Material'), name
    assert all(n in names for n in ('CaptureTexture','Linked','PortalColor')), 'Missing portal material parameters'
    cue_counts=collections.Counter(re.findall(r'^Sounds=\(AssetName="([^"]+)"',text,re.M))
    for name,count in cue_counts.items():
        cue=require(name,'SoundCue'); f=fields(cue)
        assert struct.unpack('<i',f['FirstNode']['value'])[0]>0, f'Empty sound {name}'
        index=objects.index(cue)+1
        random=next(o for o in objects if o['outer']==index and o['cls']=='SoundNodeRandom')
        assert len(refs(fields(random)['ChildNodes']))==count, f'Lost randomized waves {name}'
    for obj in objects:
        if obj['cls'] in ('SoundNodeModulator','SoundNodeAttenuation','SoundNodeLooping'):
            assert refs(fields(obj)['ChildNodes']), obj['name']
    animsets=[o['name'] for o in objects if o['cls']=='AnimSet']
    sequences=[]
    for obj in objects:
        if obj['cls']=='AnimSequence':
            f=fields(obj)
            sequences.append(Reader(f['SequenceName']['value']).fname(names) if 'SequenceName' in f else obj['name'])
            body=data[obj['offset']+4:obj['offset']+obj['size']]
            _,position=properties(body,names)
            raw=Reader(body); raw.p=position
            track_count=raw.i32()
            for _ in range(track_count):
                for expected_size in (12,16):
                    size,count=raw.i32(),raw.i32()
                    assert size==expected_size and count>0, f'Invalid raw animation {obj["name"]}'
                    raw.raw(size*count)
            stream_size=raw.i32()
            assert stream_size>0 and raw.p+stream_size==len(body), f'Empty/invalid runtime animation {obj["name"]}'
            # ACF_None (the default, so unsaved) rotations crash KF2's decoder.
            assert 'RotationCompressionFormat' in f, f'ACF_None rotations in {obj["name"]}'
            offsets=Reader(f['CompressedTrackOffsets']['value'])
            assert offsets.i32()==track_count*4, f'Incomplete animation bone tracks {obj["name"]}'
            for _ in range(track_count):
                translation,translation_count,rotation,rotation_count=[offsets.i32() for _ in range(4)]
                # ACF_None translations (12 bytes) and ACF_Float96NoW rotations
                # (12 bytes): KF2 cannot decode ACF_None rotations (aligned SSE).
                assert translation%4==rotation%4==0 and translation_count>0 and rotation_count>0
                assert 0<=translation<translation+translation_count*12<=stream_size
                assert 0<=rotation<rotation+rotation_count*12<=stream_size
    assert len(sequences)==15, f'Expected 14 original takes plus rigid VR reference idle: {sequences}'
    report=dict(package=str(path.resolve()),dependencies=dependencies,exports=len(objects),materials=materials,
                cues=dict(cue_counts),animsets=animsets,sequences=sequences,passed=True)
    path.with_suffix('.audit.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package',type=Path)
    parser.add_argument('--config',type=Path,default=Path(__file__).resolve().parents[1]/'build/portal/assets.ini')
    args=parser.parse_args()
    audit(args.package,args.config)
