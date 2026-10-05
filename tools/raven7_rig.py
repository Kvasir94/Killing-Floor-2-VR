"""RAVEN-7 first-person rig, authored grip review and UI icon (Blender).

Called by raven7_model.main() with the finished, export-scaled weapon object.
Writes, beside VRTomahawk.fbx in build/hand-meshes/:
  VRTomahawk.fbx      the static prop with UCX collision (thrown/dropped axe)
  VRTomahawkRig.fbx   VRFloatingHands skeleton + RW_Weapon, the weapon skinned
                      rigidly to RW_Weapon, and every stock one-handed melee
                      take holding the solved grip (also the reference pose)
  VRTomahawk3P.fbx    one-bone third-person attachment in the knife's socket
                      frame
  VRTomahawkIcon.tga  white-on-transparent weapon silhouette for the trader and
                      the VR weapon selector
and grip review renders to build/tomahawks/raven7/. The grip itself is solved
by raven7_grip.py against the rendered hand's skin.
"""
from pathlib import Path
import hashlib
import math
import sys

import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import raven7_grip as grip  # noqa: E402
from generate_floating_hands import remove_fbx_armature_container  # noqa: E402


def quaternion(q):
    return Quaternion((q[3], q[0], q[1], q[2]))


def strip_container_animation(path):
    """Drop Blender's constant identity channels on the Armature container.

    UE3 has no Armature stripping; remove_fbx_armature_container then removes
    the container itself. Same verified postpass as build_engineer_meshes.py.
    """
    from io_scene_fbx import data_types, encode_bin, parse_fbx
    root, version = parse_fbx.parse(str(path))
    objects = next(e for e in root.elems if e.id == b'Objects')
    connections = next(e for e in root.elems if e.id == b'Connections')
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
            values = next(e for e in curve.elems if e.id == b'KeyValueFloat').props[0]
            if curve.id != b'AnimationCurve' or any(abs(v - expected) > 1e-6 for v in values):
                raise ValueError('Refusing to remove nonidentity Armature animation')
            removed.add(curve.props[0])
    counts = {}
    for i in removed:
        counts[by_id[i].id] = counts.get(by_id[i].id, 0) + 1
    objects.elems[:] = [e for e in objects.elems if e.props[0] not in removed]
    connections.elems[:] = [e for e in connections.elems if e.props[1] not in removed and e.props[2] not in removed]
    definitions = next(e for e in root.elems if e.id == b'Definitions')
    next(e for e in definitions.elems if e.id == b'Count').props[0] -= len(removed)
    for definition in definitions.elems:
        if definition.id == b'ObjectType' and definition.props[0] in counts:
            next(e for e in definition.elems if e.id == b'Count').props[0] -= counts[definition.props[0]]
    names = ('BOOL', 'CHAR', 'INT8', 'INT16', 'INT32', 'INT64', 'FLOAT32', 'FLOAT64', 'BYTES', 'STRING',
             'INT32_ARRAY', 'INT64_ARRAY', 'FLOAT32_ARRAY', 'FLOAT64_ARRAY', 'BOOL_ARRAY', 'BYTE_ARRAY')
    methods = {getattr(data_types, n): 'add_' + n.lower() for n in names}
    def encode(element):
        result = encode_bin.FBXElem(element.id)
        for kind, value in zip(element.props_type, element.props):
            getattr(result, methods[kind])(value)
        result.elems = [encode(child) for child in element.elems]
        return result
    encode_bin.write(str(path), encode(root), version)


def weapon_matrix(result):
    """Authored model space -> rig component space (RW_Weapon * model offset)."""
    return (Matrix.Translation(Vector(result['rw_p'])) @ quaternion(result['rw_q']).to_matrix().to_4x4()
            @ Matrix.Translation(Vector(result['model_offset'])))


def white_emission():
    mat = bpy.data.materials.new('RAVEN icon white')
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    nodes.clear()
    out = nodes.new('ShaderNodeOutputMaterial')
    emit = nodes.new('ShaderNodeEmission'); emit.inputs[1].default_value = 1.0
    mat.node_tree.links.new(emit.outputs[0], out.inputs[0])
    return mat


