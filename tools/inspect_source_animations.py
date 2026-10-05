"""Inspect original launcher animation channels using the local TF2 VPK.

Run with Blender's Python, which also hosts the mesh conversion dependencies.
Only requested MDLs are decoded; the installed archives remain read-only.
"""
from pathlib import Path
import hashlib
import json
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'tools'),str(ROOT/'third_party')]
from extract_source_weapons import VPK
from SourceIO.library.models.mdl.structs.header import MdlHeaderV49
from SourceIO.library.models.mdl.structs.bone import Bone
from SourceIO.library.models.mdl.structs.local_animation import StudioAnimDesc
from SourceIO.library.models.mdl.structs.sequence import StudioSequence
from SourceIO.library.utils import MemoryBuffer

archive=VPK(Path('C:/Program Files (x86)/Steam/steamapps/common/Team Fortress 2/tf/tf2_misc_dir.vpk'))
paths=['models/weapons/c_models/c_demo_animations.mdl',
       'models/weapons/c_models/c_stickybomb_launcher/c_stickybomb_launcher.mdl',
       'models/weapons/c_models/c_stickybomb_launcher.mdl',
       'models/weapons/v_models/v_stickybomb_launcher_demo.mdl']
report={}
for path in paths:
    raw=archive.read(path)
    buffer=MemoryBuffer(raw)
    header=MdlHeaderV49.from_buffer(buffer)
    buffer.seek(header.bone_offset)
    bones=[Bone.from_buffer(buffer,header.version) for _ in range(header.bone_count)]
    for i,bone in enumerate(bones): bone.bone_id=i
    buffer.seek(header.local_animation_offset)
    animations=[StudioAnimDesc.from_buffer(buffer) for _ in range(header.local_animation_count)]
    buffer.seek(header.local_sequence_offset)
    sequences=[StudioSequence.from_buffer(buffer,header.version) for _ in range(header.local_sequence_count)]
    selected=[a for a in animations if a.name.startswith('@sb_') or 'sticky' in a.name.lower()
              or 'pipe' in a.name.lower() or 'reload' in a.name.lower()]
    channels={}
    for animation in selected:
        if animation.animblock_id: continue
        frames=animation.read_animations(buffer,bones)
        channels[animation.name]={name:dict(pos=values['pos'].tolist(),rot=values['rot'].tolist())
                                  for name,values in frames.items() if 'weapon' in name.lower()}
    report[path]=dict(archive=str(archive.path),sha256=hashlib.sha256(raw).hexdigest(),
                     bones=[bone.name for bone in bones],
                     bone_reference=[dict(name=bone.name,parent=bone.parent_id,pos=list(bone.position),
                                          rot=list(bone.quat)) for bone in bones],
                     animations=[dict(name=a.name,fps=a.fps,frames=a.frame_count,block=a.animblock_id,
                                      flags=int(a.flags)) for a in animations],
                     sequences=[dict(name=s.name,activity=s.activity_name,anims=s.anim_desc_indices) for s in sequences],
                     weapon_channels=channels)
output=ROOT/'build/source-weapons/animation-inspection.json'
output.write_text(json.dumps(report,indent=2))
print('SOURCE_ANIMATIONS_INSPECTED',json.dumps({p:dict(animations=len(v['animations']),selected=list(v['weapon_channels'])) for p,v in report.items()}))
