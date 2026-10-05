"""Blender authoring study for the user-supplied Horzine glove/watch references.

Keeps the installed-game anatomy local and preserves the production assets.
Run in Blender; all output is an ignored, independently reviewable art candidate.
Centimetres: X wrist to fingers, Y toward thumb, Z dorsal. No reference pixels
are projected on the model. Materials, hardware, typography and seams are 3D.
"""
from pathlib import Path
import bpy, bmesh, math, json, runpy, random
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/hand-redesign-20260924'
OUT.mkdir(parents=True, exist_ok=True)
REV = int(globals().get('REVISION', 7))
random.seed(842)
scene = bpy.data.scenes.new(f'Horzine reference rebuild {REV:02d}')
bpy.context.window.scene = scene
scene.unit_settings.system = 'METRIC'
scene.unit_settings.scale_length = .01
parts = {}

def mesh(name, verts, faces, mat):
    me = bpy.data.meshes.new(name); me.from_pydata(verts, [], faces); me.update()
    ob = bpy.data.objects.new(name, me); scene.collection.objects.link(ob)
    if mat: me.materials.append(mat)
    for p in me.polygons: p.use_smooth = True
    parts[name] = ob
    return ob

def bevel(ob, width=.08, segments=3):
    m = ob.modifiers.new('Machined radii', 'BEVEL');m.width=width;m.segments=segments
    m = ob.modifiers.new('Face weighted normals','WEIGHTED_NORMAL');m.keep_sharp=True
    return ob

def box(name, loc, size, mat, radius=.08):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    ob=bpy.context.object;ob.name=name;ob.dimensions=size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    ob.data.materials.append(mat);parts[name]=ob
    if radius:bevel(ob,radius)
    return ob

def tube(name, points, radius, mat, cyclic=False):
    cu=bpy.data.curves.new(name,'CURVE');cu.dimensions='3D';cu.resolution_u=12
    cu.bevel_depth=radius;cu.bevel_resolution=3
    if REV >= 5 and name.startswith('Conduit'):
        sp=cu.splines.new('BEZIER');sp.bezier_points.add(len(points)-1)
        for p,co in zip(sp.bezier_points,points):p.co=co;p.handle_left_type='AUTO';p.handle_right_type='AUTO'
    else:
        sp=cu.splines.new('POLY');sp.points.add(len(points)-1)
        for p,co in zip(sp.points,points):p.co=(*co,1)
    sp.use_cyclic_u=cyclic
    ob=bpy.data.objects.new(name,cu);scene.collection.objects.link(ob);cu.materials.append(mat);parts[name]=ob
    return ob

def cylinder(name, loc, radius, depth, mat, direction=(0,0,1), vertices=24):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=loc)
    ob=bpy.context.object;ob.name=name
    ob.rotation_euler=Vector(direction).to_track_quat('Z','Y').to_euler()
    ob.data.materials.append(mat);parts[name]=ob;bevel(ob,.035,2)
    return ob

def material(name, color, rough=.5, metal=0, scale=10, bump=.06, color2=None):
    ma=bpy.data.materials.new(name);ma.use_nodes=True
    n=ma.node_tree.nodes;l=ma.node_tree.links;bs=n.get('Principled BSDF')
    bs.inputs['Base Color'].default_value=(*color,1);bs.inputs['Metallic'].default_value=metal
    bs.inputs['Roughness'].default_value=rough
    tex=n.new('ShaderNodeTexNoise');tex.inputs['Scale'].default_value=scale;tex.inputs['Detail'].default_value=4
    coord=n.new('ShaderNodeTexCoord');l.new(coord.outputs['Object'],tex.inputs['Vector'])
    ramp=n.new('ShaderNodeValToRGB');ramp.color_ramp.elements[0].position=.25;ramp.color_ramp.elements[1].position=.8
    ramp.color_ramp.elements[0].color=(*color,1)
    ramp.color_ramp.elements[1].color=(*(color2 or tuple(c*1.7 for c in color)),1)
    l.new(tex.outputs['Fac'],ramp.inputs[0]);l.new(ramp.outputs[0],bs.inputs['Base Color'])
    fine=n.new('ShaderNodeTexNoise');fine.inputs['Scale'].default_value=scale*12;fine.inputs['Detail'].default_value=3
    l.new(coord.outputs['Object'],fine.inputs['Vector'])
    bn=n.new('ShaderNodeBump');bn.inputs['Strength'].default_value=.48;bn.inputs['Distance'].default_value=bump
    l.new(fine.outputs['Fac'],bn.inputs['Height']);l.new(bn.outputs[0],bs.inputs['Normal'])
    return ma

leather=material('Glove | aged charcoal leather',(.019,.015,.012),.57,scale=2.5,bump=.05,color2=(.072,.053,.035))
panel=material('Glove | burnished knuckle hide',(.025,.021,.017),.39,scale=4,bump=.04,color2=(.09,.069,.046))
edge=material('Glove | abraded seam edges',(.12,.087,.049),.77,scale=6,bump=.025)
thread=material('Glove | waxed flax stitches',(.20,.145,.084),.82,scale=8,bump=.01)
steel=material('Watch | oxidized gunmetal',(.055,.064,.061),.43,.8,3,.018,(.18,.19,.16))
bright=material('Watch | worn nickel edges',(.25,.26,.22),.35,.82,5,.01)
rubber=material('Watch | graphite rubber',(.008,.01,.009),.68,0,8,.035)
web=material('Cuff | olive woven nylon',(.063,.051,.030),.91,0,3,.07,(.14,.117,.073))
blood=material('Wear | dried oxide traces',(.052,.006,.004),.44,0,3,.013)
glass=material('Screen | smoked glass',(.002,.013,.014),.2,.25,20,.002)
skin=material('Skin | scarred warm tissue',(.24,.119,.086),.49,0,1,.08,(.45,.28,.22))
scar=material('Skin | healed scar ridges',(.31,.18,.145),.43,0,4,.03)

