"""Bake the approved Blender study into local game assets, preserving full KF2 rig.

Input: KF2VR-Horzine-Hands.blend. Output stays in ignored build/; originals are
not overwritten by this script. The caller promotes only after inspection.
"""
import bpy, bmesh, runpy, struct, json, math, hashlib, os
from pathlib import Path
from mathutils import Vector, Matrix
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(os.environ.get('KF2VR_ART_EXPORT_DIR',str(ROOT/'build/hand-redesign-20260924/runtime')))
OUT.mkdir(parents=True,exist_ok=True)
revision=int(os.environ.get('KF2VR_ART_REVISION','7'))
authoring_file=Path(bpy.data.filepath)
source=bpy.data.scenes[f'Horzine reference rebuild {revision:02d}']
bpy.context.window.scene=source
g=runpy.run_path(str(ROOT/'tools/generate_floating_hands.py'),run_name='asset_source')
calibrate=runpy.run_path(str(ROOT/'tools/calibrate_reference_materials.py'))['calibrate']
c=g['read_psk'](ROOT/'extract/arms-audit/CHR_1P_Arms_MESH/SkeletalMesh3/Wep_1stP_Naked_Hands_Rig.psk')
bones,names=g['bone_data'](c);bind=g['bind_positions'](bones)
def hand_frame(side):
    wrist=names.index(side+'Hand_1stP')
    f=(bind[names.index(side+'HandMiddle1_1stP')]-bind[wrist]).normalized()
    t=bind[names.index(side+'HandIndex1_1stP')]-bind[names.index(side+'HandPinky1_1stP')]
    t=(t-f*t.dot(f)).normalized();d=f.cross(t).normalized()*(1 if side=='Right' else -1)
    return Matrix((f,-t if revision>=59 else t,d)).transposed(),bind[wrist]
def is_watch(ob):return ob.name.startswith(('Watch |','UI ','UI |','Case |','Horzine ','ID plate','Conduit |','Cuff |','Buckle ','Folded webbing'))

# Use the evaluated weighted right-hand study, mirrored back into the canonical
# left authoring frame, to retain the exact sculpt attributes and skin weights.
pose=bpy.data.scenes[f'Horzine pose review {revision:02d}'];pose.frame_set(1)
right=next(o for o in pose.objects if o.name.startswith('Right | complete'))
hand=right.copy();hand.data=right.data.copy();hand.name='Runtime hand';hand.modifiers.clear()
hand.animation_data_clear();hand.parent=None;hand.location=(0,0,0);hand.rotation_euler=(0,0,0);hand.scale=(1,1,1)
source.collection.objects.link(hand)
for v in hand.data.vertices:v.co.y=-v.co.y
bm=bmesh.new();bm.from_mesh(hand.data);bmesh.ops.reverse_faces(bm,faces=list(bm.faces));bm.to_mesh(hand.data);bm.free()
for vg in hand.vertex_groups:vg.name=vg.name.replace('Right','Left')

# Merge mechanical parts after evaluation, without any static telemetry.
verts=[];polys=[];uvs=[];mats=[];mi=[];attrs={k:[] for k in ['ContactWear','DriedBlood','HealedScar']}
dg=bpy.context.evaluated_depsgraph_get()
for ob in list(source.objects):
    if not is_watch(ob) or ob.name.startswith(('UI ','UI |')) or ob.type not in {'MESH','CURVE','FONT'}:continue
    ev=ob.evaluated_get(dg);me=ev.to_mesh();start=len(verts)
    verts.extend([ob.matrix_world@v.co for v in me.vertices])
    for k,values in attrs.items():
        a=me.attributes.get(k);values.extend(a.data[i].value if a else 0 for i in range(len(me.vertices)))
    slots=[]
    for ma in me.materials:
        ma=ma.original
        if ma not in mats:mats.append(ma)
        slots.append(mats.index(ma))
    for p in me.polygons:polys.append(tuple(start+i for i in p.vertices));mi.append(slots[p.material_index])
    ev.to_mesh_clear()
