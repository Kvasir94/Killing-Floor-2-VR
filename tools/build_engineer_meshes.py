"""Convert owned TF2 Engineer models/animations/textures in background Blender.

Keeps original vertices, UVs, material sources, default bodygroups, articulated
bones and animation samples. Bakes the original idle into the reference pose
so an unanimated UE mesh is upright. Retains sequence/blend/event metadata in
the local report: importing FBX animation takes is not full Source parity.
"""
from __future__ import annotations

import dataclasses
import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix, Vector, Quaternion

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'third_party'), str(ROOT / 'tools')]
from SourceIO.blender_bindings.bindings import register
from SourceIO.blender_bindings.models import import_model
from SourceIO.blender_bindings.models.common import put_into_collections
from SourceIO.blender_bindings.models.import_animations import import_animations_to_armature
from SourceIO.blender_bindings.operators.import_settings_base import ModelOptions
from SourceIO.library.models.mdl.v49 import MdlV49
from SourceIO.library.models.mdl.v44 import MdlV44
from SourceIO.library.models.mdl.load_animations import load_animations_from_mdl, AnimationData
from SourceIO.library.models.mdl.structs.local_animation import StudioAnimDesc, AnimBoneFlags, ANIM_DTYPE
from SourceIO.library.shared.content_manager import ContentManager
from SourceIO.library.shared.content_manager.providers.loose_files import LooseFilesContentProvider
from SourceIO.library.source1.vtf import load_texture
from SourceIO.library.source1.vmt import VMT
from SourceIO.library.utils import FileBuffer, TinyPath
from generate_floating_hands import remove_fbx_armature_container

SOURCE = ROOT / 'extract/engineer'
OUT = ROOT / 'build/engineer-meshes'
OUT.mkdir(parents=True, exist_ok=True)
(OUT / 'textures').mkdir(exist_ok=True)
register()
bpy.context.scene.unit_settings.system = 'METRIC'
bpy.context.scene.unit_settings.scale_length = 0.01
SPECS = [
    ('ConstructionPDA', 'models/weapons/c_models/c_pda_engineer/c_pda_engineer.mdl', 'tool'),
    ('DestructionPDA', 'models/weapons/c_models/c_builder/c_builder.mdl', 'tool'),
    ('Toolbox', 'models/weapons/c_models/c_toolbox/c_toolbox.mdl', 'tool'),
    ('Wrench', 'models/weapons/c_models/c_wrench/c_wrench.mdl', 'tool'),
    ('Wrangler', 'models/weapons/c_models/c_wrangler.mdl', 'tool'),
    ('SentryBlueprint', 'models/buildables/sentry1_blueprint.mdl', 'world'),
    *[(f'Sentry{level}', f'models/buildables/sentry{level}.mdl', 'world') for level in (1, 2, 3)],
    *[(f'Sentry{level}Build', f'models/buildables/sentry{level}_heavy.mdl', 'world') for level in (1, 2, 3)],
    ('SentryRocket', 'models/buildables/sentry3_rockets.mdl', 'static'),
    ('SentryScrap', 'models/buildables/gibs/sentry1_gib1.mdl', 'static'),
    ('SentryShield', 'models/buildables/sentry_shield.mdl', 'world'),
]


def asset_name(path: str, prefix: str) -> str:
    return prefix + hashlib.sha256(path.lower().encode()).hexdigest()[:16]


textures = {}
materials = {}

# The upstream RLE decoder adds bind values to STUDIO_ANIM_DELTA channels.
# Source stores those channels relative to zero/identity. Correct the call
# inputs locally; shared SourceIO files and other conversion tasks are untouched.
_source_rot_reader = StudioAnimDesc._read_anim_rot_value
_source_pos_reader = StudioAnimDesc._read_anim_pos_value
def _read_delta_rotation(self, buf, flags, count, base_quat, base_rot, scale):
    if flags & AnimBoneFlags.ANIM_DELTA:
        base_quat, base_rot = (0, 0, 0, 1), (0, 0, 0)
    return _source_rot_reader(self, buf, flags, count, base_quat, base_rot, scale)