# Explicit fine crossing yarns in the fabric shader.
n=web.node_tree.nodes;l=web.node_tree.links;bs=n.get('Principled BSDF');coord=n.new('ShaderNodeTexCoord')
waves=[]
for axis in ['X','Y']:
    wa=n.new('ShaderNodeTexWave');wa.bands_direction=axis;wa.inputs['Scale'].default_value=35
    l.new(coord.outputs['Object'],wa.inputs['Vector']);waves.append(wa)
mix=n.new('ShaderNodeMath');mix.operation='MULTIPLY';l.new(waves[0].outputs['Color'],mix.inputs[0]);l.new(waves[1].outputs['Color'],mix.inputs[1])
bn=n.new('ShaderNodeBump');bn.inputs['Strength'].default_value=.6;bn.inputs['Distance'].default_value=.035
l.new(mix.outputs[0],bn.inputs['Height']);l.new(bn.outputs[0],bs.inputs['Normal'])

def emissive(name, color, strength=1.6):
    ma=bpy.data.materials.new(name);ma.use_nodes=True;bs=ma.node_tree.nodes.get('Principled BSDF')
    bs.inputs['Base Color'].default_value=(*color,1);bs.inputs['Emission Color'].default_value=(*color,1);bs.inputs['Emission Strength'].default_value=strength
    bs.inputs['Roughness'].default_value=.38
    return ma
cyan=emissive('UI | medical cyan',(.08,.8,.79));blue=emissive('UI | armor blue',(.02,.22,1));amber=emissive('UI | amber caution',(1,.44,.045));white=emissive('Markings | ivory',(.49,.57,.52),.15)

# Preserve stock surface topology and UVs; extend the floating cut to include the cuff.
g=runpy.run_path(str(ROOT/'tools/generate_floating_hands.py'),run_name='hand_source')
source=g['read_psk'](ROOT/'extract/arms-audit/CHR_1P_Arms_MESH/SkeletalMesh3/Wep_1stP_Naked_Hands_Rig.psk')
c,cut_report=g['cut_hands'](source,wrist_offset=-13)
bones,names=g['bone_data'](c);bind=g['bind_positions'](bones)
points,wedges,faces,weights=g['decode_geometry'](c)
wrist=names.index('LeftHand_1stP');members=g['descendants'](bones,wrist)
fwd=(bind[names.index('LeftHandMiddle1_1stP')]-bind[wrist]).normalized()
across=bind[names.index('LeftHandIndex1_1stP')]-bind[names.index('LeftHandPinky1_1stP')]
across=(across-fwd*across.dot(fwd)).normalized();dorsal=-fwd.cross(across).normalized()
frame=Matrix((fwd,across,dorsal));coords=[frame@(Vector(p)-bind[wrist]) for p in points]
selected=[i for i in range(len(points)) if max(weights[i],key=weights[i].get) in members]
idx={v:i for i,v in enumerate(selected)}
sf=[f for f in faces if wedges[f[0]][0] in idx]
tri=[[idx[wedges[w][0]] for w in reversed(f[:3])] for f in sf]
hand=mesh('LEFT | anatomical skin and wrist',[coords[i] for i in selected],tri,skin)
uv=hand.data.uv_layers.new(name='StockSkinUV')
for po,fa in zip(hand.data.polygons,sf):
    for li,wi in zip(po.loop_indices,reversed(fa[:3])):uv.data[li].uv=(wedges[wi][1],1-wedges[wi][2])
if REV >= 2:
    # Canonical dorsal coordinates reflect the source frame: restore outward normals
    # before constructing the offset glove, retaining per-loop source UVs.
    bm=bmesh.new();bm.from_mesh(hand.data)
    bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(hand.data);bm.free()
for i,nm in enumerate(names):
    vg=hand.vertex_groups.new(name=nm)
    for old in selected:
        if i in weights[old]:vg.add([idx[old]],weights[old][i],'REPLACE')
sub=hand.modifiers.new('Anatomical smoothing','SUBSURF');sub.levels=2;sub.render_levels=2
if REV >= 4:
    # Sculpt healed ridges into the skin itself, preserving UVs and vertex groups.
    sub.levels=3;sub.render_levels=3
    bpy.ops.object.select_all(action='DESELECT');hand.select_set(True);bpy.context.view_layer.objects.active=hand
    bpy.ops.object.modifier_apply(modifier=sub.name)
    scars=[(-11.9,-1.5,2.7,.5),(-11.4,.4,3.1,-.7),(-9.9,1.8,2.4,.3),(-10.6,-.5,1.9,1.1),(-5.8,1.1,3.1,-.2),(-4.9,-1.4,2.6,.5),(-3.2,.2,2,-.8)]
    if REV >= 5:
        scars += [(-12.8,3.0,3.5,.9),(-12.4,5.1,3.1,-1.3),(-12.9,1.4,2.8,1.2),(-11.4,4.2,3.8,-1.0),(-12.6,-2.6,3.1,1.4),(-10.9,2.4,2.5,1.1),(-6.1,3.2,4.2,-2.4),(-6.4,-2.1,3.7,2),(-5.4,.2,4.3,2.2)]
    scar_attribute=hand.data.attributes.new('HealedScar','FLOAT','POINT')
    # Never query normals after a neighbour has already been displaced: mesh
    # normal recomputation made the old in-place loop fold the skin into fins.
    original_surface=[(v.co.copy(),v.normal.copy()) for v in hand.data.vertices]
    displaced=[co.copy() for co,nrm in original_surface]
    for v,(co,nrm) in zip(hand.data.vertices,original_surface):
        x,y,z=co
        if x > -.3 or x < -12.95:continue
        strength=0;scar_mask=0
        for sx,sy,length,slope in scars:
            t=(x-sx)/length
            if 0<t<1:
                path=sy+slope*t+.19*math.sin(t*8+sx)
                width=(.22 if REV >= 26 else (.18 if REV >= 23 else (.14 if REV >= 5 else .075)))+.045*math.sin(t*5)**2
                ridge=math.exp(-((y-path)/width)**2)*math.sin(math.pi*t)
                scar_mask=max(scar_mask,ridge)
                strength+=((.34 if REV >= 23 else (.21 if REV >= 6 else (.32 if REV >= 5 else .15)))*ridge-.055*math.exp(-((y-path-.19)/.11)**2)*math.sin(math.pi*t))
        strength*=min(1,max(0,(abs(z)-.5)*.6))
        if REV>=26:strength=.23*math.tanh(strength/.23)
        displaced[v.index]=co+nrm*strength
        scar_attribute.data[v.index].value=scar_mask
    for v,co in zip(hand.data.vertices,displaced):v.co=co
    hand.data.update()

