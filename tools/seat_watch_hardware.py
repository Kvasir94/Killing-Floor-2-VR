"""Seat the wrist panel's strap buckles and keepers on their straps (Blender).

Run inside Blender with KF2VR_ART_REVISION=<revision> whose runtime folder
already holds a copy of the base Horzine-runtime-baked.blend. The runtime
watch was optimised into loose parts: each buckle is a flat plate over a
round strap, so it touched only along the strap's centre line and its ends
stood several millimetres proud; the underside keepers hung clear of the
strap. This moves each hardware group inward until it meets its strap and
flattens the strap under each buckle, shifting both strap faces together so
the webbing keeps its thickness. The watch is then re-exported exactly as
bake_watch_components.py exports it. Nothing else in the mesh changes.
"""
import json, os
from pathlib import Path
import bpy, bmesh
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

ROOT = Path(__file__).resolve().parents[1]
CONTACT_CM = 0.01
FALLOFF_CM = 0.5
# Authoring-frame centres of the two straps' hardware (cm).
STRAP_X = (-6.83, -0.99)


def parts(me):
    bm = bmesh.new(); bm.from_mesh(me); bm.verts.ensure_lookup_table()
    seen, out = set(), []
    for v in bm.verts:
        if v.index in seen:
            continue
        stack, comp = [v], []
        seen.add(v.index)
        while stack:
            x = stack.pop(); comp.append(x.index)
            for e in x.link_edges:
                o = e.other_vert(x)
                if o.index not in seen:
                    seen.add(o.index); stack.append(o)
        out.append(comp)
    bm.free()
    return out


def box(me, comp):
    cos = [me.vertices[i].co for i in comp]
    return Vector([min(c[k] for c in cos) for k in range(3)]), Vector([max(c[k] for c in cos) for k in range(3)])


def main():
    runtime = ROOT / 'build/watch-detail-20260924' / os.environ['KF2VR_ART_REVISION'] / 'runtime'
    report_path = runtime / 'watch-hardware-seat.json'
    if report_path.exists():
        raise RuntimeError('This candidate was already seated; preserve it and start a new version.')
    bpy.ops.wm.open_mainfile(filepath=str(runtime / 'Horzine-runtime-baked.blend'))
    watch = bpy.data.objects['Runtime watch']
    me = watch.data
    normals = [n.vector.copy() for n in me.corner_normals]
    comps = parts(me)
    boxes = [box(me, c) for c in comps]
    polys = {}
    owner = {}
    for ci, c in enumerate(comps):
        for i in c:
            owner[i] = ci
    for p in me.polygons:
        polys.setdefault(owner[p.vertices[0]], []).append(list(p.vertices))
    co = [v.co.copy() for v in me.vertices]
    report = {}
    for x in STRAP_X:
        # The strap wraps the arm (spans > 5 cm vertically); the buckle sits on
        # its outboard side; the keeper under the arm.
        strap = [ci for ci, (lo, hi) in enumerate(boxes)
                 if lo.x < x + .8 and hi.x > x - .8 and hi.y - lo.y > 5 and hi.x - lo.x < 2.5]
        buckle = [ci for ci, (lo, hi) in enumerate(boxes)
                  if ci not in strap and abs((lo.x + hi.x) / 2 - x) < 1.2 and hi.y < -3.8
                  and lo.z > -1.5 and hi.z < 1.7]
        keeper = [ci for ci, (lo, hi) in enumerate(boxes)
                  if ci not in strap and abs((lo.x + hi.x) / 2 - x) < 1.2 and hi.z < -2.5
                  and abs((lo.y + hi.y) / 2) < 1.5]
        strap_bvh = BVHTree.FromPolygons(co, [p for ci in strap for p in polys[ci]])
        for name, group in (('buckle', buckle), ('keeper', keeper)):
            ids = [i for ci in group for i in comps[ci]]
            centre = sum((co[i] for i in ids), Vector()) / len(ids)
            n = Vector((0, -centre.y, -centre.z - .5)).normalized()
            hits = [strap_bvh.ray_cast(co[i], n, 3.0)[3] for i in ids]
            gap = min(h for h in hits if h is not None)
            shift = n * max(0.0, gap - CONTACT_CM)
            for i in ids:
                co[i] += shift
            entry = {'parts': len(group), 'vertices': len(ids), 'gap_before_cm': round(gap, 4),
                     'moved_cm': round(shift.length, 4)}
            if name == 'buckle':
                # Flatten the strap to the buckle's back: every strap vertex
                # moves by the gap measured from the strap's OUTER surface at
                # its position, so inner and outer faces move together.
                back = BVHTree.FromPolygons(co, [p for ci in group for p in polys[ci]])
                strap_ids = [i for ci in strap for i in comps[ci]]
                disp = {}
                for i in strap_ids:
                    outer = strap_bvh.ray_cast(co[i] - n * 2, n, 4.0)
                    if outer[0] is None:
                        continue
                    hit = back.ray_cast(outer[0], -n, 2.0)
                    if hit[0] is not None and hit[3] > CONTACT_CM:
                        disp[i] = hit[3] - CONTACT_CM
                tree = KDTree(len(disp))
                for i in disp:
                    tree.insert(co[i], i)
                tree.balance()
                moved, peak = 0, 0.0
                for i in strap_ids:
                    if i in disp:
                        d = disp[i]
                    elif disp:
                        _, j, dist = tree.find(co[i])
                        d = disp[j] * max(0.0, 1 - dist / FALLOFF_CM)
                    else:
                        d = 0
                    if d > 0:
                        co[i] -= n * d
                        moved += 1; peak = max(peak, d)
                entry.update({'strap_vertices_moved': moved, 'strap_max_outward_cm': round(peak, 4)})
            report[f'{name}_x{x}'] = entry
    for v, c in zip(me.vertices, co):
        v.co = c
    me.update()
    me.normals_split_custom_set(normals)
    bpy.ops.wm.save_as_mainfile(filepath=str(runtime / 'Horzine-runtime-baked.blend'))
    export_frame = Matrix(((0, 0, -1, 3.72), (-1, 0, 0, -3.9), (0, 1, 0, 0), (0, 0, 0, 1)))
    export_normals = [(export_frame.to_3x3() @ n.vector).normalized() for n in me.corner_normals]
    me.transform(export_frame); me.normals_split_custom_set(export_normals)
    # Opening a file resets the operator context; name the selection explicitly.
    window = bpy.context.window_manager.windows[0]
    with bpy.context.temp_override(window=window, selected_objects=[watch], active_object=watch, object=watch):
        bpy.ops.export_scene.fbx(filepath=str(runtime / 'VRWristwatch.fbx'), use_selection=True, object_types={'MESH'},
                                 global_scale=1, apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS',
                                 axis_forward='-X', axis_up='Z', bake_anim=False, mesh_smooth_type='FACE',
                                 path_mode='STRIP')
    # Leave the saved authoring-frame blend untouched by the export transform.
    bpy.ops.wm.revert_mainfile()
    report_path.write_text(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    print('WATCH_HARDWARE_SEATED', json.dumps(main()), flush=True)
