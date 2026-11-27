"""Seat the wrist panel's two underside buckles on their straps (Blender).

Revision 70's `seat_watch_hardware.py` moved each underside buckle straight up
until its nearest point met the strap. The buckle is a flat frame and the strap
there runs round a flared, sloping forearm, so only the strap tail under the
frame touched: the frame itself hung 2-15 mm clear and read as floating. This
pass, for each underside buckle:

- fits the strap's outer surface under the buckle and turns the whole buckle
  rigidly onto that plane, long axis along the strap;
- moves it in until its back is tangent to the strap;
- flattens the strap under the buckle onto that back, moving both strap faces
  together so the webbing keeps its thickness, with a short blend either side.

It works on the exported watch FBX (the authoring blends of revisions 60-72
are gone), re-exports with the frame and settings `bake_watch_components.py`
uses, and re-imports the result to check it. Nothing else in the mesh moves.

    blender --background --python tools/seat_watch_keepers.py -- <revision>
    python tools/seat_watch_keepers.py --stage <revision>

The first reads build/hand-meshes/VRWristwatch.fbx and writes the candidate to
build/watch-detail-20260924/<revision>/runtime/. The second (plain Python)
backs up the staged watch into that folder and copies the candidate over it;
`tools/build-hand-assets.ps1` then re-imports the package.
"""
import hashlib, json, math, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'build/watch-detail-20260924'
STAGED = ROOT / 'build/hand-meshes/VRWristwatch.fbx'
CONTACT_CM = 0.01
FALLOFF_CM = 0.9
# Authoring-frame centres of the two straps (cm): fingers +X, thumb -Y, dorsal +Z.
STRAP_X = (-9.31, -3.47)
# The watch export frame: where the mesh's own frame (at the screen) sits on the left hand. Until hand art
# revision 83 it was (3.72, -3.9), as in bake_watch_components.py / render_watch_runtime.py; revision 88
# moved the watch 2.5 cm up the forearm (tools/move_watch_up_forearm.py). VRSpatialHUD.GetWristwatchTransform
# carries the same two offsets.
EXPORT_FRAME = ((0, 0, -1, 3.657), (-1, 0, 0, -6.3788), (0, 1, 0, 0), (0, 0, 0, 1))


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def stage(revision):
    runtime = ART / revision / 'runtime'
    candidate = runtime / 'VRWristwatch.fbx'
    check = json.loads((runtime / 'fbx-roundtrip.json').read_text())
    if not check['passed'] or check['fbx_sha256'] != digest(candidate):
        raise SystemExit('The candidate watch has no passing roundtrip check.')
    backup = ART / revision / 'before-staging' / STAGED.name
    if not backup.exists():
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(STAGED, backup)
    shutil.copy2(candidate, STAGED)
    print(json.dumps({'staged_revision': revision, 'watch_sha256': digest(STAGED), 'backup': str(backup)}))


def load_watch(path):
    """The exported watch as one mesh object in the authoring frame."""
    import bpy
    from mathutils import Matrix
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=str(path), use_custom_normals=True)
    new = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in new if o.type == 'MESH']
    if len(meshes) != 1:
        raise RuntimeError('Expected one exported wrist mesh')
    watch = meshes[0]
    frame = Matrix(EXPORT_FRAME).inverted() @ watch.matrix_world
    turn = frame.to_3x3().inverted().transposed()
    normals = [(turn @ n.vector).normalized() for n in watch.data.corner_normals]
    watch.data.transform(frame)
    watch.matrix_world = Matrix.Identity(4)
    for p in watch.data.polygons:
        p.use_smooth = True
    watch.data.normals_split_custom_set(normals)
    for o in new:
        if o is not watch:
            bpy.data.objects.remove(o, do_unlink=True)
    return watch


