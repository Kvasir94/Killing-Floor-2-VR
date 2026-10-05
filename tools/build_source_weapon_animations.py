"""Bake original TF2 mechanism channels on the converted KF2 weapon skeleton.

Run in background Blender after inspect_source_animations.py. These separate
animation files do not overwrite the validated geometry or KF2VRSource.upk.
The Demoman hand/weapon-root motion is removed so VR tracking owns the gun.
"""
from pathlib import Path
import hashlib
import json
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from generate_floating_hands import remove_fbx_armature_container

OUT = ROOT / "build/source-weapons/animations"
OUT.mkdir(parents=True, exist_ok=True)
report = json.loads((ROOT / "build/source-weapons/animation-inspection.json").read_text())
fit_scale = json.loads((ROOT / "build/source-weapons/meshes.json").read_text())["models"]["StickybombLauncher"]["vr_fit_scale"]
demo = report["models/weapons/c_models/c_demo_animations.mdl"]
model = report["models/weapons/c_models/c_stickybomb_launcher/c_stickybomb_launcher.mdl"]
model_bones = {bone["name"]: bone for bone in model["bone_reference"]}
demo_bones = {bone["name"]: bone for bone in demo["bone_reference"]}
actions = {
    "@sb_idle": "StickyIdle", "@sb_fire": "StickyFire",
    "@sb_draw": "StickyDraw", "@sb_autofire": "StickyCharge",
    "@sb_reload_start": "StickyReloadStart", "@sb_reload_loop": "StickyReloadLoop",
    "@sb_reload_end": "StickyReloadEnd",
}


def transform(position, rotation):
    x, y, z, w = rotation
    return Matrix.LocRotScale(Vector(position) * (2.54 * fit_scale), Quaternion((w, x, y, z)), (1, 1, 1))


def remove_identity_object_animation(file):
    """Remove exporter-created identity rig channels before container stripping."""
    from io_scene_fbx import data_types, encode_bin, parse_fbx
    root, version = parse_fbx.parse(str(file))
    objects = next(e for e in root.elems if e.id == b'Objects')
    connections = next(e for e in root.elems if e.id == b'Connections')
    by_id = {e.props[0]: e for e in objects.elems}
    container = next(e.props[0] for e in objects.elems if e.id == b'Model'
                     and e.props[1].split(b'\0')[0] == b'Armature')
    tracks = {e.props[1]: e.props[3] for e in connections.elems
              if len(e.props) > 3 and e.props[2] == container and by_id[e.props[1]].id == b'AnimationCurveNode'}
    curves = {}
    for connection in connections.elems:
        if len(connection.props) > 3 and connection.props[2] in tracks:
            curve, track = connection.props[1:3]
            expected = 1 if tracks[track] == b'Lcl Scaling' else 0
            if tracks[track] not in (b'Lcl Scaling', b'Lcl Rotation', b'Lcl Translation'):
                raise ValueError('Unexpected animated Armature property')
            values = next(e.props[0] for e in by_id[curve].elems if e.id == b'KeyValueFloat')
            if any(abs(value - expected) > 1e-6 for value in values):
                raise ValueError('Refusing to discard a nonidentity Armature animation')
            curves[curve] = track
    removed = set(tracks) | set(curves)
    removed_types = {kind: sum(by_id[i].id == kind for i in removed)
                     for kind in (b'AnimationCurve', b'AnimationCurveNode')}
    objects.elems[:] = [e for e in objects.elems if e.props[0] not in removed]
    connections.elems[:] = [e for e in connections.elems if len(e.props) < 3
                            or not ({e.props[1], e.props[2]} & removed)]
    definitions = next(e for e in root.elems if e.id == b'Definitions')
    next(e for e in definitions.elems if e.id == b'Count').props[0] -= len(removed)
    for definition in definitions.elems:
        if definition.id == b'ObjectType' and definition.props[0] in removed_types:
            next(e for e in definition.elems if e.id == b'Count').props[0] -= removed_types[definition.props[0]]
    kinds = ('BOOL', 'CHAR', 'INT8', 'INT16', 'INT32', 'INT64', 'FLOAT32', 'FLOAT64', 'BYTES', 'STRING',
             'INT32_ARRAY', 'INT64_ARRAY', 'FLOAT32_ARRAY', 'FLOAT64_ARRAY', 'BOOL_ARRAY', 'BYTE_ARRAY')
    methods = {getattr(data_types, kind): 'add_' + kind.lower() for kind in kinds}
    def encode(element):
        result = encode_bin.FBXElem(element.id)
        for kind, value in zip(element.props_type, element.props):
            getattr(result, methods[kind])(value)
        result.elems = [encode(e) for e in element.elems]
        return result
    encode_bin.write(str(file), encode(root), version)


bpy.ops.wm.open_mainfile(filepath=str(ROOT / "build/source-weapons/StickybombLauncher.blend"))
rig = next(obj for obj in bpy.data.objects if obj.type == "ARMATURE")
rig.animation_data_clear()
for action in list(bpy.data.actions):
    bpy.data.actions.remove(action)
