import bpy, json, math, sys, numpy as np
from mathutils import Vector, Matrix
a=sys.argv[sys.argv.index('--')+1:]; S,state=a[0],a[1]
D=json.load(open(S+'/clot_gore.json'))
ob=bpy.data.objects['ClotGore']; me=ob.data; rig=next(o for o in bpy.data.objects if o.type=='ARMATURE')
for o in bpy.data.objects:
    if o.type=='MESH' and o.name!='ClotGore': o.hide_render=True
n=len(me.vertices)
orig=[0]*n; part=[0]*n
me.attributes['orig'].data.foreach_get('value',orig); me.attributes['part'].data.foreach_get('value',part)
G={g.name:g for g in ob.vertex_groups}
def setw(v,inf):
    for g in ob.vertex_groups: g.remove([v])
    for nm,w in inf:
        if nm not in G: G[nm]=ob.vertex_groups.new(name=nm)
        G[nm].add([v],w,'REPLACE')
chunk=state in('chunk','both','ribs','compare'); slice_=state in('slice','both')
SL=D['joints']['LeftShoulder']['alt']
for v in range(n):
    if part[v]==1 and (chunk or slice_): setw(v,[('Gore_ChestL',1.0)])
    elif slice_ and str(orig[v]) in SL: setw(v,[(nm,w/255) for nm,w in SL[str(orig[v])]])
HEAD=['Gore_FrontR','gore_jaw'] if state=='compare' else []
for hb in HEAD:
    for v,inf in D['joints'][hb]['alt'].items():
        vi=[i for i in range(n) if orig[i]==int(v) and part[i]==0]
        for i in vi: setw(i,[(nm,w/255) for nm,w in inf])
# ribs in the hole (rest pose), parented to Spine2
if state=='ribs':
    pcs=json.load(open(S+'/gore_static.json'))['FX_Gore_Lribs']
    V=np.array(pcs['positions']); V[:,1]*=-1; Vc=V-V.mean(0)
    w,U=np.linalg.eigh(np.cov(Vc.T)); thin=U[:,0]
    cv=[me.vertices[v].co for v in range(n) if part[v]==1]; C=sum(cv,Vector())/len(cv)
    N=Vector((0.25,-1,0.1)).normalized()
    q=Vector(thin).rotation_difference(N); R=q.to_matrix()
    rmax=max((c-C).length for c in cv)
    ext=np.abs(Vc).max(); sc=rmax/ext*1.1
    pts=[C-N*1.8+ (R@Vector(p))*sc for p in Vc]
    keep=[ (pt-C).length<rmax*0.95 for pt in pts]
    tris=[t for t in pcs['triangles'] if all(keep[i] for i in t)]
    rm=bpy.data.meshes.new('ribsfit'); rm.from_pydata([tuple(p) for p in pts],[],[t[::-1] for t in tris]); rm.update()
    rm.materials.append(bpy.data.materials['piece'])
    ul=rm.uv_layers.new(name='UV')
    for _p in rm.polygons:
        for _li in _p.loop_indices:
            _u,_v=pcs['uv'][rm.loops[_li].vertex_index]; ul.data[_li].uv=(_u,1-_v)
    for p_ in rm.polygons: p_.use_smooth=True
    ro=bpy.data.objects.new('ribsfit',rm); bpy.context.scene.collection.objects.link(ro)
    W=ro.matrix_world.copy(); ro.parent=rig; ro.parent_type='BONE'; ro.parent_bone='Spine2'; ro.matrix_world=W
# pose
act=bpy.data.actions['Walk_F_V1']; rig.animation_data_create(); rig.animation_data.action=act
f0,f1=act.frame_range; bpy.context.scene.frame_set(int(f0+(f1-f0)*0.3)); bpy.context.view_layer.update()
basis={pb.name:pb.matrix_basis.copy() for pb in rig.pose.bones}; rig.animation_data.action=None
for pb in rig.pose.bones: pb.matrix_basis=basis[pb.name]
bpy.context.view_layer.update()
if chunk: rig.pose.bones['Gore_ChestL'].scale=(0.001,)*3
for hb in HEAD: rig.pose.bones[hb].scale=(0.001,)*3
if slice_:
    pb=rig.pose.bones['LeftShoulder']; M=pb.matrix.copy(); M.translation+=Vector((28,-8,-14)); pb.matrix=M
