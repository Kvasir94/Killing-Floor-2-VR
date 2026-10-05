"""Blender audit of empty-hand rest/curl using the locally generated KF2 mesh.

Reads ignored game-derived PSK input and writes only ignored build artifacts.
No mesh or animation package is modified. Curl values and anatomical axes match
VRFreeHandPose; this visual/mesh audit does not prove the engine controller ABI.
"""
from pathlib import Path
import bpy, runpy, json, math
from mathutils import Quaternion, Vector, Matrix
from mathutils.bvhtree import BVHTree

root = Path(__file__).resolve().parents[1]
(root/'build/dual-foundation').mkdir(parents=True, exist_ok=True)
g = runpy.run_path(str(root/'tools/generate_floating_hands.py'), run_name='free_hand_audit')
c = g['read_psk'](root/'build/hand-meshes/VRFloatingHands.psk')
bones, names = g['bone_data'](c)
points, wedges, faces, weights = g['decode_geometry'](c)
positions, rotations = [], []
for i,b in enumerate(bones):
    q=Quaternion((b[7],b[4],b[5],b[6]))
    p=Vector(b[8:11])
    if i:
        p=positions[b[3]] + rotations[b[3]] @ p
        q=rotations[b[3]] @ q.conjugated()
    positions.append(p); rotations.append(q)

scene=bpy.data.scenes.new('Free hand pose audit')
bpy.context.window.scene=scene
report=[]
for side,x in [('Left',-15),('Right',15)]:
    wrist=names.index(side+'Hand_1stP')
    finger=lambda f,n:names.index(side+'Hand'+f+str(n)+'_1stP')
    fwd=(positions[finger('Middle',1)]-positions[wrist]).normalized()
    thumb=(positions[finger('Index',1)]-positions[finger('Pinky',1)])
    thumb=(thumb-fwd*thumb.dot(fwd)).normalized()
    palm=fwd.cross(thumb).normalized() * (1 if side=='Left' else -1)
    across=thumb
    axes={}; angles={}; extra={}
    for fi,f in enumerate(['Thumb','Index','Middle','Ring','Pinky']):
        for joint in range(1,4):
            i=finger(f,joint)
            direction=(positions[finger(f,joint+1)]-positions[i]) if joint<3 else (positions[i]-positions[finger(f,joint-1)])
            target=palm
            axis=direction.cross(target).normalized()
            axes[i]=rotations[i].inverted() @ axis
            angles[i]=([55,-45,-15] if f=='Thumb' else [40+(fi-1)*4,45,25])[joint-1]
            if f=='Thumb' and joint==1:
                opposition=palm.copy()
                if direction.cross(positions[finger('Index',1)]-positions[i]).dot(palm)<0: opposition=-opposition
                extra[i]=(rotations[i].inverted() @ opposition,45)
        a=(positions[finger(f,2)]-positions[finger(f,1)]).normalized()
        b=(positions[finger(f,3)]-positions[finger(f,2)]).normalized()
        report.append({'side':side,'finger':f,'rest_joint_angle':math.degrees(a.angle(b)),'curl_toward_palm':(b-a*a.dot(b)).dot(palm)})
    members=g['descendants'](bones,wrist)
    for amount,row in [(0,0),(.25,0),(.5,0),(.75,0),(1,27)]:
        pp=[]; pq=[]
        for i,b in enumerate(bones):
            if i:
                parent=b[3]
                lp=rotations[parent].inverted() @ (positions[i]-positions[parent])
                lq=rotations[parent].inverted() @ rotations[i]
                p=pp[parent]+pq[parent] @ lp
                q=pq[parent] @ lq
            else:p=positions[i].copy();q=rotations[i].copy()
            if i in axes:
                lift_amount=min(1,amount*1.8) if i in extra else amount
                delta=Quaternion(axes[i], math.radians(angles[i])*lift_amount)
                if i in extra:delta=Quaternion(extra[i][0],math.radians(extra[i][1])*amount) @ delta
                q=q @ delta
            pp.append(p);pq.append(q)
        posed=[]; include=[]
        for n,v in enumerate(points):
            if max(weights[n],key=weights[n].get) not in members:
                posed.append((0,0,0));continue
            include.append(n)
            p=Vector((0,0,0))
            for bone,weight in weights[n].items():
                p+=weight*(pp[bone]+pq[bone] @ (rotations[bone].inverted() @ (Vector(v)-positions[bone])))
            v=p-positions[wrist]
            posed.append((v.dot(across)+x,v.dot(fwd)+row,v.dot(palm)))
        mesh=bpy.data.meshes.new(f'{side}-{amount}')
        if side=='Right':
            report.append({'amount':amount,'positions':{names[i]:list(Matrix((across,fwd,palm))@(pp[i]-positions[wrist])) for i in axes}})
        selected=set(include)
        tris=[[wedges[w][0] for w in f[:3]] for f in faces if wedges[f[0]][0] in selected]
        thumb_ids={finger('Thumb',i) for i in [1,2,3]}
        thumb_weight=lambda n:sum(weights[n].get(b,0) for b in thumb_ids)
        thumb_tris=[t for t in tris if all(thumb_weight(n)>.8 for n in t)]
        other_tris=[t for t in tris if all(thumb_weight(n)<.2 for n in t)]
        collisions=BVHTree.FromPolygons(posed,thumb_tris,all_triangles=True).overlap(BVHTree.FromPolygons(posed,other_tris,all_triangles=True))
        groups={}
        for a,b in collisions:
            bone=max(weights[other_tris[b][0]],key=weights[other_tris[b][0]].get)
            groups[names[bone]]=groups.get(names[bone],0)+1
        report.append({'side':side,'amount':amount,'thumb_intersections':len(collisions),'with':groups})
        if amount not in [0,1]:continue
        mesh.from_pydata(posed,[],tris)
        ob=bpy.data.objects.new(mesh.name,mesh);scene.collection.objects.link(ob)
        ob.color=(0.60,0.39,0.26,1)
        for p in mesh.polygons:p.use_smooth=True
camera=bpy.data.objects.new('Pose review camera',bpy.data.cameras.new('Pose review camera'))
scene.collection.objects.link(camera)
target=Vector((0,21,0));camera.location=(36,-33,88)
camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
camera.data.type='ORTHO';camera.data.ortho_scale=69;scene.camera=camera
scene.render.engine='BLENDER_WORKBENCH'
scene.display.shading.light='STUDIO';scene.display.shading.color_type='OBJECT'
scene.display.shading.show_shadows=True;scene.display.shading.show_cavity=True
scene.display.shading.cavity_type='BOTH';scene.display.shading.background_type='WORLD'
scene.world=bpy.data.worlds.new('Pose audit world');scene.world.color=(0.025,0.025,0.025)
scene.render.resolution_x=1200;scene.render.resolution_y=1000;scene.render.resolution_percentage=100
scene.render.filepath=str(root/'build/dual-foundation/free-hands.png')
scene.render.image_settings.file_format='PNG'
bpy.ops.render.render(write_still=True)
(root/'build/dual-foundation/free-hand-anatomy.json').write_text(json.dumps(report,indent=2))
print(json.dumps([r for r in report if 'thumb_intersections' in r]))