me=bpy.data.meshes.new('Runtime watch');me.from_pydata(verts,[],polys);me.update()
watch=bpy.data.objects.new('Runtime watch',me);source.collection.objects.link(watch)
for ma in mats:me.materials.append(ma)
for p,i in zip(me.polygons,mi):p.material_index=i;p.use_smooth=True
for k,values in attrs.items():
    a=me.attributes.new(k,'FLOAT','POINT')
    for t,v in zip(a.data,values):t.value=v

scene=bpy.data.scenes.new('Runtime baked asset inspection');bpy.context.window.scene=scene
scene.unit_settings.system='METRIC';scene.unit_settings.scale_length=.01
scene.world=source.world;scene.render.engine='CYCLES';scene.cycles.samples=8
scene.render.bake.margin=12;scene.render.bake.use_clear=True
for ob in [hand,watch]:source.collection.objects.unlink(ob);scene.collection.objects.link(ob)
for old in source.objects:
    if old.type in {'LIGHT','CAMERA'}:
        ob=old.copy();ob.data=old.data.copy();scene.collection.objects.link(ob)
        if old==source.camera:scene.camera=ob

report={}
for ob,label,target in [(hand,'VRHorzineHands',18000),(watch,'VRHorzineWatch',14000 if revision>=21 else 10000)]:
    high=None
    if (revision>=21 and label=='VRHorzineHands') or (revision>=27 and label=='VRHorzineWatch'):
        # Preserve the sculpt's scar/crease relief in the runtime normal map.
        # Baking only after decimation flattened the high-resolution sculpt.
        high=ob.copy();high.data=ob.data.copy();high.name='Bake-only high resolution '+label
        scene.collection.objects.link(high);high.hide_render=True
    bpy.ops.object.select_all(action='DESELECT');ob.select_set(True);bpy.context.view_layer.objects.active=ob
    ob.data.calc_loop_triangles();before=len(ob.data.loop_triangles)
    dec=ob.modifiers.new('Runtime polygon budget','DECIMATE');dec.ratio=min(1,target/before)
    bpy.ops.object.modifier_apply(modifier=dec.name)
    # Bind existing image samplers explicitly to the original skin UVs before
    # adding an atlas. Procedural wear is baked from the sculpt attributes.
    original_uv=ob.data.uv_layers.active.name if ob.data.uv_layers.active else None
    materials=[]
    for i,ma in enumerate(list(ob.data.materials)):
        ma=ma.copy();ob.data.materials[i]=ma;materials.append(ma)
        if label=='VRHorzineHands':calibrate(ma)
        nt=ma.node_tree
        if original_uv:
            uv=nt.nodes.new('ShaderNodeUVMap');uv.uv_map=original_uv
            for n in list(nt.nodes):
                if n.type=='TEX_IMAGE' and not n.inputs['Vector'].is_linked:nt.links.new(uv.outputs[0],n.inputs['Vector'])
                if n.type=='NORMAL_MAP':n.uv_map=original_uv
    atlas=ob.data.uv_layers.new(name='RuntimeUV');ob.data.uv_layers.active=atlas
    bpy.ops.object.mode_set(mode='EDIT');bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(66),island_margin=.008)
    bpy.ops.object.mode_set(mode='OBJECT')
    baked={};original_outputs={}
    for ma in materials:
        nt=ma.node_tree;out=next(n for n in nt.nodes if n.type=='OUTPUT_MATERIAL')
        original_outputs[ma]=out.inputs['Surface'].links[0].from_socket
    for channel in ['D','N','S']:
        im=bpy.data.images.new(label+'_'+channel,2048,2048,alpha=False)
        if channel!='D':im.colorspace_settings.name='Non-Color'
        for ma in materials:
            nt=ma.node_tree;n=nt.nodes;out=next(x for x in n if x.type=='OUTPUT_MATERIAL')
            nt.links.new(original_outputs[ma],out.inputs['Surface'])
            shader=n.get('Principled BSDF')
            if channel in {'D','S'}:
                e=n.new('ShaderNodeEmission')
                if channel=='D':
                    if shader and shader.inputs['Base Color'].is_linked:nt.links.new(shader.inputs['Base Color'].links[0].from_socket,e.inputs['Color'])
                    elif shader:e.inputs['Color'].default_value=shader.inputs['Base Color'].default_value
                    else:e.inputs['Color'].default_value=(.1,.1,.1,1)
                    if revision>=21 and ma.name.startswith('Watch | oxidized gunmetal'):
                        tone=n.new('ShaderNodeMixRGB');tone.blend_type='MULTIPLY'
                        tone.inputs[0].default_value=1;tone.inputs[2].default_value=(.65,.65,.65,1)
                        nt.links.new(e.inputs['Color'].links[0].from_socket,tone.inputs[1])
                        nt.links.new(tone.outputs[0],e.inputs['Color'])
                    if 27<=revision<32 and label=='VRHorzineWatch':
                        # Keep short-range contact shadows under the plaque,
                        # hinge and socket lips when KF2's hand fill is frontal.
                        ao=n.new('ShaderNodeAmbientOcclusion');ao.inputs['Distance'].default_value=.24
                        ao.only_local=True;ao.samples=16
                        shade=n.new('ShaderNodeMixRGB');shade.blend_type='MULTIPLY';shade.inputs[0].default_value=.70
                        if e.inputs['Color'].is_linked:nt.links.new(e.inputs['Color'].links[0].from_socket,shade.inputs[1])
                        else:shade.inputs[1].default_value=e.inputs['Color'].default_value
                        nt.links.new(ao.outputs['Color'],shade.inputs[2]);nt.links.new(shade.outputs[0],e.inputs['Color'])
                else:
                    # UE3 specular mask: polished metal stronger than worn leather.
                    metal=shader.inputs['Metallic'].default_value if shader else 0
                    e.inputs['Color'].default_value=(.045+metal*.5,)*3+(1,)
                    if label=='VRHorzineHands' and ma.name.startswith('Glove |'):
                        wear=n.new('ShaderNodeAttribute');wear.attribute_name='ContactWear'
                        spec=n.new('ShaderNodeMapRange');spec.inputs['To Min'].default_value=.012;spec.inputs['To Max'].default_value=.085
                        nt.links.new(wear.outputs['Fac'],spec.inputs['Value']);nt.links.new(spec.outputs[0],e.inputs['Color'])
                nt.links.new(e.outputs[0],out.inputs['Surface'])
            tex=n.new('ShaderNodeTexImage');tex.image=im;n.active=tex;tex.select=True
        if channel=='N' and high:
            import numpy as np
            # Keep a safe local-material normal as the fallback where the cage
            # projects onto another leather layer or across the open cut edge.
            bpy.ops.object.bake(type='NORMAL',uv_layer='RuntimeUV',normal_space='TANGENT',use_selected_to_active=False)
            baseline=np.empty(len(im.pixels),dtype=np.float32);im.pixels.foreach_get(baseline)
            high.hide_render=False;high.select_set(True);ob.select_set(True)
            bpy.context.view_layer.objects.active=ob
            bpy.ops.object.bake(type='NORMAL',uv_layer='RuntimeUV',normal_space='TANGENT',
                                use_selected_to_active=True,
                                cage_extrusion=.08 if label=='VRHorzineWatch' else .25,
                                max_ray_distance=.18 if label=='VRHorzineWatch' else .6)
            high.select_set(False);high.hide_render=True
            projected=np.empty(len(im.pixels),dtype=np.float32);im.pixels.foreach_get(projected)
            low=baseline.reshape(-1,4)[:,:3]*2-1;hi=projected.reshape(-1,4)[:,:3]*2-1
            low/=np.maximum(np.linalg.norm(low,axis=1,keepdims=True),1e-6)
            hi/=np.maximum(np.linalg.norm(hi,axis=1,keepdims=True),1e-6)
            confidence=np.clip((np.sum(low*hi,axis=1)-.76)/.18,0,1)[:,None]
            normal=low*(1-confidence)+hi*confidence
            normal/=np.maximum(np.linalg.norm(normal,axis=1,keepdims=True),1e-6)
            projected.reshape(-1,4)[:,:3]=normal*.5+.5
            im.pixels.foreach_set(projected)
        else:
            bpy.ops.object.bake(type='NORMAL' if channel=='N' else 'EMIT',uv_layer='RuntimeUV',normal_space='TANGENT',use_selected_to_active=False)
        im.filepath_raw=str(OUT/(label+'_'+channel+'.tga'));im.file_format='TARGA'
        if channel=='N':
            # UE3 uses DirectX tangent normals. Keep the Blender preview's
            # OpenGL pixels packed; write flipped green only to the game TGA.
            import numpy as np
            pixels=np.empty(len(im.pixels),dtype=np.float32);im.pixels.foreach_get(pixels)
            if label=='VRHorzineHands':
                strength=.65 if revision>=21 else .45
                pixels[0::4]=(pixels[0::4]-.5)*strength+.5
                pixels[1::4]=(pixels[1::4]-.5)*strength+.5
                pixels[2::4]=(np.sqrt(np.maximum(0,1-(pixels[0::4]*2-1)**2-(pixels[1::4]*2-1)**2))+1)*.5
            directx=pixels.copy();directx[1::4]=1-directx[1::4];im.pixels.foreach_set(directx);im.save()
            im.pixels.foreach_set(pixels);im.pack()
        else:im.save();im.pack()
        baked[channel]=im
        print('BAKED',label,channel,flush=True)
    # Replace all procedural slots with one baked material and one runtime UV.
    ma=bpy.data.materials.new(label);ma.use_nodes=True;nt=ma.node_tree;shader=nt.nodes.get('Principled BSDF')
    for channel in ['D','N','S']:
        t=nt.nodes.new('ShaderNodeTexImage');t.image=baked[channel]
        if channel=='D':nt.links.new(t.outputs['Color'],shader.inputs['Base Color'])
        elif channel=='N':
            n=nt.nodes.new('ShaderNodeNormalMap');nt.links.new(t.outputs['Color'],n.inputs['Color']);nt.links.new(n.outputs[0],shader.inputs['Normal'])
    shader.inputs['Roughness'].default_value=.63 if label=='VRHorzineHands' else .48
    ob.data.materials.clear();ob.data.materials.append(ma)
    for p in ob.data.polygons:p.material_index=0
    for uv in list(ob.data.uv_layers):
        if uv.name!='RuntimeUV':ob.data.uv_layers.remove(uv)
    ob.data.uv_layers.active=ob.data.uv_layers['RuntimeUV'];ob.data.uv_layers.active.active_render=True
    ob.data.calc_loop_triangles()
    report[label]={'source_triangles':before,'triangles':len(ob.data.loop_triangles),'vertices':len(ob.data.vertices)}
    if high:bpy.data.objects.remove(high,do_unlink=True)