def _read_delta_position(self, buf, flags, count, base_pos, scale):
    if flags & AnimBoneFlags.ANIM_DELTA:
        base_pos = (0, 0, 0)
    return _source_pos_reader(self, buf, flags, count, base_pos, scale)
StudioAnimDesc._read_anim_rot_value = _read_delta_rotation
StudioAnimDesc._read_anim_pos_value = _read_delta_position


def prepare_animated_fbx(path, expected_takes):
    """Remove only verified identity object channels before root stripping.

    Source animates bones. Blender also emits constant tracks for its identity
    Armature container; UE3 would otherwise import that extra container bone.
    """
    from io_scene_fbx import data_types, encode_bin, parse_fbx
    root, version = parse_fbx.parse(str(path))
    objects = next(e for e in root.elems if e.id == b'Objects')
    connections = next(e for e in root.elems if e.id == b'Connections')
    stacks = [e for e in objects.elems if e.id == b'AnimationStack']
    if len(stacks) != expected_takes:
        raise ValueError(f'FBX omitted animation takes: {path}: {len(stacks)}/{expected_takes}')
    by_id = {e.props[0]: e for e in objects.elems}
    container = next(e for e in objects.elems if e.id == b'Model'
                     and e.props[1].split(b'\0')[0] == b'Armature' and e.props[2] == b'Null')
    removed = set()
    for link in connections.elems:
        if len(link.props) < 4 or link.props[0] != b'OP' or link.props[2] != container.props[0]:
            continue
        node = by_id[link.props[1]]
        if node.id != b'AnimationCurveNode' or link.props[3] not in (b'Lcl Translation', b'Lcl Rotation', b'Lcl Scaling'):
            raise ValueError('Unexpected animated Armature object property')
        expected = 1.0 if link.props[3] == b'Lcl Scaling' else 0.0
        removed.add(node.props[0])
        for curve_link in connections.elems:
            if curve_link.props[2] != node.props[0]:
                continue
            curve = by_id[curve_link.props[1]]
            keys = next(e for e in curve.elems if e.id == b'KeyValueFloat').props[0]
            if curve.id != b'AnimationCurve' or any(abs(v - expected) > 0.000001 for v in keys):
                raise ValueError('Refusing to remove nonidentity Armature animation')
            removed.add(curve.props[0])
    removed_types = Counter(by_id[i].id for i in removed)
    objects.elems[:] = [e for e in objects.elems if e.props[0] not in removed]
    connections.elems[:] = [e for e in connections.elems if e.props[1] not in removed and e.props[2] not in removed]
    definitions = next(e for e in root.elems if e.id == b'Definitions')
    next(e for e in definitions.elems if e.id == b'Count').props[0] -= len(removed)
    for definition in definitions.elems:
        if definition.id == b'ObjectType' and definition.props[0] in removed_types:
            next(e for e in definition.elems if e.id == b'Count').props[0] -= removed_types[definition.props[0]]
    names = ('BOOL', 'CHAR', 'INT8', 'INT16', 'INT32', 'INT64', 'FLOAT32', 'FLOAT64',
             'BYTES', 'STRING', 'INT32_ARRAY', 'INT64_ARRAY', 'FLOAT32_ARRAY',
             'FLOAT64_ARRAY', 'BOOL_ARRAY', 'BYTE_ARRAY')
    methods = {getattr(data_types, n): 'add_' + n.lower() for n in names}
    def encode(element):
        result = encode_bin.FBXElem(element.id)
        for typ, value in zip(element.props_type, element.props):
            getattr(result, methods[typ])(value)
        result.elems = [encode(child) for child in element.elems]
        return result
    encode_bin.write(str(path), encode(root), version)


