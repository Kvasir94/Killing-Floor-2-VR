"""Bake the wrist assembly without collapsing its lettering or material frames.

Fine yarns and chips project onto intact hardware. Source objects retain their
own local procedural coordinates. The accepted hand assets are copied verbatim;
this wrist-only pass cannot change the hand rig or its skinning.
"""
import bpy, math, os, json, hashlib, shutil, runpy
from pathlib import Path
from mathutils import Matrix, Vector
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
REV=int(os.environ['KF2VR_ART_REVISION'])
SOURCE_REV=int(os.environ.get('KF2VR_SOURCE_REVISION',str(REV)))
HAND_REV=os.environ.get('KF2VR_HAND_SURFACE_REVISION')
SIZE=int(os.environ.get('KF2VR_WATCH_BAKE_SIZE','4096'))
if SIZE not in (2048,4096):raise ValueError('Expected a 2K check or 4K final bake')
SUPERSAMPLE=2
BAKE_SIZE=SIZE*SUPERSAMPLE
BASE=ROOT/'build/watch-detail-20260924'/str(REV)
OUT=BASE/'runtime';OUT.mkdir(exist_ok=True)
(OUT/'source').mkdir(exist_ok=True)
for filename in ['bake_watch_components.py','optimize_watch_components.py','pack_watch_atlas.py','generate_watch_glass.py','render_watch_runtime.py']:
    shutil.copy2(ROOT/'tools'/filename,OUT/'source'/filename)
source=bpy.data.scenes[f'Horzine reference rebuild {SOURCE_REV:02d}']
bpy.context.window.scene=source
def is_watch(o):
    return o.type in {'MESH','CURVE','FONT'} and o.name.startswith(('Watch |','Case |','Horzine ','ID plate','Conduit |','Cuff |','Buckle ','Folded webbing'))