def render_icon(source, path):
    """KF2 weapon-select art: flat white silhouette, head right, blade down."""
    scene = bpy.data.scenes.new('RAVEN-7 icon')
    icon = bpy.data.objects.new('RAVEN-7 icon', source.data.copy())
    scene.collection.objects.link(icon)
    icon.data.materials.clear(); icon.data.materials.append(white_emission())
    # Model +Z (head) to image right (+X); blade (+X) down (-Z); view along +Y.
    icon.matrix_world = Matrix(((0, 0, 1, 0), (0, 1, 0, 0), (-1, 0, 0, 0), (0, 0, 0, 1)))
    bpy.context.view_layer.update()
    corners = [icon.matrix_world @ Vector(c) for c in icon.bound_box]
    lo = Vector([min(c[i] for c in corners) for i in range(3)])
    hi = Vector([max(c[i] for c in corners) for i in range(3)])
    centre = (lo + hi) / 2
    cam = bpy.data.objects.new('Icon camera', bpy.data.cameras.new('Icon camera'))
    scene.collection.objects.link(cam)
    cam.data.type = 'ORTHO'
    cam.data.ortho_scale = max(hi.x - lo.x, (hi.z - lo.z) * 2) * 1.08
    cam.location = (centre.x, lo.y - 50, centre.z)
    cam.rotation_euler = (math.radians(90), 0, 0)
    scene.camera = cam
    scene.render.engine = 'CYCLES'; scene.cycles.device = 'CPU'; scene.cycles.samples = 16
    scene.render.film_transparent = True
    scene.render.resolution_x, scene.render.resolution_y = 256, 128
    scene.render.image_settings.file_format = 'TARGA'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.view_settings.view_transform = 'Standard'
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True, scene=scene.name)
    bpy.data.scenes.remove(scene)


def render_grip(result, hawk, review):
    """Two review views of the solved hand wrapped on the handle (CPU Cycles)."""
    hand = grip.Hand()
    skin, _, _ = hand.skin(result['local_q'])
    chunks = grip.read_chunks(grip.HANDS_PSK)
    wedge_point = [grip.struct.unpack('<IffBBH', r)[0] for r in chunks['VTXW0000'][2]]
    index = {int(p): i for i, p in enumerate(hand.right)}
    faces = []
    for row in chunks['FACE0000'][2]:
        a, b, c = (wedge_point[w] for w in grip.struct.unpack('<3HBBI', row)[:3])
        if a in index and b in index and c in index:
            faces.append((index[a], index[c], index[b]))
    scene = bpy.data.scenes.new('RAVEN-7 grip review')
    data = bpy.data.meshes.new('Solved right hand')
    data.from_pydata([tuple(v) for v in skin], [], faces)
    skin_mat = bpy.data.materials.new('Review skin'); skin_mat.diffuse_color = (0.75, 0.55, 0.45, 1)
    data.materials.append(skin_mat)
    scene.collection.objects.link(bpy.data.objects.new('Solved right hand', data))
    weapon = bpy.data.objects.new('Held RAVEN-7', hawk.data)
    weapon.matrix_world = weapon_matrix(result)
    scene.collection.objects.link(weapon)
    wrist = Vector(skin.mean(axis=0))
    scene.world = bpy.data.worlds.new('Review grey'); scene.world.use_nodes = True
    scene.world.node_tree.nodes['Background'].inputs[0].default_value = (0.35, 0.37, 0.4, 1)
    scene.render.engine = 'CYCLES'; scene.cycles.device = 'CPU'; scene.cycles.samples = 24
    scene.render.resolution_x = scene.render.resolution_y = 700
    scene.render.image_settings.file_format = 'PNG'
    axes = weapon.matrix_world.to_3x3()
    for name, direction in (('grip-front', axes @ Vector((1, -0.35, 0.15))), ('grip-palm', axes @ Vector((-0.2, 1, 0.1))),
                            ('grip-back', axes @ Vector((-1, 0.3, 0.1)))):
        cam = bpy.data.objects.new(name, bpy.data.cameras.new(name))
        scene.collection.objects.link(cam)
        cam.data.type = 'ORTHO'; cam.data.ortho_scale = 22
        cam.location = wrist + direction.normalized() * 60
        cam.rotation_euler = (wrist - cam.location).to_track_quat('-Z', 'Z').to_euler()
        light = bpy.data.objects.new(name + ' key', bpy.data.lights.new(name + ' key', 'SUN'))
        light.rotation_euler = cam.rotation_euler; light.data.energy = 3
        scene.collection.objects.link(light)
        scene.camera = cam
        scene.render.filepath = str(review / (name + '.png'))
        bpy.ops.render.render(write_still=True, scene=scene.name)
        scene.collection.objects.unlink(light)
    bpy.data.scenes.remove(scene)