# Stock normal and albedo supply real pores and nails beneath a subtle dirty tint.
nt=skin.node_tree;bs=nt.nodes.get('Principled BSDF')
texdir=ROOT/'extract/hands-materials/CHR_1P_Arms_TEX/Texture2D'
tex=nt.nodes.new('ShaderNodeTexImage');tex.image=bpy.data.images.load(str(texdir/'Wep_1stPersonHands_Male_D.tga'),check_existing=True)
mix=nt.nodes.new('ShaderNodeMixRGB');mix.blend_type='MULTIPLY';mix.inputs[0].default_value=.52;mix.inputs[2].default_value=(.58,.40,.34,1)
nt.links.new(tex.outputs['Color'],mix.inputs[1]);nt.links.new(mix.outputs[0],bs.inputs['Base Color'])
if REV >= 4:
    hue=nt.nodes.new('ShaderNodeHueSaturation');hue.inputs['Saturation'].default_value=.57;hue.inputs['Value'].default_value=1.1
    nt.links.new(tex.outputs['Color'],hue.inputs['Color']);nt.links.new(hue.outputs[0],mix.inputs[1])
texn=nt.nodes.new('ShaderNodeTexImage');texn.image=bpy.data.images.load(str(texdir/'Wep_1stPersonHands_Male_N.tga'),check_existing=True);texn.image.colorspace_settings.name='Non-Color'
normal=nt.nodes.new('ShaderNodeNormalMap');normal.inputs['Strength'].default_value=.8
nt.links.new(texn.outputs['Color'],normal.inputs['Color']);nt.links.new(normal.outputs[0],bs.inputs['Normal'])
bs.inputs['Subsurface Weight'].default_value=.07

# Glove is a continuous offset copy of anatomy, trimmed at each finger joint.
glove=hand.copy();glove.data=hand.data.copy();glove.name='LEFT | connected fingerless glove';scene.collection.objects.link(glove)
glove.modifiers.clear();glove.data.materials.clear();glove.data.materials.append(leather)
bm=bmesh.new();bm.from_mesh(glove.data)
bmesh.ops.bisect_plane(bm,geom=list(bm.verts)+list(bm.edges)+list(bm.faces),plane_co=(.4,0,0),plane_no=(1,0,0),clear_inner=True,clear_outer=False)
bm.verts.ensure_lookup_table();deform=bm.verts.layers.deform.active
finger2=[names.index('LeftHand'+f+'2_1stP') for f in ['Thumb','Index','Middle','Ring','Pinky']]
remove=[]
for face in bm.faces:
    if any(sum(v[deform].get(i,0)+v[deform].get(i+1,0) for i in finger2)>.52 for v in face.verts):remove.append(face)
bmesh.ops.delete(bm,geom=remove,context='FACES')
bmesh.ops.delete(bm,geom=[v for v in bm.verts if not v.link_faces],context='VERTS')
bm.normal_update()
for v in bm.verts:v.co+=v.normal*(.19 if REV >= 2 else .11)
bm.to_mesh(glove.data);bm.free()
sub=glove.modifiers.new('Soft glove tailoring','SUBSURF');sub.levels=0 if REV >= 4 else 2;sub.render_levels=sub.levels
sol=glove.modifiers.new('Leather thickness','SOLIDIFY');sol.thickness=.09
bpy.context.view_layer.update()
dg=bpy.context.evaluated_depsgraph_get();he=hand.evaluated_get(dg);hm=he.to_mesh()
bvh=BVHTree.FromPolygons([v.co for v in hm.vertices],[p.vertices[:] for p in hm.polygons])
def surface(x,y,offset=.23,top=True):
    hit=bvh.ray_cast(Vector((x,y,25 if top else -25)),Vector((0,0,-1 if top else 1)))
    return (x,y,hit[0].z+(offset if top else -offset)) if hit[0] else (x,y,.4 if top else -3)

def seam(name, xy, top=True, stitch=True, offset=.27):
    pp=[surface(x,y,offset,top) for x,y in xy];tube(name+' piping',pp,.055,edge)
    if REV >= 7:
        tube(name+' embedded seam dirt',[surface(x,y,offset-.065,top) for x,y in xy],.087,rubber)
    if stitch:
        for j in range(len(pp)-1):
            a=Vector(pp[j]);b=Vector(pp[j+1]);length=(b-a).length
            for k in range(max(1,int(length/.24))):
                t=(k+.15)/max(1,int(length/.24));u=min(1,t+.12/max(.12,length))
                if REV >= 3:
                    direction=(b-a).normalized();shift=Vector((-direction.y,direction.x,0))*.13
                    pa=a.lerp(b,t)+shift;pb=a.lerp(b,u)+shift
                    pa=Vector(surface(pa.x,pa.y,offset+.035,top));pb=Vector(surface(pb.x,pb.y,offset+.035,top))
                    tube(name+f' stitch {j}-{k}',[pa,pb],.019,thread)
                else:tube(name+f' stitch {j}-{k}',[a.lerp(b,t),a.lerp(b,u)],.016,thread)

