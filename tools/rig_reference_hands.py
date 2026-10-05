"""Build an independently poseable Blender pair from the current authoring scene.

The editable construction scenes stay intact. This evaluated presentation rig
uses the stock hand/finger bone names and sampled skin weights; it is not a
certified replacement for the game's complete skeletal hierarchy.
"""
import bpy, math, runpy, json
from pathlib import Path
from mathutils import Vector, Matrix, Quaternion
from mathutils.bvhtree import BVHTree
from mathutils.geometry import barycentric_transform
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/hand-redesign-20260924'
source=bpy.context.scene
revision=int(source.name.rsplit(' ',1)[-1])
source_objects=list(source.objects)
dg=bpy.context.evaluated_depsgraph_get()
g=runpy.run_path(str(ROOT/'tools/generate_floating_hands.py'),run_name='hand_rig_source')
c=g['read_psk'](ROOT/'extract/arms-audit/CHR_1P_Arms_MESH/SkeletalMesh3/Wep_1stP_Naked_Hands_Rig.psk')
c,_=g['cut_hands'](c,wrist_offset=-13)
bones,names=g['bone_data'](c);bind=g['bind_positions'](bones)
points,wedges,faces,weights=g['decode_geometry'](c)
wrist=names.index('LeftHand_1stP');members=g['descendants'](bones,wrist)
fwd=(bind[names.index('LeftHandMiddle1_1stP')]-bind[wrist]).normalized()
across=bind[names.index('LeftHandIndex1_1stP')]-bind[names.index('LeftHandPinky1_1stP')]
across=(across-fwd*across.dot(fwd)).normalized();dorsal=-fwd.cross(across).normalized()
frame=Matrix((fwd,-across if revision>=59 else across,dorsal))
bindlocal={i:frame@(bind[i]-bind[wrist]) for i in members}
selected=[i for i,p in enumerate(points) if max(weights[i],key=weights[i].get) in members]
skin_source=next(o for o in source_objects if o.name.startswith('LEFT | anatomical'))
skin_eval=skin_source.evaluated_get(dg);skin_mesh=skin_eval.to_mesh();skin_mesh.calc_loop_triangles()
skin_coords=[v.co.copy() for v in skin_mesh.vertices]
skin_tri=[tuple(t.vertices) for t in skin_mesh.loop_triangles]
skin_weights=[{names.index(skin_source.vertex_groups[g.group].name):g.weight for g in v.groups} for v in skin_mesh.vertices]
surface=BVHTree.FromPolygons(skin_coords,skin_tri,all_triangles=True)
skin_eval.to_mesh_clear()

scene=bpy.data.scenes.new(f'Horzine pose review {revision:02d}')
scene.world=source.world
scene.unit_settings.system='METRIC';scene.unit_settings.scale_length=.01
scene.render.engine='CYCLES';scene.cycles.samples=40;scene.cycles.use_denoising=True
scene.render.resolution_x=1600;scene.render.resolution_y=1100;scene.render.resolution_percentage=100
scene.view_settings.view_transform='AgX';scene.render.image_settings.file_format='PNG'
for o in source_objects:
    if o.type in {'CAMERA','LIGHT'}:
        cp=o.copy();cp.data=o.data.copy();scene.collection.objects.link(cp)
        if o==source.camera:scene.camera=cp

def is_watch(o):
    return o.name.startswith(('Watch |','UI ','UI |','Case |','Horzine ','ID plate','Conduit |','Cuff |','Buckle ','Folded webbing'))

def gather(right=False):
    verts=[];polys=[];mats=[];poly_mats=[];uvs=[];ranges=[];scar_values=[];wear_values=[];blood_values=[];authored_weights=[]
    for ob in source_objects:
        if ob.type not in {'MESH','CURVE','FONT'} or ob.name.startswith('Review |'):continue
        if right and is_watch(ob):continue
        ev=ob.evaluated_get(dg);me=ev.to_mesh();start=len(verts)
        scars=me.attributes.get('HealedScar')
        wear=me.attributes.get('ContactWear')
        blood=me.attributes.get('DriedBlood')
        for v in me.vertices:
            p=ob.matrix_world@v.co
            if right:p.y=-p.y
            verts.append(tuple(p))
            scar_values.append(scars.data[v.index].value if scars else 0)
            wear_values.append(wear.data[v.index].value if wear else 0)
            blood_values.append(blood.data[v.index].value if blood else 0)
            authored_weights.append({names.index(ob.vertex_groups[g.group].name):g.weight for g in v.groups} if len(ob.vertex_groups) else None)
        slots=[]
        for ma in me.materials:
            ma=ma.original
            if ma not in mats:mats.append(ma)
            slots.append(mats.index(ma))
        uv=me.uv_layers.active
        for p in me.polygons:
            ids=list(p.vertices);loops=list(p.loop_indices)
            if right:ids.reverse();loops.reverse()
            polys.append(tuple(start+i for i in ids));poly_mats.append(slots[p.material_index] if slots else 0)
            uvs.extend([tuple(uv.data[i].uv) if uv else (0,0) for i in loops])
        ranges.append((start,len(verts),is_watch(ob)))
        ev.to_mesh_clear()
    return verts,polys,mats,poly_mats,uvs,ranges,scar_values,wear_values,blood_values,authored_weights

