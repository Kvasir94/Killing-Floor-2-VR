"""Prepare reproducible Portal 2 material, animation and sound imports."""
from pathlib import Path
import json
import re
import struct

ROOT = Path(__file__).resolve().parents[1]
OUT, SOURCE = ROOT / 'build/portal', ROOT / 'extract/portal'

def ini(value):
    if isinstance(value, dict):
        return '(' + ','.join(f'{k}={ini(v)}' for k,v in value.items()) + ')'
    if isinstance(value,(list,tuple)):
        return '(' + ','.join(ini(v) for v in value) + ')'
    if isinstance(value,bool):
        return 'True' if value else 'False'
    if isinstance(value,str):
        if any(c in value for c in ('"','\n','\r')):
            raise ValueError('Unsafe config string')
        return '"' + value.replace('\\','/') + '"'
    return str(value)

def sound_entry(text, entry):
    # Top-level Source sound blocks contain nested operator stacks. Balance
    # braces so nested "volume" parameters cannot replace the entry volume.
    start = re.search(r'"'+re.escape(entry)+r'"\s*\{',text).end()
    depth, end = 1, start
    while depth:
        depth += (text[end]=='{') - (text[end]=='}')
        end += 1
    return text[start:end-1]

def animation_entries(name):
    data=(OUT/(name+'.psa')).read_bytes()
    chunks={};offset=0
    while offset<len(data):
        label,flags,size,count=struct.unpack_from('<20siii',data,offset);offset+=32
        chunks[label.split(b'\0')[0].decode()]=(size,count,data[offset:offset+size*count]);offset+=size*count
    bone_size,bone_count,bone_data=chunks['BONENAMES']
    bones=[bone_data[i*bone_size:i*bone_size+64].split(b'\0')[0].decode().replace('.','_') for i in range(bone_count)]
    entry_size,entry_count,entry_data=chunks['ANIMINFO']
    key_size,key_count,key_data=chunks['ANIMKEYS']
    results=[]
    for i in range(entry_count):
        info=entry_data[i*entry_size:(i+1)*entry_size]
        sequence=info[:64].split(b'\0')[0].decode()
        fps=struct.unpack_from('<f',info,152)[0]
        first,frames=struct.unpack_from('<ii',info,160)
        tracks=[]; compressed=bytearray(); offsets=[]
        for bone in range(bone_count):
            keys=[struct.unpack_from('<7f',key_data,((first+frame)*bone_count+bone)*key_size) for frame in range(frames)]
            # PSA is mirrored for the DCC convention. Unreal's native import
            # flips position Y and quaternion Y/W. The PSA exporter already
            # conjugated non-root bone rotations; preserve that convention.
            keys=[(x,-y,z,qx,-qy,qz,-qw) for x,y,z,qx,qy,qz,qw in keys]
            positions=[k[:3] for k in keys]; rotations=[k[3:] for k in keys]
            if all(p==positions[0] for p in positions): positions=positions[:1]
            if all(q==rotations[0] for q in rotations): rotations=rotations[:1]
            # UE3 AKF_ConstantKeyLerp: ACF_None FVector translations and
            # ACF_Float96NoW rotations (x,y,z of a unit quaternion with w>=0;
            # the decoder rebuilds w), four offset/count ints per track.
            # Rotations must not be ACF_None: KF2 reads FQuat keys with aligned
            # SSE loads from a 4-byte packed stream and faults on the first
            # pose (headset crash 2026-09-27, KFGame RVA 0x123652).
            # SDK AnimSequence.uc; UEViewer Unreal/UnrealMesh/UnAnim3.cpp.
            translation_offset=len(compressed)
            for p in positions: compressed.extend(struct.pack('<3f',*p))
            rotation_offset=len(compressed)
            for qx,qy,qz,qw in rotations:
                length=(qx*qx+qy*qy+qz*qz+qw*qw)**.5 or 1.0
                sign=-1.0 if qw<0 else 1.0
                compressed.extend(struct.pack('<3f',sign*qx/length,sign*qy/length,sign*qz/length))
            offsets.extend((translation_offset,len(positions),rotation_offset,len(rotations)))
            def values(samples,axes):
                return '('+','.join('('+','.join(axis+'='+format(v,'.9f') for axis,v in zip(axes,sample))+')' for sample in samples)+')'
            tracks.append('(PosKeys='+values(positions,'XYZ')+',RotKeys='+values(rotations,'XYZW')+')')
        results.append(dict(AssetName=name+'_Anims',SequenceName=sequence,TrackBoneNames=bones,
                            NumFrames=frames,SequenceLength=max(1,frames-1)/fps,RawData='('+','.join(tracks)+')',
                            TrackOffsets=offsets,CompressedData=list(compressed)))
    return results

