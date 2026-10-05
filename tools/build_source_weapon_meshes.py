"""Convert owned Valve meshes to the KF2 hand skeleton in background Blender.

Source geometry, UVs, normals, materials, articulated bones and sockets are
retained. The KF2 mesh contributes only its rig, never replacement gun geometry.
All generated artwork and source-derived metadata stay under ignored build/.
"""
from pathlib import Path
import hashlib
import json
import math
import sys

import bpy
import bmesh
from mathutils import Matrix, Vector, Quaternion

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'third_party'), str(ROOT / 'tools')]
from SourceIO.blender_bindings.bindings import register
from SourceIO.blender_bindings.models import import_model
from SourceIO.blender_bindings.models.common import put_into_collections
from SourceIO.blender_bindings.operators.import_settings_base import ModelOptions
from SourceIO.library.shared.content_manager import ContentManager
from SourceIO.library.shared.content_manager.providers.loose_files import LooseFilesContentProvider
from SourceIO.library.utils import FileBuffer, TinyPath
from SourceIO.library.source1.vtf import load_texture
from SourceIO.library.models.mdl.v49 import MdlV49
from generate_floating_hands import remove_fbx_armature_container
from repair_gravity_viewmodel import repair_viewmodel
from source_texture_sheets import read_sheet, repack_sheet, write_tga

OUT = ROOT / 'build/source-weapons'
OUT.mkdir(parents=True, exist_ok=True)
register()
bpy.context.scene.unit_settings.system = 'METRIC'
bpy.context.scene.unit_settings.scale_length = 0.01
specs = [
    ('gravity', 'models/weapons/v_superphyscannon.mdl', 'SuperGravityGun',
     Matrix(((0,-1,0,0),(1,0,0,0),(0,0,1,0),(0,0,0,1))), 'Base'),
    ('sticky', 'models/weapons/c_models/c_stickybomb_launcher/c_stickybomb_launcher.mdl', 'StickybombLauncher',
     Matrix(((0,0,1,0),(1,0,0,0),(0,1,0,0),(0,0,0,1))), 'weapon_bone'),
    ('sticky', 'models/weapons/w_models/w_stickybomb.mdl', 'Stickybomb', Matrix.Identity(4), 'polymsh1'),
]
reports = {}