def original_animations(mdl, buf, cm, path, visited=None):
    """Resolve every include and reject incomplete animation decodes."""
    visited = set() if visited is None else visited
    key = str(path).lower()
    if key in visited:
        raise ValueError(f'Animation include cycle: {path}')
    visited.add(key)
    loaded = load_animations_from_mdl(mdl, buf, cm, path)
    if len(loaded) != len(mdl.anim_descs):
        raise ValueError(f'Incomplete original animation decode: {path}')
    for anim in loaded:
        for bone in mdl.bones:
            if bone.name not in anim.frames:
                # An omitted track means bind pose (or neutral delta), not an
                # omitted animation. Constant takes still need FBX channels.
                frames = np.zeros(anim.frame_count, ANIM_DTYPE)
                frames['pos'] = (0, 0, 0) if anim.is_delta else bone.position
                frames['rot'] = (0, 0, 0, 1) if anim.is_delta else bone.quat
                anim.frames[bone.name] = frames
    sequences = []
    for sequence in mdl.sequences:
        value = dataclasses.asdict(sequence)
        value['model'] = str(path)
        value['animation_names'] = [loaded[i].name for i in sequence.anim_desc_indices]
        sequences.append(value)
    for included in mdl.include_models:
        inc_path = SOURCE / included
        if not inc_path.is_file():
            raise FileNotFoundError(f'Missing original animation include: {included}')
        with FileBuffer(TinyPath(str(inc_path))) as inc_buf:
            version = int.from_bytes(inc_path.read_bytes()[4:8], 'little')
            inc_mdl = (MdlV49 if version >= 45 else MdlV44).from_buffer(inc_buf)
            inc_loaded, inc_sequences = original_animations(inc_mdl, inc_buf, cm, TinyPath(str(inc_path)), visited)
        loaded.extend(inc_loaded)
        sequences.extend(inc_sequences)
    visited.remove(key)
    return loaded, sequences


def world_export_animations(rig, originals):
    """Export deltas as target poses, retaining their additive provenance.

    FBX has no Source delta-track flag. The runtime must blend these against
    the baked reference pose; base construction and upgrade takes are absolute.
    """
    result = []
    for anim in originals:
        if not anim.is_delta:
            result.append(anim)
            continue
        tracks = {}
        for name, frames in anim.frames.items():
            bone = rig.data.bones[name]
            local = bone.parent.matrix_local.inverted() @ bone.matrix_local if bone.parent else bone.matrix_local
            position, rotation = local.to_translation() / 2.54, local.to_quaternion()
            absolute = frames.copy()
            for index, frame in enumerate(frames):
                x, y, z, w = frame['rot']
                q = rotation @ Quaternion((w, x, y, z))
                absolute[index]['pos'] = position + Vector(frame['pos'])
                absolute[index]['rot'] = (q.x, q.y, q.z, q.w)
            tracks[name] = absolute
        result.append(AnimationData(anim.name, anim.fps, anim.frame_count, anim.bone_names,
                                    tracks, anim.is_looping, False))
    return result


def texture_file(relative: str) -> str:
    relative = relative.lower().replace('\\', '/').removesuffix('.vtf')
    path = SOURCE / 'materials' / (relative.removeprefix('materials/') + '.vtf')
    if not path.is_file():
        raise FileNotFoundError(f'Original texture missing: {path}')
    key = str(path.relative_to(SOURCE)).replace('\\', '/')
    if key not in textures:
        pixels, height, width = load_texture(FileBuffer(TinyPath(str(path))))
        if pixels is None:
            raise ValueError(f'Cannot decode {path}')
        image = bpy.data.images.new(asset_name(key, 'Tex_'), width=width, height=height, alpha=True)
        image.colorspace_settings.name = 'Non-Color'
        image.pixels.foreach_set(pixels.ravel())
        target = OUT / 'textures' / (asset_name(key, 'Tex_') + '.tga')
        image.file_format = 'TARGA'
        image.filepath_raw = str(target)
        image.save()
        bpy.data.images.remove(image)
        textures[key] = {'file': str(target), 'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                         'source_sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'width': width, 'height': height}
    return textures[key]['file']