# Save canonical baked geometry for independent visual inspection.
scene.render.resolution_x=1600;scene.render.resolution_y=1050;scene.render.resolution_percentage=100
scene.cycles.samples=32;scene.view_settings.view_transform='AgX'
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'Horzine-runtime-baked.blend'))

# Emit PSK with the untouched 43-bone (or actual source count) hierarchy and
# both bind-space hands. Deduplicated UV wedges stay within ActorX's 16-bit limit.
points=[];wedges=[];faces=[];weights=[];lookup={}
hand.data.calc_loop_triangles();uv=hand.data.uv_layers.active
for side in ['Left','Right']:
    frame,origin=hand_frame(side);base=len(points)
    for v in hand.data.vertices:
        p=frame@v.co+origin;points.append(struct.pack('<3f',*p))
        ws=[(names.index(hand.vertex_groups[a.group].name.replace('Left',side)),a.weight) for a in v.groups if a.weight>.001]
        ws=sorted(ws,key=lambda x:-x[1])[:4]
        if not ws:ws=[(names.index(side+'Hand_1stP'),1)]
        total=sum(w for _,w in ws)
        weights.extend(g['WEIGHT'].pack(w/total,base+v.index,b) for b,w in ws)
    for tri in hand.data.loop_triangles:
        ids=[]
        # ActorX stores clockwise triangles. Convert Blender's CCW order after
        # accounting for the authoring-to-bind reflection. Omitting this final
        # convention change exports both hands inside out and UE3 culls skin.
        loops=list(tri.loops)
        if frame.determinant()>0:loops.reverse()
        for li in loops:
            vi=base+hand.data.loops[li].vertex_index;u,v=uv.data[li].uv
            key=(vi,round(u,7),round(v,7))
            if key not in lookup:lookup[key]=len(wedges);wedges.append(g['WEDGE'].pack(vi,u,1-v,0,0,0))
            ids.append(lookup[key])
        faces.append(g['FACE'].pack(*ids,0,0,1))
