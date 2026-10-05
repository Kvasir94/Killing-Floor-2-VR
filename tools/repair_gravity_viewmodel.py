"""Complete the camera-culled HL2 viewmodel for inspection from every VR angle.

Retain the original first-person surfaces and UVs. Repeat its own cylindrical
sector and articulated claw for the omitted side; take only the front plate
from the original world mesh. Coordinates below are landmarks in Valve's
reference pose, expressed in Source inches and scaled by the caller.
"""
import math
import bpy
import bmesh
from mathutils import Matrix, Vector


def repair_viewmodel(container, world, scale):
    mesh, arm = container.objects[0], container.armature
    data = mesh.data
    bm = bmesh.new()
    bm.from_mesh(data)
    # UV seams remain on face loops; welding makes geometric boundaries usable.
    bmesh.ops.remove_doubles(bm, verts=list(bm.verts), dist=0.0001 * scale)
    deform = bm.verts.layers.deform.verify()
    axis = Vector((-12.254, 0, 54.747)) * scale
    original_faces = len(bm.faces)

    # The first-person barrel is a deliberately incomplete cylindrical sector.
    # Complete the hidden lower-left sector using its original textured faces.
    remaining = set(bm.verts)
    components = []
    while remaining:
        visited = {remaining.pop()}
        frontier = list(visited)
        while frontier:
            for edge in frontier.pop().link_edges:
                for vert in edge.verts:
                    if vert in remaining:
                        remaining.remove(vert)
                        visited.add(vert)
                        frontier.append(vert)
        faces = {f for v in visited for f in v.link_faces}
        if faces and max(v.co.y for v in visited) < -40 * scale:
            components.append((sum(f.calc_area() for f in faces), faces))
    core = max(components, key=lambda x: x[0])[1]
    repeat = []
    for face in core:
        p = face.calc_center_median() - axis
        angle = math.degrees(math.atan2(p.z, p.x))
        if -20 <= angle <= 100:
            repeat.append(face)
    duplicated = bmesh.ops.duplicate(bm, geom=repeat)['geom']
    for vert in (v for v in duplicated if isinstance(v, bmesh.types.BMVert)):
        vert.co.x = 2 * axis.x - vert.co.x
        vert.co.z = 2 * axis.z - vert.co.z

    # The absent third claw reuses the detailed side claw, including its small
    # linkage pieces. Mirroring requires winding reversal, not negative scale.
    mirror = Matrix.Diagonal((-1, 1, 1, 1))
    mirror.translation.x = 2 * arm.data.bones['Prong_A'].head_local.x
    mapped = {'Prong_B': 'Prong_C', 'Base_B': 'Base_C', 'Tip_B': 'Tip_C',
              'Doodad_1': 'Doodad_C1', 'Doodad_2': 'Doodad_C2'}
    old_groups = {mesh.vertex_groups[k].index for k in mapped}
    group_map = {mesh.vertex_groups[k].index: mesh.vertex_groups.new(name=v).index for k, v in mapped.items()}
    claw_faces = [f for f in list(bm.faces)
                  if all(sum(v[deform].get(g, 0) for g in old_groups) > 0.5 for v in f.verts)]
    duplicated = bmesh.ops.duplicate(bm, geom=claw_faces)['geom']
    for vert in (v for v in duplicated if isinstance(v, bmesh.types.BMVert)):
        vert.co = mirror @ vert.co
        weights = dict(vert[deform])
        vert[deform].clear()
        for group, weight in weights.items():
            vert[deform][group_map.get(group, group)] = weight
    bmesh.ops.reverse_faces(bm, faces=[f for f in duplicated if isinstance(f, bmesh.types.BMFace)])

    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    for source, target in mapped.items():
        src = arm.data.edit_bones[source]
        bone = arm.data.edit_bones.new(target)
        # Reflection on both sides keeps the bone basis right-handed.
        bone.matrix = mirror @ src.matrix @ Matrix.Diagonal((-1, 1, 1, 1))
        bone.length = src.length
        parent = mapped.get(src.parent.name, src.parent.name) if src.parent else 'Base'
        bone.parent = arm.data.edit_bones[parent]
    bpy.ops.object.mode_set(mode='OBJECT')

    # Preserve the original supercharged front-plate texture, absent from the
    # viewmodel's atlas, and its inner barrel beneath the detailed FP cage.
    world_mesh = world.objects[0]
    world_skin = list(world_mesh['skin_groups']['1'])[0]
    data.materials.append(world_skin)
    plate_material = len(data.materials) - 1
    uv = bm.loops.layers.uv.verify()
    source_uv = world_mesh.data.uv_layers.active.data
    plate_faces = 0
    source_center = Vector((0.523248, -23.975893, 2.510689)) * scale
    target_center = Vector((-12.254, -58.55, 54.747)) * scale
    for polygon in world_mesh.data.polygons:
        points = [world_mesh.data.vertices[i].co for i in polygon.vertices]
        center = sum(points, Vector()) / len(points)
        radius = max(math.hypot(p.x-source_center.x, p.z-source_center.z) for p in points)
        front_plate = -24.8 * scale < center.y < -22 * scale and polygon.normal.y < -0.35
        barrel_liner = -22 * scale <= center.y < -8 * scale and radius < 4.7 * scale
        if not (front_plate or barrel_liner) or radius > 5.1 * scale:
            continue
        verts = []
        for point in points:
            p = (point - source_center) * 1.03 + target_center
            if barrel_liner:
                p.x = target_center.x + (p.x-target_center.x) * 0.97
                p.z = target_center.z + (p.z-target_center.z) * 0.97
            v = bm.verts.new(p)
            v[deform][mesh.vertex_groups['Base'].index] = 1
            verts.append(v)
        face = bm.faces.new(verts)
        face.material_index = plate_material
        for loop, index in zip(face.loops, polygon.loop_indices):
            loop[uv].uv = source_uv[index].uv
        plate_faces += 1
    bm.normal_update()
    bm.to_mesh(data)
    bm.free()
    return {'original_faces': original_faces, 'completed_faces': len(data.polygons),
            'third_claw_source': 'Prong_B', 'front_plate_faces': plate_faces,
            'world_material_slot': plate_material}