high=[o for o in source.objects if is_watch(o)]
optimization=runpy.run_path(str(ROOT/'tools/optimize_watch_components.py'))
optimized=REV>=51
group_ids={key:i for i,key in enumerate(sorted({optimization['projection_group'](o.name) for o in high}))}
def group_offset(name):
    i=group_ids[optimization['projection_group'](name)]
    return Vector(((i%10)*30,((i//10)%10)*30,(i//100)*30)) if optimized else Vector((0,0,0))
micro=('Case | roller woven','Case | keeper woven','Case | keeper compressed',
       'Case | webbing short','Case | keeper short frayed')
projected=('Case | textured webbing roller','Case | rounded compressed nylon keeper',
           'Case | inset keeper webbing','Case | woven latch feed')
fascia=('Watch | six level','Watch | machined outer','Watch | inner glass','Watch | bezel dirt',
        'Case | stamped latch','Case | protected side','Case | side key','Case | selector',
        'Case | hinge','Case | roller end','Case | latch','Case | top latch','Case | control captive',
        'Case | chipped finish','Case | upper stepped keeper','Case | wide strap keeper','Case | left keeper')
focal=('Case | hinge','Case | roller end','Case | protected side','Case | side key','Case | control captive',
       'Case | selector','Case | right control tower','Case | roller recess')
vertices=[];faces=[];normals=[];smooth=[];components=[];atlas_groups=[];degenerate_triangles=0
low_local=[];low_generated=[];low_materials=[];low_face_materials=[];detail_faces=[];low_offsets=[]
buried_triangles=0
fit_geometry={}
low_attrs={key:[] for key in ['ContactWear','DriedBlood','HealedScar']}
# Keep high and low isolated until every source component has been evaluated.
for original in high:
    if optimization['omitted'](original.name) if optimized else original.name.startswith(micro):continue
    o=original.copy();o.data=original.data.copy();source.collection.objects.link(o)
    if optimized:optimization['simplify_copy'](o)
    # Evaluate a disposable runtime copy. Frame outlines stay authored while
    # the optimizer reduces construction sampling and transfers surface detail.
    bpy.context.view_layer.update();dg=bpy.context.evaluated_depsgraph_get()
    ev=o.evaluated_get(dg);me=ev.to_mesh();me.calc_loop_triangles()
    if REV>=58 and (original.name.startswith(('Cuff | webbing band','Cuff | adjuster webbing feed','Case | upper stepped keeper','Case | top retention mounting','Case | stamped latch','Conduit | upper')) or original.name=='Cuff | padded leather saddle'):
        fit_geometry[original.name]=([o.matrix_world@v.co for v in me.vertices],[tuple(t.vertices) for t in me.loop_triangles])
    start=len(vertices);world=o.matrix_world;normal_matrix=world.to_3x3().inverted().transposed()
    vertices.extend(world@v.co for v in me.vertices)
    low_offsets.extend([group_offset(original.name)]*len(me.vertices))
    low_local.extend(v.co.copy() for v in me.vertices)
    lo=Vector(tuple(min(v.co[a] for v in me.vertices) for a in range(3)))
    extent=Vector(tuple(max(v.co[a] for v in me.vertices)-lo[a] for a in range(3)))
    low_generated.extend(tuple((v.co[a]-lo[a])/max(extent[a],1e-8) for a in range(3)) for v in me.vertices)
    for key,values in low_attrs.items():
        attr=me.attributes.get(key);values.extend(attr.data[i].value if attr else 0 for i in range(len(me.vertices)))
    slots=[]
    for ma in me.materials:
        ma=ma.original
        if ma not in low_materials:low_materials.append(ma)
        slots.append(low_materials.index(ma))
    fabric=original.name.startswith(('Cuff | webbing','Folded webbing')) or any(any(word in ma.name.lower() for word in ('woven','nylon','yarn','webbing')) for ma in original.data.materials)
    group='badge' if original.name.startswith(('Case | badge','ID plate','Horzine ')) else 'woven' if original.name.startswith(projected) else 'strap' if original.name.startswith(('Case | descending webbing','Cuff | adjuster webbing')) else 'fabric' if fabric else 'wrap' if original.name.startswith('Cuff | padded leather') else 'focal' if original.name.startswith(focal) else 'fascia' if original.name.startswith(fascia) else 'hardware'
    for triangle in me.loop_triangles:
        a,b,c=(world@me.vertices[v].co for v in triangle.vertices)
        # Sub-micron slivers make FBX's single-precision normal frames unstable.
        if (b-a).cross(c-a).length*.5<=1e-6:
            degenerate_triangles+=1
            continue
        p=me.polygons[triangle.polygon_index]
        if optimized and optimization['buried_face'](original.name,(normal_matrix@p.normal).normalized(),(a,b,c)):
            buried_triangles+=1
            continue
        hidden=original.name.startswith('Watch | recessed dark lens') or (original.name.startswith(('Watch | stepped shock','Watch | layered armor')) and abs(p.normal.z)>.95 and p.area>5)
        world_normal=(normal_matrix@p.normal).normalized()
        # Reserve close-up density for exposed top/front faces. Rear and wrist
        # contact surfaces still receive maps, in a smaller dedicated region.
        position=world@p.center
        exposed=any(world_normal.dot((Vector(camera)-position).normalized())>.07
                    for camera in [(-4,-5,38),(-8,-19,25),(-1,-10,17)])
        if group in {'focal','fascia','hardware','woven','strap'} and not exposed:
            hidden=True
        under_case=abs(position.y)<1.75 and position.z>2.6
        strap_exposed=exposed or world_normal.dot((Vector((-6,17,18))-position).normalized())>.07
        visible_strap=group=='fabric' and original.type=='MESH' and original.name.startswith('Cuff | webbing') and strap_exposed and not under_case and position.z> -2.6 and (abs(position.y)>2.3 or position.z>1)
        faces.append(tuple(start+v for v in triangle.vertices));smooth.append(True);atlas_groups.append('hidden' if hidden else 'strap' if visible_strap else group)
        low_face_materials.append(slots[p.material_index])
        # Unchanged explicit mesh surfaces (notably the fluted wheel) bake
        # directly. Projection adds no detail there and can miss sharp valleys.
        transfer=optimized and (original.type!='MESH' or bool(original.modifiers))
        if transfer or original.name.startswith(projected):detail_faces.append(len(faces)-1)
        normals.extend((normal_matrix@me.corner_normals[i].vector).normalized() for i in triangle.loops)
    components.append({'name':original.name,'triangles':len(me.loop_triangles)})
    ev.to_mesh_clear();bpy.data.objects.remove(o,do_unlink=True)
if fit_geometry:
    from mathutils.bvhtree import BVHTree
    trees={name:BVHTree.FromPolygons(*data,all_triangles=True) for name,data in fit_geometry.items()}
    strap_names=[name for name in trees if name.startswith(('Cuff | webbing band','Cuff | adjuster webbing feed'))]
    contacts=[]
    for name in strap_names:
        for other in trees:
            if other in strap_names:continue
            overlaps=trees[name].overlap(trees[other])
            if overlaps:contacts.append({'strap':name,'hardware':other,'intersecting_triangle_pairs':len(overlaps)})
    (OUT/'strap-fit.json').write_text(json.dumps(contacts,indent=2))
    assert not contacts,contacts
me=bpy.data.meshes.new('Preserved watch components');me.from_pydata(vertices,[],faces);me.update()
watch=bpy.data.objects.new('Runtime watch',me);source.collection.objects.link(watch)
for p,s in zip(me.polygons,smooth):p.use_smooth=s
me.normals_split_custom_set(normals)
bpy.ops.object.select_all(action='DESELECT');watch.select_set(True);bpy.context.view_layer.objects.active=watch
uv=me.uv_layers.new(name='RuntimeUV');me.uv_layers.active=uv
bpy.ops.object.mode_set(mode='EDIT');bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.uv.smart_project(angle_limit=math.radians(55),island_margin=.003)
bpy.ops.object.mode_set(mode='OBJECT')
atlas_receipt=runpy.run_path(str(ROOT/'tools/pack_watch_atlas.py'))['pack_watch_atlas'](me,atlas_groups,SIZE)
me.normals_split_custom_set(normals)
(OUT/'atlas-layout.json').write_text(json.dumps(atlas_receipt,indent=2))

# Keep vertex sharing while storing normals and UVs per corner. Unnecessary
# point splits exceed the pinned SDK's 65,535-point import limit. Removing the
# unstable sliver triangles above preserves the corner normals through FBX.
old=me;old_uv=old.uv_layers.active;vertices=[];faces=[];remap=[];keys={}
for p in old.polygons:
    face=[]
    for li in p.loop_indices:
        vi=old.loops[li].vertex_index
        key=vi
        if key not in keys:
            keys[key]=len(vertices);vertices.append(old.vertices[vi].co.copy());remap.append(vi)
        face.append(keys[key])
    faces.append(face)
me=bpy.data.meshes.new('Watch shared points and explicit corner normals');me.from_pydata(vertices,[],faces);me.update()
if len(vertices)>65535:raise RuntimeError('Watch exceeds the pinned SDK vertex limit')
uv=me.uv_layers.new(name='RuntimeUV')
for p in me.polygons:p.use_smooth=True
for li in range(len(me.loops)):uv.data[li].uv=old_uv.data[li].uv
me.normals_split_custom_set(normals);watch.data=me
low_local=[low_local[i] for i in remap];low_generated=[low_generated[i] for i in remap];low_offsets=[low_offsets[i] for i in remap]
low_attrs={key:[values[i] for i in remap] for key,values in low_attrs.items()}
bpy.data.meshes.remove(old)
if optimized and len(me.polygons)>30000:raise RuntimeError(f'Runtime geometry budget exceeded: {len(me.polygons)} triangles')
if os.environ.get('KF2VR_GEOMETRY_ONLY')=='1':
    (OUT/'geometry-budget.json').write_text(json.dumps({'triangles':len(me.polygons),'vertices':len(me.vertices),
        'buried_triangles_removed':buried_triangles,'components':components},indent=2))
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'geometry-check.blend'))
    print('GEOMETRY_BUDGET',len(me.polygons),len(me.vertices),flush=True)
    raise SystemExit(0)
target=bpy.data.materials.new('Watch bake target');target.use_nodes=True;me.materials.append(target)
tex=target.node_tree.nodes.new('ShaderNodeTexImage');target.node_tree.nodes.active=tex
source.render.engine='CYCLES';source.cycles.samples=16
source.render.bake.margin=8*SUPERSAMPLE;source.render.bake.use_clear=True
source.render.bake.use_selected_to_active=True
me.calc_loop_triangles()
print('WATCH_COMPONENTS',len(components),'TRIANGLES',len(me.loop_triangles),flush=True)
# One projection source avoids a separate atlas traversal for every tiny fiber.
# Store component-local coordinates before merging so grain size and direction
# do not change into coordinates of the whole wrist assembly.
hv=[];hf=[];hn=[];hs=[];hm=list(low_materials);hi=[];local_coords=[];generated_coords=[]
detail_attrs={key:[] for key in ['ContactWear','DriedBlood','HealedScar']}
bpy.context.view_layer.update();dg=bpy.context.evaluated_depsgraph_get()
for o in high:
    if not optimized and not o.name.startswith(projected+micro):continue
    ev=o.evaluated_get(dg);src=ev.to_mesh();start=len(hv)
    hv.extend(o.matrix_world@v.co+group_offset(o.name) for v in src.vertices);local_coords.extend(v.co.copy() for v in src.vertices)
    lo=Vector(tuple(min(v.co[a] for v in src.vertices) for a in range(3)))
    extent=Vector(tuple(max(v.co[a] for v in src.vertices)-lo[a] for a in range(3)))
    generated_coords.extend(tuple((v.co[a]-lo[a])/max(extent[a],1e-8) for a in range(3)) for v in src.vertices)
    for key,values in detail_attrs.items():
        attr=src.attributes.get(key);values.extend(attr.data[i].value if attr else 0 for i in range(len(src.vertices)))
    normal_matrix=o.matrix_world.to_3x3().inverted().transposed();slots=[]
    for material in src.materials:
        material=material.original
        if material not in hm:hm.append(material)
        slots.append(hm.index(material))
    for p in src.polygons:
        hf.append(tuple(start+v for v in p.vertices));hs.append(p.use_smooth);hi.append(slots[p.material_index])
        hn.extend((normal_matrix@src.corner_normals[i].vector).normalized() for i in p.loop_indices)
    ev.to_mesh_clear()
high_mesh=bpy.data.meshes.new('Watch projection with component coordinates');high_mesh.from_pydata(hv,[],hf);high_mesh.update()
for name,values in [('SourceObjectCoordinates',local_coords),('SourceGeneratedCoordinates',generated_coords)]:
    attr=high_mesh.attributes.new(name,'FLOAT_VECTOR','POINT')
    attr.data.foreach_set('vector',[c for p in values for c in p])
for name,values in detail_attrs.items():
    attr=high_mesh.attributes.new(name,'FLOAT','POINT');attr.data.foreach_set('value',values)
for material in hm:
    material=material.copy();nt=material.node_tree;attrs={}
    for socket,name in [('Object','SourceObjectCoordinates'),('Generated','SourceGeneratedCoordinates')]:
        node=nt.nodes.new('ShaderNodeAttribute');node.attribute_name=name;attrs[socket]=node.outputs['Vector']
    for link in list(nt.links):
        if link.from_node.type=='TEX_COORD' and link.from_socket.name in attrs:
            nt.links.new(attrs[link.from_socket.name],link.to_socket)
    for node in list(nt.nodes):
        if node.type in {'TEX_NOISE','TEX_WAVE','TEX_VORONOI','TEX_MUSGRAVE'} and not node.inputs['Vector'].is_linked:
            nt.links.new(attrs['Generated'],node.inputs['Vector'])
    high_mesh.materials.append(material)
for p,s,index in zip(high_mesh.polygons,hs,hi):p.use_smooth=s;p.material_index=index
high_mesh.normals_split_custom_set(hn)
projection=bpy.data.objects.new('Watch bake projection source',high_mesh);source.collection.objects.link(projection)
high=[projection]
# Bake unchanged surfaces directly: casting rays between adjacent layers was
# imprinting neighbours onto bezels and leaving black misses around seals.
for name,values in [('SourceObjectCoordinates',low_local),('SourceGeneratedCoordinates',low_generated)]:
    attr=me.attributes.new(name,'FLOAT_VECTOR','POINT');attr.data.foreach_set('vector',[c for p in values for c in p])
for name,values in low_attrs.items():
    attr=me.attributes.new(name,'FLOAT','POINT');attr.data.foreach_set('value',values)
me.materials.clear()
for material in high_mesh.materials:me.materials.append(material)
for p,index in zip(me.polygons,low_face_materials):p.material_index=index
# Project only surfaces that were simplified or receive baked source detail.
dm=bpy.data.meshes.new('Isolated component bake target');dm.from_pydata([v+offset for v,offset in zip(vertices,low_offsets)],[],[faces[i] for i in detail_faces]);dm.update()
duv=dm.uv_layers.new(name='RuntimeUV');detail_normals=[]
uv=me.uv_layers['RuntimeUV']
for dp,index in zip(dm.polygons,detail_faces):
    p=me.polygons[index];dp.use_smooth=p.use_smooth
    for dl,sl in zip(dp.loop_indices,p.loop_indices):
        duv.data[dl].uv=uv.data[sl].uv;detail_normals.append(me.corner_normals[sl].vector.copy())
dm.normals_split_custom_set(detail_normals);dm.materials.append(target)
detail=bpy.data.objects.new('Isolated component bake target',dm);source.collection.objects.link(detail)
materials=set(ma for o in high for ma in o.data.materials if ma and ma.use_nodes)
outputs={};destinations=[]
for ma in materials:
    nt=ma.node_tree;out=next(n for n in nt.nodes if n.type=='OUTPUT_MATERIAL')
    outputs[ma]=out.inputs['Surface'].links[0].from_socket
    dest=nt.nodes.new('ShaderNodeTexImage');nt.nodes.active=dest;destinations.append(dest)
saved_visibility={o:o.hide_render for o in source.objects}
for o in source.objects:
    if o.type in {'MESH','CURVE','FONT'}:o.hide_render=o not in high and o!=watch
for o in high:o.hide_render=False
baked={}
for channel in ['D','N','S','R','M']:
    source.cycles.samples=(4 if SIZE==2048 else 8) if channel=='D' else 4 if channel=='N' else 1
    print('BAKE_START',channel,flush=True)
    im=bpy.data.images.new('VRHorzineWatch_'+channel,BAKE_SIZE,BAKE_SIZE,alpha=False,float_buffer=True)
    im.colorspace_settings.name='sRGB' if channel=='D' else 'Non-Color'
    tex.image=im
    for dest in destinations:dest.image=im
    for ma in materials:
        nt=ma.node_tree;out=next(n for n in nt.nodes if n.type=='OUTPUT_MATERIAL')
        nt.links.new(outputs[ma],out.inputs['Surface'])
        bs=nt.nodes.get('Principled BSDF')
        if channel=='N':continue
        emit=nt.nodes.new('ShaderNodeEmission')
        socket=bs.inputs['Base Color' if channel=='D' else 'Roughness' if channel=='R' else 'Metallic']
        if channel=='S':
            # UE3 legacy specular response, using the same material metal mask.
            base=.045+bs.inputs['Metallic'].default_value*.5
            rough=bs.inputs['Roughness']
            if rough.is_linked:
                response=nt.nodes.new('ShaderNodeMapRange')
                response.inputs['To Min'].default_value=base
                response.inputs['To Max'].default_value=base*.55
                nt.links.new(rough.links[0].from_socket,response.inputs['Value'])
                nt.links.new(response.outputs[0],emit.inputs['Color'])
            else:emit.inputs['Color'].default_value=(base*(1-rough.default_value*.45),)*3+(1,)
        elif socket.is_linked:nt.links.new(socket.links[0].from_socket,emit.inputs['Color'])
        elif channel=='D':emit.inputs['Color'].default_value=socket.default_value
        else:emit.inputs['Color'].default_value=(socket.default_value,)*3+(1,)
        nt.links.new(emit.outputs[0],out.inputs['Surface'])
    bpy.ops.object.select_all(action='DESELECT')
    projection.hide_render=True;detail.hide_render=True;watch.hide_render=False
    watch.select_set(True);bpy.context.view_layer.objects.active=watch
    bpy.ops.object.bake(type='NORMAL' if channel=='N' else 'EMIT',uv_layer='RuntimeUV',
                        normal_space='TANGENT',use_selected_to_active=False,use_clear=True)
    bpy.ops.object.select_all(action='DESELECT')
    watch.hide_render=True;projection.hide_render=False;detail.hide_render=False
    projection.select_set(True);detail.select_set(True);bpy.context.view_layer.objects.active=detail
    bpy.ops.object.bake(type='NORMAL' if channel=='N' else 'EMIT',uv_layer='RuntimeUV',
                        normal_space='TANGENT',use_selected_to_active=True,use_clear=False,cage_extrusion=.075,max_ray_distance=.15)
    # A single tangent sample per texel aliased the fine authored grain into
    # large bright facets. Integrate four samples before the final 4K texture.
    raw=np.empty(BAKE_SIZE*BAKE_SIZE*4,dtype=np.float32);im.pixels.foreach_get(raw)
    averaged=raw.reshape(SIZE,SUPERSAMPLE,SIZE,SUPERSAMPLE,4).mean(axis=(1,3))
    if channel=='N':
        vector=averaged[:,:,:3]*2-1
        vector/=np.maximum(np.linalg.norm(vector,axis=2,keepdims=True),1e-8)
        averaged[:,:,:3]=vector*.5+.5
    im.scale(SIZE,SIZE);im.pixels.foreach_set(averaged.ravel())
    del raw,averaged
    if channel=='N':del vector
    im.filepath_raw=str(OUT/('VRHorzineWatch_'+channel+'.tga'));im.file_format='TARGA'
    if channel=='N':
        pixels=np.empty(len(im.pixels),dtype=np.float32);im.pixels.foreach_get(pixels)
        directx=pixels.copy();directx[1::4]=1-directx[1::4];im.pixels.foreach_set(directx);im.save()
        im.pixels.foreach_set(pixels);im.pack()
    else:im.save();im.pack()
    baked[channel]=im
    print('COMPONENT_BAKE',channel,flush=True)
for ma in materials:
    nt=ma.node_tree;out=next(n for n in nt.nodes if n.type=='OUTPUT_MATERIAL')
    nt.links.new(outputs[ma],out.inputs['Surface'])
for o,state in saved_visibility.items():o.hide_render=state
bpy.data.objects.remove(detail,do_unlink=True)

ma=bpy.data.materials.new('VRHorzineWatch');ma.use_nodes=True;nt=ma.node_tree;bs=nt.nodes.get('Principled BSDF')
for channel in ['D','N','R','M']:
    t=nt.nodes.new('ShaderNodeTexImage');t.image=baked[channel]
    if channel=='N':
        n=nt.nodes.new('ShaderNodeNormalMap');nt.links.new(t.outputs['Color'],n.inputs['Color']);nt.links.new(n.outputs[0],bs.inputs['Normal'])
    else:nt.links.new(t.outputs['Color'],bs.inputs[{'D':'Base Color','R':'Roughness','M':'Metallic'}[channel]])
me.materials.clear();me.materials.append(ma)
for p in me.polygons:p.material_index=0
scene=bpy.data.scenes.new('Runtime baked asset inspection');scene.world=source.world
scene.unit_settings.system='METRIC';scene.unit_settings.scale_length=.01
scene.render.engine='CYCLES';scene.cycles.samples=48
scene.render.resolution_x=1600;scene.render.resolution_y=1050;scene.render.resolution_percentage=100
scene.view_settings.view_transform='AgX'
source.collection.objects.unlink(watch);scene.collection.objects.link(watch)
for old in source.objects:
    if old.type in {'LIGHT','CAMERA'}:
        o=old.copy();o.data=old.data.copy();scene.collection.objects.link(o)
        if old==source.camera:scene.camera=o
# Hand surface candidates may include a UV-only re-export. Their geometry and
# rig preservation checks remain in hand-surface-report.json.
hand_root=ROOT/'build/watch-detail-20260924'/HAND_REV/'runtime' if HAND_REV else None
hand_preview=hand_root/'Horzine-runtime-baked.blend' if hand_root else ROOT/'build/watch-detail-20260924/35/runtime/Horzine-runtime-baked.blend'
with bpy.data.libraries.load(str(hand_preview),link=False) as (src,dst):
    dst.objects=[n for n in src.objects if n=='Runtime hand']
for o in dst.objects:
    scene.collection.objects.link(o)
    if SOURCE_REV>=59 and not hand_root:
        import bmesh
        o.data.transform(Matrix.Diagonal((1,-1,1,1)))
        bm=bmesh.new();bm.from_mesh(o.data);bmesh.ops.reverse_faces(bm,faces=list(bm.faces));bm.to_mesh(o.data);bm.free()
bpy.context.window.scene=scene
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'Horzine-runtime-baked.blend'))
bpy.ops.object.select_all(action='DESELECT');watch.select_set(True);bpy.context.view_layer.objects.active=watch
# Transform the mesh and its custom normals together into the live screen frame.
export_frame=Matrix(((0,0,-1,3.72),(-1,0,0,-3.9),(0,1,0,0),(0,0,0,1)))
export_normals=[(export_frame.to_3x3()@n.vector).normalized() for n in watch.data.corner_normals]
watch.data.transform(export_frame);watch.data.normals_split_custom_set(export_normals)
bpy.ops.export_scene.fbx(filepath=str(OUT/'VRWristwatch.fbx'),use_selection=True,object_types={'MESH'},global_scale=1,
                        apply_unit_scale=True,apply_scale_options='FBX_SCALE_UNITS',axis_forward='-X',axis_up='Z',
                        bake_anim=False,mesh_smooth_type='FACE',path_mode='STRIP')
