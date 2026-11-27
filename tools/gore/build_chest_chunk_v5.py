# The chest chunk Kvasir94 chose (2026-11-10, "go back to v5"): the larger, denser cut with
# a deep crater. Build a front-left chest shrink chunk on the rebuilt stock Clot gore
# mesh and save chest.blend in the scratch folder given as the only argument, which
# must hold clot_gore.json and the base scene (docs/re/ZED_GORE_MESH_ALT_WEIGHTS.md).
# Known costs, measured by the audit: +3,532 vertices (+39%) from subdividing the chest,
# and a third material section. build_chest_chunk.py is the lean variant (+181 vertices,
# two materials) with a smaller, simpler hole.
import bpy, bmesh, json, math, random, sys
from mathutils import Vector, kdtree, noise
S=sys.argv[sys.argv.index('--')+1]
random.seed(7)
D=json.load(open(S+'/clot_gore.json'))
ob=bpy.data.objects['ClotGore']; me=ob.data; rig=next(o for o in bpy.data.objects if o.type=='ARMATURE')
R=8.5
SL=D['joints']['LeftShoulder']['alt']
def slab_id(i): return str(i) in SL and max(SL[str(i)],key=lambda x:x[1])[0]=='LeftShoulder'
bm=bmesh.new(); bm.from_mesh(me)
orig=bm.verts.layers.int.new('orig'); tag=bm.verts.layers.int.new('part')
for v in bm.verts: v[orig]=v.index
bm.verts.layers.int  # new verts get -1 by default? ensure below
dl=bm.verts.layers.deform.active
bm.verts.ensure_lookup_table()
# chunk centre: front-most body point near (x=9, z=132); scene front is -Y
cands=[v for v in bm.verts if v.index<5522 and abs(v.co.x-8.5)<1.8 and abs(v.co.z-136.5)<2.0]
C=min(cands,key=lambda v:v.co.y).co.copy()
N=Vector((0.25,-1,0.1)).normalized()   # outward normal, roughly
print('centre',C)
def rd(co):  # distance in the tangent plane around C
    d=co-C; return (d-N*d.dot(N)).length
ovw=[(v.co.copy(),v[orig],dict(v[dl].items())) for v in bm.verts if v.index<5522]
_ks=kdtree.KDTree(5522)
for v in bm.verts:
    if v.index<5522: _ks.insert(v.co,v.index)
_ks.balance()
_slabpos=set()
for v in bm.verts:
    if v.index<5522:
        grp=[i for _,i,_ in _ks.find_range(v.co,1e-3)]
        if all(slab_id(i) for i in grp): _slabpos.add(v.index)
def slab(i): return i in _slabpos
kd=kdtree.KDTree(len(ovw))
for i,(co,_,_) in enumerate(ovw): kd.insert(co,i)
kd.balance()
def fix_new():
    for v in bm.verts:
        if v.index>=8985:
            co,i,_=kd.find(v.co); _,o,w=ovw[i]; v[orig]=o
# 1. densify the area: two rounds of subdivision on body edges near the centre
for _ in range(3):
    es=[e for e in bm.edges if all(v[orig]<5522 and slab(v[orig]) and rd(v.co)<R*1.3+3 and (v.co-C).dot(N)>-6 for v in e.verts)
        and all(f.material_index==0 for f in e.link_faces)]
    bmesh.ops.subdivide_edges(bm,edges=es,cuts=1,use_grid_fill=True)
    bmesh.ops.triangulate(bm,faces=[f for f in bm.faces if len(f.verts)>3])
    bm.verts.ensure_lookup_table()
    fix_new()