assert len(wedges)<65536, len(wedges)
for key,rows in [('PNTS0000',points),('VTXW0000',wedges),('FACE0000',faces),('RAWWEIGHTS',weights)]:
    old=c[key];c[key]=g['Chunk'](key,old.kind,old.size,rows)
c['MATT0000'].rows=c['MATT0000'].rows[:1]
psk=OUT/'VRFloatingHands.psk';psk.write_bytes(b''.join(chunk.encode() for chunk in c.values()))
report.update(g['export_fbx'](psk,OUT/'VRFloatingHands.fbx'))

# Export the same mechanical assembly in the live watch's screen-local frame.
bpy.context.window.scene=scene
bpy.ops.object.select_all(action='DESELECT');watch.select_set(True);bpy.context.view_layer.objects.active=watch
for v in watch.data.vertices:
    x,y,z=v.co;v.co=(3.72-z,-(x+3.9) if revision>=21 else x+3.9,y)
# UE3's static FBX import reflects the screen's horizontal axis. Correct the
# geometry, UVs and winding together; otherwise the maker mark reads backwards
# below the left pane even while the separately rendered Canvas reads normally.
if revision<21:
    bm=bmesh.new();bm.from_mesh(watch.data);bmesh.ops.reverse_faces(bm,faces=list(bm.faces));bm.to_mesh(watch.data);bm.free()
