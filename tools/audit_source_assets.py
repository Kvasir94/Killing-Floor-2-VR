"""Inspect the actual saved optional package before accepting it for deployment.

No game/editor launch. Checks package dependencies, native asset classes,
material graphs, particle LODs/modules, sound graphs, and attachment names.
"""
from pathlib import Path
import argparse
import collections
import json
import re
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ue3.upkg import Reader, read_header


def read_package(path):
    info, names, imports, _ = read_header(str(path))
    data = path.read_bytes()
    r = Reader(data)
    r.p = info['export_offset']
    objects = []
    for _ in range(info['export_count']):
        cls, parent, outer = r.i32(), r.i32(), r.i32()
        name, archetype, flags = r.fname(names), r.i32(), r.u64()
        size, offset = r.i32(), r.i32()
        r.u32()
        r.raw(r.i32() * 4)
        r.raw(16)
        r.u32()
        assert 0 <= offset <= len(data) and 0 <= size <= len(data)-offset, (name, offset, size)
        objects.append(dict(name=name, cls=imports[-cls-1]['name'] if cls<0 else '',
                            outer=outer, archetype=archetype, flags=flags, size=size, offset=offset))
    assert r.p <= info['header_size'], 'Export table extends beyond header'
    return data, names, imports, objects


def properties(data, names):
    r, result = Reader(data), {}
    while True:
        name = r.fname(names)
        if name == 'None':
            return result, r.p
        kind, size, index = r.fname(names), r.i32(), r.i32()
        extra = None
        if kind in ('StructProperty', 'ByteProperty'):
            extra = r.fname(names)
        elif kind == 'BoolProperty':
            extra = r.raw(1) != b'\0'
        assert 0 <= size <= len(data)-r.p, (name, kind, size)
        result[name] = dict(kind=kind, extra=extra, value=r.raw(size), index=index)


def vorbis_audio(payload):
    """Validate the PC playback container, including its final granule count."""
    pos, sequence, stream, packets, pending, last_granule = 0, 0, None, [], bytearray(), 0
    ended = False
    while pos < len(payload):
        assert pos + 27 <= len(payload) and payload[pos:pos+4] == b'OggS', 'Missing/truncated PC Ogg page'
        assert payload[pos+4] == 0 and not ended, 'Invalid Ogg version or data after EOS'
        flags = payload[pos+5]
        granule, serial, page = struct.unpack_from('<QII', payload, pos+6)
        if stream is None:
            stream = serial
            assert flags & 2, 'PC audio has no beginning-of-stream page'
        assert serial == stream and page == sequence, 'Discontinuous PC Ogg stream'
        sequence += 1
        segments = payload[pos+26]
        start = pos + 27 + segments
        assert start <= len(payload), 'Truncated Ogg lacing table'
        sizes = payload[pos+27:start]
        end = start + sum(sizes)
        assert end <= len(payload), 'Truncated PC audio packet'
        cursor = start
        for size in sizes:
            pending.extend(payload[cursor:cursor+size]); cursor += size
            if size < 255:
                if len(packets) < 3: packets.append(bytes(pending))
                pending.clear()
        if granule != 0xffffffffffffffff: last_granule = granule
        ended = bool(flags & 4)
        pos = end
    assert ended and not pending and last_granule > 0, 'PC audio has no complete playable ending'
    assert len(packets) >= 3 and all(p.startswith(bytes([kind])+b'vorbis') for p, kind in zip(packets, (1,3,5))), 'Missing Vorbis headers'
    identification = packets[0]
    assert len(identification) >= 30, 'Truncated Vorbis identification'
    version, channels, rate = struct.unpack_from('<IBI', identification, 7)
    assert version == 0 and channels in (1,2) and 8000 <= rate <= 192000, 'Unsupported PC audio format'
    return dict(pc_bytes=len(payload), channels=channels, sample_rate=rate, seconds=last_granule/rate)


def sound_wave_payload(data, names, obj):
    f, tagged = properties(data[obj['offset']+4:obj['offset']+obj['size']], names)
    cursor, limit, blobs = obj['offset'] + 4 + tagged, obj['offset'] + obj['size'], []
    # The pinned SDK serializes RawData then CompressedPCData. Both must be
    # inline and uncompressed at the package layer for this importer.
    for label in ('RawData', 'CompressedPCData'):
        assert cursor + 16 <= limit, f"{obj['name']}: missing {label} bulk header"
        flags, count, size, offset = struct.unpack_from('<4i', data, cursor)
        cursor += 16
        assert flags == 0 and count == size and size >= 0 and offset == cursor, f"{obj['name']}: invalid {label} bulk layout"
        assert cursor + size <= limit, f"{obj['name']}: {label} extends beyond export"
        blobs.append(data[cursor:cursor+size]); cursor += size
    assert blobs[0].startswith(b'RIFF'), f"{obj['name']}: missing imported WAV source"
    assert blobs[1], f"{obj['name']}: no CompressedPCData (editor WAV alone is silent in KFGame)"
    result = vorbis_audio(blobs[1])
    duration = struct.unpack('<f', f['Duration']['value'])[0]
    assert abs(result['seconds']-duration) < 0.05, f"{obj['name']}: playback duration differs from source"
    return result