# Every sequence KF2's one-handed melee weapon states can request, at the stock
# Commando/Berserker knife AnimSet's durations (seconds). Each holds the
# authored grip: in VR the tracked hand, not the clip, moves the weapon, and
# the weapon states still time equip, guard, block hits and sprint from these
# lengths. ADD_Walk is omitted: bUseAdditiveMoveAnim is off and a non-additive
# take in an additive slot would double the pose.
TAKES = {
    'Idle': 6.134, 'Equip': 1.6, 'PutAway': 0.625, 'Guncheck_v1': 3.4, 'Guncheck_v2': 7.55,
    'Guncheck_v3': 2.532, 'Settle_V1': 1.452, 'Walk': 3.135, 'Sprint_In': 0.292,
    'Sprint_Loop': 1.851, 'Sprint_Out': 0.924, 'Brace_in': 0.378, 'Brace_loop': 2.151,
    'Brace_out': 1.117, 'Block_Hit_V1': 0.733, 'Block_Hit_V2': 0.733, 'Block_Hit_V3': 0.733,
    'Clean_Blood': 1.881, 'Clean_NoBlood': 1.15, 'Nade_Throw': 1.721, 'Bash': 1.237,
    'Atk_F': 0.734, 'Atk_B': 0.7, 'Atk_L': 0.65, 'Atk_R': 0.634, 'Atk_H_F': 0.894,
    'Atk_H_B': 0.894, 'Atk_H_L': 0.894, 'Atk_H_R': 0.879, 'Combo_F': 0.384, 'Combo_FL': 0.384,
    'Combo_FR': 0.384, 'Combo_L': 0.384, 'Combo_R': 0.384, 'Combo_BL': 0.384, 'Combo_BR': 0.384,
}
# Third person rides the pawn's weapon socket like the stock Berserker knife
# (whose character AnimSet it uses): handle centre 3.5 cm below the socket,
# offset 0.75 cm toward its spine, blade (+Z) up and edge toward -Y. The
# tomahawk's edge is +X in its own frame, so it is yawed -90 degrees.
ATTACHMENT_GRIP = Vector((0.0, -0.75, -3.5))
ATTACHMENT_YAW_DEGREES = -90.0


def attachment_matrix():
    return (Matrix.Translation(ATTACHMENT_GRIP) @ Matrix.Rotation(math.radians(ATTACHMENT_YAW_DEGREES), 4, 'Z')
            @ Matrix.Translation(Vector((0.0, 0.0, -grip.FIST_CENTRE_Z))))


def new_scene(name):
    scene = bpy.data.scenes.new(name)
    bpy.context.window.scene = scene
    scene.unit_settings.system = 'METRIC'
    scene.unit_settings.scale_length = 0.01
    scene.unit_settings.length_unit = 'CENTIMETERS'
    scene.render.fps = 30
    return scene


def import_skeleton(psk, names, check_bone, check_position):
    if bpy.ops.psk.import_file(filepath=str(psk), scale=1.0) != {'FINISHED'}:
        raise RuntimeError(f'PSK import failed: {psk}')
    scene = bpy.context.window.scene
    rigs = [o for o in scene.objects if o.type == 'ARMATURE']
    if len(rigs) != 1:
        raise ValueError('Expected one imported rig')
    rig = rigs[0]
    for o in [o for o in scene.objects if o.type == 'MESH']:
        bpy.data.objects.remove(o, do_unlink=True)
    if list(rig.data.bones.keys()) != names:
        raise ValueError('Blender import changed the skeleton names/order')
    # The PSK importer keeps ActorX component coordinates; verify rather than
    # assume, since the weapon is placed in those coordinates.
    head = rig.matrix_world @ rig.data.bones[check_bone].head_local
    if (head - Vector(check_position)).length > 0.01:
        raise ValueError(f'Unexpected PSK import frame: {check_bone} at {tuple(head)}, expected {check_position}')
    return rig