# Sculpted connected four-lobe knuckle pad, dome height follows anatomy.
def pad(name, xmin,xmax,ymin,ymax,top=True,height=.5):
    verts=[];polys=[];nx=22;ny=44
    for i in range(nx+1):
        u=i/nx
        for j in range(ny+1):
            v=j/ny;y=ymin+(ymax-ymin)*v
            wave=.22*math.cos(v*math.pi*8)
            x=xmin+(xmax-xmin)*u+wave*(u**3)
            p=Vector(surface(x,y,.32 if REV >= 2 else .25,top))
            lobe=(.55+.45*(.5+.5*math.cos((v-.07)*math.pi*8))) if REV >= 2 and top else 1
            if REV >= 3 and top:
                lobe=sum(math.exp(-((y-yy)/.73)**2-((x-(8.95-.13*abs(yy) if REV >= 6 else 8.4))/(1.0 if REV >= 6 else 1.3))**2) for yy in [-3.65,-1.7,.35,2.15])
                p.z+=.19*math.sin(math.pi*u)*math.sin(math.pi*v)+(1.08 if REV >= 6 else .92)*lobe
            else:p.z+=(1 if top else -1)*height*(math.sin(math.pi*u)*math.sin(math.pi*v))**.6*lobe
            verts.append(p)
    for i in range(nx):
        for j in range(ny):
            a=i*(ny+1)+j;polys.append((a,a+ny+1,a+ny+2,a+1))
    ob=mesh(name,verts,polys,panel)
    sol=ob.modifiers.new('Padded leather shell','SOLIDIFY');sol.thickness=.09
    boundary=[(xmin,ymin+(ymax-ymin)*j/ny) for j in range(ny+1)]
    boundary += [(xmin+(xmax-xmin)*i/nx+.22*math.cos(math.pi*8)*(i/nx)**3,ymax) for i in range(1,nx+1)]
    boundary += [(xmax+.22*math.cos(j/ny*math.pi*8),ymin+(ymax-ymin)*j/ny) for j in range(ny-1,-1,-1)]
    boundary += [(xmin+(xmax-xmin)*i/nx+.22*(i/nx)**3,ymin) for i in range(nx-1,-1,-1)]
    seam(name,boundary+[boundary[0]],top)
    return ob
pad('LEFT | continuous scalloped knuckle shield',6.4,10.2,-4.35,2.65,height=.66)
seam('Dorsal wrist welt',[(1.1,-3.1),(1.1,-2),(1.1,-1),(1.1,0),(1.1,1),(1.1,2.3)])
for y in [-2.8,-.7,1.45]:
    seam('Dorsal tendon panel',[(1.6,y),(3,y-.1),(4.6,y),(6.1,y)])
pad('Palm | heel reinforcement',1.7,5.0,-2.8,.6,False,.18)

# Hem follows actual open edges of the subdivided glove before solidification.
sol.show_viewport=False;sol.show_render=False
bpy.context.view_layer.update();ge=glove.evaluated_get(dg);gm=ge.to_mesh()
eb=bmesh.new();eb.from_mesh(gm)
boundary=set(e for e in eb.edges if e.is_boundary)
while boundary:
    e=boundary.pop();start=e.verts[0];v=e.verts[1];pp=[start.co.copy(),v.co.copy()]
    while v!=start:
        options=[ed for ed in v.link_edges if ed in boundary]
        if not options:break
        ed=options[0];boundary.remove(ed);v=ed.other_vert(v);pp.append(v.co.copy())
    tube('Glove rolled opening',pp,.055,edge,v==start)
eb.free();ge.to_mesh_clear();sol.show_viewport=True;sol.show_render=True

# Cuff and twin webbing bands sweep an anatomical elliptical cross-section.
def cuff_point(x,a,raise_by):
    if REV >= 3:
        center=Vector((x,0,-.3));direction=Vector((0,math.cos(a),math.sin(a)))
        hit=bvh.ray_cast(center+direction*20,-direction)
        if hit[0]:return hit[0]+direction*(raise_by+.10)
    return Vector((x,(3.32+raise_by)*math.cos(a),-.3+(2.50+raise_by)*math.sin(a)))
def strap(name,x,width,mat,raise_by=0):
    verts=[];faces=[];N=96
    for xx in [x-width/2,x+width/2]:
        for j in range(N):
            a=(.16+(math.pi-.32)*j/(N-1)) if REV >= 4 and 'saddle' in name else 2*math.pi*j/N
            verts.append(cuff_point(xx,a,raise_by))
    for j in range(N-1 if REV >= 4 and 'saddle' in name else N):faces.append((j,(j+1)%N,(j+1)%N+N,j+N))
    ob=mesh(name,verts,faces,mat);so=ob.modifiers.new('Fabric thickness','SOLIDIFY');so.thickness=.15;bevel(ob,.055,2)
    for xx in [x-width/2+.11,x+width/2-.11]:
        arc=REV >= 4 and 'saddle' in name
        tube(name+' edge',[cuff_point(xx,.16+(math.pi-.32)*j/(N-1) if arc else j*2*math.pi/N,raise_by+.06) for j in range(N)],.035,edge,not arc)
    return ob
strap('Cuff | padded leather saddle',-3.9,8.6,leather,.12)
for i,x in enumerate([-7.05,-.6]):
    strap(f'Cuff | webbing band {i+1}',x,1.28,web,.32)
    # Underside rectangular buckles, with central tongue and looped webbing.
    z=(min(cuff_point(x+off,math.pi*1.5,.55).z for off in [-.9,0,.9])-.2) if REV >= 4 else (cuff_point(x,math.pi*1.5,.5).z if REV >= 3 else -3.28)
    for yy in [-1.1,1.1]:box('Buckle long rail',(x,yy,z),(1.77,.19,.22),bright)
    for xx in [x-.79,x+.79]:box('Buckle return',(xx,0,z),(.19,2.3,.22),steel)
    box('Buckle tension bar',(x,0,z-.1),(.22,2.2,.24),bright)
    box('Folded webbing tail',(x,.2,z+.13),(1.21,2.7,.18),web)

# Angular clipped chassis, shallow stepped metal shell (screen lies in XY).
def outline(cx,cy,w,h,ch=.35):
    return [(cx-w/2+ch,cy-h/2),(cx+w/2-ch,cy-h/2),(cx+w/2,cy-h/2+ch),(cx+w/2,cy+h/2-ch),(cx+w/2-ch,cy+h/2),(cx-w/2+ch,cy+h/2),(cx-w/2,cy+h/2-ch),(cx-w/2,cy-h/2+ch)]