def audit(path, config):
    data, names, imports, objects = read_package(path)
    dependencies = sorted(i['name'] for i in imports if i['cls']=='Package' and i['outer']==0)
    assert set(dependencies) <= {'Core', 'Engine'}, f'Unexpected runtime dependencies: {dependencies}'
    counts = collections.Counter(o['cls'] for o in objects)
    root = {o['name']:o for o in objects if o['outer']==0}
    text = config.read_text()

    def fields(obj):
        return properties(data[obj['offset']+4:obj['offset']+obj['size']], names)[0]

    def require(name, kind):
        assert name in root, f'Missing root asset {name}'
        assert root[name]['cls']==kind, (name, root[name]['cls'], kind)
        return root[name]

    def refs(field):
        r=Reader(field['value'])
        result=[r.i32() for _ in range(r.i32())]
        assert r.p==len(field['value'])
        assert all(0 < i <= len(objects) for i in result)
        return [objects[i-1] for i in result]

    for name,kind in [('SuperGravityGun','SkeletalMesh'),('StickybombLauncher','SkeletalMesh'),
                      ('Stickybomb','StaticMesh'),('GravityIcon','Texture2D'),('StickyIcon','Texture2D')]:
        require(name,kind)
    for name in re.findall(r'^Materials=\(AssetName="([^"]+)"',text,re.M):
        obj=require(name,'Material')
        f=fields(obj)
        assert 'Expressions' in f and refs(f['Expressions']), f'Material graph missing: {name}'
        # UE3 serializes the native class default archetype as package index 0.
        # A nonzero archetype must resolve explicitly to Engine's Material CDO.
        archetype=obj['archetype']
        native_default=archetype==0
        if archetype<0:
            imported=imports[-archetype-1]
            native_default=(imported['name']=='Default__Material' and imported['outer']<0
                            and imports[-imported['outer']-1]['name']=='Engine')
        assert native_default, f'Editor template leaked: {name}'
    systems=collections.Counter(re.findall(r'^Emitters=\(SystemName="([^"]+)"',text,re.M))
    for name,count in systems.items():
        obj=require(name,'ParticleSystem')
        emitters=refs(fields(obj)['Emitters'])
        assert len(emitters)==count, (name,len(emitters),count)
        for emitter in emitters:
            assert emitter['cls']=='ParticleSpriteEmitter'
            levels=refs(fields(emitter)['LODLevels'])
            assert len(levels)==1
            f=fields(levels[0])
            assert struct.unpack('<i',f['RequiredModule']['value'])[0]>0
            assert struct.unpack('<i',f['SpawnModule']['value'])[0]>0
            assert len(refs(f['Modules']))>=5
    sound_report = {}
    for name in re.findall(r'^Sounds=\(AssetName="([^"]+)"',text,re.M):
        cue=require(name,'SoundCue')
        wave=require(name+'Wave','SoundNodeWave')
        assert struct.unpack('<i',fields(cue)['FirstNode']['value'])[0]>0
        sound_report[name] = sound_wave_payload(data, names, wave)
    animations = re.findall(r'^Animations=\(TakeName="([^"]+)",Frames=(\d+),FPS=([\d.]+)\)', text, re.M)
    animation_report = {}
    if animations:
        aset = fields(require('StickybombLauncher_Anims', 'AnimSet'))
        assert struct.unpack_from('<i', aset['TrackBoneNames']['value'])[0] == 73
        assert aset['bAnimRotationOnly']['extra'] is False, 'Mechanism translation tracks must remain enabled'
        sequences = refs(aset['Sequences'])
        assert len(sequences) == len(animations) == 7
        expected = {name: (int(frames), float(fps)) for name,frames,fps in animations}
        for obj in sequences:
            assert obj['cls'] == 'AnimSequence'
            f = fields(obj)
            name = Reader(f['SequenceName']['value']).fname(names)
            assert name in expected and name not in animation_report, f'Unexpected/duplicate animation {name}'
            count, fps = expected[name]
            frames = struct.unpack('<i', f['NumFrames']['value'])[0]
            duration = struct.unpack('<f', f['SequenceLength']['value'])[0]
            assert frames == count and abs(duration - (count-1)/fps) < 0.00001
            assert struct.unpack_from('<i', f['CompressedTrackOffsets']['value'])[0] > 0
            animation_report[name] = dict(frames=frames, seconds=duration)
    for bone in ['VR_PrimaryGrip','VR_SupportGrip','VR_Muzzle'] + [f'VR_fork{i}{s}' for i in (1,2,3) for s in 'bmt'] + [f'VR_ClawClosed_{c}' for c in 'ABC']:
        assert bone in names, f'Missing weapon attachment/bone {bone}'
    report=dict(package=str(path.resolve()),dependencies=dependencies,exports=len(objects),
                classes=dict(counts),systems=dict(systems),sounds=sound_report,animations=animation_report,passed=True)
    path.with_suffix('.audit.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package',type=Path)
    parser.add_argument('--config',type=Path,default=Path(__file__).resolve().parents[1]/'build/source-weapons/assets.ini')
    args=parser.parse_args()
    audit(args.package,args.config)