def export_skinned(hawk, rig, matrix, fbx, takes):
    """The weapon rigidly on RW_Weapon; one identity-keyed take per name."""
    scene = bpy.context.window.scene
    mesh = bpy.data.objects.new(fbx.stem + '_export', hawk.data.copy())
    scene.collection.objects.link(mesh)
    mesh.matrix_world = matrix
    for o in scene.objects: o.select_set(o == mesh)
    bpy.context.view_layer.objects.active = mesh
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    group = mesh.vertex_groups.new(name='RW_Weapon')
    group.add(range(len(mesh.data.vertices)), 1.0, 'REPLACE')
    mesh.parent = rig
    mesh.modifiers.new('Armature', 'ARMATURE').object = rig
    for action in list(bpy.data.actions): bpy.data.actions.remove(action)
    if takes:
        rig.animation_data_create()
        for name, seconds in takes.items():
            rig.animation_data.action = None
            last = max(1, round(seconds * scene.render.fps))
            for bone in rig.pose.bones:
                bone.location = (0, 0, 0); bone.rotation_mode = 'QUATERNION'; bone.rotation_quaternion = (1, 0, 0, 0)
                for frame in (0, last):
                    bone.keyframe_insert('location', frame=frame); bone.keyframe_insert('rotation_quaternion', frame=frame)
            rig.animation_data.action.name = name
        # Blender's all-actions exporter needs an AnimData owner.
        rig.animation_data.action = None
    old = bpy.data.objects.get('Armature')
    if old and old != rig: old.name = 'Preserved existing Armature'
    rig.name = 'Armature'
    for o in scene.objects: o.select_set(o in (rig, mesh))
    bpy.context.view_layer.objects.active = mesh
    result_op = bpy.ops.export_scene.fbx(
        filepath=str(fbx), use_selection=True, object_types={'ARMATURE', 'MESH'},
        global_scale=1.0, apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS',
        axis_forward='Y', axis_up='Z', use_space_transform=True, bake_space_transform=False,
        add_leaf_bones=False, primary_bone_axis='Y', secondary_bone_axis='X',
        use_armature_deform_only=False, armature_nodetype='NULL', bake_anim=bool(takes),
        bake_anim_use_all_actions=True, bake_anim_use_nla_strips=False, bake_anim_simplify_factor=0,
        use_mesh_modifiers=False, mesh_smooth_type='EDGE', path_mode='STRIP', embed_textures=False)
    if result_op != {'FINISHED'}:
        raise RuntimeError(f'FBX export failed: {fbx}')
    if takes: strip_container_animation(fbx)
    remove_fbx_armature_container(fbx)
    rig.name = fbx.stem + ' rig'


def export_prop(hawk, fbx):
    """VRTomahawk.fbx: the static prop (thrown axe, dropped pickup) with two
    UCX convex boxes, handle and head, so a dropped RAVEN-7 tumbles and rests
    under rigid-body physics like a stock pickup."""
    scene = bpy.context.window.scene
    verts = np.array([tuple(hawk.matrix_world @ v.co) for v in hawk.data.vertices])
    split = grip.FIST_CENTRE_Z + 12.0   # top of the grip wrap, below the head
    hulls = []
    for i, part in enumerate((verts[verts[:, 2] < split], verts[verts[:, 2] >= split])):
        lo, hi = part.min(axis=0), part.max(axis=0)
        data = bpy.data.meshes.new(f'UCX_{hawk.name}_{i:02d}')
        corners = [(x, y, z) for x in (lo[0], hi[0]) for y in (lo[1], hi[1]) for z in (lo[2], hi[2])]
        data.from_pydata(corners, [], [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)])
        hull = bpy.data.objects.new(data.name, data)
        scene.collection.objects.link(hull)
        hulls.append(hull)
    bpy.context.view_layer.update()  # newly linked hulls join the view layer
    for o in bpy.context.view_layer.objects: o.select_set(o == hawk or o in hulls)
    if sum(o.select_get() for o in bpy.context.view_layer.objects) != 1 + len(hulls):
        raise RuntimeError('Prop collision boxes are not selectable for export')
    bpy.context.view_layer.objects.active = hawk
    result = bpy.ops.export_scene.fbx(
        filepath=str(fbx), use_selection=True, global_scale=1.0,
        axis_forward='-X', axis_up='Z', apply_unit_scale=True,
        apply_scale_options='FBX_SCALE_UNITS', bake_space_transform=False,
        mesh_smooth_type='EDGE', add_leaf_bones=False, bake_anim=False,
        use_mesh_modifiers=False, object_types={'MESH'})
    for hull in hulls: bpy.data.objects.remove(hull, do_unlink=True)
    if result != {'FINISHED'}:
        raise RuntimeError(f'FBX export failed: {fbx}')
    return {'output_fbx': str(fbx), 'fbx_sha256': hashlib.sha256(fbx.read_bytes()).hexdigest().upper(),
            'vertices': len(hawk.data.vertices), 'triangles': sum(len(p.vertices) - 2 for p in hawk.data.polygons),
            'bounds_min': [round(float(x), 3) for x in verts.min(axis=0)],
            'bounds_max': [round(float(x), 3) for x in verts.max(axis=0)], 'collision_boxes': len(hulls)}