def main():
    report = json.loads((OUT/'meshes.json').read_text())
    materials = [dict(AssetName=m['name'],TextureFile=m['diffuse'],NormalFile=m['normal'],
        bUnlit=False,bTranslucent=m['properties'].get('$translucent')=='1',
        bAdditive=m['properties'].get('$additive')=='1',bTwoSided=False,bSelfIllum=False,PhongPower=32)
        for m in report['materials']+report.get('world',{}).get('materials',[])]
    meshes = [dict(AssetName='PortalGun',MeshFile=str(OUT/'PortalGunAnimations.fbx'),
                   AnimationFile=str(OUT/'PortalGun.psa'),
                   MaterialNames=[m['name'] for m in report['materials']],bStatic=False,bAnimations=True),
              *[dict(AssetName=n,MeshFile=str(OUT/(n+'.fbx')),MaterialNames=[m],bStatic=True,bAnimations=False)
                for n,m in [('SM_PortalAperture','M_PortalSurface'),('SM_PortalRim','M_PortalRim')]]]
    if 'world' in report:
        meshes.append(dict(AssetName='PortalGunWorld',MeshFile=str(OUT/'PortalGunWorld.fbx'),
                            AnimationFile=str(OUT/'PortalGunWorld.psa'),
                            MaterialNames=[m['name'] for m in report['world']['materials']],bStatic=False,bAnimations=True))
    mapping = [('PortalFireBlue','Weapon_Portalgun.fire_blue'),('PortalFireOrange','Weapon_Portalgun.fire_red'),
               ('PortalOpenBlue','Portal.open_blue'),('PortalOpenOrange','Portal.open_red'),
               ('PortalEnter','PortalPlayer.EnterPortal'),('PortalExit','PortalPlayer.ExitPortal'),
               ('PortalInvalid','Portal.fizzle_invalid_surface'),('PortalClose','Portal.close_blue'),
               ('PortalCloseOrange','Portal.close_red'),('PortalHold','Weapon_Portalgun.HoldSound'),
               ('PortalPowerup','Weapon_Portalgun.powerup')]
    text = re.sub(r'//[^\n]*','',(SOURCE/'scripts/game_sounds_weapons_portal.txt').read_text())
    sounds, source_sounds = [], []
    for name,entry in mapping:
        block = sound_entry(text,entry)
        waves = re.findall(r'"wave"\s*"([^"\n]+)"',block)
        props = {k:re.search(r'"'+k+r'"\s*"([^"\n]+)"',block).group(1) for k in ('volume','pitch','soundlevel')}
        pitch = [float(x)/100 for x in props['pitch'].split(',')]
        for index,wave in enumerate(waves):
            file = SOURCE/'sound'/wave.lstrip('*#@^)(<>!')
            if not file.is_file():
                raise FileNotFoundError(file)
            sounds.append(dict(AssetName=name,WaveName=name+'Wave'+str(index),WaveFile=str(file),
                               Volume=float(props['volume']),PitchMin=pitch[0],PitchMax=pitch[-1],
                               bLoop=name=='PortalHold'))
        source_sounds.append(dict(name=name,source=entry,properties=props,waves=waves))
    sockets = [dict(MeshName='PortalGun',SocketName='MuzzleFlash',BoneName='VR_Muzzle')]
    if 'world' in report:
        sockets.append(dict(MeshName='PortalGunWorld',SocketName='MuzzleFlash',BoneName='VR_Muzzle'))
    lines = ['[PortalAssetTools.VRPortalAssetCommandlet]']
    animations=animation_entries('PortalGun')+animation_entries('PortalGunWorld')
    for key,entries in [('Materials',materials),('Meshes',meshes),('Sockets',sockets),('Sounds',sounds),('Animations',animations)]:
        lines.extend(key+'='+ini(entry) for entry in entries)
    (OUT/'assets.ini').write_text('\n'.join(lines)+'\n')
    summary = dict(meshes=len(meshes),materials=len(materials)+2,cues=len(mapping),waves=len(sounds),
                   source_sounds=source_sounds,parity_pending=report['limitations']+[
                       'Portal 2 PCF particle effect operator graphs are extracted but not converted',
                       'Source sound operator stacks, attenuation, occlusion and entry limiting differ',
                       'Screen-position portal scene capture and animation playback require in-game validation'])
    (OUT/'conversion-report.json').write_text(json.dumps(summary,indent=2))
    print(json.dumps({k:summary[k] for k in ('meshes','materials','cues','waves')}))

if __name__ == '__main__':
    main()
