"""Comparable renders of the actual exported and baked watch asset."""
import bpy,os,json,runpy
from pathlib import Path
from mathutils import Vector,Matrix
from mathutils.kdtree import KDTree

OUT=Path(__file__).resolve().parents[1]/'build/watch-detail-20260924'/os.environ['KF2VR_ART_REVISION']
s=bpy.context.scene
surface_report=OUT/'runtime/hand-surface-report.json'
if surface_report.exists() and json.loads(surface_report.read_text()).get('uv_repack'):
    old_hand=next(o for o in s.objects if o.name=='Runtime hand');material=old_hand.data.materials[0]
    hand,hand_check=runpy.run_path(str(Path(__file__).resolve().parent/'load_runtime_hand_context.py'))['load_left_hand'](OUT/'runtime/VRFloatingHands.fbx',s)
    tree=KDTree(len(old_hand.data.vertices))
    for v in old_hand.data.vertices:tree.insert(v.co,v.index)
    tree.balance();hand_check['max_surface_position_error_cm']=max(tree.find(v.co)[2] for v in hand.data.vertices)
    source_uv=old_hand.data.uv_layers['RuntimeUV'];source_corners={}
    for loop in old_hand.data.loops:source_corners.setdefault(loop.vertex_index,[]).append(source_uv.data[loop.index].uv.copy())
    errors=[];uv=hand.data.uv_layers.active
    for loop in hand.data.loops:
        matches=[u for point,index,distance in tree.find_range(hand.data.vertices[loop.vertex_index].co,.0001) for u in source_corners.get(index,[])]
        errors.append(min((u-uv.data[loop.index].uv).length for u in matches))
    hand_check['max_uv_error']=max(errors)
    hand_check['passed']=hand_check['max_surface_position_error_cm']<.0001 and max(errors)<.00001
    (OUT/'runtime/hand-fbx-roundtrip.json').write_text(json.dumps(hand_check,indent=2))
    if not hand_check['passed']:raise RuntimeError('Hand FBX surface changed: '+str(hand_check))
    hand.data.materials.clear();hand.data.materials.append(material)
    bpy.data.objects.remove(old_hand,do_unlink=True);hand.name='Runtime hand'
# Verify and render the actual FBX after import, including its exported normals
# and UVs, rather than relying solely on the canonical pre-export Blender mesh.
fbx=OUT/'runtime/VRWristwatch.fbx'
if fbx.exists():
    original=next(o for o in s.objects if o.name=='Runtime watch')
    material=original.data.materials[0]
    source_uv=original.data.uv_layers.active
    source_corners={}
    for loop in original.data.loops:
        source_corners.setdefault(loop.vertex_index,[]).append((source_uv.data[loop.index].uv.copy(),original.data.corner_normals[loop.index].vector.normalized()))
    tree=KDTree(len(original.data.vertices))
    for v in original.data.vertices:tree.insert(original.matrix_world@v.co,v.index)
    tree.balance();before=set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=str(fbx),use_custom_normals=True)
    imported=[o for o in bpy.data.objects if o not in before and o.type=='MESH']
    if len(imported)!=1:raise RuntimeError('Expected one exported wrist mesh')
    watch=imported[0]
    inverse=Matrix(((0,0,-1,3.72),(-1,0,0,-3.9),(0,1,0,0),(0,0,0,1))).inverted()
    frame=inverse@watch.matrix_world
    imported_normals=[(frame.to_3x3().inverted().transposed()@n.vector).normalized() for n in watch.data.corner_normals]
    watch.data.transform(frame);watch.matrix_world=Matrix.Identity(4)
    for p in watch.data.polygons:p.use_smooth=True
    watch.data.normals_split_custom_set(imported_normals)
    deviation=max(tree.find(v.co)[2] for v in watch.data.vertices)
    original.data.calc_loop_triangles();watch.data.calc_loop_triangles()
    import math
    angles=[];unmatched=0;import_uv=watch.data.uv_layers.active
    for loop in watch.data.loops:
        matches=[];value=import_uv.data[loop.index].uv
        for point,index,distance in tree.find_range(watch.data.vertices[loop.vertex_index].co,.0001):
            matches.extend(n for uv,n in source_corners[index] if (uv-value).length<.0001)
        if not matches:unmatched+=1;continue
        actual=watch.data.corner_normals[loop.index].vector.normalized()
        angles.append(math.degrees(math.acos(max(-1,min(1,max(n.dot(actual) for n in matches))))))
    angles.sort()
    check={'maximum_vertex_deviation_cm':deviation,'source_triangles':len(original.data.loop_triangles),
           'maximum_normal_angle_degrees':max(angles),'normal_p99_degrees':angles[int(len(angles)*.99)],
           'unmatched_corners':unmatched,'normal_check_passed':not unmatched and max(angles)<.5,
           'fbx_triangles':len(watch.data.loop_triangles),
           'passed':deviation<.0001 and len(original.data.loop_triangles)==len(watch.data.loop_triangles) and not unmatched and max(angles)<.5}
    (OUT/'runtime/fbx-roundtrip.json').write_text(json.dumps(check,indent=2))
    if not check['passed']:raise RuntimeError('FBX roundtrip differs: '+str(check))
    watch.data.materials.clear();watch.data.materials.append(material)
    for p in watch.data.polygons:p.material_index=0
    bpy.data.objects.remove(original,do_unlink=True);watch.name='Runtime watch'