baseline=ROOT/'build/watch-detail-20260924/baseline-26/runtime'
preserved=[]
for p in baseline.iterdir():
    if p.name.startswith(('VRFloatingHands','VRHorzineHands','VRHorzineWatchFont')):
        shutil.copy2(p,OUT/p.name);preserved.append(p.name)
if hand_root:
    for p in hand_root.glob('VRHorzineHands_*.tga'):shutil.copy2(p,OUT/p.name)
    shutil.copy2(hand_root/'hand-surface-report.json',OUT/'hand-surface-report.json')
    preserved=[name for name in preserved if not name.startswith('VRHorzineHands_')]
    hand_report=json.loads((hand_root/'hand-surface-report.json').read_text())
    if hand_report.get('uv_repack'):
        for name in ('VRFloatingHands.psk','VRFloatingHands.fbx'):shutil.copy2(hand_root/name,OUT/name)
        preserved=[name for name in preserved if not name.startswith('VRFloatingHands')]
display=runpy.run_path(str(ROOT/'tools/generate_watch_glass.py'))
display['generate'](OUT/'VRHorzineWatchGlass.tga');display['generate_glow'](OUT/'VRHorzineWatchGlow.tga')
me.calc_loop_triangles()
uv=me.uv_layers.active
render_vertices=len({(loop.vertex_index,*(round(float(x),6) for x in me.corner_normals[loop.index].vector),
                     *(round(float(x),6) for x in uv.data[loop.index].uv)) for loop in me.loops})
report={'concept_revision':REV,'authoring_revision':SOURCE_REV,'watch_triangles':len(me.loop_triangles),'watch_vertices':len(me.vertices),
        'hand_surface_revision':int(HAND_REV) if HAND_REV else None,
        'estimated_render_vertices_after_uv_normal_splits':render_vertices,'material_slots':len(me.materials),'uv_channels':len(me.uv_layers),
        'degenerate_triangles_removed':degenerate_triangles,
        'buried_triangles_removed':buried_triangles,'optimized_runtime':optimized,
        'watch_texture_size':SIZE,'bake_supersampling':SUPERSAMPLE,'preserved_baseline_files':preserved,'components':components,
        'authoring_source':str(BASE/'watch-source.blend'),'game_acceptance':False,
        'preview_material':'Baked D/N/R/M; game uses D/N/S with UE3 legacy shading',
        'files_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in OUT.iterdir() if p.is_file() and p.suffix in {'.tga','.fbx','.psk'}}}
(OUT/'asset-report.json').write_text(json.dumps(report,indent=2))
print('COMPONENT_EXPORT_READY',report['watch_triangles'],flush=True)