def plate(name,cx,cy,w,h,z,thick,mat,ch=.35):
    xy=outline(cx,cy,w,h,ch);verts=[(x,y,zz) for zz in [z-thick,z] for x,y in xy]
    faces=[tuple(reversed(range(8))),tuple(range(8,16))]+[(i,(i+1)%8,(i+1)%8+8,i+8) for i in range(8)]
    return bevel(mesh(name,verts,faces,mat),.06,3)
def ring(name,cx,cy,w,h,z,mat,r=.045,ch=.2):
    return tube(name,[(x,y,z) for x,y in outline(cx,cy,w,h,ch)],r,mat,True)
cx=-3.9
plate('Watch | undercarriage',cx,0,10.7,6.5,2.8,.7,rubber,.7)
plate('Watch | armored outer frame',cx,0,11.35,7.1,3.36,.7,steel,.7)
plate('Watch | machined perimeter',cx,0,11.05,6.82,3.51,.19,bright,.62)
plate('Watch | recessed bezel',cx,0,10.76,6.53,3.58,.14,steel,.52)
plate('Watch | smoked display lens',cx,0,10.29,5.98,3.61,.08,glass,.4)
for px in [-6.65,-1.35]:ring('Watch | inset screen seal',px,0,4.7,5.5,3.64,rubber,.085,.2)
ring('UI | left perimeter',-6.65,0,4.56,5.32,3.69,cyan,.023,.18)
ring('UI | amber right perimeter',-1.35,0,4.6,5.32,3.69,amber,.035,.18)

fontpath=Path('C:/Windows/Fonts/bahnschrift.ttf' if REV >= 2 else 'C:/Windows/Fonts/consola.ttf')
font=bpy.data.fonts.load(str(fontpath)) if fontpath.exists() else None
def text(name,body,x,y,z,size,mat,align='LEFT'):
    cu=bpy.data.curves.new(name,'FONT');cu.body=body;cu.size=size;cu.space_character=1.05;cu.extrude=.002;cu.align_x=align
    if font:cu.font=font
    ob=bpy.data.objects.new(name,cu);scene.collection.objects.link(ob);ob.location=(x,y,z);cu.materials.append(mat);parts[name]=ob
    return ob
Z=3.72
text('UI health','HEALTH',-8.64,1.94,Z,.45,cyan)
text('UI health number','96',-4.96,.86,Z,.63,cyan,'RIGHT')
ring('UI health track',-6.66,1.12,4.0,.94,Z,cyan,.018,.1)
for i in range(14):box('UI health segment',(-8.42+i*.196,1.12,Z),(.15,.64,.025),cyan,.012)
text('UI armor','ARMOR',-8.64,-.17,Z,.43,blue)
ring('UI armor track',-6.66,-1.10,4,.96,Z,blue,.021,.1)
box('UI armor fill',(-7.13,-1.10,Z),(2.6,.66,.025),blue,.025)
text('UI armor number','84',-4.96,-1.31,Z,.62,blue,'RIGHT')
text('UI telemetry','BIOMETRICS / LINKED',-8.62,-2.30,Z,.205,cyan)
text('UI symptoms','SYMPTOMS:',-3.35,1.87,Z,.35,cyan)
text('UI active','ACTIVE',-.90,1.87,Z,.35,amber)
text('UI vitality','VITALITY: STABLE',-3.35,.99,Z,.35,cyan)
text('UI dosh','DOSH',-3.35,-.50,Z,.26,cyan);text('UI currency','4,250',-2.15,-.50,Z,.29,amber)
text('UI wave','WAVE 12/20',-3.35,-1.09,Z,.27,cyan)
text('UI syringe','SYRINGES [ II ]',-3.35,-1.66,Z,.255,amber)
text('UI time','TIME 18:34:02',-3.35,-2.23,Z,.255,cyan)
# Real 3D fasteners, brackets, crown and serial plate.
for x in [cx-5.33,cx+5.33]:
    for y in [-2.42,2.42]:
        box('Case | bolt lug',(x,y,3.69),(.58,.85,.24),steel,.1)
        cylinder('Case | captive screw',(x,y,3.85),.17,.08,bright)
        box('Case | screw slot',(x,y,3.9),(.22,.035,.014),rubber,.008)
for x in [-7.05,-.6]:
    for y in [-3.35,3.35]:
        box('Case | strap bracket',(x,y,3.5),(1.9,.6,.35),steel,.13)
        box('Case | webbing tab',(x,y,3.72),(1.2,.42,.13),web,.045)
plate('Case | identification plate',-.6,-3.11,3.1,.85,3.89,.16,steel,.22)
text('Horzine maker','HORZINE',-.6,-3.10,3.91,.38,white,'CENTER')
text('Horzine serial','BIOTECH / 07-184',-.6,-3.39,3.92,.135,white,'CENTER')
for x in [-1.92,.73]:cylinder('ID plate rivet',(x,-3.2,3.94),.09,.06,bright)
for y in [-1,-.7,-.4,-.1,.2,.5,.8]:box('Case | cooling rib',(1.85,y,3.38),(.3,.13,.36),bright,.04)
for x in [-7.25,-.35]:
    pts=[(x,-2.8,2.9),(x,-3.9,2.1),(x-.15,-4.1,.1),(x-.6,-3.9,-1.9),(x-1.4,-2.9,-2.7)]
    if REV >= 5:
        end=cuff_point(x-1.4,4.1,.42)
        pts=[(x,-2.8,2.9),(x,-3.65,2.1),(x-.2,-4.0,.2),tuple(end+Vector((-.3,-.3,-.4))),tuple(end)]
    tube('Conduit | armored service loop',pts,.17,rubber)
    cylinder('Conduit | chassis ferrule',pts[0],.24,.5,steel,(0,1,0))
    cylinder('Conduit | cuff anchor',pts[-1],.25,.5,steel,(0,1,0))

