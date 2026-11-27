# Export the chest-chunk Clot gore mesh as FBX (base weights) plus a JSON sidecar with
# per-vertex data the alternate-weight patcher needs.
import bpy, bmesh, json, sys
from mathutils import Vector
sys.path.insert(0, r'D:\KF2-VR\tools')
a=sys.argv[sys.argv.index('--')+1:]; S,OUT=a[0],a[1]
D=json.load(open(S+'/clot_gore.json'))
ob=bpy.data.objects['ClotGore']; me=ob.data; rig=next(o for o in bpy.data.objects if o.type=='ARMATURE')
for o in list(bpy.data.objects):
    if o not in (ob,rig): bpy.data.objects.remove(o)
n0=len(me.vertices)
orig=[0]*n0; part=[0]*n0
me.attributes['orig'].data.foreach_get('value',orig); me.attributes['part'].data.foreach_get('value',part)
# alternate influence per Blender vertex: new chunk -> Gore_ChestL; else the stock alt of its source vertex
stock_alt={}; lists={}
for j,e in D['joints'].items():
    for v,inf in e['alt'].items(): stock_alt[int(v)]=inf
    lists[j]=set(e['vertices'])
alt={}; member={}
for v in range(n0):
    if part[v]==1:
        alt[v]=[['Gore_ChestL',255]]; member[v]=['Gore_ChestL']
        # the chunk still has to leave with the stock breaks that covered it
        member[v]+= [j for j,s in lists.items() if orig[v] in s]
    elif part[v]==0 and orig[v] in stock_alt:
        alt[v]=stock_alt[orig[v]]; member[v]=[j for j,s in lists.items() if orig[v] in s]
# helper triangles so every alternate bone is in its section's bone map
G={g.name:g.index for g in ob.vertex_groups}
used={0:set(),1:set(),2:set()}; need={0:set(),1:set(),2:set()}
vmat={}
for p in me.polygons:
    for v in p.vertices: vmat[v]=p.material_index
gname={g.index:g.name for g in ob.vertex_groups}
for v in range(n0):
    m=vmat.get(v,0)
    for g in me.vertices[v].groups:
        if g.weight>0: used[m].add(gname[g.group])
    for nm,w in alt.get(v,[]): need[m].add(nm)
bm=bmesh.new(); bm.from_mesh(me); dl=bm.verts.layers.deform.verify(); uvl=bm.loops.layers.uv.active
helpers=[]
for m in (0,1,2):
    for nm in sorted(need[m]-used[m]):
        if nm not in G: G[nm]=ob.vertex_groups.new(name=nm).index
        c=rig.data.bones['Spine1'].head_local+Vector((0,2,0))
        vs=[bm.verts.new(c+d) for d in (Vector((0,0,0)),Vector((0.3,0,0)),Vector((0,0,0.3)))]
        for v in vs: v[dl][G[nm]]=1.0
        f=bm.faces.new(vs); f.material_index=m
        for l in f.loops: l[uvl].uv=(0.5,0.5)
        helpers.append((m,nm))
bm.to_mesh(me); bm.free(); me.update()
print('EXPORT helpers',helpers)
side={'vertices':[],'parents':dict({j:e['parent'] for j,e in D['joints'].items()},Gore_ChestL='LeftShoulder')}
uv=me.uv_layers.active.data
vuv={}
for p in me.polygons:
    for li in p.loop_indices: vuv.setdefault(me.loops[li].vertex_index,tuple(uv[li].uv))
for v in range(len(me.vertices)):
    co=me.vertices[v].co
    side['vertices'].append({'co':[co.x,co.y,co.z],'uv':list(vuv.get(v,(0,0))),'mat':vmat.get(v,0) if v<n0 else None,
        'alt':alt.get(v),'member':member.get(v),'part':part[v] if v<n0 else 9})
json.dump(side,open(OUT+'/ClotGoreChest.json','w'))
for o in bpy.context.scene.objects: o.select_set(o in (rig,ob))
ob.parent=rig
rig.name='Armature'; bpy.context.view_layer.objects.active=ob
rig.animation_data_clear()
for pb in rig.pose.bones: pb.matrix_basis.identity()
sc=bpy.context.scene; sc.unit_settings.system='METRIC'; sc.unit_settings.scale_length=0.01; sc.unit_settings.length_unit='CENTIMETERS'
path=OUT+'/ClotGoreChest.fbx'
r=bpy.ops.export_scene.fbx(filepath=path,use_selection=True,object_types={'ARMATURE','MESH'},
    global_scale=1.0,apply_unit_scale=True,apply_scale_options='FBX_SCALE_UNITS',
    axis_forward='Y',axis_up='Z',use_space_transform=True,bake_space_transform=False,
    add_leaf_bones=False,primary_bone_axis='Y',secondary_bone_axis='X',
    use_armature_deform_only=False,armature_nodetype='NULL',bake_anim=False,
    use_mesh_modifiers=False,mesh_smooth_type='EDGE',path_mode='STRIP',embed_textures=False)
from generate_floating_hands import remove_fbx_armature_container
remove_fbx_armature_container(path)
print('EXPORT ok',path,len(me.vertices),'verts',len(me.polygons),'tris')
