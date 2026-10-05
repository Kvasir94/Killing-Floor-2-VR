"""Convert the locally extracted Portal 2 gun to KF2's tracked weapon rig.

Run in background Blender with the same SourceIO/PSK dependencies used by the
other local weapon importers. Original geometry, materials, articulated bones,
attachments and animation takes are retained; the default potato bodygroup is
absent, matching the base Portal 2 gun. Engine shader parity remains separate.
"""
from pathlib import Path
import hashlib
import json
import math
import re
import sys
import importlib

import bpy
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'third_party'), str(ROOT / 'tools')]
from SourceIO.blender_bindings.bindings import register
from SourceIO.blender_bindings.models import import_model
from SourceIO.blender_bindings.models.common import put_into_collections
from SourceIO.blender_bindings.models.import_animations import import_animations_to_armature
from SourceIO.blender_bindings.operators.import_settings_base import ModelOptions
from SourceIO.library.models.mdl.v49 import MdlV49
from SourceIO.library.models.mdl.load_animations import load_all_animations
from SourceIO.library.shared.content_manager import ContentManager
from SourceIO.library.shared.content_manager.providers.loose_files import LooseFilesContentProvider
from SourceIO.library.source1.vtf import load_texture
from SourceIO.library.source1.vmt import VMT
from SourceIO.library.utils import FileBuffer, TinyPath
from generate_floating_hands import remove_fbx_armature_container
from source_texture_sheets import write_tga

SOURCE, OUT = ROOT / 'extract/portal', ROOT / 'build/portal'
OUT.mkdir(parents=True, exist_ok=True)
(OUT / 'textures').mkdir(exist_ok=True)
register()
bpy.context.scene.unit_settings.system = 'METRIC'
bpy.context.scene.unit_settings.scale_length = 0.01
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
cm = ContentManager()
cm.children.clear()
for cache in (cm._cache, cm._exists_cache, cm._owner_cache):
    cache.clear()
cm.children.add(LooseFilesContentProvider(TinyPath(str(SOURCE))))
path = TinyPath(str(SOURCE / 'models/weapons/v_portalgun.mdl'))
options = ModelOptions.default()
options.scale = 2.54
options.import_textures = False
options.import_animations = False
mdl = MdlV49.from_buffer(FileBuffer(path))
raw_animations = load_all_animations(mdl, FileBuffer(path), cm, path)
container = import_model(path, FileBuffer(path), cm, options)
put_into_collections(container, 'PortalGun', bodygroup_grouping=False)
bpy.context.view_layer.update()
original_rig = container.armature
import_animations_to_armature(original_rig, raw_animations, options.scale)
original_rig.animation_data_clear()
for bone in original_rig.pose.bones:
    bone.matrix_basis = Matrix.Identity(4)
bpy.context.view_layer.update()
defaults = {p.models[0].name for p in mdl.body_parts if p.models and p.models[0].vertex_count > 0}
meshes = [m for m in container.objects if m.name in defaults]
if len(meshes) != 1:
    raise ValueError('Unexpected default Portal 2 gun bodygroup layout')
mesh = meshes[0]
mesh.data.__class__ = bpy.types.Mesh
# The original gun frame has +Z forward, +Y up. Derive its alignment from the
# original Base bind transform, rather than baking the viewmodel arm pose.
axes = Matrix(((0,0,1,0),(1,0,0,0),(0,1,0,0),(0,0,0,1)))
normalization = axes @ original_rig.data.bones['ValveBiped.Base'].matrix_local.inverted()
attachments = {a.name.split('.')[0]: normalization @ a.matrix_world.translation for a in container.attachments}
parents = {a.name.split('.')[0]: next((c.subtarget for c in a.constraints if c.type == 'CHILD_OF'), 'ValveBiped.Base')
           for a in container.attachments}
anchors = {'VR_PrimaryGrip': normalization @ original_rig.data.bones['ValveBiped.Bip01_R_Hand'].head_local,
           'VR_SupportGrip': Vector((28,0,-5)), 'VR_Muzzle': attachments['muzzle']}