bpy.context.view_layer.update()
dg=bpy.context.evaluated_depsgraph_get(); ev=ob.evaluated_get(dg); em=ev.to_mesh()
# focus: rest-pose chunk centre moved by Spine2
pc=[ob.matrix_world@em.vertices[v].co for v in range(n) if part[v]==1 and not chunk] 
sp=rig.matrix_world@rig.pose.bones['Spine2'].head
cpts=[ob.matrix_world@em.vertices[v].co for v in range(n) if part[v]==2]
cc=sum(cpts,Vector())/len(cpts)
hd=rig.matrix_world@rig.pose.bones['head'].head
tgt=(cc+hd)/2 if state=='compare' else cc
# stand-in for a wound decal: a soft, uneven blood stain around the hole (world space, posed)
if chunk:
    rr=max((p_-cc).length for p_ in cpts)
    m=me.materials[0].copy(); me.materials[0]=m; nt=m.node_tree; bsdf=nt.nodes['Principled BSDF']
    tex=[n_ for n_ in nt.nodes if n_.type=='TEX_IMAGE' and n_.image.colorspace_settings.name!='Non-Color'][0]
    geo=nt.nodes.new('ShaderNodeNewGeometry')
    dist=nt.nodes.new('ShaderNodeVectorMath'); dist.operation='DISTANCE'; dist.inputs[1].default_value=cc
    nt.links.new(geo.outputs['Position'],dist.inputs[0])
    nz=nt.nodes.new('ShaderNodeTexNoise'); nz.inputs['Scale'].default_value=0.25; nz.inputs['Detail'].default_value=6
    nt.links.new(geo.outputs['Position'],nz.inputs['Vector'])
    add=nt.nodes.new('ShaderNodeMath'); add.operation='MULTIPLY_ADD'; add.inputs[1].default_value=rr*0.9; add.inputs[2].default_value=-rr*0.45
    nt.links.new(nz.outputs['Fac'],add.inputs[0])
    d2=nt.nodes.new('ShaderNodeMath'); d2.operation='SUBTRACT'
    nt.links.new(dist.outputs['Value'],d2.inputs[0]); nt.links.new(add.outputs[0],d2.inputs[1])
    mr=nt.nodes.new('ShaderNodeMapRange'); mr.interpolation_type='SMOOTHSTEP'
    mr.inputs[1].default_value=rr*0.9; mr.inputs[2].default_value=rr*2.3; mr.inputs[3].default_value=1.0; mr.inputs[4].default_value=0.0
    nt.links.new(d2.outputs[0],mr.inputs[0])
    mix=nt.nodes.new('ShaderNodeMix'); mix.data_type='RGBA'; mix.blend_type='MULTIPLY'
    mix.inputs[7].default_value=(0.30,0.03,0.025,1)
    nt.links.new(mr.outputs[0],mix.inputs[0]); nt.links.new(tex.outputs['Color'],mix.inputs[6]); nt.links.new(mix.outputs[2],bsdf.inputs['Base Color'])
    me.materials[1].node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value=0.5
sc=bpy.context.scene; sc.render.engine='BLENDER_EEVEE'; sc.render.resolution_x=640; sc.render.resolution_y=640
w=bpy.data.worlds.new('w'); sc.world=w; w.use_nodes=True; w.node_tree.nodes['Background'].inputs[0].default_value=(0.09,0.09,0.1,1); w.node_tree.nodes['Background'].inputs[1].default_value=1.3
cam=bpy.data.objects.new('cam',bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera=cam; cam.data.lens=50
views=[(0,105),(-25,95)] if state=='compare' else [(-15,65),(-45,75)] if state not in('slice','both') else [(-20,125),(35,130)]
for i,(ang,dist) in enumerate(views):
    for L in [o for o in sc.objects if o.type=='LIGHT']: bpy.data.objects.remove(L)
    r=math.radians(ang); d=Vector((math.sin(r),-math.cos(r),0.35)).normalized()
    cam.location=tgt+d*dist; cam.rotation_euler=(-d).to_track_quat('-Z','Y').to_euler()
    L=bpy.data.objects.new('k',bpy.data.lights.new('k','SUN')); L.data.energy=3.0; sc.collection.objects.link(L); L.rotation_euler=cam.rotation_euler
    L2=bpy.data.objects.new('r',bpy.data.lights.new('r','SUN')); L2.data.energy=1.0; sc.collection.objects.link(L2); L2.rotation_euler=(math.radians(-50),0,math.radians(ang+160))
    sc.render.filepath='%s/ch_%s_%d.png'%(S,state,i); bpy.ops.render.render(write_still=True)