bm.verts.ensure_lookup_table()
nl=bm.verts.layers.float_vector.new('n0')
bm.normal_update()
for v in bm.verts: v[nl]=v.normal
# 2. organic outline: low-frequency lobes plus fine coherent noise, cut along the contour
# torn outline: an irregular polygon of 6 straight-ish breaks
random.seed(11)
K=6
angs=[(i+random.uniform(-0.3,0.3))*6.283/K for i in range(K)]
rads=[R*random.uniform(0.72,1.25) for _ in range(K)]
pts=[(math.cos(a)*r,math.sin(a)*r) for a,r in zip(angs,rads)]
def poly_r(a):
    dx,dy=math.cos(a),math.sin(a); best=1e9
    for i in range(K):
        x1,y1=pts[i]; x2,y2=pts[(i+1)%K]; ex,ey=x2-x1,y2-y1
        den=dx*ey-dy*ex
        if abs(den)<1e-9: continue
        t=(x1*ey-y1*ex)/den; u=(x1*dy-y1*dx)/den
        if t>0 and -1e-6<=u<=1+1e-6: best=min(best,t)
    return best if best<1e8 else R
def rad(co):
    d=co-C; d=d-N*d.dot(N); a=math.atan2(d.z,d.x)
    return poly_r(a)*(1+0.035*noise.noise(co*0.9))
def fval(co): return rd(co)/rad(co)-1.0
def ok(v): return v[orig]<5522 and slab(v[orig]) and (v.co-C).dot(N)>-5 and v[tag]==0
cross=[e for e in bm.edges if ok(e.verts[0]) and ok(e.verts[1]) and all(f.material_index==0 for f in e.link_faces)
       and (fval(e.verts[0].co)<0)!=(fval(e.verts[1].co)<0)]
newv=[]
for e in cross:
    v0,v1=e.verts; f0,f1=fval(v0.co),fval(v1.co); t=f0/(f0-f1)
    ne,nv=bmesh.utils.edge_split(e,v0,t); newv.append(nv)
nset=set(newv)
for f in list({f for v in newv for f in v.link_faces}):
    vs=[v for v in f.verts if v in nset]
    if len(vs)==2:
        try: bmesh.ops.connect_verts(bm,verts=vs)
        except Exception: pass
bmesh.ops.triangulate(bm,faces=[f for f in bm.faces if len(f.verts)>3])
bm.verts.ensure_lookup_table(); fix_new()
for v in nset: v[tag]=0
bm.normal_update()
for v in bm.verts:
    if v.index>=8985: v[nl]=v.normal
region=[f for f in bm.faces if f.material_index==0 and all(ok(v) or v in nset for v in f.verts)
        and all(fval(v.co)<1e-3 for v in f.verts) and (f.calc_center_median()-C).dot(N)>-4]
print('chunk faces',len(region))
rset=set(region)
boundary=[e for e in bm.edges if sum(1 for f in e.link_faces if f in rset)==1]
bmesh.ops.split_edges(bm,edges=boundary)
chunk_verts={v for f in region for v in f.verts}
for v in chunk_verts: v[tag]=1
# 3. meat crater: duplicate the chunk faces, push inward, roughen
dup=bmesh.ops.duplicate(bm,geom=list(region))
dfaces=[g for g in dup['geom'] if isinstance(g,bmesh.types.BMFace)]
dverts={v for f in dfaces for v in f.verts}
for v in dverts: v[tag]=2
dorig={v:v.co.copy() for v in dverts}
# smooth normals merged by proximity (the stock mesh is split along UV seams)
_pts=[]; 
for f in bm.faces:
    if f.material_index!=0 or rd(f.calc_center_median())>R*1.6+3: continue
    fn=f.normal*f.calc_area()
    for v in f.verts: _pts.append((v.co.copy(),fn))
_kn=kdtree.KDTree(len(_pts))
for i,(co,_) in enumerate(_pts): _kn.insert(co,i)
_kn.balance()
def snorm(co):
    acc=Vector()
    for _,i,d in _kn.find_range(co,1.2): acc+=_pts[i][1]*(1.2-d)
    if acc.length<1e-9: return N
    acc.normalize()
    return -acc if acc.dot(N)<0 else acc
