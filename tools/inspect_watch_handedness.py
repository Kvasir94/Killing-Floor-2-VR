"""Audit source/FBX hand frames and show the whole authoring hand."""
import bpy,json,runpy
import numpy as np
from pathlib import Path
from mathutils import Vector,Matrix
ROOT=Path(__file__).resolve().parents[1]
out=Path(bpy.data.filepath).parent;source=bpy.context.scene
g=runpy.run_path(str(ROOT/'tools/generate_floating_hands.py'),run_name='hand_source')
chunks=g['read_psk'](ROOT/'extract/arms-audit/CHR_1P_Arms_MESH/SkeletalMesh3/Wep_1stP_Naked_Hands_Rig.psk')
bones,names=g['bone_data'](chunks);bind=g['bind_positions'](bones)
def axes(points,side):
    wrist=points[side+'Hand_1stP']
    f=(points[side+'HandMiddle1_1stP']-wrist).normalized()
    t=points[side+'HandIndex1_1stP']-points[side+'HandPinky1_1stP'];t=(t-f*t.dot(f)).normalized()
    a=(points[side+'HandMiddle2_1stP']-points[side+'HandMiddle1_1stP']).normalized()
    b=(points[side+'HandMiddle3_1stP']-points[side+'HandMiddle2_1stP']).normalized()
    curl=(b-a*b.dot(a)).normalized();cross=f.cross(t).normalized()
    palm=cross if cross.dot(curl)>0 else -cross
    return f,t,-palm,cross.dot(curl)
raw=dict(zip(names,bind));f,t,d,curl=axes(raw,'Left')
authored_d=-f.cross(t).normalized();frame=Matrix((f,-t if source.get('authoring_handedness','').startswith('left;') else t,authored_d))
report={'authoring_frame_determinant':frame.determinant(),
        'source_dorsal_dot_finger_inferred_dorsal':authored_d.dot(d),
        'source_raw_left_curl_dot_forward_cross_thumb':curl,
        'canonical_thumb_direction':list(frame@t)}
skin=next(o for o in source.objects if o.name.startswith('LEFT | anatomical'))
def weighted_center(finger):
    ids={v.index for v in skin.vertex_groups if 'Hand'+finger in v.name}
    total=0;center=Vector()
    for v in skin.data.vertices:
        weight=sum(a.weight for a in v.groups if a.group in ids)
        center+=(skin.matrix_world@v.co)*weight;total+=weight
    return center/total
report['geometry_thumb_minus_middle_y_cm']=weighted_center('Thumb').y-weighted_center('Middle').y
if source.get('authoring_handedness','').startswith('left;'):
    assert report['geometry_thumb_minus_middle_y_cm']< -1,report
s=bpy.data.scenes.new('Handedness FBX audit');bpy.context.window.scene=s
bpy.ops.import_scene.fbx(filepath=str(ROOT/'build/watch-detail-20260924/baseline-26/runtime/VRFloatingHands.fbx'))
rig=next(o for o in s.objects if o.type=='ARMATURE')
actual={b.name:rig.matrix_world@b.head_local for b in rig.data.bones}
for side in ['Left','Right']:
    f,t,d,curl=axes(actual,side)
    report[side+'_fbx']={'curl_dot_forward_cross_thumb':curl,
                         'dorsal_dot_forward_cross_thumb':d.dot(f.cross(t)),
                         'inspection_frame_determinant':Matrix((f,d.cross(f),d)).determinant()}
A=np.array([[*raw[n],1] for n in names]);B=np.array([list(actual[n]) for n in names])
mapping=np.linalg.lstsq(A,B,rcond=None)[0]
report['raw_psk_to_fbx_bone_frame_determinant']=float(np.linalg.det(mapping[:3]))
report['raw_psk_to_fbx_bone_frame_residual_cm']=float(np.max(np.linalg.norm(A@mapping-B,axis=1)))
sdk_path=out/'imported-sdk/KF2VRHands/SkeletalMesh3/VRFloatingHands.psk'
if sdk_path.exists():
    cb=g['read_psk'](sdk_path);bb,nn=g['bone_data'](cb);pp=g['bind_positions'](bb);sdk=dict(zip(nn,pp))
    B=np.array([list(sdk[n]) for n in names]);mapping=np.linalg.lstsq(A,B,rcond=None)[0]
    report['raw_psk_to_sdk_bone_frame_determinant']=float(np.linalg.det(mapping[:3]))
    report['raw_psk_to_sdk_bone_frame_residual_cm']=float(np.max(np.linalg.norm(A@mapping-B,axis=1)))
    report['raw_psk_to_sdk_mapping']=mapping.tolist()
    for side in ['Left','Right']:
        f,t,d,curl=axes(sdk,side);report[side+'_sdk_curl_dot_forward_cross_thumb']=curl
(out/'handedness-audit.json').write_text(json.dumps(report,indent=2));print('HANDEDNESS',json.dumps(report),flush=True)
bpy.context.window.scene=source
source.cycles.samples=32;source.camera.location=(1.5,0,45)
source.camera.rotation_euler=(Vector((1.5,0,0))-source.camera.location).to_track_quat('-Z','Y').to_euler()
source.camera.data.ortho_scale=31;source.render.filepath=str(out/'hand-context.png')
if not (out/'hand-context.png').exists():bpy.ops.render.render(write_still=True)
