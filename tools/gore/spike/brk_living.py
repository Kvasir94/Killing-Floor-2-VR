# apply alt weights for breaks and pose: args S tag pieces breaks pull(bone:dx,dy,dz;...) shrink(bones) angles
import bpy, json, math, sys
from mathutils import Vector
a=sys.argv[sys.argv.index('--')+1:]; S,tag=a[0],a[1]; show=a[2].split(','); brks=[b for b in a[3].split(',') if b]
pulls=[p for p in a[4].split(';') if p]; shrink=[b for b in a[5].split(',') if b]; angs=[float(x) for x in a[6].split(',')]
ACT=a[7] if len(a)>7 else ''; FR=float(a[8]) if len(a)>8 else 0; FOC=a[9] if len(a)>9 else 'Spine1'; DIST=float(a[10]) if len(a)>10 else 230
D=json.load(open(S+'/clot_gore.json'))
ob=bpy.data.objects['ClotGore']; rig=next(o for o in bpy.data.objects if o.type=='ARMATURE')
G={g.name:g for g in ob.vertex_groups}
if ACT:
    act=bpy.data.actions[ACT]; rig.animation_data_create(); rig.animation_data.action=act
    f0,f1=act.frame_range; bpy.context.scene.frame_set(int(f0+(f1-f0)*FR)); bpy.context.view_layer.update()
    basis={pb.name:pb.matrix_basis.copy() for pb in rig.pose.bones}
    rig.animation_data.action=None
    for pb in rig.pose.bones: pb.matrix_basis=basis[pb.name]
    bpy.context.view_layer.update()
for b in brks:
    for v,inf in D['joints'][b]['alt'].items():
        v=int(v)
        for g in ob.vertex_groups: g.remove([v])
        for n,w in inf:
            if n not in G: G[n]=ob.vertex_groups.new(name=n)
            G[n].add([v],w/255,'REPLACE')
for p in pulls:
    bn,vec=p.split(':'); d=Vector([float(x) for x in vec.split(',')])
    pb=rig.pose.bones[bn]
    # move in armature space
    M=pb.matrix.copy(); M.translation+=d; pb.matrix=M
    bpy.context.view_layer.update()
for b in shrink: rig.pose.bones[b].scale=(0.001,)*3
for o in bpy.data.objects:
    if o.type=='MESH' and o.name!='ClotGore': o.hide_render = o.name not in show
sc=bpy.context.scene; sc.render.engine='BLENDER_EEVEE'; sc.render.resolution_x=640; sc.render.resolution_y=800
w=bpy.data.worlds.new('w'); sc.world=w; w.use_nodes=True; w.node_tree.nodes['Background'].inputs[0].default_value=(0.09,0.09,0.1,1); w.node_tree.nodes['Background'].inputs[1].default_value=1.4
cam=bpy.data.objects.new('cam',bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera=cam; cam.data.lens=60
bpy.context.view_layer.update()
tgt=rig.matrix_world@rig.pose.bones[FOC].head
for i,ang in enumerate(angs):
    for L in [o for o in sc.objects if o.type=='LIGHT']: bpy.data.objects.remove(L)
    r=math.radians(ang); d=Vector((math.sin(r),-math.cos(r),0.2)).normalized()
    cam.location=tgt+d*DIST; cam.rotation_euler=(-d).to_track_quat('-Z','Y').to_euler()
    L=bpy.data.objects.new('k',bpy.data.lights.new('k','SUN')); L.data.energy=3.0; sc.collection.objects.link(L); L.rotation_euler=cam.rotation_euler
    L2=bpy.data.objects.new('r',bpy.data.lights.new('r','SUN')); L2.data.energy=1.2; sc.collection.objects.link(L2); L2.rotation_euler=(math.radians(-60),0,math.radians(ang+180))
    sc.render.filepath='%s/bk_%s_%d.png'%(S,tag,i); bpy.ops.render.render(write_still=True)