for v in dverts:
    r=min(rd(v.co)/max(rad(v.co),0.1),1)
    depth=1.2+2.6*(1-r*r)**0.8
    nin=snorm(dorig[v])
    v.co=v.co-nin*(depth+0.45*noise.noise(v.co*0.35)*(1-r))
for f in dfaces: f.material_index=1
uvl=bm.loops.layers.uv.active
T1=(N.cross(Vector((0,0,1)))).normalized(); T2=N.cross(T1)
def meat_uv(co):
    d=co-C; return (0.76+0.2*(0.5+d.dot(T1)/(2.6*R)), 0.07+0.3*(0.5+d.dot(T2)/(2.6*R)))
def rib_uv(co):
    # painted rib cage on stock ZED_GoreAttach_D; ribs run across the hole
    d=co-C; return (0.03+0.26*(0.5+d.dot(T1)/(2.4*R)), 0.10+0.30*(0.5+d.dot(T2)/(2.4*R)))
for f in dfaces:
    f.material_index=2
    for l in f.loops: l[uvl].uv=rib_uv(dorig.get(l.vert,l.vert.co))
# side wall: for each crater rim edge, connect to the coincident skin hole rim
crater_edges=[e for e in bm.edges if e.verts[0] in dverts and e.verts[1] in dverts and len(e.link_faces)==1]
skin_rim=[v for v in bm.verts if v[tag]==0 and any(len(e.link_faces)==1 for e in v.link_edges)]
ks=kdtree.KDTree(len(skin_rim))
for i,v in enumerate(skin_rim): ks.insert(v.co,i)
ks.balance()
made=0; miss=0
for e in crater_edges:
    a_,b_=e.verts
    ra=ks.find(dorig[a_]); rb=ks.find(dorig[b_])
    if ra[2]>0.05 or rb[2]>0.05: miss+=1; continue
    sa,sb=skin_rim[ra[1]],skin_rim[rb[1]]
    if sa==sb: continue
    try:
        f=bm.faces.new((sa,sb,b_,a_)); f.material_index=1; made+=1
        for l in f.loops: l[uvl].uv=meat_uv(dorig.get(l.vert,l.vert.co))
    except ValueError: pass
print('rim edges',len(crater_edges),'wall faces',made,'unmatched',miss)
bl=bm.verts.layers.float.new('blood')
for v in bm.verts:
    if v[tag]==0 and v[orig]<5522 and (v.co-C).dot(N)>-5 and rd(v.co)<R*1.6+4:
        x=fval(v.co)*rad(v.co)          # cm outside the rim
        fall=2.6+1.4*noise.noise(v.co*0.35)
        v[bl]=max(0.0,min(1.0,1-x/fall))**1.6
bm.to_mesh(me); bm.free(); me.update()
if 'piece' not in [m_.name for m_ in me.materials if m_]: me.materials.append(bpy.data.materials['piece'])

import numpy as _np
nn=_np.zeros(len(me.vertices)*3); me.attributes['n0'].data.foreach_get('vector',nn); nn=nn.reshape(-1,3)
part_=[0]*len(me.vertices); me.attributes['part'].data.foreach_get('value',part_)
vn=[tuple(nn[i]) if part_[i]!=2 else (0,0,0) for i in range(len(me.vertices))]
try:
    pass
except Exception as ex: print('normals',ex)
for p in me.polygons: p.use_smooth=True
# 4. chunk bone off the left shoulder, identical rest frame
bpy.context.view_layer.objects.active=rig; bpy.ops.object.mode_set(mode='EDIT')
eb=rig.data.edit_bones; src=eb['LeftShoulder']; nb=eb.new('Gore_ChestL')
nb.head=src.head; nb.tail=src.tail; nb.roll=src.roll; nb.parent=src
bpy.ops.object.mode_set(mode='OBJECT')
if 'Gore_ChestL' not in ob.vertex_groups: ob.vertex_groups.new(name='Gore_ChestL')
bpy.ops.wm.save_as_mainfile(filepath=S+'/chest.blend')
