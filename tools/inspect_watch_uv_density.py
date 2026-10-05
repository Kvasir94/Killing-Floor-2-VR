import bpy, json, math
from pathlib import Path
from mathutils import Vector
root=Path(bpy.data.filepath).parent
watch=bpy.context.scene.objects['Runtime watch'];me=watch.data;uv=me.uv_layers.active
bpy.context.window.scene=next(s for s in bpy.data.scenes if s.name.startswith('Horzine reference rebuild'))
bpy.context.view_layer.update()
rows=[]
for name in ['Cuff | adjuster webbing feed','Cuff | adjuster webbing feed.001','Case | descending webbing tongue']:
    ob=bpy.data.objects.get(name)
    bounds=[ob.matrix_world@Vector(p) for p in ob.bound_box]
    lo=Vector(tuple(min(p[a] for p in bounds)-.06 for a in range(3)))
    hi=Vector(tuple(max(p[a] for p in bounds)+.06 for a in range(3)))
    values=[];coords=[]
    for p in me.polygons:
        if p.normal.y>-.6 or not all(lo[a]<=p.center[a]<=hi[a] for a in range(3)):continue
        points=[uv.data[i].uv.copy() for i in p.loop_indices]
        area=abs((points[1]-points[0]).cross(points[2]-points[0]))*.5
        if p.area>1e-8:values.append(math.sqrt(area/p.area)*4096);coords+=points
    values.sort()
    rows.append({'name':name,'bounds':[list(lo),list(hi)],'faces':len(values),'px_per_cm_min_median_max':[values[0],values[len(values)//2],values[-1]] if values else [],
                 'uv_bounds':[[min(v[a] for v in coords),max(v[a] for v in coords)] for a in range(2)] if coords else []})
(root/'uv-density.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows),flush=True)