# Raised scar paths use ray-cast attachment, with branches and variable width.
for k in range(14 if REV == 1 else 0):
    xx=random.uniform(-12.7,-8.4);yy=random.uniform(-2.1,2.1)
    pp=[surface(xx+i*.29,yy+.18*math.sin(i*.85+k),.035) for i in range(random.randint(5,11))]
    tube('Skin | healed scar '+str(k),pp,random.uniform(.035,.07),scar)

# Studio camera and neutral floor permit repeatable comparisons.
world=bpy.data.worlds.new('Review | charcoal studio');world.use_nodes=True
world.node_tree.nodes.get('Background').inputs[0].default_value=(.07,.085,.095,1)
world.node_tree.nodes.get('Background').inputs[1].default_value=.35;scene.world=world
floor=material('Studio ground',(.018,.023,.026),.85,scale=1,bump=0)
box('Review | shadow floor',(0,0,-8),(200,200,.2),floor,0)
def aim(ob,target):ob.rotation_euler=(Vector(target)-ob.location).to_track_quat('-Z','Y').to_euler()
for name,loc,power,color,size in [('Key',(-6,-12,27),16000,(.82,.91,1),20),('Rim',(12,9,19),21000,(1,.81,.6),14),('Fill',(-15,14,12),10000,(.64,.85,1),16)]:
    da=bpy.data.lights.new('Review '+name,'AREA');da.energy=power;da.color=color;da.shape='DISK';da.size=size
    ob=bpy.data.objects.new(da.name,da);scene.collection.objects.link(ob);ob.location=loc;aim(ob,(0,0,0))
if REV >= 2:
    # Layer healed folds, pores and bruising in skin shading rather than free tubes.
    nt=skin.node_tree;n=nt.nodes;l=nt.links
    co=n.new('ShaderNodeTexCoord');noise=n.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=1.6;noise.inputs['Detail'].default_value=5;noise.inputs['Roughness'].default_value=.75
    l.new(co.outputs['Object'],noise.inputs['Vector'])
    vor=n.new('ShaderNodeTexVoronoi');vor.feature='DISTANCE_TO_EDGE';vor.inputs['Scale'].default_value=2.2
    l.new(noise.outputs['Color'],vor.inputs['Vector'])
    bn=n.new('ShaderNodeBump');bn.inputs['Distance'].default_value=.06 if REV >= 4 else .24;bn.inputs['Strength'].default_value=.8
    l.new(vor.outputs['Distance'],bn.inputs['Height']);l.new(normal.outputs[0],bn.inputs['Normal']);l.new(bn.outputs[0],bs.inputs['Normal'])
    dirt=n.new('ShaderNodeMixRGB');dirt.blend_type='MULTIPLY';dirt.inputs[0].default_value=.55
    ramp=n.new('ShaderNodeValToRGB');ramp.color_ramp.elements[0].color=(.16,.053,.04,1);ramp.color_ramp.elements[0].position=.28;ramp.color_ramp.elements[1].color=(.65,.45,.35,1);ramp.color_ramp.elements[1].position=.72
    l.new(noise.outputs['Fac'],ramp.inputs[0]);l.new(mix.outputs[0],dirt.inputs[1]);l.new(ramp.outputs[0],dirt.inputs[2]);l.new(dirt.outputs[0],bs.inputs['Base Color'])
    # Localized irregular dark patches are attached to dorsal glove and pad surfaces.
    for k in range(34 if REV == 2 else 0):
        x=random.uniform(2,10);y=random.uniform(-3.7,2.3)
        if 6.4 < x < 10.2:continue
        rr=random.uniform(.035,.15);pts=[]
        for i in range(8):
            a=i*math.tau/8;r=rr*random.uniform(.5,1.4);pts.append(surface(x+r*math.cos(a),y+r*math.sin(a),.29))
        mesh('Glove | embedded grime fleck',pts,[tuple(range(8))],blood)
    if REV >= 3:
        # Worn edges plus irregular fine fissures in the leather, no loose paint chips.
        for ma in [leather,panel]:
            no=ma.node_tree.nodes;li=ma.node_tree.links;shader=no.get('Principled BSDF')
            coord=no.new('ShaderNodeTexCoord');vor=no.new('ShaderNodeTexVoronoi');vor.feature='DISTANCE_TO_EDGE';vor.inputs['Scale'].default_value=18
            li.new(coord.outputs['Object'],vor.inputs['Vector'])
            ramp=no.new('ShaderNodeValToRGB');ramp.color_ramp.elements[0].position=.008;ramp.color_ramp.elements[0].color=(.008,.006,.005,1);ramp.color_ramp.elements[1].position=.052;ramp.color_ramp.elements[1].color=(.072,.051,.03,1)
            li.new(vor.outputs['Distance'],ramp.inputs[0])
            old=shader.inputs['Base Color'].links[0].from_socket
            mx=no.new('ShaderNodeMixRGB');mx.blend_type='MULTIPLY';mx.inputs[0].default_value=.24
            li.new(old,mx.inputs[1]);li.new(ramp.outputs[0],mx.inputs[2]);li.new(mx.outputs[0],shader.inputs['Base Color'])
            oldnormal=shader.inputs['Normal'].links[0].from_socket
            bumpnode=no.new('ShaderNodeBump');bumpnode.inputs['Distance'].default_value=.055;bumpnode.inputs['Strength'].default_value=.5
            li.new(vor.outputs['Distance'],bumpnode.inputs['Height']);li.new(oldnormal,bumpnode.inputs['Normal']);li.new(bumpnode.outputs[0],shader.inputs['Normal'])
        # Skin-tone scar ribbons taper flush into the actual forearm surface.
        for k in range(23 if REV == 3 else 0):
            x=random.uniform(-12.9,-8.6);y=random.uniform(-2.9,2.6)
            count=random.randint(9,20);verts=[];faces=[];wid=random.uniform(.06,.14)
            for j in range(count):
                t=j/(count-1);xx=x+t*random.uniform(1.4,2.4);yy=y+.22*math.sin(t*6+k)
                for q in range(7):
                    s=q/6;zz=.014+.095*math.sin(math.pi*s)*math.sin(math.pi*t)
                    verts.append(surface(xx,yy+(s-.5)*wid*2,zz))
            for j in range(count-1):
                for q in range(6):
                    a=j*7+q;faces.append((a,a+7,a+8,a+1))
            mesh('Skin | tapered healed scar',verts,faces,scar)
        # Compact, broad monitor aspect ratio and clearer main telemetry.
        for ob in list(scene.objects):
            if ob.name.startswith(('Watch |','UI ','UI |','Case |','Horzine ','Horzine maker','Horzine serial','ID plate')):
                ob.location.y*=.84
                ob.scale.y*=.84
        for ob in scene.objects:
            if ob.type=='FONT' and ob.name.startswith(('UI symptoms','UI active','UI vitality')):
                ob.data.size*=1.13
        # Mechanical cable clips bury the termination inside the saddle.
        for xx in [-8.65,-1.75]:
            p=cuff_point(xx,4.1,.5)
            cylinder('Conduit | bolted saddle clamp',p,.30,.3,steel,(0,-.8,-.6))
    if REV >= 5:
        # Attribute-driven albedo makes the real sculpted scar tracks legible.
        no=skin.node_tree.nodes;li=skin.node_tree.links;shader=no.get('Principled BSDF')
        att=no.new('ShaderNodeAttribute');att.attribute_name='HealedScar'
        col=no.new('ShaderNodeValToRGB');col.color_ramp.elements[0].position=.08;col.color_ramp.elements[0].color=(.11,.027,.024,1);col.color_ramp.elements[1].position=.78;col.color_ramp.elements[1].color=(.30,.145,.12,1) if REV >= 6 else (.43,.235,.21,1)
        li.new(att.outputs['Fac'],col.inputs[0])
        old=shader.inputs['Base Color'].links[0].from_socket
        mx=no.new('ShaderNodeMixRGB');li.new(att.outputs['Fac'],mx.inputs[0]);li.new(old,mx.inputs[1]);li.new(col.outputs[0],mx.inputs[2]);li.new(mx.outputs[0],shader.inputs['Base Color'])
        # Selective glossy abrasion at raised leather features, broken by fine noise.
        for ma in [leather,panel]:
            no=ma.node_tree.nodes;li=ma.node_tree.links;shader=no.get('Principled BSDF')
            geom=no.new('ShaderNodeNewGeometry');curv=no.new('ShaderNodeValToRGB')
            curv.color_ramp.elements[0].position=.48;curv.color_ramp.elements[0].color=(0,0,0,1)
            curv.color_ramp.elements[1].position=.56;curv.color_ramp.elements[1].color=(.72,.72,.72,1)
            li.new(geom.outputs['Pointiness'],curv.inputs[0])
            grain=no.new('ShaderNodeTexNoise');grain.inputs['Scale'].default_value=45;grain.inputs['Detail'].default_value=3
            mul=no.new('ShaderNodeMath');mul.operation='MULTIPLY';li.new(grain.outputs['Fac'],mul.inputs[0]);li.new(curv.outputs[0],mul.inputs[1])
            old=shader.inputs['Base Color'].links[0].from_socket
            worn=no.new('ShaderNodeMixRGB');worn.inputs[2].default_value=(.12,.085,.052,1)
            li.new(mul.outputs[0],worn.inputs[0]);li.new(old,worn.inputs[1]);li.new(worn.outputs[0],shader.inputs['Base Color'])
            rough=no.new('ShaderNodeMapRange');rough.inputs['From Min'].default_value=0;rough.inputs['From Max'].default_value=.5;rough.inputs['To Min'].default_value=.55;rough.inputs['To Max'].default_value=.25
            li.new(curv.outputs[0],rough.inputs['Value']);li.new(rough.outputs[0],shader.inputs['Roughness'])
        # Small edge scratches in exposed chassis metal.
        for k in range(40):
            x=random.uniform(-8.6,.7);y=random.choice([-2.68,2.68]);length=random.uniform(.07,.22)
            tube('Case | edge abrasion',[(x,y,3.56),(x+length,y+random.uniform(-.03,.03),3.565)],.012,bright)
    # Reduce studio fill and avoid the bright silver/plastic first-pass appearance.
    for ob in scene.objects:
        if ob.type=='LIGHT':ob.data.energy*=.42
    for mat in [steel,bright,leather,panel,edge,thread]:
        for nd in mat.node_tree.nodes:
            if nd.type=='VALTORGB':
                for el in nd.color_ramp.elements:
                    fac=.55 if mat in [steel,bright] else .48
                    el.color=(*(v*fac for v in el.color[:3]),1)