# Evaluate geometry while the original scene owns the dependency graph.
left_data=gather();right_data=gather(True)
bpy.context.window.scene=scene
report={}
for side,data,mirror,offset in [('Left',left_data,1,8.3),('Right',right_data,-1,-8.3)]:
    verts,polys,mats,poly_mats,uvs,ranges,scar_values,wear_values,blood_values,authored_weights=data
    me=bpy.data.meshes.new(f'{side} Horzine surface');me.from_pydata(verts,[],polys);me.update()
    ob=bpy.data.objects.new(f'{side} | complete weighted assembly',me);scene.collection.objects.link(ob);ob.location.y=offset
    scars=me.attributes.new('HealedScar','FLOAT','POINT')
    for a,value in zip(scars.data,scar_values):a.value=value
    wear=me.attributes.new('ContactWear','FLOAT','POINT')
    for a,value in zip(wear.data,wear_values):a.value=value
    blood=me.attributes.new('DriedBlood','FLOAT','POINT')
    for a,value in zip(blood.data,blood_values):a.value=value
    for ma in mats:me.materials.append(ma)
    uv=me.uv_layers.new(name='AuthoringUV')
    for item,value in zip(uv.data,uvs):item.uv=value
    for p,mi in zip(me.polygons,poly_mats):p.material_index=mi;p.use_smooth=True
    ad=bpy.data.armatures.new(side+' authored hand rig');rig=bpy.data.objects.new(side+' | finger rig',ad)
    scene.collection.objects.link(rig);rig.location.y=offset
    bpy.ops.object.select_all(action='DESELECT');rig.select_set(True);bpy.context.view_layer.objects.active=rig
    bpy.ops.object.mode_set(mode='EDIT')
    def pos(i):
        p=bindlocal[i].copy();p.y*=mirror;return p
    for i in sorted(members):
        name=names[i].replace('Left',side);eb=ad.edit_bones.new(name);eb.head=pos(i)
        child=next((j for j in members if bones[j][3]==i),None)
        if child is not None:eb.tail=pos(child)
        else:eb.tail=pos(i)+(pos(i)-pos(bones[i][3]))*.72
        if bones[i][3] in members:eb.parent=ad.edit_bones[names[bones[i][3]].replace('Left',side)]
    bpy.ops.object.mode_set(mode='OBJECT')
    vg={i:ob.vertex_groups.new(name=names[i].replace('Left',side)) for i in members}
    rigid=set()
    for a,b,fixed in ranges:
        if fixed:rigid.update(range(a,b))
    for v in me.vertices:
        if v.index in rigid or v.co.x<.3:
            vg[wrist].add([v.index],1,'REPLACE');continue
        p=v.co.copy();p.y*=mirror;acc=authored_weights[v.index]
        if not acc:
            co,_,face_index,_=surface.find_nearest(p)
            ids=skin_tri[face_index]
            facs=barycentric_transform(co,*(skin_coords[i] for i in ids),Vector((1,0,0)),Vector((0,1,0)),Vector((0,0,1)))
            acc={}
            for i,fac in zip(ids,facs):
                for bi,w in skin_weights[i].items():acc[bi]=acc.get(bi,0)+max(0,fac)*w
        total=sum(acc.values())
        for bi,w in acc.items():
            if bi in vg and w/total>.00001:vg[bi].add([v.index],w/total,'REPLACE')
    mod=ob.modifiers.new('Anatomical finger articulation','ARMATURE');mod.object=rig
    # Reference-pose, open-hand and grip keys remain inspectable in Blender.
    for frame_number,amount,label in [(1,0,'RELAXED'),(20,-.70,'OPEN'),(40,.75,'GRIP')]:
        scene.frame_set(frame_number)
        for fi,finger in enumerate(['Thumb','Index','Middle','Ring','Pinky']):
            for joint in range(1,4):
                i=names.index('LeftHand'+finger+str(joint)+'_1stP')
                direction=pos(i+1)-pos(i) if joint<3 else pos(i)-pos(i-1)
                axis=direction.cross(Vector((0,0,-1))).normalized()
                pb=rig.pose.bones[names[i].replace('Left',side)]
                axis_local=pb.bone.matrix_local.to_3x3().inverted()@axis
                angles=([30,30,15] if finger=='Thumb' else [40+(fi-1)*4,45,25])
                pb.rotation_mode='QUATERNION';pb.rotation_quaternion=Quaternion(axis_local,math.radians(angles[joint-1])*amount)
                pb.keyframe_insert(data_path='rotation_quaternion',frame=frame_number,group=finger)
        if side=='Left':scene.timeline_markers.new(label,frame=frame_number)
    report[side]={'vertices':len(verts),'polygons':len(polys),'materials':len(mats),'bones':len(members)}
scene.frame_start=1;scene.frame_end=40;scene.frame_set(1)
scene['status']='Blender authoring rig. Game hierarchy/material baking/acceptance pending.'
scene.camera.location=(8,-48,66);scene.camera.rotation_euler=(-scene.camera.location).to_track_quat('-Z','Y').to_euler();scene.camera.data.ortho_scale=43
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/f'{revision:02d}-horzine-rigged-pair.blend'),copy=True)
if revision == 7:
    for font in bpy.data.fonts:
        if font.filepath and font.filepath!='<builtin>':
            try:font.pack()
            except RuntimeError:pass
    bpy.data.libraries.write(str(OUT/'KF2VR-Horzine-Hands.blend'),{source,scene},fake_user=True,compress=True)
(OUT/f'{revision:02d}-rig.json').write_text(json.dumps(report,indent=2))
print('RIGGED_PAIR_READY',report)
