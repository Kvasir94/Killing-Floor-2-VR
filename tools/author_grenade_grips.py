"""Offline authored grenade grips on the existing floating-hand skeleton.

Run inside the existing Blender MCP (runpy, then inspect()) or Blender CPU.
Reads original PSK and cooked surfaces; writes only an isolated ignored build
folder. These fixed authoring angles become runtime local quaternion tables.
No runtime contact solver, asset mutation, gameplay or installation.
"""
import json, math, runpy
from pathlib import Path
from mathutils import Vector, Quaternion, Matrix
from mathutils.bvhtree import BVHTree

DIGITS = ('Thumb', 'Index', 'Middle', 'Ring', 'Pinky')
# Fifteen authored flexion angles followed by thumb opposition, in degrees.
PROFILES = {
    'Compact': [[35,-30,-20],[-10,70,0],[-15,55,0],[-20,45,0],[-30,40,-5],35],
    'Canister': [[35,-30,-20],[-10,75,0],[-10,55,0],[-20,50,0],[-30,50,-5],35],
    'Wide': [[75,-30,-20],[-5,5,-5],[-5,5,-5],[-20,15,-10],[-35,20,-15],20],
    'Stick': [[15,-30,-20],[0,70,0],[0,65,0],[-5,65,0],[-15,65,0],45],
    'Bottle': [[50,-30,-20],[-20,50,-5],[-25,45,-5],[-30,35,-5],[-40,30,-15],35],
}
SHAPES = {
    'Frag': ('Compact', (8.5,0,3.8)), 'HE': ('Compact',(8.5,0,4.0)),
    'EMP': ('Canister',(8.5,0,3.7)), 'FlashBang': ('Canister',(8.5,0,3.7)),
    'Freeze': ('Wide',(9,0,7.5)), 'Medic': ('Wide',(9,0,7)),
    'Dynamite': ('Stick',(9.5,0,3.5)), 'Molotov': ('Bottle',(8.5,0,5.2)),
    'NailBomb': ('Bottle',(8.5,-7,5.2)),
}
BASELINE = [[55,-45,-15],[40,45,25],[44,45,25],[48,45,25],[52,45,25],45]
CENTERS = {'NailBomb':(0,0,17.34),'Dynamite':(0,0,2.39),'EMP':(.54,.64,1.90),'Molotov':(0,0,1.78)}

def context(root, hand_path):
    g=runpy.run_path(str(root/'tools/generate_floating_hands.py'),run_name='grenade_hand_reader')
    c=g['read_psk'](hand_path);bones,names=g['bone_data'](c)
    points,wedges,faces,weights=g['decode_geometry'](c);p0=[];q0=[]
    for i,b in enumerate(bones):
        q=Quaternion((b[7],b[4],b[5],b[6]));p=Vector(b[8:11])
        if i:p=p0[b[3]]+q0[b[3]]@p;q=q0[b[3]]@q.conjugated()
        p0.append(p);q0.append(q)
    return dict(g=g,bones=bones,names=names,points=points,wedges=wedges,faces=faces,weights=weights,p0=p0,q0=q0)

def hand(ctx, side, values):
    g,bones,names,points,wedges,faces,weights,p0,q0=(ctx[k] for k in ('g','bones','names','points','wedges','faces','weights','p0','q0'))
    wrist=names.index(side+'Hand_1stP');members=g['descendants'](bones,wrist)
    finger=lambda f,j:names.index(side+'Hand'+f+str(j)+'_1stP')
    F=(p0[finger('Middle',1)]-p0[wrist]).normalized();T=p0[finger('Index',1)]-p0[finger('Pinky',1)];T=(T-F*T.dot(F)).normalized();P=F.cross(T).normalized()
    a=(p0[finger('Middle',2)]-p0[finger('Middle',1)]).normalized();b=(p0[finger('Middle',3)]-p0[finger('Middle',2)]).normalized()
    if (b-a*b.dot(a)).dot(P)<0:P=-P
    frame=Matrix((F,T,P));deltas={}
    for fi,f in enumerate(DIGITS):
        for j in range(1,4):
            i=finger(f,j);direction=p0[finger(f,j+1)]-p0[i] if j<3 else p0[i]-p0[finger(f,j-1)]
            axis=q0[i].inverted()@direction.cross(P).normalized()
            delta=Quaternion(axis,math.radians(values[fi][j-1]))
            if fi==0 and j==1:
                axis=P.copy()
                if direction.cross(p0[finger('Index',1)]-p0[i]).dot(P)<0:axis=-axis
                delta=Quaternion(q0[i].inverted()@axis,math.radians(values[5]))@delta
            deltas[i]=delta
    pp=[];pq=[]
    for i,b in enumerate(bones):
        p=p0[i].copy();q=q0[i].copy()
        if i:
            par=b[3];p=pp[par]+pq[par]@(q0[par].inverted()@(p0[i]-p0[par]));q=pq[par]@(q0[par].inverted()@q0[i])
        if i in deltas:q=q@deltas[i]
        pp.append(p);pq.append(q)
    skin=[]
    for i,v in enumerate(points):
        p=Vector()
        for bone,weight in weights[i].items():p+=weight*(pp[bone]+pq[bone]@(q0[bone].inverted()@(Vector(v)-p0[bone])))
        skin.append(frame@(p-p0[wrist]))
    tris=[[wedges[w][0] for w in reversed(face[:3])] for face in faces if max(weights[wedges[face[0]][0]],key=weights[wedges[face[0]][0]].get) in members]
    if frame.determinant()<0:tris=[t[::-1] for t in tris]
    groups={f:[i for i in range(len(points)) if sum(weights[i].get(finger(f,j),0) for j in range(1,4))>.8] for f in DIGITS}
    tips={f:[i for i in groups[f] if weights[i].get(finger(f,3),0)>.8] for f in DIGITS}
    return dict(vertices=skin,triangles=tris,groups=groups,tips=tips,Y=frame@(T.cross(F)),deltas=[deltas[finger(f,j)] for f in DIGITS for j in range(1,4)],joints={names[i]:list(frame@(pp[i]-p0[wrist])) for i in deltas})