bpy.ops.export_scene.fbx(filepath=str(OUT/'VRWristwatch.fbx'),use_selection=True,object_types={'MESH'},global_scale=1,apply_unit_scale=True,apply_scale_options='FBX_SCALE_UNITS',axis_forward='-X',axis_up='Z',bake_anim=False,mesh_smooth_type='FACE',path_mode='STRIP')
report.update({'skeleton_records_preserved':True,'skeleton_bones':len(bones),'texture_size':2048,'hands_uv_wedges':len(wedges),'watch_screen_size':list(source.get('display_size_cm',[10.24,5.12])),'concept_revision':revision,'game_acceptance':False})
(OUT/'asset-report.json').write_text(json.dumps(report,indent=2))
print('RUNTIME_EXPORT_READY',report,flush=True)

def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def authoring_dependency(name):
    archived=authoring_file.parent/'source'/name
    return archived if archived.exists() else ROOT/'tools'/name
source_psk=ROOT/'extract/arms-audit/CHR_1P_Arms_MESH/SkeletalMesh3/Wep_1stP_Naked_Hands_Rig.psk'
receipt=dict(report,generator_relative='tools/export_reference_hands.py',generator_sha256=digest(__file__),
             source=str(source_psk),source_sha256=digest(source_psk),fbx_sha256=digest(OUT/'VRFloatingHands.fbx'),
             dependencies_sha256={str(p.relative_to(ROOT)).replace('\\','/'):digest(p) for p in
                [ROOT/'tools/generate_floating_hands.py',ROOT/'tools/calibrate_reference_materials.py',
                 authoring_dependency('build_reference_hands.py'),authoring_dependency('refine_reference_shapes.py'),authoring_file]})
if revision>=27:
    path=authoring_dependency('refine_watch_detail.py')
    receipt['dependencies_sha256'][str(path.relative_to(ROOT)).replace('\\','/')]=digest(path)
(OUT/'VRFloatingHands.json').write_text(json.dumps(receipt,indent=2))