rig.animation_data_create()
scene = bpy.context.scene
scene.render.fps = 30
scene.render.fps_base = 1
scene.frame_start = 1
moving = [name for name in model_bones if name != "weapon_bone" and name in demo_bones]
reference = {}
idle_reference = {}
basis_differences = {}
idle = demo['weapon_channels']['@sb_idle']
idle_origin = transform(idle['weapon_bone']['pos'][0], idle['weapon_bone']['rot'][0])
for name in moving:
    # The original animation model makes these weapon channels siblings of
    # weapon_bone under bip_hand_R. Cancel that shared parent explicitly.
    assert demo_bones[name]["parent"] == demo_bones["weapon_bone"]["parent"]
    assert model_bones[name]["parent"] == 0
    bone = rig.data.bones["SRC_" + name]
    exported_local = bone.parent.matrix_local.inverted() @ bone.matrix_local
    source_local = transform(model_bones[name]["pos"], model_bones[name]["rot"])
    error = exported_local.inverted() @ source_local
    if error.translation.length > 0.002:
        raise ValueError(f"Converted bone pivot differs from Source: {name}: {error}")
    # Imported edit-bone roll may differ from the MDL basis. Conjugate the
    # original idle-relative motion into this mesh's actual bind basis; this
    # retains its validated idle surface and rotates around the original pivot.
    reference[name] = exported_local
    idle_reference[name] = idle_origin.inverted() @ transform(idle[name]['pos'][0], idle[name]['rot'][0])
    basis_differences[name] = error.to_quaternion().angle

stats = {}
for original, converted in actions.items():
    meta = next(a for a in demo["animations"] if a["name"] == original)
    channels = demo["weapon_channels"][original]
    assert meta["fps"] == 30 and meta["block"] == 0 and not (meta['flags'] & 4), 'Absolute mechanism takes required'
    action = bpy.data.actions.new(converted)
    action.use_fake_user = True
    rig.animation_data.action = action
    scene.frame_end = meta["frames"]
    extent = {name: {"translation_cm": 0.0, "rotation_radians": 0.0} for name in moving}
    for frame in range(meta["frames"]):
        scene.frame_set(frame + 1)
        for bone in rig.pose.bones:
            bone.rotation_mode = 'QUATERNION'
            bone.matrix_basis = Matrix.Identity(4)
        origin = transform(channels["weapon_bone"]["pos"][frame], channels["weapon_bone"]["rot"][frame])
        for name in moving:
            channel = channels.get(name)
            if channel is None:
                continue
            local = origin.inverted() @ transform(channel["pos"][frame], channel["rot"][frame])
            delta = reference[name].inverted() @ local @ idle_reference[name].inverted() @ reference[name]
            bone = rig.pose.bones["SRC_" + name]
            bone.matrix_basis = delta
            extent[name]["translation_cm"] = max(extent[name]["translation_cm"], delta.translation.length)
            extent[name]["rotation_radians"] = max(extent[name]["rotation_radians"], delta.to_quaternion().angle)
        for bone in rig.pose.bones:
            bone.keyframe_insert("location", frame=frame + 1, group=bone.name)
            bone.keyframe_insert("rotation_quaternion", frame=frame + 1, group=bone.name)
            bone.keyframe_insert("scale", frame=frame + 1, group=bone.name)
    stats[converted] = dict(source=original, frames=meta["frames"], fps=30,
                            sequence_seconds=(meta["frames"] - 1) / 30, mechanism_delta=extent)

rig.animation_data.action = bpy.data.actions["StickyIdle"]
scene.frame_set(1)
bpy.ops.object.select_all(action='DESELECT')
rig.select_set(True)
next(obj for obj in bpy.data.objects if obj.type == 'MESH').select_set(True)
bpy.context.view_layer.objects.active = rig
fbx = OUT / "StickyMechanism.fbx"
bpy.ops.export_scene.fbx(filepath=str(fbx), use_selection=True, object_types={'ARMATURE', 'MESH'},
    global_scale=1.0, apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS',
    axis_forward='Y', axis_up='Z', use_space_transform=True, bake_space_transform=False,
    add_leaf_bones=False, primary_bone_axis='Y', secondary_bone_axis='X',
    use_armature_deform_only=False, armature_nodetype='NULL', bake_anim=True,
    bake_anim_use_all_bones=True, bake_anim_use_nla_strips=False, bake_anim_use_all_actions=True,
    bake_anim_force_startend_keying=True, bake_anim_step=1, bake_anim_simplify_factor=0,
    path_mode='STRIP', embed_textures=False)
remove_identity_object_animation(fbx)
remove_fbx_armature_container(fbx)
from io_scene_fbx import parse_fbx
fbx_root, _ = parse_fbx.parse(str(fbx))
fbx_objects = next(e for e in fbx_root.elems if e.id == b'Objects')
stacks = [e.props[1].split(b'\0')[0].decode() for e in fbx_objects.elems if e.id == b'AnimationStack']
if len(stacks) != len(actions) or any(not any(s.endswith(name) for s in stacks) for name in actions.values()):
    raise ValueError(f'Missing original animation takes in exported FBX: {stacks}')
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "StickyMechanism.blend"))
result = dict(source_model_sha256=model["sha256"], source_animation_sha256=demo["sha256"],
              fbx=str(fbx), fbx_sha256=hashlib.sha256(fbx.read_bytes()).hexdigest(),
              neutralized_bone="weapon_bone", animated_bones=moving, actions=stats)
result['bind_basis_roll_difference_radians'] = basis_differences
result['exported_animation_stacks'] = stacks
(OUT / "build.json").write_text(json.dumps(result, indent=2))
print("SOURCE_ANIMATIONS_BUILT", json.dumps(result))