def build(hawk, out, review):
    """Write the rig, attachment and icon for the finished weapon object."""
    verts = np.array([tuple(hawk.matrix_world @ v.co) for v in hawk.data.vertices])
    result = grip.solve(verts)
    previous = bpy.context.window.scene
    try:
        new_scene('RAVEN-7 rig export')
        rig_psk = out / 'VRTomahawkRig.psk'
        grip.write_rig_psk(result, rig_psk)
        rig = import_skeleton(rig_psk, result['skeleton'].names + ['RW_Weapon'], 'RW_Weapon', result['rw_p'])
        fbx = out / 'VRTomahawkRig.fbx'
        export_skinned(hawk, rig, weapon_matrix(result), fbx, TAKES)
        new_scene('RAVEN-7 attachment export')
        third_psk = out / 'VRTomahawk3P.psk'
        grip.write_weapon_bone_psk(result, third_psk)
        rig3 = import_skeleton(third_psk, ['RW_Weapon'], 'RW_Weapon', (0.0, 0.0, 0.0))
        third = out / 'VRTomahawk3P.fbx'
        export_skinned(hawk, rig3, attachment_matrix(), third, {})
    finally:
        bpy.context.window.scene = previous
    render_grip(result, hawk, review)
    icon = out / 'VRTomahawkIcon.tga'
    render_icon(hawk, icon)
    # Physical-melee head capsule in RW_Weapon space: the far 55% of reach,
    # fitted like tools/re/measure_melee_head.py, then moved by the offset.
    head = verts[verts[:, 2] >= 0.55 * verts[:, 2].max()]
    centre = head.mean(axis=0)
    _, _, vt = np.linalg.svd(head - centre)
    axis = vt[0] if vt[0][0] >= 0 else -vt[0]
    proj = (head - centre) @ axis
    radial = np.linalg.norm((head - centre) - np.outer(proj, axis), axis=1)
    offset = np.array(result['model_offset'])
    capsule = dict(MeleeHeadStart=[round(float(x), 1) for x in centre + axis * proj.min() + offset],
                   MeleeHeadEnd=[round(float(x), 1) for x in centre + axis * proj.max() + offset],
                   MeleeRadius=round(float(max(3.0, min(14.0, np.percentile(radial, 80)))), 1))
    # The authored model origin: a MuzzleFlash socket on each skeleton's
    # RW_Weapon. Remote VR avatars place the attachment by matching them, and
    # throws/recalls read the held axe's frame from the rig's socket.
    grip_3p = attachment_matrix() @ Vector((0.0, 0.0, 0.0))
    return dict(rig_fbx=str(fbx), rig_fbx_sha256=hashlib.sha256(fbx.read_bytes()).hexdigest().upper(),
                attachment_fbx=str(third), attachment_fbx_sha256=hashlib.sha256(third.read_bytes()).hexdigest().upper(),
                rig_grip_socket=[round(x, 3) for x in result['model_offset']],
                attachment_grip_socket=[round(x, 3) for x in grip_3p],
                attachment_grip_yaw_uu=int(round(ATTACHMENT_YAW_DEGREES * 65536 / 360)),
                rig_takes=sorted(TAKES), rig_take_seconds=[TAKES[t] for t in sorted(TAKES)],
                icon=str(icon), icon_sha256=hashlib.sha256(icon.read_bytes()).hexdigest().upper(),
                rig_bones=len(result['skeleton'].names) + 1, idle_take='Idle',
                model_offset_in_weapon=[round(x, 3) for x in result['model_offset']],
                grip_closure_degrees=result['closure_degrees'], grip_link_clearance_cm=result['link_clearance_cm'],
                grip_penetrating_vertices=result['penetrating_vertices'],
                grip_max_penetration_cm=result['max_penetration_cm'],
                grip_source='Bone Crusher mace Idle right hand, re-closed on the RAVEN-7 handle against VRFloatingHands skin',
                hands_psk_sha256=hashlib.sha256(grip.HANDS_PSK.read_bytes()).hexdigest().upper(),
                melee_capsule=capsule)