if REV >= 21:
    runpy.run_path(str(ROOT/'tools/refine_reference_shapes.py'))['refine'](globals())
if REV >= 6:
    # Deliberately authored wear fields at pressure/contact regions, not global dirt.
    for ob in scene.objects:
        if ob.type!='MESH' or not any(ma in [leather,panel,web] for ma in ob.data.materials):continue
        attr=ob.data.attributes.new('ContactWear','FLOAT','POINT')
        stain_attr=ob.data.attributes.new('DriedBlood','FLOAT','POINT')
        for v in ob.data.vertices:
            x,y,z=v.co
            crown=max(math.exp(-((x-(8.95-.13*abs(yy)))/1.05)**2-((y-yy)/.78)**2) for yy in [-3.65,-1.7,.35,2.15]) if z>-.2 else 0
            rims=.6*max(0,min(1,(x-10)/2)) if z>-.5 else 0
            heel=.5*math.exp(-((x-3)/2)**2-((y+1)/1.8)**2) if z<-.8 else 0
            edge_mask=.38*math.exp(-((x-6.5)/.16)**2) if 'shield' in ob.name else 0
            val=max(crown,rims,heel,edge_mask)
            if REV >= 7 and 'shield' in ob.name:
                arcs=[]
                for yy in [-3.65,-1.7,.35,2.15]:
                    xc=8.95-.13*abs(yy)
                    radius=math.sqrt(((x-xc)/1.0)**2+((y-yy)/.7)**2)
                    arcs.append(math.exp(-((radius-.73)/.18)**2)*(1 if x>xc-.3 else .15))
                val=max(max(arcs)*.95,edge_mask)
            if 'webbing' in ob.name:
                val=.65*max(math.exp(-((x-xx)/.16)**2) for xx in [-7.61,-6.49,-1.16,-.04])
            attr.data[v.index].value=val
            stain_attr.data[v.index].value=max(math.exp(-((x-8.8)/.7)**2-((y+1.9)/.65)**2),.8*math.exp(-((x-7.2)/.5)**2-((y-1.9)/.8)**2)) if z>-.1 else 0
    for ma in [leather,panel,web]:
        no=ma.node_tree.nodes;li=ma.node_tree.links;shader=no.get('Principled BSDF')
        att=no.new('ShaderNodeAttribute');att.attribute_name='ContactWear'
        co=no.new('ShaderNodeTexCoord');grain=no.new('ShaderNodeTexNoise');grain.inputs['Scale'].default_value=9;grain.inputs['Detail'].default_value=5;grain.inputs['Roughness'].default_value=.8
        li.new(co.outputs['Object'],grain.inputs['Vector'])
        broken=no.new('ShaderNodeValToRGB');broken.color_ramp.elements[0].position=.36 if REV>=7 else .30;broken.color_ramp.elements[0].color=(.05,.05,.05,1);broken.color_ramp.elements[1].position=.53 if REV>=7 else .63
        li.new(grain.outputs['Fac'],broken.inputs[0])
        mul=no.new('ShaderNodeMath');mul.operation='MULTIPLY';li.new(att.outputs['Fac'],mul.inputs[0]);li.new(broken.outputs[0],mul.inputs[1])
        base=no.new('ShaderNodeMixRGB');base.inputs[1].default_value=(.005,.006,.005,1);base.inputs[2].default_value=(.021,.023,.020,1)
        if ma==web:base.inputs[1].default_value=(.028,.025,.016,1);base.inputs[2].default_value=(.055,.048,.030,1)
        li.new(grain.outputs['Fac'],base.inputs[0])
        worn=no.new('ShaderNodeMixRGB');worn.inputs[2].default_value=(.19,.151,.102,1) if ma==web else ((.32,.26,.19,1) if REV>=7 else (.135,.108,.078,1))
        li.new(mul.outputs[0],worn.inputs[0]);li.new(base.outputs[0],worn.inputs[1]);li.new(worn.outputs[0],shader.inputs['Base Color'])
        rough=no.new('ShaderNodeMapRange');rough.inputs['From Min'].default_value=0;rough.inputs['From Max'].default_value=1;rough.inputs['To Min'].default_value=.67 if ma==web else .53;rough.inputs['To Max'].default_value=.45 if ma==web else .25
        li.new(att.outputs['Fac'],rough.inputs['Value']);li.new(rough.outputs[0],shader.inputs['Roughness'])
        if ma==panel:
            stain=no.new('ShaderNodeValToRGB');stain.color_ramp.elements[0].position=.69;stain.color_ramp.elements[0].color=(0,0,0,1);stain.color_ramp.elements[1].position=.79;stain.color_ramp.elements[1].color=(.7,.7,.7,1)
            li.new(grain.outputs['Fac'],stain.inputs[0]);mx=no.new('ShaderNodeMixRGB');mx.inputs[2].default_value=(.05,.006,.004,1)
            li.new(stain.outputs[0],mx.inputs[0]);li.new(worn.outputs[0],mx.inputs[1]);li.new(mx.outputs[0],shader.inputs['Base Color'])
            if REV >= 7:
                bloodatt=no.new('ShaderNodeAttribute');bloodatt.attribute_name='DriedBlood'
                multi=no.new('ShaderNodeMath');multi.operation='MULTIPLY';li.new(bloodatt.outputs['Fac'],multi.inputs[0]);li.new(broken.outputs[0],multi.inputs[1])
                mx=no.new('ShaderNodeMixRGB');mx.inputs[2].default_value=(.075,.004,.002,1)
                li.new(multi.outputs[0],mx.inputs[0]);li.new(worn.outputs[0],mx.inputs[1]);li.new(mx.outputs[0],shader.inputs['Base Color'])
    if REV >= 7:
        # Broken, stained rolled hems instead of immaculate tan outlines.
        for nd in edge.node_tree.nodes:
            if nd.type=='VALTORGB':
                nd.color_ramp.elements[0].position=.38;nd.color_ramp.elements[0].color=(.016,.012,.007,1)
                nd.color_ramp.elements[1].position=.65;nd.color_ramp.elements[1].color=(.26,.19,.11,1)