def material_entry(source_name: str, search_paths=()) -> str:
    source_name = source_name.lower().removesuffix('.vmt')
    # Source material names may be relative to any of the MDL's cdmaterials
    # directories. SourceIO keeps those short names on several buildables.
    candidates = [source_name] + [str(Path(p) / source_name).replace('\\', '/').lower() for p in search_paths]
    source_name = next((p for p in candidates if (SOURCE / 'materials' / (p + '.vmt')).is_file()), source_name)
    if source_name in materials:
        return materials[source_name]['name']
    path = SOURCE / 'materials' / (source_name + '.vmt')
    if not path.is_file():
        raise FileNotFoundError(f'Original material missing: {path}')
    # VMT numeric values can be unquoted; patches/conditions and comments are
    # grammar, not regex texture references. Use SourceIO's actual KV parser.
    with FileBuffer(TinyPath(str(path))) as buffer:
        vmt = VMT(buffer, source_name, cm)
    props = {k.lower(): v for k, v in vmt.data.items() if k.startswith('$') and isinstance(v, str)}
    if '$basetexture' not in props:
        # Blueprint materials use an envmap/tint without a diffuse texture.
        if 'blueprint' not in source_name:
            raise ValueError(f'Unresolved original material shader: {path}')
    entry = {'name': asset_name(source_name, 'Mat_'), 'source': source_name, 'shader': vmt.shader,
             'source_sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'properties': props,
             'diffuse': texture_file(props['$basetexture']) if '$basetexture' in props else '',
             'normal': texture_file(props['$bumpmap']) if '$bumpmap' in props else '',
             'lightwarp': texture_file(props['$lightwarptexture']) if '$lightwarptexture' in props else ''}
    materials[source_name] = entry
    return entry['name']


