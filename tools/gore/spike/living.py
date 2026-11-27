import bpy, json, math, sys, mathutils
from mathutils import Matrix, Vector
a=sys.argv[sys.argv.index('--')+1:]
S, PSK, PSA = a[0], a[1], a[2]
for o in list(bpy.data.objects): bpy.data.objects.remove(o)
bpy.ops.psk.import_file(filepath=PSK, scale=1.0)
rig=next(o for o in bpy.data.objects if o.type=='ARMATURE')
psk_mesh=next(o for o in bpy.data.objects if o.type=='MESH')
bpy.context.view_layer.objects.active=rig
bpy.ops.psa.import_file(filepath=PSA, should_use_fake_user=True, should_stash=False, should_use_action_name_prefix=False)
D=json.load(open(S+'/clot_gore.json'))
pv=[psk_mesh.matrix_world@v.co for v in psk_mesh.data.vertices]
def score(sy):
    import random
    random.seed(1); tot=0
    for p in random.sample(D['positions_cm'][:5522],200):
        q=Vector((p[0],sy*p[1],p[2])); tot+=min((q-v).length for v in pv[::3])
    return tot/200
s1,s2=score(1),score(-1); SY=1 if s1<s2 else -1
print('match no-flip %.2f flip %.2f -> SY=%d'%(s1,s2,SY))
verts=[(p[0],SY*p[1],p[2]) for p in D['positions_cm']]
tris=D['triangles'] if SY==1 else [t[::-1] for t in D['triangles']]
me=bpy.data.meshes.new('ClotGore'); me.from_pydata(verts,[],tris); me.update()
_uvl=me.uv_layers.new(name='UV')
for _p in me.polygons:
    for _li in _p.loop_indices:
        _u,_v=D['uv'][me.loops[_li].vertex_index]; _uvl.data[_li].uv=(_u,1-_v)
ob=bpy.data.objects.new('ClotGore',me); bpy.context.scene.collection.objects.link(ob)
bpy.data.objects.remove(psk_mesh)
TEX=S+'/tex/'
def mat(name,col,rough=0.5,img=None,nrm=None):
    m=bpy.data.materials.new(name); m.use_nodes=True; nt=m.node_tree; b=nt.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value=col; b.inputs['Roughness'].default_value=rough
    if img:
        t=nt.nodes.new('ShaderNodeTexImage'); t.image=bpy.data.images.load(TEX+img); nt.links.new(t.outputs['Color'],b.inputs['Base Color'])
    if nrm:
        t=nt.nodes.new('ShaderNodeTexImage'); t.image=bpy.data.images.load(TEX+nrm); t.image.colorspace_settings.name='Non-Color'
        nm=nt.nodes.new('ShaderNodeNormalMap'); nt.links.new(t.outputs['Color'],nm.inputs['Color']); nt.links.new(nm.outputs['Normal'],b.inputs['Normal'])
    return m
SKIN=mat('skin',(0.55,0.52,0.48,1),0.6,'ZED_Clot_TEX/Texture2D/ZED_Clot_D.png','ZED_Clot_TEX/Texture2D/ZED_Clot_N.png'); MEAT=mat('meat',(0.55,0.03,0.02,1),0.3,'FX_Gore_TEX/Texture2D/ZED_Gore_D.png','FX_Gore_TEX/Texture2D/ZED_Gore_N.png'); PIECE=mat('piece',(0.85,0.18,0.12,1),0.5,'FX_Gore_TEX/Texture2D/ZED_GoreAttach_D.png','FX_Gore_TEX/Texture2D/ZED_GoreAttach_N.png')
me.materials.append(SKIN); me.materials.append(MEAT)
for p in me.polygons: p.material_index=1 if p.vertices[0]>=5522 else 0; p.use_smooth=True
G={}
def grp(n):
    if n not in G: G[n]=ob.vertex_groups.new(name=n)
    return G[n]
for v,inf in enumerate(D['base_weights']):
    for n,w in inf: grp(n).add([v],w/255,'ADD')