def parts(me):
    """Connected parts, joining the points FBX split for normals and UVs."""
    parent = list(range(len(me.vertices)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    first = {}
    for v in me.vertices:
        key = (round(v.co.x, 4), round(v.co.y, 4), round(v.co.z, 4))
        parent[find(v.index)] = find(first.setdefault(key, v.index))
    for e in me.edges:
        parent[find(e.vertices[0])] = find(e.vertices[1])
    out = {}
    for v in me.vertices:
        out.setdefault(find(v.index), []).append(v.index)
    return list(out.values())


def smooth_normals(co, faces):
    """Area-weighted normals per position, so split points share one."""
    from mathutils import Vector
    total = {}
    for f in faces:
        a, b, c = (co[i] for i in f[:3])
        n = (b - a).cross(c - a)
        for i in f:
            k = (round(co[i].x, 4), round(co[i].y, 4), round(co[i].z, 4))
            total[k] = total.get(k, Vector()) + n
    return total


def seat(me):
    """Seat both underside buckles in place on mesh `me`; returns the report."""
    from mathutils import Matrix, Vector
    from mathutils.bvhtree import BVHTree
    from mathutils.kdtree import KDTree
    import numpy as np
    loop_normals = [n.vector.copy() for n in me.corner_normals]
    comps = parts(me)
    owner = {i: ci for ci, c in enumerate(comps) for i in c}
    polys = {}
    for p in me.polygons:
        polys.setdefault(owner[p.vertices[0]], []).append(p)
    co = [v.co.copy() for v in me.vertices]
    boxes = []
    for c in comps:
        cos = [co[i] for i in c]
        boxes.append((Vector([min(q[k] for q in cos) for k in range(3)]), Vector([max(q[k] for q in cos) for k in range(3)])))
    report = {}
    for x in STRAP_X:
        # The strap wraps the arm (spans > 5 cm across it); the underside buckle
        # is the hardware below the arm on the strap's centre line.
        strap = [ci for ci, (lo, hi) in enumerate(boxes)
                 if lo.x < x + .8 and hi.x > x - .8 and hi.y - lo.y > 5 and hi.x - lo.x < 2.5]
        keeper = [ci for ci, (lo, hi) in enumerate(boxes)
                  if ci not in strap and abs((lo.x + hi.x) / 2 - x) < 1.2 and hi.z < -2.3
                  and abs((lo.y + hi.y) / 2) < 1.6]
        strap_ids = [i for ci in strap for i in comps[ci]]
        keeper_ids = [i for ci in keeper for i in comps[ci]]
        strap_faces = [list(p.vertices) for ci in strap for p in polys[ci]]
        strap_bvh = BVHTree.FromPolygons(co, strap_faces)
        before_normals = smooth_normals(co, strap_faces)
        # The buckle as authored: flat, back to +Z, long axis Y. Its plate (the
        # part with most points) marks the centre.
        plate = max(keeper, key=lambda ci: len(comps[ci]))
        lo = Vector([min(boxes[ci][0][k] for ci in keeper) for k in range(3)])
        hi = Vector([max(boxes[ci][1][k] for ci in keeper) for k in range(3)])
        pivot = Vector(((boxes[plate][0].x + boxes[plate][1].x) / 2, (boxes[plate][0].y + boxes[plate][1].y) / 2, hi.z))
        up = Vector((0, 0, 1))
        gaps_before = [strap_bvh.find_nearest(co[i])[3] for i in keeper_ids]
        # Strap outer surface under the buckle's footprint.
        strap_lo = min(co[i].x for i in strap_ids) + .08
        strap_hi = max(co[i].x for i in strap_ids) - .08
        hits = []
        for sx in np.linspace(strap_lo, strap_hi, 7):
            for sy in np.linspace(lo.y, hi.y, 15):
                hit = strap_bvh.ray_cast(Vector((sx, sy, pivot.z - 3)), up, 6)[0]
                if hit is not None:
                    hits.append(hit)
        centre = sum(hits, Vector()) / len(hits)
        _, _, axes = np.linalg.svd(np.array([tuple(h - centre) for h in hits]))
        n = Vector(axes[2]).normalized()
        if n.z < 0:
            n = -n
        # Long axis: the strap's run across the footprint, laid in the plane.
        run = [strap_bvh.ray_cast(Vector(((strap_lo + strap_hi) / 2, sy, pivot.z - 3)), up, 6)[0] for sy in (lo.y, hi.y)]
        t = run[1] - run[0]
        t = (t - n * t.dot(n)).normalized()
        b = t.cross(n).normalized()
        turn = Matrix((b, t, n)).transposed()
        # Where the centre lands on the fitted plane, then out until tangent.
        anchor = Vector((pivot.x, pivot.y, centre.z + ((centre.x - pivot.x) * n.x + (centre.y - pivot.y) * n.y) / n.z))
        half_u = (strap_hi - strap_lo) / 2
        proud = -3.0
        for u in np.linspace(-half_u, half_u, 9):
            for w in np.linspace(lo.y - pivot.y, hi.y - pivot.y, 25):
                hit = strap_bvh.ray_cast(anchor + b * u + t * w - n * 3, n, 6)
                if hit[0] is not None:
                    proud = max(proud, 3 - hit[3])
        anchor -= n * (proud + CONTACT_CM)
        for i in keeper_ids:
            co[i] = anchor + turn @ (co[i] - pivot)
        # Flatten the strap onto the buckle's back. Each strap point moves by the
        # gap measured at the strap's OUTER surface, so both faces move together.
        disp = {}
        for i in strap_ids:
            if abs((co[i] - anchor).dot(n)) > 1.5:
                continue
            outer = strap_bvh.ray_cast(co[i] - n * 2, n, 4.0)[0]
            if outer is None:
                continue
            rel = outer - anchor
            if lo.y - pivot.y <= rel.dot(t) <= hi.y - pivot.y and abs(rel.dot(b)) <= (hi.x - lo.x) / 2:
                gap = rel.dot(n) - CONTACT_CM
                if gap > 0:
                    disp[i] = gap
        tree = KDTree(len(disp))
        for i in disp:
            tree.insert(co[i], i)
        tree.balance()
        moved, peak = 0, 0.0
        for i in strap_ids:
            d = disp.get(i)
            if d is None:
                if abs((co[i] - anchor).dot(n)) > 1.5:
                    continue
                _, j, dist = tree.find(co[i])
                f = max(0.0, 1 - dist / FALLOFF_CM)
                d = disp[j] * f * f * (3 - 2 * f)
            if d > 0:
                co[i] = co[i] - n * d
                moved += 1
                peak = max(peak, d)
        # Normals: the buckle's turn with it; the strap's follow its new surface.
        after_normals = smooth_normals(co, strap_faces)
        old_co = [v.co.copy() for v in me.vertices]
        for ci in keeper:
            for p in polys[ci]:
                for li in p.loop_indices:
                    loop_normals[li] = (turn @ loop_normals[li]).normalized()
        for ci in strap:
            for p in polys[ci]:
                for li in p.loop_indices:
                    vi = me.loops[li].vertex_index
                    was = before_normals[(round(old_co[vi].x, 4), round(old_co[vi].y, 4), round(old_co[vi].z, 4))]
                    now = after_normals[(round(co[vi].x, 4), round(co[vi].y, 4), round(co[vi].z, 4))]
                    if was.length > 1e-9 and now.length > 1e-9:
                        loop_normals[li] = (was.rotation_difference(now) @ loop_normals[li]).normalized()
        for i in strap_ids + keeper_ids:
            me.vertices[i].co = co[i]
        new_strap = BVHTree.FromPolygons(co, strap_faces)
        gaps_after = [new_strap.find_nearest(co[i])[3] for i in keeper_ids]
        report[f'keeper_x{x}'] = {
            'parts': len(keeper), 'vertices': len(keeper_ids),
            'gap_before_cm': [round(min(gaps_before), 4), round(max(gaps_before), 4)],
            'gap_after_cm': [round(min(gaps_after), 4), round(max(gaps_after), 4)],
            'tilt_degrees': round(math.degrees(math.acos(max(-1, min(1, n.z)))), 2),
            'strap_vertices_moved': moved, 'strap_max_outward_cm': round(peak, 4)}
    me.update()
    me.normals_split_custom_set(loop_normals)
    return report


def export(watch, path):
    """Write `watch` as bake_watch_components.py does; the object is left as it was."""
    import bpy
    from mathutils import Matrix
    frame = Matrix(EXPORT_FRAME)
    me = watch.data
    copy = me.copy()
    normals = [(frame.to_3x3() @ n.vector).normalized() for n in copy.corner_normals]
    copy.transform(frame)
    copy.normals_split_custom_set(normals)
    watch.data = copy
    try:
        window = bpy.context.window_manager.windows[0]
        with bpy.context.temp_override(window=window, selected_objects=[watch], active_object=watch, object=watch):
            bpy.ops.export_scene.fbx(filepath=str(path), use_selection=True, object_types={'MESH'},
                                     global_scale=1, apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS',
                                     axis_forward='-X', axis_up='Z', bake_anim=False, mesh_smooth_type='FACE',
                                     path_mode='STRIP')
    finally:
        watch.data = me
        bpy.data.meshes.remove(copy)


def roundtrip(watch, path):
    """Re-import `path` and compare it with `watch`: positions, triangles, UVs, normals."""
    import bpy
    from mathutils.kdtree import KDTree
    again = load_watch(path)
    try:
        source, me = watch.data, again.data
        tree = KDTree(len(source.vertices))
        for v in source.vertices:
            tree.insert(v.co, v.index)
        tree.balance()
        uv = source.uv_layers.active
        corners = {}
        for loop in source.loops:
            corners.setdefault(loop.vertex_index, []).append((uv.data[loop.index].uv.copy(), source.corner_normals[loop.index].vector.normalized()))
        deviation = max(tree.find(v.co)[2] for v in me.vertices)
        angles, unmatched = [], 0
        new_uv = me.uv_layers.active
        for loop in me.loops:
            value = new_uv.data[loop.index].uv
            near = [nrm for _, index, _ in tree.find_range(me.vertices[loop.vertex_index].co, .0001)
                    for at, nrm in corners[index] if (at - value).length < .0001]
            if not near:
                unmatched += 1
                continue
            actual = me.corner_normals[loop.index].vector.normalized()
            angles.append(math.degrees(math.acos(max(-1, min(1, max(nrm.dot(actual) for nrm in near))))))
        source.calc_loop_triangles()
        me.calc_loop_triangles()
        check = {'maximum_vertex_deviation_cm': deviation, 'source_triangles': len(source.loop_triangles),
                 'fbx_triangles': len(me.loop_triangles), 'unmatched_corners': unmatched,
                 'maximum_normal_angle_degrees': max(angles), 'fbx_sha256': digest(path)}
        check['passed'] = (deviation < .0001 and check['source_triangles'] == check['fbx_triangles']
                           and not unmatched and max(angles) < .5)
        return check
    finally:
        bpy.data.objects.remove(again, do_unlink=True)


def main(revision):
    import bpy
    runtime = ART / revision / 'runtime'
    report_path = runtime / 'watch-keeper-seat.json'
    if report_path.exists():
        raise RuntimeError('This candidate was already seated; preserve it and start a new revision.')
    runtime.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.context.scene.unit_settings.system = 'METRIC'
    bpy.context.scene.unit_settings.scale_length = 0.01
    watch = load_watch(STAGED)
    watch.data.calc_loop_triangles()
    report = {'base_sha256': digest(STAGED), 'base_triangles': len(watch.data.loop_triangles)}
    report.update(seat(watch.data))
    export(watch, runtime / 'VRWristwatch.fbx')
    check = roundtrip(watch, runtime / 'VRWristwatch.fbx')
    (runtime / 'fbx-roundtrip.json').write_text(json.dumps(check, indent=2))
    if not check['passed'] or check['fbx_triangles'] != report['base_triangles']:
        raise RuntimeError('FBX roundtrip differs: ' + str(check))
    report_path.write_text(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    if args[:1] == ['--stage']:
        stage(args[1])
    else:
        print('WATCH_KEEPERS_SEATED', json.dumps(main(args[0])), flush=True)