models = {}
for name, relative, kind in SPECS:
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)
    for mat in list(bpy.data.materials):
        bpy.data.materials.remove(mat)
    cm = ContentManager()
    cm.children.clear()
    for cache in (cm._cache, cm._exists_cache, cm._owner_cache):
        cache.clear()
    cm.children.add(LooseFilesContentProvider(TinyPath(str(SOURCE))))
    path = TinyPath(str(SOURCE / relative))
    options = ModelOptions.default()
    options.scale = 2.54
    options.import_textures = False
    # Use SourceIO's current, name-matched animation decoder, not its older
    # ndarray-indexed import_mdl49.import_animations compatibility path.
    options.import_animations = kind != 'static'
    options.import_include_animations = kind != 'static'
    with FileBuffer(path) as buf:
        version = int.from_bytes((SOURCE / relative).read_bytes()[4:8], 'little')
        mdl = (MdlV49 if version >= 45 else MdlV44).from_buffer(buf)
        raw_animations, sequences = original_animations(mdl, buf, cm, path) if kind != 'static' else ([], [])
    with FileBuffer(path) as buf:
        container = import_model(path, buf, cm, options)
    put_into_collections(container, name, bodygroup_grouping=False)
    rig = container.armature
    part_lookup = {(model.name if version >= 45 else part.name + '_' + model.name): (part.name, index)
                   for part in mdl.body_parts for index, model in enumerate(part.models) if model.vertex_count > 0}
    meshes = [o for o in container.objects if o.name in part_lookup
              and (kind == 'world' or part_lookup[o.name][1] == 0)]
    if not meshes:
        raise ValueError(f'No default visible bodygroups in {relative}')
    for mesh in meshes:
        mesh.data.__class__ = bpy.types.Mesh
    default_animation = next((a for a in ('@aim_nat', '@idle', 'a_idle', '@idle_off') if bpy.data.actions.get(a)), None)
    if rig and default_animation:
        rig.animation_data_create()
        rig.animation_data.action = bpy.data.actions[default_animation]
        bpy.context.scene.frame_set(1)
    bpy.context.view_layer.update()
    # Bake the original idle, with no edited vertices or guessed orientation.
    if rig:
        for mesh in meshes:
            evaluated = mesh.evaluated_get(bpy.context.evaluated_depsgraph_get())
            baked = bpy.data.meshes.new_from_object(evaluated, preserve_all_data_layers=True,
                                                  depsgraph=bpy.context.evaluated_depsgraph_get())
            mesh.data = baked
        bpy.ops.object.select_all(action='DESELECT')
        rig.select_set(True); bpy.context.view_layer.objects.active = rig
        bpy.ops.object.mode_set(mode='POSE')
        bpy.ops.pose.armature_apply(selected=False)
        bpy.ops.object.mode_set(mode='OBJECT')
        rig.animation_data_clear()
    # Attachments get their own bones. UE sockets can then follow the original
    # articulated parent without guessing an FBX local-axis conversion.
    sockets = []
    if rig:
        bpy.context.view_layer.update()
        socket_matrices = [(a.name.split('.')[0], a.matrix_world.copy(),
                            next((c.subtarget for c in a.constraints if c.type == 'CHILD_OF'), '')) for a in container.attachments]
        bpy.ops.object.mode_set(mode='EDIT')
        for socket, matrix, parent in socket_matrices:
            bone = rig.data.edit_bones.new('ATT_' + socket)
            bone.matrix = matrix; bone.length = 1
            bone.parent = rig.data.edit_bones.get(parent) or rig.data.edit_bones[0]
            sockets.append({'name': socket, 'bone': bone.name})
        bpy.ops.object.mode_set(mode='OBJECT')
    # Map each mesh material once; preserve the original-to-generated mapping.
    slot_sources, slot_parts = {}, {}
    for mesh in meshes:
        for mat in mesh.data.materials:
            if not mat.name.startswith('Mat_'):
                mat.name = material_entry(mat.name, mdl.materials_paths)
        if kind == 'world':
            # A unique FBX material slot per bodygroup variant keeps geometry
            # switchable through UE3 ShowMaterialSection. Each slot is bound
            # back to the same original material after import, without copying
            # textures or changing their pixels.
            group, variant = part_lookup[mesh.name]
            for index, mat in enumerate(mesh.data.materials):
                distinct = mat.copy()
                distinct.name = asset_name(f'{name}/{group}/{variant}/{mat.name}', 'Slot_')
                slot_sources[distinct.name] = mat.name
                slot_parts[distinct.name] = (group, variant)
                mesh.data.materials[index] = distinct
    bpy.ops.object.select_all(action='DESELECT')
    for mesh in meshes: mesh.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.join()
    mesh = bpy.context.view_layer.objects.active
    mesh.name = name
    if kind == 'tool':
        if rig is None: raise ValueError(f'Missing tool rig: {name}')
        original_bones = [(b.name, b.parent.name if b.parent else None, b.matrix_local.copy()) for b in rig.data.bones]
        axes = Matrix(((0,0,1,0),(-1,0,0,0),(0,-1,0,0),(0,0,0,1)))
        normalization = axes @ Matrix.Translation(-rig.data.bones['weapon_bone'].head_local)
        before = set(bpy.data.objects)
        bpy.ops.psk.import_file(filepath=str(ROOT / 'extract/weapons/WEP_1P_MB500_MESH/SkeletalMesh3/Wep_1stP_MB500_Rig.psk'), scale=1.0)
        hand_rig = next(o for o in set(bpy.data.objects) - before if o.type == 'ARMATURE')
        kfroot = hand_rig.data.bones['RW_Weapon'].matrix_local.copy()
        transform = kfroot @ normalization
        mesh.data.transform(transform)
        bpy.ops.object.select_all(action='DESELECT')
        hand_rig.select_set(True); bpy.context.view_layer.objects.active = hand_rig
        bpy.ops.object.mode_set(mode='EDIT')
        for bone_name, parent_name, matrix in original_bones:
            bone = hand_rig.data.edit_bones.new('SRC_' + bone_name)
            bone.matrix = transform @ matrix; bone.length = 1
            bone.parent = hand_rig.data.edit_bones['SRC_' + parent_name] if parent_name else hand_rig.data.edit_bones['RW_Weapon']
        for anchor, point in [('VR_PrimaryGrip', Vector((0,0,0))), ('VR_Muzzle', Vector((30,0,0)))]:
            bone = hand_rig.data.edit_bones.new(anchor)
            bone.head = kfroot @ point; bone.tail = bone.head + Vector((0,1,0))
            bone.parent = hand_rig.data.edit_bones['RW_Weapon']
        bpy.ops.object.mode_set(mode='OBJECT')
        for group in mesh.vertex_groups: group.name = 'SRC_' + group.name
        for modifier in list(mesh.modifiers): mesh.modifiers.remove(modifier)
        modifier = mesh.modifiers.new('OriginalToolRig', 'ARMATURE'); modifier.object = hand_rig
        mesh.parent = hand_rig; rig = hand_rig
        sockets = [{'name': 'MuzzleFlash', 'bone': 'VR_Muzzle'}]
        # c_engineer_animations supplies viewmodel animation. Retargeting and
        # blending those tracks into the KF2 hand rig is a separate parity gate.
        animations = []
    elif rig and kind == 'world':
        for action in list(bpy.data.actions): bpy.data.actions.remove(action)
        actions = import_animations_to_armature(rig, world_export_animations(rig, raw_animations), 2.54)
        if len(actions) != len(raw_animations):
            raise ValueError(f'Incomplete animation conversion: {name}: {len(actions)}/{len(raw_animations)}')
        animations = []
        for action, original in zip(actions, raw_animations):
            action.name = 'Source_' + re.sub(r'[^A-Za-z0-9_]', '', original.name)
            animations.append({'take': action.name, 'source': original.name, 'fps': original.fps,
                               'frames': original.frame_count, 'delta': original.is_delta, 'looping': original.is_looping})
        rig.animation_data_clear()
        # Blender's all-actions exporter skips an object with no AnimData,
        # even when matching actions exist. Retain an empty AnimData owner.
        rig.animation_data_create()
    else:
        animations = []
    export_objects = [mesh] + ([rig] if rig and kind != 'static' else [])
    if kind == 'static':
        mesh.parent = None
        for modifier in list(mesh.modifiers): mesh.modifiers.remove(modifier)
    for obj in list(bpy.data.objects):
        if obj not in export_objects: bpy.data.objects.remove(obj, do_unlink=True)
    if rig and kind != 'static': rig.name = 'Armature'
    bpy.ops.object.select_all(action='SELECT')
    bpy.context.view_layer.objects.active = mesh
    fbx = OUT / (name + '.fbx')
    bpy.context.scene.render.fps = 30
    bpy.ops.export_scene.fbx(filepath=str(fbx), use_selection=True, object_types={'ARMATURE','MESH'},
        global_scale=1.0, apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS',
        axis_forward='Y', axis_up='Z', use_space_transform=True, bake_space_transform=False,
        add_leaf_bones=False, primary_bone_axis='Y', secondary_bone_axis='X',
        use_armature_deform_only=False, armature_nodetype='NULL', bake_anim=bool(animations),
        bake_anim_use_all_actions=True, bake_anim_use_nla_strips=False, bake_anim_simplify_factor=0,
        use_mesh_modifiers=True, mesh_smooth_type='FACE', path_mode='STRIP', embed_textures=False)
    if animations: prepare_animated_fbx(fbx, len(animations))
    if rig and kind != 'static': remove_fbx_armature_container(fbx)
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / (name + '.blend')))
    models[name] = {'source': relative, 'kind': kind, 'fbx': str(fbx), 'sha256': hashlib.sha256(fbx.read_bytes()).hexdigest(),
                    'vertices': len(mesh.data.vertices), 'triangles': len(mesh.data.polygons),
                    'materials': [slot_sources.get(m.name, m.name) for m in mesh.data.materials], 'sockets': sockets,
                    'material_bodygroups': [dict(slot=i, group=slot_parts[m.name][0], variant=slot_parts[m.name][1])
                                           for i, m in enumerate(mesh.data.materials) if m.name in slot_parts],
                    'default_animation': default_animation, 'animations': animations,
                    'sequences': sequences,
                    'bodygroups': [{'name': p.name, 'models': [m.name for m in p.models]} for p in mdl.body_parts],
                    'bounds': [[min(v.co[i] for v in mesh.data.vertices) for i in range(3)],
                               [max(v.co[i] for v in mesh.data.vertices) for i in range(3)]]}
    print('ENGINEER_MESH_COMPLETE', name, models[name]['vertices'], flush=True)