ob.modifiers.new('arm','ARMATURE').object=rig
# sockets + pieces
socks={s['SocketName']:s for s in json.load(open(S+'/clot_sockets.json')) if 'BoneName' in s}
pieces=json.load(open(S+'/gore_static.json'))
def rotm(r):
    P,Y,R=[x*math.pi/32768 for x in r]
    SP,CP,SY_,CY,SR,CR=math.sin(P),math.cos(P),math.sin(Y),math.cos(Y),math.sin(R),math.cos(R)
    X=(CP*CY,CP*SY_,SP); Yv=(SR*SP*CY-CR*SY_,SR*SP*SY_+CR*CY,-SR*CP); Z=(-(CR*SP*CY+SR*SY_),CY*SR-CR*SP*SY_,CR*CP)
    return Matrix(((X[0],Yv[0],Z[0]),(X[1],Yv[1],Z[1]),(X[2],Yv[2],Z[2]))).to_4x4()
FLIP=Matrix.Diagonal((1,SY,1,1))
import struct as _s
from mathutils import Quaternion
def psk_bones(path, conj_children=True):
    d=open(path,'rb').read(); o=0; bones=None
    while o<len(d):
        cid=d[o:o+20].split(bytes(1))[0].decode(); ds,dc=_s.unpack_from('<ii',d,o+24); o+=32
        if cid=='REFSKELT':
            bones=[]
            for i in range(dc):
                q=o+i*ds; nm=d[q:q+64].split(bytes(1))[0].decode()
                fl,nc,par=_s.unpack_from('<3i',d,q+64); qx,qy,qz,qw,px,py,pz=_s.unpack_from('<7f',d,q+76)
                bones.append((nm,par,(qx,qy,qz,qw),(px,py,pz)))
        o+=ds*dc
    W={}; Wl=[]
    for i,(nm,par,(qx,qy,qz,qw),pos) in enumerate(bones):
        Q=Quaternion((qw,qx,qy,qz))
        if i>0 and conj_children: Q=Q.conjugated()
        # UE (row-vector, left-handed) local transform as a column matrix acting on UE points
        R=Q.to_matrix().to_4x4(); R=R.transposed() if MODE_T else R
        M=Matrix.Translation(Vector(pos))@R
        Wm=M if i==0 else Wl[par]@M
        Wl.append(Wm); W[nm]=Wm
    return W
MODE_T=bool(int(a[3])) if len(a)>3 else False
UEW=psk_bones(PSK, conj_children=bool(int(a[4])) if len(a)>4 else True)
print('hips',UEW['hips'].translation,'head',UEW['head'].translation)
def attach(piece, sock, name):
    s=socks[sock]; pb=rig.data.bones[s['BoneName']]
    loc=Vector(s.get('RelativeLocation',(0,0,0))); rot=s.get('RelativeRotation',(0,0,0)); sc=s.get('RelativeScale',(1,1,1))
    # socket in UE bone space, mapped through the same Y flip as the mesh
    L=Matrix.Translation(loc)@rotm(rot)@Matrix.Diagonal((*sc,1))
    P=pieces[piece]
    m=bpy.data.meshes.new(name); 
    vs=[(p[0],SY*p[1],p[2]) for p in P['positions']]; ts=P['triangles'] if SY==1 else [t[::-1] for t in P['triangles']]
    m.from_pydata(vs,[],ts); m.update(); m.materials.append(PIECE)
    if P.get('uv'):
        ul=m.uv_layers.new(name='UV')
        for _p in m.polygons:
            for _li in _p.loop_indices:
                _u,_v=P['uv'][m.loops[_li].vertex_index]; ul.data[_li].uv=(_u,1-_v)
    for p in m.polygons: p.use_smooth=True
    o=bpy.data.objects.new(name,m); bpy.context.scene.collection.objects.link(o)
    W=FLIP@UEW[s['BoneName']]@L@FLIP
    o.parent=rig; o.parent_type='BONE'; o.parent_bone=s['BoneName']
    o.matrix_world = W
    return o
ATT={'guts':('FX_Gore_Intestine','Intestine_Attach'),'spine':('FX_Gore_BaseSpine','Spinal_Attach'),
     'ribsR':('FX_Gore_Rribs','RShoulder_Attach'),'ribsL':('FX_Gore_Lribs','LShoulder_Attach'),'skull':('FX_Gore_Skull','Head_Attach')}
objs={k:attach(p,s,k) for k,(p,s) in ATT.items()}
bpy.ops.wm.save_as_mainfile(filepath=S+'/living_wounds.blend')
print('actions',len(bpy.data.actions),[a.name for a in bpy.data.actions][:8])