for kind, relative, name, axes, root_name in specs:
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    cm = ContentManager()
    cm.children.clear()
    for cache in (cm._cache, cm._exists_cache, cm._owner_cache):
        cache.clear()
    source_root = ROOT / 'extract/source-weapons' / kind
    cm.children.add(LooseFilesContentProvider(TinyPath(str(source_root))))
    opt = ModelOptions.default()
    # Source viewmodels were authored for a flat-screen camera. Fit the held
    # geometry to adult VR hands; leave the KF donor hand skeleton at scale 1.
    # The bomb's mesh radius also needs to match its 5.08 UU swept collision.
    fit_scale = 0.6 if name != 'Stickybomb' else 1.0 / 3.0
    opt.scale = 2.54 * fit_scale
    path = TinyPath(str(source_root / relative))
    with FileBuffer(path) as f:
        container = import_model(path, f, cm, opt)
    put_into_collections(container, name, bodygroup_grouping=False)
    bpy.context.view_layer.update()
    original_rig = container.armature
    normalization = axes @ Matrix.Translation(-original_rig.data.bones[root_name].head_local)
    attachments = {a.name.split('.')[0]: normalization @ a.matrix_world.translation for a in container.attachments}
    attachment_parents = {a.name.split('.')[0]: next((c.subtarget for c in a.constraints if c.type == 'CHILD_OF'), root_name)
                          for a in container.attachments}
    mesh = container.objects[0]
    # SourceIO's Python acceleration subclass must be unwrapped before C-side
    # Blender operators, which require the exact bpy.types.Mesh RNA wrapper.
    mesh.data.__class__ = bpy.types.Mesh
    # Remove Gordon's baked viewmodel hand; the existing tracked floating KF2
    # hand rig supplies both hands in VR. The weapon itself is untouched.
    removed_faces = 0
    bm = bmesh.new()
    bm.from_mesh(mesh.data)
    hands = [f for f in bm.faces if 'hand' in mesh.data.materials[f.material_index].name.lower()]
    removed_faces = len(hands)
    bmesh.ops.delete(bm, geom=hands, context='FACES')
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
    bm.to_mesh(mesh.data)
    bm.free()
    repair = None
    claw_poses = {}
    if kind == 'gravity':
        world_path = TinyPath(str(source_root / 'models/weapons/w_physics.mdl'))
        world = import_model(world_path, FileBuffer(world_path), cm, opt)
        put_into_collections(world, 'Gravity completion reference', bodygroup_grouping=False)
        bpy.context.view_layer.update()
        world.objects[0].data.__class__ = bpy.types.Mesh
        repair = repair_viewmodel(container, world, opt.scale)
        mdl = MdlV49.from_buffer(FileBuffer(path))
        closed = next(a for d, a in zip(mdl.anim_descs, mdl.animations) if d.name == 'ProngsShut')
        for bone_name, frames in closed.items():
            b = original_rig.data.bones[bone_name]
            frame = frames[0]
            x, y, z, w = frame['rot']
            transform = Matrix.LocRotScale(Vector(frame['pos']) * opt.scale, Quaternion((w,x,y,z)), (1,1,1))
            basis = b.matrix_local.inverted() @ b.parent.matrix_local @ transform
            claw_poses['SRC_' + bone_name] = {'position': list(basis.translation), 'rotation': list(basis.to_quaternion())}
        mirror_basis = Matrix.Diagonal((-1,1,1,1))
        b = claw_poses['SRC_Prong_B']
        third = mirror_basis @ Matrix.LocRotScale(Vector(b['position']), Quaternion(b['rotation']), (1,1,1)) @ mirror_basis
        claw_poses['SRC_Prong_C'] = {'position': list(third.translation), 'rotation': list(third.to_quaternion())}
        for suffix in ('b', 'm', 't'):
            key = 'fork2' + suffix
            point = normalization.inverted() @ attachments[key]
            point.x = 2 * original_rig.data.bones['Prong_A'].head_local.x - point.x
            attachments['fork3' + suffix] = normalization @ point
            attachment_parents['fork3' + suffix] = attachment_parents[key].replace('_B', '_C')
    original_bones = [(b.name, b.parent.name if b.parent else None, b.matrix_local.copy()) for b in original_rig.data.bones]
    mesh.data.transform(normalization)
    used_materials = {p.material_index for p in mesh.data.polygons}
    for slot in reversed(range(len(mesh.data.materials))):
        if slot not in used_materials: mesh.data.materials.pop(index=slot)
    mesh.parent = None
    mesh.matrix_world = Matrix.Identity(4)
    for modifier in list(mesh.modifiers):
        mesh.modifiers.remove(modifier)
    bounds = [min(v.co[i] for v in mesh.data.vertices) for i in range(3)], [max(v.co[i] for v in mesh.data.vertices) for i in range(3)]
    # UE material names are intentionally short and stable. The original VMT
    # names and paths remain in the conversion report for provenance.
    source_materials = [m.name for m in mesh.data.materials]
    for i, m in enumerate(mesh.data.materials):
        m.name = name + ('Material' if i == 0 else f'Material{i}')
    if name != 'Stickybomb':
        primary = normalization @ original_rig.data.bones['Handle'].head_local if kind == 'gravity' else Vector((-7,0,-14)) * fit_scale
        support = (Vector((18, 0, -8)) if kind == 'gravity' else Vector((52, 0, -13))) * fit_scale
        muzzle = attachments.get('muzzle', Vector((bounds[1][0], 0, 0)))
        before = set(bpy.data.objects)
        bpy.ops.psk.import_file(filepath=str(ROOT / 'extract/weapons/WEP_1P_MB500_MESH/SkeletalMesh3/Wep_1stP_MB500_Rig.psk'), scale=1.0)
        rig = next(o for o in set(bpy.data.objects) - before if o.type == 'ARMATURE')
        kfroot = rig.data.bones['RW_Weapon'].matrix_local.copy()
        for o in set(bpy.data.objects) - before:
            if o.type == 'MESH':
                bpy.data.objects.remove(o, do_unlink=True)
        mesh.data.transform(kfroot)
        bpy.ops.object.select_all(action='DESELECT')
        rig.select_set(True)
        bpy.context.view_layer.objects.active = rig
        bpy.ops.object.mode_set(mode='EDIT')
        for bone_name, parent_name, transform in original_bones:
            bone = rig.data.edit_bones.new('SRC_' + bone_name)
            bone.matrix = kfroot @ normalization @ transform
            bone.length = 1
            bone.parent = rig.data.edit_bones['SRC_' + parent_name] if parent_name else rig.data.edit_bones['RW_Weapon']
        anchors = {'VR_PrimaryGrip': primary, 'VR_SupportGrip': support, 'VR_Muzzle': muzzle}
        anchors.update({'VR_' + key: value for key, value in attachments.items() if key != 'muzzle'})
        for anchor, point in anchors.items():
            bone = rig.data.edit_bones.new(anchor)
            bone.head = kfroot @ point
            bone.tail = bone.head + kfroot.to_3x3() @ Vector((0,1,0))
            parent = attachment_parents.get(anchor.removeprefix('VR_'))
            bone.parent = rig.data.edit_bones['SRC_' + parent] if parent else rig.data.edit_bones['RW_Weapon']
        for bone_name, pose in claw_poses.items():
            source = rig.data.edit_bones[bone_name]
            bone = rig.data.edit_bones.new('VR_ClawClosed_' + bone_name[-1])
            bone.matrix = source.matrix @ Matrix.LocRotScale(Vector(pose['position']), Quaternion(pose['rotation']), (1,1,1))
            bone.length = 1
            bone.parent = source.parent
        bpy.ops.object.mode_set(mode='OBJECT')
        for group in mesh.vertex_groups:
            group.name = 'SRC_' + group.name
        modifier = mesh.modifiers.new('KF2_SourceRig', 'ARMATURE')
        modifier.object = rig
        mesh.parent = rig
        if claw_poses: rig['source_claw_closed'] = json.dumps(claw_poses)
        export_objects = [rig, mesh]
        original_rig.hide_render = True
    else:
        anchors = {}
        export_objects = [mesh]
    for o in list(bpy.data.objects):
        if o not in export_objects:
            bpy.data.objects.remove(o, do_unlink=True)
    mesh.name = name
    if name != 'Stickybomb': rig.name = 'Armature'
    bpy.ops.object.select_all(action='SELECT')
    fbx = OUT / (name + '.fbx')
    bpy.ops.export_scene.fbx(filepath=str(fbx), use_selection=True, object_types={'ARMATURE','MESH'},
        global_scale=1.0, apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS',
        axis_forward='Y', axis_up='Z', use_space_transform=True, bake_space_transform=False,
        add_leaf_bones=False, primary_bone_axis='Y', secondary_bone_axis='X',
        use_armature_deform_only=False, armature_nodetype='NULL', bake_anim=False,
        use_mesh_modifiers=True, mesh_smooth_type='FACE', path_mode='STRIP', embed_textures=False)
    if name != 'Stickybomb': remove_fbx_armature_container(fbx)
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / (name + '.blend')))
    reports[name] = {'source': str(path), 'fbx_sha256': hashlib.sha256(fbx.read_bytes()).hexdigest(),
        'vertices': len(mesh.data.vertices), 'triangles': len(mesh.data.polygons), 'removed_hand_faces': removed_faces,
        'materials': source_materials, 'repair': repair, 'claw_closed_pose': claw_poses, 'vr_fit_scale': fit_scale, 'bounds_cm': bounds, 'anchors': {k:list(v) for k,v in anchors.items()},
        'bones': [b.name for b in rig.data.bones] if name != 'Stickybomb' else []}

# Preserve original VTF pixel bytes and unpack Source's sprite sequences.
texture_root = OUT / 'textures'
texture_root.mkdir(exist_ok=True)
for kind in ('gravity', 'sticky'):
    for path in (ROOT / 'extract/source-weapons' / kind / 'materials').rglob('*.vtf'):
        data, height, width = load_texture(FileBuffer(TinyPath(str(path))))
        if data is None: raise RuntimeError(f'VTF decode failed: {path}')
        tex_name = kind + '_' + path.stem
        sheet = read_sheet(path.read_bytes())
        if sheet:
            data, metadata = repack_sheet(data, sheet)
            (texture_root / (tex_name + '.sheet.json')).write_text(json.dumps(metadata, indent=2))
        write_tga(texture_root / (tex_name + '.tga'), data)
(OUT / 'meshes.json').write_text(json.dumps({'generator_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                            'models': reports}, indent=2))
print('SOURCE_WEAPON_MESHES_COMPLETE', json.dumps({k: {'vertices': v['vertices'], 'bones': len(v['bones'])} for k,v in reports.items()}))