anchors.update({'VR_' + key: value for key, value in attachments.items() if key != 'muzzle'})
original_bones = [(b.name, b.parent.name if b.parent else None, b.matrix_local.copy()) for b in original_rig.data.bones]
textures, materials = {}, []

def texture(relative):
    relative = relative.lower().replace('\\', '/').removesuffix('.vtf').removeprefix('materials/')
    file = SOURCE / 'materials' / (relative + '.vtf')
    name = 'Tex_' + hashlib.sha256(relative.encode()).hexdigest()[:16]
    output = OUT / 'textures' / (name + '.tga')
    if relative not in textures:
        pixels, height, width = load_texture(FileBuffer(TinyPath(str(file))))
        if pixels is None:
            raise ValueError(f'Cannot decode texture: {file}')
        write_tga(output, pixels)
        textures[relative] = dict(file=str(output), sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
                                  source_sha256=hashlib.sha256(file.read_bytes()).hexdigest(), width=width, height=height)
    return str(output)

for index, material in enumerate(mesh.data.materials):
    original = material.name.lower().replace('\\', '/')
    candidates = [original] + [p.lower().replace('\\', '/') + original for p in mdl.materials_paths]
    relative = next(n for n in candidates if (SOURCE / 'materials' / (n + '.vmt')).is_file())
    source = SOURCE / 'materials' / (relative + '.vmt')
    vmt = VMT(FileBuffer(TinyPath(str(source))), relative, cm)
    props = {k.lower(): v for k,v in vmt.data.items() if k.startswith('$') and isinstance(v,str)}
    name = 'PortalGunMaterial' + (str(index) if index else '')
    material.name = name
    materials.append(dict(name=name, source=relative, shader=vmt.shader, properties=props,
                          diffuse=texture(props['$basetexture']),
                          normal=texture(props['$bumpmap']) if '$bumpmap' in props else '',
                          exponent=texture(props['$phongexponenttexture']) if '$phongexponenttexture' in props else ''))

before = set(bpy.data.objects)
bpy.ops.psk.import_file(filepath=str(ROOT / 'extract/weapons/WEP_1P_MB500_MESH/SkeletalMesh3/Wep_1stP_MB500_Rig.psk'), scale=1.0)
rig = next(o for o in set(bpy.data.objects)-before if o.type == 'ARMATURE')
kfroot = rig.data.bones['RW_Weapon'].matrix_local.copy()
mesh.parent = None
mesh.matrix_world = Matrix.Identity(4)
mesh.data.transform(kfroot @ normalization)
for modifier in list(mesh.modifiers):
    mesh.modifiers.remove(modifier)
bpy.ops.object.select_all(action='DESELECT')
rig.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode='EDIT')
for bone_name, parent, transform in original_bones:
    bone = rig.data.edit_bones.new('SRC_' + bone_name)
    bone.matrix = kfroot @ normalization @ transform
    bone.length = 1
    bone.parent = rig.data.edit_bones['SRC_' + parent] if parent else rig.data.edit_bones['RW_Weapon']
for anchor, point in anchors.items():
    bone = rig.data.edit_bones.new(anchor)
    bone.head = kfroot @ point
    bone.tail = bone.head + kfroot.to_3x3() @ Vector((0,1,0))
    source = parents.get(anchor.removeprefix('VR_'))
    bone.parent = rig.data.edit_bones['SRC_' + source] if source else rig.data.edit_bones['RW_Weapon']
bpy.ops.object.mode_set(mode='OBJECT')
for group in mesh.vertex_groups:
    group.name = 'SRC_' + group.name
modifier = mesh.modifiers.new('Portal2OriginalRig', 'ARMATURE')
modifier.object = rig
mesh.parent = rig
# SourceIO actions use local bone basis transforms. All source bones receive
# the same rigid normalization, so local channels transfer without resampling.
animations = []
for action in list(bpy.data.actions):
    changed = 0
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for curve in bag.fcurves:
                    if curve.data_path.startswith('pose.bones["'):
                        curve.data_path = curve.data_path.replace('pose.bones["', 'pose.bones["SRC_', 1)
                        changed += 1
    if changed:
        original = action.name
        action.name = 'Portal_' + re.sub('[^A-Za-z0-9_]', '', original)
        animations.append(dict(name=action.name, source=original, frames=list(action.frame_range), channels=changed))
