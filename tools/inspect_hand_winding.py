"""Audit actual hand triangle orientation, including the SDK-exported mesh."""
import bpy, json, runpy, os
from pathlib import Path
from mathutils import Vector
from mathutils.bvhtree import BVHTree

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'build/watch-detail-20260924'/os.environ.get('KF2VR_ART_REVISION','64')
OUT=BASE/'hand-winding-audit.json'
INPUT=Path(os.environ.get('KF2VR_HAND_INPUT_DIR',str(ROOT/'build/watch-detail-20260924/baseline-26/runtime')))
g=runpy.run_path(str(ROOT/'tools/generate_floating_hands.py'),run_name='asset_source')

def shells(vertices, faces):
    parent=list(range(len(vertices)))
    def root(i):
        while parent[i]!=i:
            parent[i]=parent[parent[i]];i=parent[i]
        return i
    for face in faces:
        for i in face[1:]:parent[root(i)]=root(face[0])
    grouped={}
    for face in faces:grouped.setdefault(root(face[0]),[]).append(face)
    result=[]
    for ff in sorted(grouped.values(),key=len,reverse=True)[:14]:
        ids=set(i for f in ff for i in f);center=sum((vertices[i] for i in ids),Vector())/len(ids)
        edges={};volume=0
        for face in ff:
            a,b,c=(vertices[i]-center for i in face)
            volume+=a.dot(b.cross(c))/6
            for i,j in zip(face,face[1:]+face[:1]):
                key=tuple(sorted((i,j)));edges.setdefault(key,[]).append((i,j))
        result.append({'triangles':len(ff),'vertices':len(ids),'signed_volume':volume,
                       'boundary_edges':sum(len(v)==1 for v in edges.values()),
                       'same_direction_shared_edges':sum(len(v)==2 and v[0]==v[1] for v in edges.values()),
                       'center':list(center)})
    return result

report={}
scene=bpy.context.scene
source=next(s for s in bpy.data.scenes if s.name.startswith('Horzine reference rebuild'))
skin=next(o for o in source.objects if o.name.startswith('LEFT | anatomical'))
skin.data.calc_loop_triangles()
sv=[skin.matrix_world@v.co for v in skin.data.vertices]
sf=[list(t.vertices) for t in skin.data.loop_triangles]
report['source_skin']=shells(sv,sf)
hand,_=runpy.run_path(str(ROOT/'tools/load_runtime_hand_context.py'))['load_left_hand'](
    INPUT/'VRFloatingHands.fbx',scene)
hand.data.calc_loop_triangles();vv=[v.co.copy() for v in hand.data.vertices];ff=[list(t.vertices) for t in hand.data.loop_triangles]
report['actual_fbx_left']=shells(vv,ff)
bvh=BVHTree.FromPolygons(sv,sf,all_triangles=True)
dots=[]
for tri in hand.data.loop_triangles:
    a,b,c=[vv[i] for i in tri.vertices];center=(a+b+c)/3
    nearest,normal,index,distance=bvh.find_nearest(center)
    if distance<.03:dots.append((b-a).cross(c-a).normalized().dot(normal))
report['near_source_skin_triangles']={'count':len(dots),'opposed_fraction':sum(d<0 for d in dots)/max(1,len(dots)),'mean_normal_dot':sum(dots)/max(1,len(dots))}
for label,path in [('input_psk',INPUT/'VRFloatingHands.psk'),
                   ('sdk_psk',Path(os.environ.get('KF2VR_SDK_HAND_PSK',str(ROOT/'build/watch-detail-20260924/50/imported-sdk/KF2VRHands/SkeletalMesh3/VRFloatingHands.psk'))))]:
    if not path.exists():continue
    chunks=g['read_psk'](path);pp,ww,faces,weights=g['decode_geometry'](chunks)
    report[label]=shells([Vector(p) for p in pp],[[ww[i][0] for i in reversed(f[:3])] for f in faces])
report['passed']=report['near_source_skin_triangles']['opposed_fraction']<.02 and all(s['signed_volume']>0 and s['boundary_edges']==0 for s in report['actual_fbx_left'][:3])
OUT.write_text(json.dumps(report,indent=2));print('HAND_WINDING',json.dumps(report),flush=True)
if os.environ.get('KF2VR_REQUIRE_OUTWARD')=='1':assert report['passed'],report
