import bpy,json,os
from pathlib import Path
s=bpy.context.scene;dg=bpy.context.evaluated_depsgraph_get();rows=[]
for ob in s.objects:
    if not ob.name.startswith(('Watch |','Case |','Horzine ','ID plate','Conduit |','Cuff |','Buckle ','Folded webbing')) or ob.type not in {'MESH','CURVE','FONT'}:continue
    ev=ob.evaluated_get(dg);me=ev.to_mesh();me.calc_loop_triangles()
    rows.append({'name':ob.name,'triangles':len(me.loop_triangles),'smooth':sum(p.use_smooth for p in me.polygons),'faces':len(me.polygons)})
    ev.to_mesh_clear()
out=Path(bpy.data.filepath).parent/'geometry-inspection.json'
out.write_text(json.dumps(sorted(rows,key=lambda r:-r['triangles']),indent=2))
print('INSPECTED',out)