for obj in list(bpy.data.objects):
    if obj not in (rig, mesh):
        bpy.data.objects.remove(obj, do_unlink=True)
rig.name, mesh.name = 'Armature', 'PortalGun'
rig.animation_data_clear()
for bone in rig.pose.bones:
    bone.rotation_mode = 'QUATERNION'
bpy.ops.object.select_all(action='SELECT')

def export(file, animated=False):
    bpy.ops.export_scene.fbx(filepath=str(file), use_selection=True, object_types={'ARMATURE','MESH'},
        global_scale=1, apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS', axis_forward='Y', axis_up='Z',
        use_space_transform=True, bake_space_transform=False, add_leaf_bones=False, primary_bone_axis='Y',
        secondary_bone_axis='X', use_armature_deform_only=False, armature_nodetype='NULL', bake_anim=animated,
        bake_anim_use_all_actions=True, bake_anim_use_nla_strips=False, bake_anim_simplify_factor=0,
        use_mesh_modifiers=True, mesh_smooth_type='FACE', path_mode='STRIP', embed_textures=False)

def remove_identity_object_animation(file):
    """Strip only constant identity channels on Blender's extra rig container."""
    from io_scene_fbx import data_types, encode_bin, parse_fbx
    root, version = parse_fbx.parse(str(file))
    objects = next(e for e in root.elems if e.id == b'Objects')
    connections = next(e for e in root.elems if e.id == b'Connections')
    by_id = {e.props[0]:e for e in objects.elems}
    container = next(e.props[0] for e in objects.elems if e.id == b'Model' and e.props[1].split(b'\0')[0] == b'Armature')
    tracks = {e.props[1] for e in connections.elems if len(e.props)>3 and e.props[2] == container
              and by_id[e.props[1]].id == b'AnimationCurveNode'}
    curves = {e.props[1] for e in connections.elems if len(e.props)>3 and e.props[2] in tracks}
    for curve in curves:
        values = next(e.props[0] for e in by_id[curve].elems if e.id == b'KeyValueFloat')
        if not (all(abs(v)<1e-6 for v in values) or all(abs(v-1)<1e-6 for v in values)):
            raise ValueError('Refusing to strip animated nonidentity Armature transform')
    removed = tracks | curves
    removed_types = {kind:sum(by_id[i].id == kind for i in removed) for kind in (b'AnimationCurve',b'AnimationCurveNode')}
    objects.elems[:] = [e for e in objects.elems if e.props[0] not in removed]
    connections.elems[:] = [e for e in connections.elems if len(e.props)<3 or not ({e.props[1],e.props[2]} & removed)]
    definitions = next(e for e in root.elems if e.id == b'Definitions')
    next(e for e in definitions.elems if e.id == b'Count').props[0] -= len(removed)
    for definition in definitions.elems:
        if definition.id == b'ObjectType' and definition.props[0] in removed_types:
            next(e for e in definition.elems if e.id == b'Count').props[0] -= removed_types[definition.props[0]]
    kinds = ('BOOL','CHAR','INT8','INT16','INT32','INT64','FLOAT32','FLOAT64','BYTES','STRING',
             'INT32_ARRAY','INT64_ARRAY','FLOAT32_ARRAY','FLOAT64_ARRAY','BOOL_ARRAY','BYTE_ARRAY')
    methods = {getattr(data_types,k):'add_'+k.lower() for k in kinds}
    def encode(element):
        result = encode_bin.FBXElem(element.id)
        for kind,value in zip(element.props_type,element.props):
            getattr(result,methods[kind])(value)
        result.elems = [encode(e) for e in element.elems]
        return result
    encode_bin.write(str(file),encode(root),version)

