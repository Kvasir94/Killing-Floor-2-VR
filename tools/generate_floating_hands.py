"""Cut locally exported KF2 arms into capped hands with Blender, preserving the rig.

Run with Blender (the PSK import addon is needed for FBX/inspection export):
  blender --background --python tools/generate_floating_hands.py -- arms.psk hands.psk

PSK inputs/outputs are derived game assets and must remain in ignored extract/ or
build/ directories. No game asset is embedded in this generator. Original bone
and material records are copied exactly; retained points keep finger skin weights.
Arm/forearm weights are merged into the hand so direct hand poses cannot stretch
the wrist back toward the hidden arm rig. --preserve-proximal-weights opts out.
Blender bisects both limbs at their wrist joint and closes the resulting opening.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import struct
import sys


HEADER = struct.Struct('<20s3i')
BONE = struct.Struct('<64s3i11f')
WEDGE = struct.Struct('<IffBBH')
FACE = struct.Struct('<3HBBI')
WEIGHT = struct.Struct('<fii')
SUPPORTED = {'ACTRHEAD', 'PNTS0000', 'VTXW0000', 'FACE0000', 'MATT0000', 'REFSKELT', 'RAWWEIGHTS'}


@dataclass
class Chunk:
    name: str
    kind: int
    size: int
    rows: list[bytes]

    def encode(self):
        return HEADER.pack(self.name.encode(), self.kind, self.size, len(self.rows)) + b''.join(self.rows)


def read_psk(path):
    data = Path(path).read_bytes()
    offset = 0
    chunks = {}
    while offset < len(data):
        if len(data) - offset < HEADER.size:
            raise ValueError('Truncated PSK chunk header')
        raw_name, kind, size, count = HEADER.unpack_from(data, offset)
        offset += HEADER.size
        name = raw_name.rstrip(b'\0').decode('ascii')
        if name not in SUPPORTED:
            raise ValueError(f'Unsupported chunk {name}; refusing to lose indexed mesh data')
        if size < 0 or count < 0 or (count and size == 0) or size * count > len(data) - offset:
            raise ValueError(f'Invalid/truncated PSK chunk {name}')
        if name in chunks:
            raise ValueError(f'Duplicate PSK chunk {name}')
        chunks[name] = Chunk(name, kind, size, [data[offset + i * size:offset + (i + 1) * size] for i in range(count)])
        offset += size * count
    for name, size in {'PNTS0000':12, 'VTXW0000':16, 'FACE0000':12, 'MATT0000':88, 'REFSKELT':120, 'RAWWEIGHTS':12}.items():
        if name not in chunks or chunks[name].size != size:
            raise ValueError(f'Missing or incompatible {name}')
    return chunks


def bone_data(chunks):
    bones = [BONE.unpack(row) for row in chunks['REFSKELT'].rows]
    names = [b[0].rstrip(b'\0').decode('ascii') for b in bones]
    if len(set(names)) != len(names):
        raise ValueError('Duplicate bone names')
    for i, bone in enumerate(bones):
        parent = bone[3]
        if (i == 0 and parent not in (0, -1)) or (i and not 0 <= parent < i):
            raise ValueError('Expected a root-first acyclic ActorX skeleton')
    return bones, names


def descendants(bones, root):
    result = {root}
    for i in range(root + 1, len(bones)):
        if bones[i][3] in result:
            result.add(i)
    return result


def decode_geometry(chunks):
    points = [struct.unpack('<3f', row) for row in chunks['PNTS0000'].rows]
    wedges = [WEDGE.unpack(row) for row in chunks['VTXW0000'].rows]
    faces = [FACE.unpack(row) for row in chunks['FACE0000'].rows]
    weights = [{} for _ in points]
    bone_count = len(chunks['REFSKELT'].rows)
    for row in chunks['RAWWEIGHTS'].rows:
        weight, point, bone = WEIGHT.unpack(row)
        if not 0 <= point < len(points) or not 0 <= bone < bone_count or not 0 < weight <= 1:
            raise ValueError('Invalid skin weight')
        weights[point][bone] = weights[point].get(bone, 0) + weight
    for wedge in wedges:
        if wedge[0] >= len(points):
            raise ValueError('Wedge references a missing point')
    for face in faces:
        if any(w >= len(wedges) for w in face[:3]) or face[3] >= len(chunks['MATT0000'].rows):
            raise ValueError('Face references a missing wedge or material')
    if any(not w or abs(sum(w.values()) - 1) > 0.002 for w in weights):
        raise ValueError('Missing or unnormalized point skin weights')
    return points, wedges, faces, weights


def bind_positions(bones):
    from mathutils import Quaternion, Vector
    positions, rotations = [], []
    for i, bone in enumerate(bones):
        x, y, z, w = bone[4:8]
        q = Quaternion((w, x, y, z))
        p = Vector(bone[8:11])
        if i:
            parent = bone[3]
            p = positions[parent] + rotations[parent] @ p
            q = rotations[parent] @ q.conjugated()
        positions.append(p)
        rotations.append(q)
    return positions


def cut_hands(chunks, wrist_offset=0.0, preserve_proximal_weights=False):
    """Use Blender's mesh bisector and hole fill; retain all rig/material records."""
    import bmesh
    from mathutils import Vector

    bones, names = bone_data(chunks)
    points, wedges, faces, weights = decode_geometry(chunks)
    bind = bind_positions(bones)
    out_points, out_wedges, out_faces, out_weights = [], [], [], []
    report = {'source_points':len(points), 'source_triangles':len(faces), 'bones':len(bones), 'hands':[]}
    for side in ('Left', 'Right'):
        arm = names.index(side + 'Arm_1stP')
        hand = names.index(side + 'Hand_1stP')
        middle = names.index(side + 'HandMiddle1_1stP')
        side_bones = descendants(bones, arm)
        hand_bones = descendants(bones, hand)
        axis = (bind[middle] - bind[hand]).normalized()
        plane = bind[hand] + axis * wrist_offset
        bm = bmesh.new()
        deform = bm.verts.layers.deform.new('SkinWeights')
        original = bm.verts.layers.int.new('OriginalPointPlusOne')
        uv = bm.loops.layers.uv.new('UVMap')
        smoothing = bm.faces.layers.int.new('SmoothingGroup')
        source_verts = {}
        for face in faces:
            ids = [wedges[w][0] for w in reversed(face[:3])]
            # Each actual source mesh has two disjoint arms; reject a mesh that
            # mixes sides within a triangle instead of cutting through its body.
            belongs = [max(weights[p], key=weights[p].get) in side_bones for p in ids]
            if not any(belongs):
                continue
            if not all(belongs):
                raise ValueError('Triangle crosses the left/right arm boundary')
            verts = []
            for point in ids:
                if point not in source_verts:
                    v = bm.verts.new(points[point])
                    v[original] = point + 1
                    for bone, weight in weights[point].items():
                        v[deform][bone] = weight
                    source_verts[point] = v
                verts.append(source_verts[point])
            f = bm.faces.new(verts)
            f.material_index = face[3]
            # Blender integer customdata is signed, PSK smoothing masks unsigned.
            f[smoothing] = face[5] if face[5] < 2**31 else face[5] - 2**32
            for loop, wedge_id in zip(f.loops, reversed(face[:3])):
                loop[uv].uv = (wedges[wedge_id][1], 1 - wedges[wedge_id][2])
        result = bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
                                      dist=0.00001, plane_co=plane, plane_no=axis,
                                      clear_inner=True, clear_outer=False)
        cut_edges = [e for e in result['geom_cut'] if isinstance(e, bmesh.types.BMEdge) and e.is_boundary]
        if not cut_edges:
            raise ValueError(f'{side} wrist plane did not create an opening')
        caps = bmesh.ops.holes_fill(bm, edges=cut_edges, sides=0)['faces']
        if len(caps) != 1:
            raise ValueError(f'Expected one {side} wrist opening, got {len(caps)}')
        # Cap UVs sample a tiny patch next to the wrist instead of stretching the
        # whole arms texture across the new surface. Side-face UVs are untouched.
        cap_uvs = [loop[uv].uv.copy() for edge in cut_edges for face in edge.link_faces if face not in caps for loop in face.loops if loop.vert in edge.verts]
        cap_uv = sum(cap_uvs, Vector((0.0, 0.0))) / len(cap_uvs)
        for cap in caps:
            cap.material_index = 0
            cap[smoothing] = 0
            for loop in cap.loops:
                loop[uv].uv = cap_uv
        bmesh.ops.triangulate(bm, faces=list(bm.faces), quad_method='FIXED', ngon_method='EAR_CLIP')
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
        bm.normal_update()
        if any(e.is_boundary for e in bm.edges):
            raise ValueError(f'{side} cut left an uncapped edge')
        bm.verts.index_update()
        start = len(out_points)
        retained, interpolated, remapped = 0, 0, 0
        for vert in bm.verts:
            point_id = start + vert.index
            out_points.append(struct.pack('<3f', *vert.co))
            source = vert[original] - 1
            # Bisect interpolates integer customdata too. Trust source identity
            # only when its original coordinate still matches exactly.
            if source >= 0 and tuple(vert.co) == tuple(points[source]):
                skin = weights[source].copy()
                retained += 1
            else:
                skin = dict(vert[deform])
                total = sum(skin.values())
                if total <= 0:
                    raise ValueError('Blender lost interpolated skin weights')
                skin = {b:w / total for b, w in skin.items() if w > 0.000001}
                interpolated += 1
            if not preserve_proximal_weights:
                proximal = sum(w for b, w in skin.items() if b not in hand_bones)
                if proximal:
                    remapped += 1
                    skin = {b:w for b, w in skin.items() if b in hand_bones}
                    # Float32 source rows may sum slightly above one. Preserve
                    # finger weights exactly and put the remaining unit weight
                    # on the hand, avoiding a >1 influence after merging.
                    skin[hand] = 1.0 - sum(w for b, w in skin.items() if b != hand)
                if not skin or not set(skin).issubset(hand_bones):
                    raise ValueError(f'{side} wrist still references a proximal or opposite-side bone')
            for bone, weight in sorted(skin.items()):
                out_weights.append(WEIGHT.pack(weight, point_id, bone))
        for face in bm.faces:
            wedge_ids = []
            for loop in reversed(list(face.loops)):
                wedge_ids.append(len(out_wedges))
                u, v = loop[uv].uv
                out_wedges.append(WEDGE.pack(start + loop.vert.index, u, 1 - v, face.material_index, 0, 0))
            if len(out_wedges) > 65535:
                raise ValueError('PSK FACE0000 wedge limit exceeded')
            out_faces.append(FACE.pack(*wedge_ids, face.material_index, 0, face[smoothing] & 0xffffffff))
        report['hands'].append({'side':side, 'points':len(bm.verts), 'triangles':len(bm.faces),
                                'original_points_preserved':retained, 'wrist_points_interpolated':interpolated,
                                'proximal_weights_merged_into_hand':remapped,
                                'wrist':list(plane), 'distal_axis':list(axis), 'cap_boundaries':len(caps),
                                'minimum_distal_distance':min((v.co-plane).dot(axis) for v in bm.verts)})
        bm.free()
    replacements = {'PNTS0000':out_points, 'VTXW0000':out_wedges, 'FACE0000':out_faces, 'RAWWEIGHTS':out_weights}
    output = {name:Chunk(name, chunk.kind, chunk.size, replacements.get(name, chunk.rows)) for name, chunk in chunks.items()}
    decode_geometry(output)
    report.update(points=len(out_points), triangles=len(out_faces), skeleton_sha256=hashlib.sha256(b''.join(chunks['REFSKELT'].rows)).hexdigest())
    return output, report


