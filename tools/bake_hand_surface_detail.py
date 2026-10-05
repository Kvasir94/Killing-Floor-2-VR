"""Transfer glove grain to the existing production hand UVs; geometry stays intact."""
import bpy,runpy,os,json,hashlib,shutil
import numpy as np
from pathlib import Path
from mathutils import Vector
from mathutils.kdtree import KDTree

ROOT=Path(__file__).resolve().parents[1];REV=int(os.environ['KF2VR_ART_REVISION'])
BASE=ROOT/'build/watch-detail-20260924'/str(REV);OUT=BASE/'runtime'
SIZE=4096
BAKE_SIZE=SIZE*2
BAKE_SKIN=os.environ.get('KF2VR_HAND_BAKE_SKIN')=='1'
REPACK=os.environ.get('KF2VR_REPACK_HAND_UV')=='1'
NORMAL_ONLY=os.environ.get('KF2VR_HAND_NORMAL_ONLY')=='1'
KEEP_UV=os.environ.get('KF2VR_HAND_KEEP_UV')=='1'
preview=bpy.context.scene;source=next(s for s in bpy.data.scenes if s.name.startswith('Horzine reference rebuild'))
baseline=ROOT/'build/watch-detail-20260924/baseline-26/runtime'
input_dir=Path(os.environ.get('KF2VR_HAND_INPUT_DIR',str(baseline)))
loader=runpy.run_path(str(ROOT/'tools/load_runtime_hand_context.py'))
hand,report=loader['load_left_hand'](input_dir/'VRFloatingHands.fbx',preview)
old=next(o for o in preview.objects if o.name=='Runtime hand')
tree=KDTree(len(old.data.vertices))
for v in old.data.vertices:tree.insert(old.matrix_world@v.co,v.index)
tree.balance();distances=sorted(tree.find(v.co)[2] for v in hand.data.vertices)
report['previous_preview_vertex_distance_cm']={'max':max(distances),'median':distances[len(distances)//2]}
print('HAND_CONTEXT',json.dumps(report),flush=True)
assert distances[len(distances)//2]<.01,report
preview.collection.objects.unlink(hand);source.collection.objects.link(hand)
bpy.context.window.scene=source;bpy.context.view_layer.update()
if KEEP_UV:
    report['uv_repack']=json.loads((OUT/'hand-surface-report.json').read_text())['uv_repack']
    report['uv_layout_preserved']=True
    if (OUT/'winding-repair.json').exists():report['winding_repair']=json.loads((OUT/'winding-repair.json').read_text())
elif REPACK:report['uv_repack']=runpy.run_path(str(ROOT/'tools/repack_hand_surface.py'))['repack'](hand,baseline,OUT,ROOT,old if NORMAL_ONLY else None)
dg=bpy.context.evaluated_depsgraph_get()
high=[o for o in source.objects if o.type in {'MESH','CURVE'} and o.name.startswith(('LEFT |','Glove','Finger |','Knuckle','Dorsal','Palm |','Skin |')) and not o.name.startswith('Glove bake projection')]
vv=[];ff=[];nn=[];coords=[];generated=[];uvs=[];materials=[];indices=[];owners=[]
attributes={k:[] for k in ['ContactWear','DriedBlood','HealedScar']}
for owner,ob in enumerate(high):
    ev=ob.evaluated_get(dg);me=ev.to_mesh();start=len(vv)
    vv.extend(ob.matrix_world@v.co for v in me.vertices);coords.extend(v.co.copy() for v in me.vertices)
    lo=Vector(tuple(min(v.co[a] for v in me.vertices) for a in range(3)))
    extent=Vector(tuple(max(v.co[a] for v in me.vertices)-lo[a] for a in range(3)))
    generated.extend(tuple((v.co[a]-lo[a])/max(extent[a],1e-8) for a in range(3)) for v in me.vertices)
    for key,values in attributes.items():
        attr=me.attributes.get(key);values.extend(attr.data[i].value if attr else 0 for i in range(len(me.vertices)))
    slots=[]
    for ma in me.materials:
        ma=ma.original
        if ma not in materials:materials.append(ma)
        slots.append(materials.index(ma))
    uv=me.uv_layers.active;normal_matrix=ob.matrix_world.to_3x3().inverted().transposed()
    for p in me.polygons:
        ff.append(tuple(start+i for i in p.vertices));indices.append(slots[p.material_index]);owners.append(owner)
        nn.extend((normal_matrix@me.corner_normals[i].vector).normalized() for i in p.loop_indices)
        uvs.extend(uv.data[i].uv.copy() if uv else (0,0) for i in p.loop_indices)
    ev.to_mesh_clear()
mesh=bpy.data.meshes.new('Glove detail projection');mesh.from_pydata(vv,[],ff);mesh.update()
uv=mesh.uv_layers.new(name='SourceUV')
for value,co in zip(uv.data,uvs):value.uv=co
for p,i in zip(mesh.polygons,indices):p.use_smooth=True;p.material_index=i
mesh.normals_split_custom_set(nn)
for name,values in [('SourceObjectCoordinates',coords),('SourceGeneratedCoordinates',generated)]:
    a=mesh.attributes.new(name,'FLOAT_VECTOR','POINT');a.data.foreach_set('vector',[c for p in values for c in p])
for name,values in attributes.items():
    a=mesh.attributes.new(name,'FLOAT','POINT');a.data.foreach_set('value',values)
outputs={};destinations=[]
for ma in materials:
    copy=ma.copy();nt=copy.node_tree;attrs={}
    for socket,name in [('Object','SourceObjectCoordinates'),('Generated','SourceGeneratedCoordinates')]:
        node=nt.nodes.new('ShaderNodeAttribute');node.attribute_name=name;attrs[socket]=node.outputs['Vector']
    for link in list(nt.links):
        if link.from_node.type=='TEX_COORD' and link.from_socket.name in attrs:nt.links.new(attrs[link.from_socket.name],link.to_socket)
    for node in list(nt.nodes):
        if node.type in {'TEX_NOISE','TEX_WAVE','TEX_VORONOI'} and not node.inputs['Vector'].is_linked:nt.links.new(attrs['Generated'],node.inputs['Vector'])
    uvnode=nt.nodes.new('ShaderNodeUVMap');uvnode.uv_map='SourceUV'
    for node in list(nt.nodes):
        if node.type=='TEX_IMAGE' and not node.inputs['Vector'].is_linked:nt.links.new(uvnode.outputs[0],node.inputs['Vector'])
        if node.type=='NORMAL_MAP':node.uv_map='SourceUV'
    bs=nt.nodes.get('Principled BSDF')
    if ma.name.startswith('Skin | scarred'):
        runpy.run_path(str(ROOT/'tools/calibrate_reference_materials.py'))['calibrate'](copy)
        grain=nt.nodes.new('ShaderNodeTexNoise');grain.inputs['Scale'].default_value=22;grain.inputs['Detail'].default_value=3
        nt.links.new(attrs['Object'],grain.inputs['Vector'])
        bump=nt.nodes.new('ShaderNodeBump');bump.inputs['Strength'].default_value=.32;bump.inputs['Distance'].default_value=.018
        nt.links.new(grain.outputs['Fac'],bump.inputs['Height'])
        if bs.inputs['Normal'].is_linked:nt.links.new(bs.inputs['Normal'].links[0].from_socket,bump.inputs['Normal'])
        nt.links.new(bump.outputs[0],bs.inputs['Normal'])
    output=next(n for n in nt.nodes if n.type=='OUTPUT_MATERIAL');outputs[copy]=output.inputs['Surface'].links[0].from_socket
    dest=nt.nodes.new('ShaderNodeTexImage');nt.nodes.active=dest;destinations.append(dest);mesh.materials.append(copy)
projection=bpy.data.objects.new('Glove bake projection',mesh);source.collection.objects.link(projection)
hand.data.materials.clear()
for ma in mesh.materials:hand.data.materials.append(ma)
report['surface_shells']=runpy.run_path(str(ROOT/'tools/transfer_hand_surface.py'))['transfer'](hand.data,mesh,owners,[o.name for o in high])
print('SURFACE_SHELLS',json.dumps(report['surface_shells'][:15]),flush=True)
for ob in source.objects:
    if ob.type in {'MESH','CURVE','FONT'}:ob.hide_render=ob!=hand
source.render.engine='CYCLES';source.cycles.samples=4;source.render.bake.margin=12
baked={};mask=None
if NORMAL_ONLY:
    for channel in ('D','S','R'):
        im=bpy.data.images.load(str(OUT/('VRHorzineHands_'+channel+'.tga')),check_existing=False)
        im.colorspace_settings.name='sRGB' if channel=='D' else 'Non-Color';im.pack();baked[channel]=im
for channel in (['N'] if NORMAL_ONLY else ['MASK','D','N','S','R']):
    print('HAND_BAKE_START',channel,flush=True)
    im=bpy.data.images.new('Glove detail '+channel,BAKE_SIZE,BAKE_SIZE,alpha=False,float_buffer=True)
    im.colorspace_settings.name='sRGB' if channel=='D' else 'Non-Color'
    for node in destinations:node.image=im
    for ma in mesh.materials:
        nt=ma.node_tree;output=next(n for n in nt.nodes if n.type=='OUTPUT_MATERIAL');nt.links.new(outputs[ma],output.inputs['Surface'])
        if channel=='N':continue
        bs=nt.nodes.get('Principled BSDF');em=nt.nodes.new('ShaderNodeEmission')
        if channel=='MASK':em.inputs['Color'].default_value=((0,0,0,1) if ma.name.startswith('Skin |') and not BAKE_SKIN else (1,1,1,1))
        elif channel in ('S','R'):
            rough=bs.inputs['Roughness'] if bs else None
            if rough and rough.is_linked:
                if channel=='R':nt.links.new(rough.links[0].from_socket,em.inputs['Color'])
                else:
                    spec=nt.nodes.new('ShaderNodeMapRange');spec.inputs['To Min'].default_value=.11;spec.inputs['To Max'].default_value=.018
                    nt.links.new(rough.links[0].from_socket,spec.inputs['Value']);nt.links.new(spec.outputs[0],em.inputs['Color'])
            else:
                value=(rough.default_value if rough else .65) if channel=='R' else .05
                em.inputs['Color'].default_value=(value,value,value,1)
        elif bs and bs.inputs['Base Color'].is_linked:nt.links.new(bs.inputs['Base Color'].links[0].from_socket,em.inputs['Color'])
        elif bs:em.inputs['Color'].default_value=bs.inputs['Base Color'].default_value
        nt.links.new(em.outputs[0],output.inputs['Surface'])
    bpy.ops.object.select_all(action='DESELECT');hand.select_set(True);bpy.context.view_layer.objects.active=hand
    bpy.ops.object.bake(type='NORMAL' if channel=='N' else 'EMIT',uv_layer='RuntimeUV',normal_space='TANGENT',
                        use_selected_to_active=False,use_clear=True)
    raw=np.empty(BAKE_SIZE*BAKE_SIZE*4,dtype=np.float32);im.pixels.foreach_get(raw)
    pixels=raw.reshape(SIZE,2,SIZE,2,4).mean(axis=(1,3)).reshape(-1,4);del raw
    im.scale(SIZE,SIZE)
    if channel=='MASK':
        mask=np.clip(pixels[:,:1],0,1).copy();bpy.data.images.remove(im);continue
    if channel in ('D','N','S') and not REPACK and not KEEP_UV:
        base=bpy.data.images.load(str(baseline/('VRHorzineHands_'+channel+'.tga')),check_existing=False)
        base.colorspace_settings.name='sRGB' if channel=='D' else 'Non-Color';base.scale(SIZE,SIZE)
        prior=np.empty(SIZE*SIZE*4,dtype=np.float32);base.pixels.foreach_get(prior);prior=prior.reshape(-1,4)
        if channel=='N':
            prior[:,1]=1-prior[:,1]
            a=pixels[:,:3]*2-1;b=prior[:,:3]*2-1
            a/=np.maximum(np.linalg.norm(a,axis=1,keepdims=True),1e-8);b/=np.maximum(np.linalg.norm(b,axis=1,keepdims=True),1e-8)
            # Surface projection can hit the reverse side of layered hems.
            # Keep the established normal where the projected frame disagrees,
            # with a continuous transition into the valid detailed samples.
            confidence=np.clip((np.sum(a*b,axis=1)-.35)/.40,0,1)[:,None]
            report['normal_projection_fallback_fraction']=float((confidence<1).mean())
            blend=mask*confidence
            pixels[:,:3]=(a*blend+b*(1-blend))*.5+.5
        else:pixels[:,:3]=pixels[:,:3]*mask+prior[:,:3]*(1-mask)
        bpy.data.images.remove(base)
    if channel=='N':
        n=pixels[:,:3]*2-1;n/=np.maximum(np.linalg.norm(n,axis=1,keepdims=True),1e-8);pixels[:,:3]=n*.5+.5
    pixels[:,3]=1;im.pixels.foreach_set(pixels.ravel());im.filepath_raw=str(OUT/('VRHorzineHands_'+channel+'.tga'));im.file_format='TARGA'
    if channel=='N':
        dx=pixels.copy();dx[:,1]=1-dx[:,1];im.pixels.foreach_set(dx.ravel());im.save();im.pixels.foreach_set(pixels.ravel())
    else:im.save()
    im.pack();baked[channel]=im;print('HAND_BAKE_DONE',channel,flush=True)
source.collection.objects.unlink(hand);preview.collection.objects.link(hand)
material=bpy.data.materials.new('Baked glove surface detail');material.use_nodes=True;nt=material.node_tree;bs=nt.nodes.get('Principled BSDF')
for channel in ('D','N','R'):
    tex=nt.nodes.new('ShaderNodeTexImage');tex.image=baked[channel]
    if channel=='N':
        normal=nt.nodes.new('ShaderNodeNormalMap');nt.links.new(tex.outputs['Color'],normal.inputs['Color']);nt.links.new(normal.outputs[0],bs.inputs['Normal'])
    else:nt.links.new(tex.outputs['Color'],bs.inputs['Base Color' if channel=='D' else 'Roughness'])
hand.data.materials.clear();hand.data.materials.append(material)
bpy.data.objects.remove(old,do_unlink=True);hand.name='Runtime hand'
bpy.context.window.scene=preview
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'Horzine-runtime-baked.blend'))
coverage=float(mask.mean()) if mask is not None else json.loads((OUT/'hand-surface-report.json').read_text())['surface_mask_coverage']
report.update({'geometry_changed':'winding_repair' in report,'texture_size':SIZE,'surface_mask_coverage':coverage,'skin_uses_previous_maps':not BAKE_SKIN,
               'normal_basis':'Production low surface plus authored material bump; no transferred high-surface normal override'})
(OUT/'hand-surface-report.json').write_text(json.dumps(report,indent=2))
for name in ('bake_hand_surface_detail.py','load_runtime_hand_context.py','transfer_hand_surface.py','repack_hand_surface.py'):shutil.copy2(ROOT/'tools'/name,OUT/'source'/name)
asset=json.loads((OUT/'asset-report.json').read_text());asset['concept_revision']=REV
asset['hand_surface_detail']=report;asset['preserved_baseline_files']=[p for p in asset['preserved_baseline_files'] if p.startswith(('VRFloatingHands','VRHorzineWatchFont'))]
if REPACK or KEEP_UV:asset['preserved_baseline_files']=[p for p in asset['preserved_baseline_files'] if not p.startswith('VRFloatingHands')]
asset['files_sha256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in OUT.iterdir() if p.suffix in {'.fbx','.psk','.tga'}}
(OUT/'asset-report.json').write_text(json.dumps(asset,indent=2));print('HAND_SURFACE_READY',json.dumps({k:v for k,v in report.items() if k!='surface_shells'}),flush=True)