def export_psa(armature, file):
    # KF2's headless FBX skeletal factory does not import animation takes;
    # use the installed PSK/PSA add-on's actual legacy animation exporter.
    module = importlib.import_module('bl_ext.user_default.io_scene_psk_psa.psa.builder')
    writer = importlib.import_module('psk_psa_py.psa.writer')
    settings = module.PsaBuildOptions()
    settings.armature_objects = [armature]
    armature.animation_data_create()
    settings.animation_data = armature.animation_data
    for action in list(bpy.data.actions):
        sequence = module.PsaBuildSequence(armature,armature.animation_data)
        sequence.name = action.name
        sequence.nla_state.action = action
        sequence.nla_state.frame_start = int(action.frame_range[0])
        sequence.nla_state.frame_end = int(action.frame_range[1])
        settings.sequences.append(sequence)
    writer.write_psa_to_file(module.build_psa(bpy.context,settings),str(file))

fbx = OUT / 'PortalGun.fbx'
export(fbx)
remove_fbx_armature_container(fbx)
bpy.context.scene.render.fps = 30
if animations:
    rig.animation_data_create()
    rig.animation_data.action = bpy.data.actions[animations[0]['name']]
    export(OUT / 'PortalGunAnimations.fbx', True)
    remove_identity_object_animation(OUT / 'PortalGunAnimations.fbx')
    remove_fbx_armature_container(OUT / 'PortalGunAnimations.fbx')
    export_psa(rig,OUT/'PortalGun.psa')
    rig.animation_data_clear()
    for bone in rig.pose.bones:
        bone.matrix_basis = Matrix.Identity(4)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / 'PortalGun.blend'))
report = dict(source='models/weapons/v_portalgun.mdl', fbx=str(fbx),
              sha256=hashlib.sha256(fbx.read_bytes()).hexdigest(), vertices=len(mesh.data.vertices),
              triangles=len(mesh.data.polygons), materials=materials, textures=textures, animations=animations,
              source_animations=[dict(name=a.name, fps=a.fps, frames=a.frame_count) for a in mdl.anim_descs],
              bones=[b.name for b in rig.data.bones], anchors={k:list(v) for k,v in anchors.items()},
              limitations=['Source shader phong/fresnel/lightwarp parity requires visual validation',
                           'VR support grip marker is fitted, primary grip and muzzle derive from source bones'])

# Valve's viewmodel omits hidden exterior faces. The shipped world model is
# retained separately for VR views around the back/underside of the weapon.
# It is rigid in Portal 2 and therefore carries no invented claw animation.
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
for action in list(bpy.data.actions):
    bpy.data.actions.remove(action)
world_path = TinyPath(str(SOURCE/'models/weapons/w_portalgun.mdl'))
world_mdl = MdlV49.from_buffer(FileBuffer(world_path))
world = import_model(world_path,FileBuffer(world_path),cm,options)
put_into_collections(world,'PortalGunWorld',bodygroup_grouping=False)
bpy.context.view_layer.update()
world_defaults = {p.models[0].name for p in world_mdl.body_parts if p.models and p.models[0].vertex_count>0}
world_mesh = next(m for m in world.objects if m.name in world_defaults)
world_mesh.data.__class__ = bpy.types.Mesh
world_normalization = axes @ Matrix.Translation(-world.armature.data.bones['weapon_bone'].head_local)
world_anchors = {'VR_PrimaryGrip':Vector((0,0,0)), 'VR_SupportGrip':Vector((24,0,-5)),
                 'VR_Muzzle':world_normalization @ world.attachments[0].matrix_world.translation}
world_materials = []
for index,material in enumerate(world_mesh.data.materials):
    relative = material.name.lower().replace('\\','/')
    source = SOURCE/'materials'/(relative+'.vmt')
    vmt = VMT(FileBuffer(TinyPath(str(source))),relative,cm)
    props = {k.lower():v for k,v in vmt.data.items() if k.startswith('$') and isinstance(v,str)}
    material.name = 'PortalGunWorldMaterial'+(str(index) if index else '')
    world_materials.append(dict(name=material.name,source=relative,shader=vmt.shader,properties=props,
                                diffuse=texture(props['$basetexture']),normal=texture(props['$bumpmap']),
                                exponent=texture(props['$phongexponenttexture'])))