def save_inspection(path, psk_path, preview=None):
    import bpy
    from mathutils import Vector
    scene = bpy.data.scenes.new('KF2 floating hands inspection')
    bpy.context.window.scene = scene
    bpy.ops.psk.import_file(filepath=str(psk_path.resolve()))
    scene['generated_psk'] = str(psk_path.resolve())
    if preview:
        chunks = read_psk(psk_path)
        bones, names = bone_data(chunks)
        points, wedges, faces, weights = decode_geometry(chunks)
        bind = bind_positions(bones)
        # A static display copy brings the two widely separated bind-pose hands
        # side by side. The imported rig and exported mesh remain untouched.
        display_points = [None] * len(points)
        for side, offset in (('Left', 13), ('Right', -13)):
            hand = names.index(side + 'Hand_1stP')
            members = descendants(bones, names.index(side + 'Arm_1stP'))
            forward = (bind[names.index(side + 'HandMiddle1_1stP')] - bind[hand]).normalized()
            lateral = (bind[names.index(side + 'HandPinky1_1stP')] - bind[names.index(side + 'HandIndex1_1stP')]).normalized()
            normal = lateral.cross(forward).normalized()
            lateral = forward.cross(normal).normalized()
            for i, point in enumerate(points):
                if max(weights[i], key=weights[i].get) in members:
                    v = Vector(point) - bind[hand]
                    display_points[i] = (v.dot(lateral) + offset, v.dot(forward), v.dot(normal))
        data = bpy.data.meshes.new('Hands presentation copy')
        data.from_pydata(display_points, [], [[wedges[w][0] for w in reversed(f[:3])] for f in faces])
        for polygon, face in zip(data.polygons, faces):
            polygon.use_smooth = face[5] != 0
        display = bpy.data.objects.new('Hands presentation copy', data)
        scene.collection.objects.link(display)
        display.color = (0.60, 0.36, 0.22, 1)
        for obj in scene.objects:
            if obj.type == 'MESH' and obj != display:
                obj.hide_render = True
        camera = bpy.data.objects.new('Hands inspection camera', bpy.data.cameras.new('Hands inspection camera'))
        scene.collection.objects.link(camera)
        target = Vector((0, 9, 0))
        camera.location = (27, -35, 48)
        camera.rotation_euler = (target - camera.location).to_track_quat('-Z', 'Y').to_euler()
        camera.data.type = 'ORTHO'
        camera.data.ortho_scale = 46
        scene.camera = camera
        scene.render.engine = 'BLENDER_WORKBENCH'
        scene.display.shading.light = 'STUDIO'
        scene.display.shading.color_type = 'OBJECT'
        scene.display.shading.show_shadows = True
        scene.display.shading.show_cavity = True
        scene.display.shading.cavity_type = 'BOTH'
        scene.display.shading.background_type = 'WORLD'
        scene.world = bpy.data.worlds.new('Hands inspection world')
        scene.world.color = (0.035, 0.035, 0.035)
        scene.render.resolution_x = 1100
        scene.render.resolution_y = 750
        scene.render.resolution_percentage = 100
        scene.render.image_settings.file_format = 'PNG'
        scene.render.filepath = str(Path(preview).resolve())
        bpy.ops.render.render(write_still=True)
    if path:
        bpy.ops.wm.save_as_mainfile(filepath=str(Path(path).resolve()), copy=True)


