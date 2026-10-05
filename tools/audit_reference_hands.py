"""Check the saved Blender pair for portable shading and usable skin weights."""
import bpy, json, math
from pathlib import Path
s=bpy.context.scene
assert s.name.startswith('Horzine pose review'), s.name
out=Path(bpy.data.filepath).parent;revision=int(s.name.rsplit(' ',1)[-1])
report={'scene':s.name,'blender':bpy.app.version_string,'hands':{},'production_ready':False}
for side in ['Left','Right']:
    ob=next(o for o in s.objects if o.type=='MESH' and o.name.startswith(side+' | complete'))
    rig=next(o for o in s.objects if o.type=='ARMATURE' and o.name.startswith(side+' |'))
    assert len(rig.data.bones)==16
    assert all(m is not None and m.use_nodes and not m.is_evaluated for m in ob.data.materials)
    missing=[];nonunit=[]
    for v in ob.data.vertices:
        assert all(math.isfinite(c) for c in v.co)
        total=sum(g.weight for g in v.groups)
        if not v.groups:missing.append(v.index)
        if abs(total-1)>.001:nonunit.append(v.index)
    assert not missing,(side,'unweighted',len(missing))
    assert not nonunit,(side,'nonunit',len(nonunit))
    for attr in ['ContactWear','HealedScar','DriedBlood']:assert ob.data.attributes.get(attr)
    assert ob.data.uv_layers.active
    report['hands'][side]={'vertices':len(ob.data.vertices),'polygons':len(ob.data.polygons),'materials':len(ob.data.materials),'bones':len(rig.data.bones),'unweighted_vertices':len(missing),'nonunit_weights':len(nonunit)}
missing_files=[]
for ma in {ma for o in s.objects if o.type=='MESH' for ma in o.data.materials}:
    for n in ma.node_tree.nodes:
        if n.type=='TEX_IMAGE' and n.image:
            im=n.image
            if not im.packed_file and not Path(bpy.path.abspath(im.filepath)).is_file():missing_files.append(im.name)
assert not missing_files,missing_files
report['missing_textures']=missing_files
report['pose_frames']=[1,20,40]
report['passed']=True
(out/f'{revision:02d}-asset-audit.json').write_text(json.dumps(report,indent=2))
print('BLENDER_ASSET_AUDIT',json.dumps(report))
