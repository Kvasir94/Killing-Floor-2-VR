"""Rear/top fit views and exact strap/upper-hardware surface intersections."""
import bpy,json,shutil
from pathlib import Path
from mathutils import Vector
from mathutils.bvhtree import BVHTree
out=Path(bpy.data.filepath).parent;s=bpy.context.scene
shutil.copy2(__file__,out/'source'/Path(__file__).name)
bpy.context.view_layer.update();dg=bpy.context.evaluated_depsgraph_get()
straps=[o for o in s.objects if o.name.startswith(('Cuff | webbing band','Cuff | adjuster webbing feed'))]
hardware=[o for o in s.objects if o.name.startswith(('Case | upper stepped keeper','Case | top retention mounting','Case | stamped latch','Conduit | upper')) or o.name=='Cuff | padded leather saddle']
def geometry(o):
    ev=o.evaluated_get(dg);me=ev.to_mesh();me.calc_loop_triangles()
    vv=[o.matrix_world@v.co for v in me.vertices];ff=[tuple(t.vertices) for t in me.loop_triangles]
    ev.to_mesh_clear();return vv,ff
cache={o:geometry(o) for o in straps+hardware};trees={o:BVHTree.FromPolygons(*cache[o],all_triangles=True) for o in cache}
rows=[]
for strap in straps:
    for part in hardware:
        overlap=trees[strap].overlap(trees[part])
        if overlap:
            points=[cache[strap][0][v] for i in {a for a,b in overlap} for v in cache[strap][1][i]]
            rows.append({'strap':strap.name,'hardware':part.name,'intersecting_triangle_pairs':len(overlap),
                         'bounds_cm':[[min(p[a] for p in points),max(p[a] for p in points)] for a in range(3)]})
(out/'strap-fit.json').write_text(json.dumps(rows,indent=2));print('STRAP_FIT',json.dumps(rows),flush=True)
if s.get('watch_detail_revision',0)>=56:assert not rows,rows
mounts={}
for ob in s.objects:
    if not ob.name.startswith(('Case | attachment lug','Cuff | webbing band','Case | wide strap keeper','Case | top retention mounting')):continue
    if ob.name.startswith('Cuff | webbing band') and ' edge' in ob.name:continue
    points=[ob.matrix_world@Vector(p) for p in ob.bound_box]
    cx=(min(p.x for p in points)+max(p.x for p in points))*.5
    target=-6.8344 if cx<-3 else -.988
    mounts[ob.name]={'center_x_cm':cx,'screen_center_x_cm':target,'offset_cm':cx-target}
(out/'strap-mount-alignment.json').write_text(json.dumps(mounts,indent=2))
assert all(abs(item['offset_cm'])<.025 for item in mounts.values()),mounts
s.cycles.samples=32
for name,loc,target,scale in [('fit-rear',(-6,17,18),(-4,2,2.5),17),('fit-overhead',(-4,0,38),(-4,0,0),17),('fit-forearm',(-18,9,14),(-6,2,2.5),13)]:
    if not globals().get('FIT_RENDER',True):break
    s.camera.location=loc;s.camera.rotation_euler=(Vector(target)-s.camera.location).to_track_quat('-Z','Y').to_euler()
    s.camera.data.ortho_scale=scale;s.render.filepath=str(out/(name+'.png'));bpy.ops.render.render(write_still=True)