def export_fbx(psk_path, fbx_path):
    """Export only the original rig and skinned cut mesh, in centimetres."""
    import bpy
    scene = bpy.data.scenes.new('KF2 floating hands FBX export')
    previous_scene = bpy.context.window.scene
    bpy.context.window.scene = scene
    try:
        scene.unit_settings.system = 'METRIC'
        scene.unit_settings.scale_length = 0.01
        scene.unit_settings.length_unit = 'CENTIMETERS'
        if bpy.ops.psk.import_file(filepath=str(psk_path.resolve()), scale=1.0) != {'FINISHED'}:
            raise RuntimeError('PSK rig import failed')
        armatures = [o for o in scene.objects if o.type == 'ARMATURE']
        meshes = [o for o in scene.objects if o.type == 'MESH']
        if len(armatures) != 1 or len(meshes) != 1:
            raise ValueError('FBX export requires exactly one rig and one skinned mesh')
        rig, mesh = armatures[0], meshes[0]
        _, names = bone_data(read_psk(psk_path))
        if list(rig.data.bones.keys()) != names:
            raise ValueError('Blender import changed the skeleton names/order')
        # Use a known container name so the validated FBX postpass can remove
        # it: KF2's UE3 importer otherwise promotes this Null into bone 42.
        old_armature = bpy.data.objects.get('Armature')
        old_name = None
        if old_armature and old_armature != rig:
            old_name = old_armature.name
            old_armature.name = 'Preserved existing Armature'
        rig.name = 'Armature'
        mesh.name = 'VRFloatingHands_export'
        for obj in scene.objects:
            obj.select_set(obj in (rig, mesh))
        bpy.context.view_layer.objects.active = rig
        fbx_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            result = bpy.ops.export_scene.fbx(
                filepath=str(fbx_path.resolve()), use_selection=True,
                object_types={'ARMATURE', 'MESH'}, global_scale=1.0,
                apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS',
                axis_forward='Y', axis_up='Z', use_space_transform=True,
                bake_space_transform=False, add_leaf_bones=False,
                primary_bone_axis='Y', secondary_bone_axis='X',
                use_armature_deform_only=False, armature_nodetype='NULL',
                bake_anim=False, use_mesh_modifiers=True, mesh_smooth_type='FACE',
                path_mode='STRIP', embed_textures=False)
            if result != {'FINISHED'}:
                raise RuntimeError('Blender FBX export failed')
            remove_fbx_armature_container(fbx_path)
        finally:
            rig.name = 'KF2 floating hands export rig'
            if old_name:
                old_armature.name = old_name
        return {'fbx_bones':len(rig.data.bones), 'fbx_unit':'centimetres',
                'fbx_axis_forward':'Y', 'fbx_axis_up':'Z', 'fbx_leaf_bones':False,
                'fbx_armature_container_removed':True, 'fbx_rigid_bind_pose':True}
    finally:
        bpy.context.window.scene = previous_scene