before = set(bpy.data.objects)
bpy.ops.psk.import_file(filepath=str(ROOT/'extract/weapons/WEP_1P_MB500_MESH/SkeletalMesh3/Wep_1stP_MB500_Rig.psk'),scale=1)
world_rig = next(o for o in set(bpy.data.objects)-before if o.type=='ARMATURE')
world_mesh.parent = None; world_mesh.matrix_world = Matrix.Identity(4)
world_mesh.data.transform(kfroot @ world_normalization)
for modifier in list(world_mesh.modifiers):
    world_mesh.modifiers.remove(modifier)
world_mesh.vertex_groups.clear()
group = world_mesh.vertex_groups.new(name='RW_Weapon')
group.add(list(range(len(world_mesh.data.vertices))),1,'REPLACE')
bpy.ops.object.select_all(action='DESELECT')
world_rig.select_set(True); bpy.context.view_layer.objects.active=world_rig
bpy.ops.object.mode_set(mode='EDIT')
for name,point in world_anchors.items():
    bone = world_rig.data.edit_bones.new(name)
    bone.head=kfroot@point; bone.tail=bone.head+kfroot.to_3x3()@Vector((0,1,0))
    bone.parent=world_rig.data.edit_bones['RW_Weapon']
bpy.ops.object.mode_set(mode='OBJECT')
modifier=world_mesh.modifiers.new('OriginalWorldWeapon','ARMATURE'); modifier.object=world_rig
world_mesh.parent=world_rig
for obj in list(bpy.data.objects):
    if obj not in (world_rig,world_mesh): bpy.data.objects.remove(obj,do_unlink=True)
world_rig.name='Armature'; world_mesh.name='PortalGunWorld'
bpy.ops.object.select_all(action='SELECT')
world_rig.animation_data_create()
world_rig.animation_data.action=bpy.data.actions.new('Portal_worldidle')
world_rig.pose.bones['RW_Weapon'].keyframe_insert('location',frame=1)
world_rig.pose.bones['RW_Weapon'].keyframe_insert('location',frame=2)
export(OUT/'PortalGunWorld.fbx',True)
remove_identity_object_animation(OUT/'PortalGunWorld.fbx')
remove_fbx_armature_container(OUT/'PortalGunWorld.fbx')
export_psa(world_rig,OUT/'PortalGunWorld.psa')
world_rig.animation_data_clear()
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'PortalGunWorld.blend'))
report['world'] = dict(source='models/weapons/w_portalgun.mdl',vertices=len(world_mesh.data.vertices),
                       triangles=len(world_mesh.data.polygons),materials=world_materials,
                       anchors={k:list(v) for k,v in world_anchors.items()},
                       animations=['Portal_worldidle'],
                       limitations=['The original world mesh is rigid and has no articulated gun animations'])

# Unit portal geometry: +X normal, Y and Z radii 1. Runtime sets real dimensions.
for name, ring in [('SM_PortalAperture', False), ('SM_PortalRim', True)]:
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    n = 128
    vertices = [(0, math.cos(i*2*math.pi/n)*r, math.sin(i*2*math.pi/n)*r)
                for r in ((1,1.16) if ring else (1,)) for i in range(n)]
    if ring:
        faces = [(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
        faces = [tuple(reversed(f)) for f in faces]
    else:
        vertices.append((0,0,0))
        faces = [(n,i,(i+1)%n) for i in range(n)]
    data = bpy.data.meshes.new(name)
    data.from_pydata(vertices,[],faces)
    data.uv_layers.new(name='UVMap')
    for face in data.polygons:
        for loop in face.loop_indices:
            v = data.vertices[data.loops[loop].vertex_index].co
            data.uv_layers.active.data[loop].uv = (v.y*.5+.5,.5-v.z*.5)
    obj = bpy.data.objects.new(name,data)
    bpy.context.collection.objects.link(obj)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    export(OUT / (name + '.fbx'))
(OUT / 'meshes.json').write_text(json.dumps(report, indent=2))
print('PORTAL_MESHES_COMPLETE', json.dumps(dict(vertices=report['vertices'], triangles=report['triangles'],
                                               animations=len(animations), materials=len(materials))))