if REV>=59:
    runpy.run_path(str(ROOT/'tools/orient_watch_left_hand.py'))['orient_left'](globals())
cam=bpy.data.objects.new('Review | hero camera',bpy.data.cameras.new('Review hero'))
scene.collection.objects.link(cam);cam.location=(5 if REV >= 2 else 17,-31,46);aim(cam,(0,0,0));cam.data.type='ORTHO';cam.data.ortho_scale=34;scene.camera=cam
scene.render.engine='CYCLES';scene.cycles.samples=40;scene.cycles.use_denoising=True
scene.render.resolution_x=1600;scene.render.resolution_y=1050;scene.render.resolution_percentage=100
scene.view_settings.view_transform='AgX'
scene.render.image_settings.file_format='PNG';scene.render.filepath=str(OUT/f'{REV:02d}-hero.png')
scene['status']='Blender art candidate, not game or headset acceptance'
scene['reference_source']='Five user-provided reference images, September 23 2026'
he.to_mesh_clear()
for im in bpy.data.images:
    if im.source=='FILE':
        try:im.pack()
        except RuntimeError:pass
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/f'{REV:02d}-horzine-study.blend'),copy=True)
(OUT/f'{REV:02d}-scene.json').write_text(json.dumps({'revision':REV,'scene':scene.name,'objects':len(scene.objects),'cut':cut_report,'production_assets_changed':False},indent=2))
print('REFERENCE_STUDY_READY',str(OUT/f'{REV:02d}-horzine-study.blend'))