# HUD images are original TF2 pixels, even where a KF2-specific layout is used.
for path in (SOURCE / 'materials/hud').glob('*.vmt'):
    try: material_entry(str(path.relative_to(SOURCE / 'materials')).replace('\\','/').removesuffix('.vmt'))
    except ValueError: pass
for path in ['effects/sniperdot_red', 'effects/sniperdot_blue',
             'backpack/weapons/c_models/c_wrangler', 'backpack/weapons/c_models/c_wrangler_large']:
    material_entry(path)

# Source draws the laser dot as a camera-facing sprite. A unit quad supplies
# the same UVs; the runtime scales its width/height to the original six units.
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
data = bpy.data.meshes.new('WranglerDot')
data.from_pydata([(0,-0.5,-0.5),(0,0.5,-0.5),(0,0.5,0.5),(0,-0.5,0.5)], [], [(0,1,2,3)])
uv = data.uv_layers.new(name='UVMap')
for loop, value in zip(data.loops, [(0,1),(1,1),(1,0),(0,0)]): uv.data[loop.index].uv = value
mat_name = material_entry('effects/sniperdot_red')
data.materials.append(bpy.data.materials.get(mat_name) or bpy.data.materials.new(mat_name))
quad = bpy.data.objects.new('WranglerDot', data)
bpy.context.collection.objects.link(quad)
quad.select_set(True)
bpy.context.view_layer.objects.active = quad
fbx = OUT / 'WranglerDot.fbx'
bpy.ops.export_scene.fbx(filepath=str(fbx), use_selection=True, object_types={'MESH'},
    global_scale=1.0, apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS',
    axis_forward='Y', axis_up='Z', mesh_smooth_type='FACE', path_mode='STRIP')
models['WranglerDot'] = {'source': 'Source DrawSprite unit quad', 'kind': 'static', 'fbx': str(fbx),
    'sha256': hashlib.sha256(fbx.read_bytes()).hexdigest(), 'materials': [mat_name], 'animations': [],
    'vertices': 4, 'triangles': 2, 'sockets': [], 'bounds': [[0,-0.5,-0.5],[0,0.5,0.5]]}
report = {'schema': 'kf2vr/engineer-meshes/1', 'generator_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
          'extract_sha256': hashlib.sha256((SOURCE / 'manifest.json').read_bytes()).hexdigest(),
          'models': models, 'materials': materials, 'textures': textures,
          'parity_pending': ['viewmodel animation retargeting', 'Source sequence blends/events/pose parameters',
                             'skin/bodygroup runtime changes', 'Source lighting/shader matching']}
(OUT / 'manifest.json').write_text(json.dumps(report, indent=2, default=str))
print('ENGINEER_MESHES_COMPLETE', len(models), flush=True)