def grenade(mesh, h, offset):
    scale=5.699153/13.671265 if mesh['label']=='EMP' else 1
    center=CENTERS.get(mesh['label'],(0,0,0));Y=h['Y']
    v=[Vector(offset)+Vector((x-center[0],z-center[2],0))*scale+Y*(y-center[1])*scale for x,y,z in mesh['vertices']]
    t=mesh['triangles'];volume=sum(v[a].dot(v[b].cross(v[c])) for a,b,c in t)/6
    if volume<0:t=[x[::-1] for x in t]
    return v,t

def contacts(h,v,t):
    # Stock grenades contain open seams and overlapping hardware. The nearest
    # triangle normal gives a local side diagnostic, not a reliable inside/
    # outside volume test. Pair counts include intended surface contact and
    # must not be interpreted as penetration depth or headset acceptance.
    bvh=BVHTree.FromPolygons(v,t,all_triangles=True);result={}
    for f,ids in h['groups'].items():
        distances=[];tips=[]
        for i in ids:
            loc,n,_,d=bvh.find_nearest(h['vertices'][i]);signed=-d if (h['vertices'][i]-loc).dot(n)<0 else d
            distances.append(signed)
            if i in h['tips'][f]:tips.append(signed)
        result[f]=dict(nearest=min(abs(d) for d in distances),nearest_normal_side_min=min(distances),tip_normal_side_min=min(tips),tip_normal_side_max=max(tips),negative_normal_side_fraction=sum(d<-.1 for d in distances)/len(distances))
    overlaps=BVHTree.FromPolygons(h['vertices'],h['triangles'],all_triangles=True).overlap(bvh)
    return dict(fingers=result,intersecting_triangle_pairs=len(overlaps))