def remove_fbx_armature_container(path):
    """Drop Blender's identity rig container without modifying skeletal data.

    UE3 does not have newer Unreal versions' special Armature stripping. The
    original Root must therefore be a direct child of the FBX scene root.
    """
    from io_scene_fbx import data_types, encode_bin, parse_fbx
    root, version = parse_fbx.parse(str(path))
    objects = next(e for e in root.elems if e.id == b'Objects')
    connections = next(e for e in root.elems if e.id == b'Connections')
    containers = [e for e in objects.elems if e.id == b'Model' and e.props[1].split(b'\0')[0] == b'Armature' and e.props[2] == b'Null']
    if len(containers) != 1:
        raise ValueError('Expected exactly one Blender Armature Null container')
    container = containers[0]
    container_id = container.props[0]
    properties = next(e for e in container.elems if e.id == b'Properties70')
    for prop in properties.elems:
        name = prop.props[0]
        if name in (b'Lcl Translation', b'Lcl Rotation', b'PreRotation', b'PostRotation', b'GeometricTranslation', b'GeometricRotation', b'Lcl Scaling', b'GeometricScaling'):
            expected = 1 if b'Scaling' in name else 0
            if any(abs(value - expected) > 0.000001 for value in prop.props[4:]):
                raise ValueError('Refusing to strip a transformed Armature container')
    children = [e.props[1] for e in connections.elems if len(e.props) >= 3 and e.props[2] == container_id]
    by_id = {e.props[0]:e for e in objects.elems}
    null_attributes = [by_id[c] for c in children if by_id[c].id == b'NodeAttribute' and by_id[c].props[2] == b'Null']
    if any(by_id[c].id != b'Model' and by_id[c] not in null_attributes for c in children):
        raise ValueError('Unexpected non-model data attached to Armature container')
    removed_ids = {container_id} | {e.props[0] for e in null_attributes}
    objects.elems[:] = [e for e in objects.elems if e.props[0] not in removed_ids]
    connections.elems[:] = [e for e in connections.elems if len(e.props) < 3 or e.props[1] not in removed_ids]
    for connection in connections.elems:
        if len(connection.props) >= 3 and connection.props[2] == container_id:
            connection.props[2] = 0
    for pose in [e for e in objects.elems if e.id == b'Pose']:
        retained = []
        for entry in pose.elems:
            if entry.id == b'PoseNode':
                node = next(e for e in entry.elems if e.id == b'Node')
                if node.props[0] == container_id:
                    matrix = next(e for e in entry.elems if e.id == b'Matrix').props[0]
                    if any(abs(value - int(i % 5 == 0)) > 0.000001 for i,value in enumerate(matrix)):
                        raise ValueError('Refusing to strip a nonidentity Armature bind pose')
                    continue
            retained.append(entry)
        pose.elems[:] = retained
        next(e for e in pose.elems if e.id == b'NbPoseNodes').props[0] = sum(e.id == b'PoseNode' for e in retained)
    definitions = next(e for e in root.elems if e.id == b'Definitions')
    next(e for e in definitions.elems if e.id == b'Count').props[0] -= len(removed_ids)
    model_definition = next(e for e in definitions.elems if e.id == b'ObjectType' and e.props[0] == b'Model')
    next(e for e in model_definition.elems if e.id == b'Count').props[0] -= 1
    if null_attributes:
        attribute_definition = next(e for e in definitions.elems if e.id == b'ObjectType' and e.props[0] == b'NodeAttribute')
        next(e for e in attribute_definition.elems if e.id == b'Count').props[0] -= len(null_attributes)

    normalize_fbx_bind_pose(root)

    # Re-encode through Blender's own binary FBX writer, retaining every numeric
    # property and array. Only the validated container relationships changed.
    names = ('BOOL', 'CHAR', 'INT8', 'INT16', 'INT32', 'INT64', 'FLOAT32', 'FLOAT64',
             'BYTES', 'STRING', 'INT32_ARRAY', 'INT64_ARRAY', 'FLOAT32_ARRAY',
             'FLOAT64_ARRAY', 'BOOL_ARRAY', 'BYTE_ARRAY')
    methods = {getattr(data_types,name):'add_' + name.lower() for name in names}
    def encode(element):
        result = encode_bin.FBXElem(element.id)
        for kind,value in zip(element.props_type,element.props):
            getattr(result,methods[kind])(value)
        result.elems = [encode(child) for child in element.elems]
        return result
    encode_bin.write(str(path),encode(root),version)


