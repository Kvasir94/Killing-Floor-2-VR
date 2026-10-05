"""Compare SDK-extracted watch attachment with the actual imported hand bind frame.

This is a CPU geometry audit, not headset or frame-time acceptance.
"""
import bpy, os, struct, json, runpy, itertools
from pathlib import Path
from mathutils import Vector, Matrix
from mathutils.kdtree import KDTree

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'build/watch-detail-20260924'/os.environ['KF2VR_ART_REVISION']
EXTRACT=BASE/'imported-sdk/KF2VRHands'
g=runpy.run_path(str(ROOT/'tools/generate_floating_hands.py'),run_name='asset_reader')
chunks=g['read_psk'](EXTRACT/'SkeletalMesh3/VRFloatingHands.psk')
bones,names=g['bone_data'](chunks);bind=g['bind_positions'](bones);points=dict(zip(names,bind))
wrist=points['LeftHand_1stP']
forward=(points['LeftHandMiddle1_1stP']-wrist).normalized()
thumb=points['LeftHandIndex1_1stP']-points['LeftHandPinky1_1stP'];thumb=(thumb-forward*thumb.dot(forward)).normalized()
palm=forward.cross(thumb).normalized()
segment=(points['LeftHandMiddle2_1stP']-points['LeftHandMiddle1_1stP']).normalized()
curve=(points['LeftHandMiddle3_1stP']-points['LeftHandMiddle2_1stP']).normalized()
if (curve-segment*curve.dot(segment)).dot(palm)<0:palm=-palm
attach=Matrix((palm,forward,palm.cross(forward).normalized())).transposed()
canonical=Matrix((forward,-thumb,-palm))
offset=-forward*3.9-palm*3.72
file=next((EXTRACT/'StaticMesh3').glob('VRWristwatch.psk*'))
data=file.read_bytes();cursor=0;raw={}
while cursor<len(data):
    name,kind,size,count=struct.unpack_from('<20s3i',data,cursor);cursor+=32
    raw[name.rstrip(b'\0').decode()]=[data[cursor+i*size:cursor+(i+1)*size] for i in range(count)]
    cursor+=size*count
local=[Vector(struct.unpack('<3f',row)) for row in raw['PNTS0000']]
actual=[canonical@(attach@p+offset) for p in local]
source=next(o for o in bpy.context.scene.objects if o.name=='Runtime watch')
tree=KDTree(len(source.data.vertices))
for v in source.data.vertices:tree.insert(source.matrix_world@v.co,v.index)
tree.balance()
distances=sorted(tree.find(p)[2] for p in actual)
report={'package':str(BASE/'package/KF2VRHands.upk'),'extracted_static_mesh':str(file),
        'game_attachment_axes':'X=Palm,Y=Forward,Z=Palm cross Forward; offset=-Forward*3.9-Palm*3.72',
        'hand':'Left, default offhand','source_frame_determinant':canonical.determinant(),
        'sdk_points':len(local),'maximum_vertex_deviation_cm':max(distances),
        'median_vertex_deviation_cm':distances[len(distances)//2],
        'passed':max(distances)<.002,'headset_acceptance':False}
if not report['passed']:
    candidates=[]
    for signs in itertools.product((-1,1),repeat=3):
        values=[tree.find(Vector(tuple(p[i]*signs[i] for i in range(3))))[2] for p in actual]
        candidates.append({'canonical_axis_signs':signs,'maximum_cm':max(values),'mean_cm':sum(values)/len(values)})
    report['reflection_diagnostics']=sorted(candidates,key=lambda v:v['mean_cm'])[:3]
(BASE/'sdk-attachment-audit.json').write_text(json.dumps(report,indent=2))
print('SDK_ATTACHMENT',json.dumps(report),flush=True)