def inspect(root, hand_path, output, *, build_scene=False, emit_runtime=False):
    root,output=Path(root),Path(output);output.mkdir(parents=True,exist_ok=True)
    meshes=json.loads((output/'meshes.json').read_text());meshes=[m for m in meshes if m['name']!='Wep_M84_Pickup']
    ctx=context(root,hand_path);report=[]
    if build_scene:
        import bpy
        scene=bpy.data.scenes.new('KF2 Authored grenade review')
    for side in ('Left','Right'):
        old=hand(ctx,side,BASELINE)
        for k,m in enumerate(meshes):
            profile,offset=SHAPES[m['label']];h=hand(ctx,side,PROFILES[profile]);v,t=grenade(m,h,offset);bv,bt=grenade(m,old,(8.5,0,3))
            report.append(dict(side=side,shape=m['label'],profile=profile,offset=offset,before=contacts(old,bv,bt),after=contacts(h,v,t),joints=h['joints']))
            if build_scene:
                shift=Vector((k%3*40+(125 if side=='Left' else 0),k//3*42,0))
                for label,verts,tris,color in [('hand',h['vertices'],h['triangles'],(.42,.3,.22)),('grenade',v,t,(.15,.32,.14))]:
                    mesh=bpy.data.meshes.new(side+m['label']+label);mesh.from_pydata(verts,[],tris);mesh.update();o=bpy.data.objects.new(mesh.name,mesh);scene.collection.objects.link(o);o.location=shift
                    mat=bpy.data.materials.new(o.name+'mat');mat.diffuse_color=(*color,1);mat.use_nodes=True;mat.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=(*color,1);mesh.materials.append(mat)
                    for p in mesh.polygons:p.use_smooth=True
    (output/'comparison.json').write_text(json.dumps(report,indent=2))
    import hashlib
    metadata=dict(hand_psk=str(hand_path),hand_psk_sha256=hashlib.sha256(Path(hand_path).read_bytes()).hexdigest(),
                  authored_profiles=PROFILES,shape_placement=SHAPES,
                  checks='18 actual mesh/hand combinations; fixed unit quaternions; CPU linear skinning/BVH',
                  limits='Nonzero triangle-pair intersections include contact and residual clipping; nearest-normal-side values do not establish solid penetration depth. Engine render and headset untested.')
    (output/'authoring.json').write_text(json.dumps(metadata,indent=2))
    print([(r['side'],r['shape'],r['before']['intersecting_triangle_pairs'],r['after']['intersecting_triangle_pairs']) for r in report])
    return ctx,report





def emit_runtime(root, ctx):
    """Export the reviewed local rotations; no geometry-dependent runtime code."""
    names=list(PROFILES)
    # Keep one table per actual grip family, including both anatomical hands.
    names=[n for n in names if n in {s[0] for s in SHAPES.values()}]
    text=['// Authored grenade presentation only. Generated by tools/author_grenade_grips.py.',
          '// Fixed local rotations on the existing floating-hand rig; no contact solver.',
          '// Order: profile, Left/Right, Thumb/Index/Middle/Ring/Pinky, joints 1..3.',
          'class VRGrenadeGripPose extends Object;', '', 'var array<quat> Rotations;', '',
          'static function int ProfileFor(name ProjectileClass)', '{', '    switch (ProjectileClass)', '    {']
    for shape,(profile,_) in SHAPES.items():
        text.append("        case 'KFProj_%sGrenade': return %d;"%(shape,names.index(profile)))
    text+=['    }','    return -1;','}','',
           '// X toward fingertips, Y toward thumb, Z out of palm, in UU.',
           '// This is a visual offset; grab anchors and launch positions remain stock.',
           'static function vector HeldOffset(name ProjectileClass)', '{', '    switch (ProjectileClass)', '    {']
    for shape,(_,offset) in SHAPES.items():
        text.append("        case 'KFProj_%sGrenade': return vect(%s);"%(shape,','.join(str(x) for x in offset)))
    text+=['    }','    return vect(8.5,0,3);','}','',
           'static function bool Read(int Profile, int Hand, int Joint, out quat Rotation)', '{',
           '    local int Index;',
           '    if (Profile < 0 || Hand < 0 || Hand > 1 || Joint < 0 || Joint >= 15) return false;',
           '    Index = Profile * 30 + Hand * 15 + Joint;',
           '    if (Index >= default.Rotations.Length) return false;',
           '    Rotation = default.Rotations[Index];',
           "    return class'VRHandRolePose'.static.ValidQuaternion(Rotation);",'}','','defaultproperties','{']
    index=0
    for profile in names:
        text.append('    // '+profile)
        for side in ('Left','Right'):
            h=hand(ctx,side,PROFILES[profile])
            for q in h['deltas']:
                assert abs(q.magnitude-1)<.00001
                text.append('    Rotations(%d)=(X=%.9f,Y=%.9f,Z=%.9f,W=%.9f)'%(index,q.x,q.y,q.z,q.w));index+=1
    text+=['}','']
    (Path(root)/'script/KF2VR/Classes/VRGrenadeGripPose.uc').write_text('\n'.join(text))
    return index

def render_cpu(scene, output, side):
    """Bounded offline review render; never changes the active UI scene or GPU."""
    import bpy
    output=Path(output)
    shift=125 if side=='Left' else 0
    camera=bpy.data.objects.new(scene.name+' camera',bpy.data.cameras.new(scene.name+' camera'))
    scene.collection.objects.link(camera);scene.camera=camera;camera.data.type='ORTHO';camera.data.ortho_scale=118
    target=Vector((49+shift,42,0));camera.location=target+Vector((25,-18,140))
    direction=(target-camera.location).normalized()
    right=Vector((1,0,0))-direction*direction.x
    right.normalize()
    up=right.cross(direction).normalized()
    camera.rotation_euler=Matrix((right,up,-direction)).transposed().to_quaternion().to_euler()
    for n,location in enumerate([(30+shift,-40,90),(50+shift,70,100)]):
        light=bpy.data.objects.new(scene.name+' light '+str(n),bpy.data.lights.new(scene.name+' light '+str(n),'AREA'))
        scene.collection.objects.link(light);light.location=location;light.data.energy=25000;light.data.shape='DISK';light.data.size=80
        light.rotation_euler=(target-light.location).to_track_quat('-Z','Y').to_euler()
    scene.world=bpy.data.worlds.new(scene.name+' world');scene.world.color=(.15,.15,.15)
    scene.render.engine='CYCLES';scene.cycles.device='CPU';scene.cycles.samples=12;scene.cycles.use_denoising=False
    scene.render.threads_mode='FIXED';scene.render.threads=6
    scene.render.resolution_x=1100;scene.render.resolution_y=1300;scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG';scene.render.filepath=str(output)
    bpy.ops.render.render(write_still=True,scene=scene.name)
    return str(output)

if __name__=='__main__':
    import argparse,sys
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--hand',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--scene',action='store_true')
    p.add_argument('--emit-runtime',action='store_true')
    argv=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else sys.argv[1:]
    args=p.parse_args(argv);root=Path(__file__).resolve().parents[1]
    ctx,_=inspect(root,args.hand,args.output,build_scene=args.scene)
    if args.emit_runtime:print('Exported',emit_runtime(root,ctx),'fixed local quaternions')