def normalize_fbx_bind_pose(root):
    """Remove float32 scale drift and make bind/skin matrices agree exactly.

    The PSK rig contains rotation/translation only. Blender's matrix-to-Euler
    decomposition introduces near-one local scales, which UE3 warns about and
    can propagate into the bind pose. Rebuild these rigid transforms in double
    precision, preserving translations, rotations, geometry and skin weights.
    """
    import array
    import math
    import numpy as np
    objects = next(e for e in root.elems if e.id == b'Objects')
    connections = next(e for e in root.elems if e.id == b'Connections')
    settings = next(e for e in root.elems if e.id == b'GlobalSettings')
    for prop in next(e for e in settings.elems if e.id == b'Properties70').elems:
        if prop.props[0] in (b'UnitScaleFactor', b'OriginalUnitScaleFactor'):
            if abs(prop.props[-1] - 1) > 0.000001:
                raise ValueError('Expected centimetre FBX units')
            prop.props[-1] = 1.0
    models = {e.props[0]:e for e in objects.elems if e.id == b'Model'}
    parents = {e.props[1]:e.props[2] for e in connections.elems if e.props[0] == b'OO' and e.props[1] in models and (e.props[2] in models or e.props[2] == 0)}
    local,world = {}, {0:np.eye(4)}
    for model_id,model in models.items():
        props = next(e for e in model.elems if e.id == b'Properties70')
        values = {p.props[0]:p.props[4:] for p in props.elems}
        for name in (b'PreRotation', b'PostRotation', b'RotationOffset', b'RotationPivot', b'ScalingOffset', b'ScalingPivot', b'GeometricTranslation', b'GeometricRotation'):
            if any(abs(v) > 0.000001 for v in values.get(name, [])):
                raise ValueError(f'Unsupported nonzero FBX transform {name}')
        if any(values.get(b'RotationOrder', [0])):
            raise ValueError('Expected FBX Euler XYZ rotation order')
        for prop in props.elems:
            if prop.props[0] in (b'Lcl Scaling', b'GeometricScaling'):
                if any(abs(v-1) > 0.0001 for v in prop.props[4:]):
                    raise ValueError('Refusing to change an intentionally scaled FBX rig')
                prop.props[4:] = [1.0,1.0,1.0]
        x,y,z = [math.radians(v) for v in values.get(b'Lcl Rotation', (0,0,0))]
        cx,sx,cy,sy,cz,sz = math.cos(x),math.sin(x),math.cos(y),math.sin(y),math.cos(z),math.sin(z)
        rx=np.array(((1,0,0),(0,cx,-sx),(0,sx,cx)))
        ry=np.array(((cy,0,sy),(0,1,0),(-sy,0,cy)))
        rz=np.array(((cz,-sz,0),(sz,cz,0),(0,0,1)))
        matrix=np.eye(4)
        matrix[:3,:3]=rz@ry@rx
        matrix[:3,3]=values.get(b'Lcl Translation',(0,0,0))
        local[model_id]=matrix
    def matrix_for(model_id):
        if model_id not in world:
            world[model_id]=matrix_for(parents[model_id])@local[model_id]
        return world[model_id]
    def set_matrix(element,matrix):
        element.props[0]=array.array('d',matrix.T.flatten())
    for pose in [e for e in objects.elems if e.id == b'Pose']:
        for entry in [e for e in pose.elems if e.id == b'PoseNode']:
            node_id=next(e for e in entry.elems if e.id == b'Node').props[0]
            stored=next(e for e in entry.elems if e.id == b'Matrix')
            old=np.array(stored.props[0]).reshape((4,4)).T
            new=matrix_for(node_id)
            if np.max(np.abs(old-new)) > 0.005:
                raise ValueError('Rigid FBX bind pose changed beyond float precision tolerance')
            set_matrix(stored,new)
    mesh_ids=[i for i,m in models.items() if m.props[2] == b'Mesh']
    if len(mesh_ids) != 1:
        raise ValueError('Expected one FBX hand mesh')
    mesh_matrix=matrix_for(mesh_ids[0])
    clusters={e.props[0]:e for e in objects.elems if e.id == b'Deformer' and e.props[2] == b'Cluster'}
    for connection in connections.elems:
        if connection.props[0] == b'OO' and connection.props[1] in models and connection.props[2] in clusters:
            bone_matrix=matrix_for(connection.props[1])
            cluster=clusters[connection.props[2]]
            set_matrix(next(e for e in cluster.elems if e.id == b'TransformLink'),bone_matrix)
            set_matrix(next(e for e in cluster.elems if e.id == b'Transform'),np.linalg.inv(bone_matrix)@mesh_matrix)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--wrist-offset', type=float, default=0.0, help='Distance distal from the hand joint, in source mesh units (default:0)')
    parser.add_argument('--preserve-proximal-weights', action='store_true', help='Keep original forearm influences; requires the original arm solver to avoid wrist stretching')
    parser.add_argument('--save-blend', type=Path, help='Add a distinct inspection scene and save a copy without replacing the open project')
    parser.add_argument('--preview', type=Path, help='Render a side-by-side wrist inspection PNG in the new scene')
    parser.add_argument('--fbx', type=Path, help='Export a matching skinned FBX for the KF2 SDK (requires Blender PSK importer)')
    args = parser.parse_args(argv)
    if args.input.resolve() == args.output.resolve():
        parser.error('Input and output must differ')
    chunks = read_psk(args.input)
    output, report = cut_hands(chunks, args.wrist_offset, args.preserve_proximal_weights)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(b''.join(c.encode() for c in output.values()))
    report['source'] = str(args.input.resolve())
    report['output'] = str(args.output.resolve())
    report['generator_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    report['source_sha256'] = hashlib.sha256(args.input.read_bytes()).hexdigest()
    report['output_sha256'] = hashlib.sha256(args.output.read_bytes()).hexdigest()
    if args.fbx:
        report.update(export_fbx(args.output, args.fbx))
        report['fbx'] = str(args.fbx.resolve())
        report['fbx_sha256'] = hashlib.sha256(args.fbx.read_bytes()).hexdigest()
    report_path = args.output.with_suffix('.json')
    report_path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    if args.save_blend or args.preview:
        save_inspection(args.save_blend, args.output, args.preview)
    print(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    main(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:])