with bpy.data.libraries.load(str(OUT/'watch-source.blend'),link=False) as (src,dst):
    dst.objects=[n for n in src.objects if n.startswith('UI live preview')]
for ob in dst.objects:s.collection.objects.link(ob)
s.cycles.samples=48
views=set(filter(None,os.environ.get('KF2VR_REVIEW_VIEWS','').split(',')))
for view,loc,target,scale in [('front',(-4,-5,38),(-4,-.3,2),17),
                              ('oblique',(-8,-19,25),(-3.9,-.5,2.8),17),
                              ('badge',(-1,-10,17),(-.2,-2.95,3.8),6.9),
                              ('dial',(9,-4,15),(2.4,0,3.8),3.7),
                              ('rear',(-6,17,18),(-4,2,2.5),17),
                              ('glove',(11,-9,25),(7.7,0,1.6),14),
                              ('skin',(-13,-7,20),(-9,-.5,0),10),
                              ('palm',(12,-7,-26),(7,0,-1),18),
                              ('hand-context',(1.5,0,45),(1.5,0,0),31)]:
    if views and view not in views:continue
    s.camera.location=loc;s.camera.rotation_euler=(Vector(target)-s.camera.location).to_track_quat('-Z','Y').to_euler()
    s.camera.data.ortho_scale=scale;s.render.filepath=str(OUT/('runtime-'+view+'.png'))
    palm_light=None
    if view=='palm':
        data=bpy.data.lights.new('Palm inspection fill','AREA');data.energy=700;data.shape='DISK';data.size=12
        palm_light=bpy.data.objects.new('Palm inspection fill',data);s.collection.objects.link(palm_light)
        palm_light.location=loc;palm_light.rotation_euler=s.camera.rotation_euler
    bpy.ops.render.render(write_still=True)
    if palm_light:bpy.data.objects.remove(palm_light,do_unlink=True)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'runtime/watch-runtime-preview.blend'))
if views and 'wireframe' not in views:raise SystemExit(0)
# Review the exported topology with the same oblique camera. This diagnostic
# material never enters the runtime scene or the FBX.
wire=bpy.data.materials.new('Review topology only');wire.use_nodes=True
nt=wire.node_tree;nt.nodes.clear();out=nt.nodes.new('ShaderNodeOutputMaterial')
em=nt.nodes.new('ShaderNodeEmission');line=nt.nodes.new('ShaderNodeWireframe');line.inputs['Size'].default_value=.004
mix=nt.nodes.new('ShaderNodeMixRGB');mix.inputs[1].default_value=(.012,.02,.025,1);mix.inputs[2].default_value=(.12,.65,.58,1)
nt.links.new(line.outputs[0],mix.inputs[0]);nt.links.new(mix.outputs[0],em.inputs[0]);nt.links.new(em.outputs[0],out.inputs[0])
watch.data.materials[0]=wire
s.camera.location=(-8,-19,25);s.camera.rotation_euler=(Vector((-3.9,-.5,2.8))-s.camera.location).to_track_quat('-Z','Y').to_euler()
s.camera.data.ortho_scale=17;s.render.filepath=str(OUT/'runtime-wireframe.png');bpy.ops.render.render(write_still=True)
