"""Close the wrist panel's open undersides (Blender).

The runtime watch was optimised by removing enclosed caps. Five of the caps it
lost are not enclosed: the three layers of the badge block overhang the case
on the thumb side with nothing under them, and the gap between the case's
middle and upper shells looks into both. The game draws one side of each face,
so from below those read as see-through strips.

This fills every open edge loop on the underside of a watch part that lies
flat (one height within 0.2 mm): a cap facing down, textured from the loop's
own corners. Openings that face up, curved openings (cable ends) and thin trim
bands are left alone. It reads the staged watch FBX and re-exports it the way
`seat_watch_keepers.py` does.

    blender --background --python tools/close_watch_undersides.py -- <revision>
    python tools/seat_watch_keepers.py --stage <revision>
"""
import collections, json, runpy, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'build/watch-detail-20260924'
STAGED = ROOT / 'build/hand-meshes/VRWristwatch.fbx'
FLAT_CM = 0.02
BAND_CM = 0.08


def close(me, parts):
    """Cap the flat open loops of mesh `me` in place; returns what was capped."""
    import bmesh
    from mathutils import Vector
    key = lambda p: (round(p.x, 4), round(p.y, 4), round(p.z, 4))
    weld, first = [], {}
    for v in me.vertices:
        weld.append(first.setdefault(key(v.co), v.index))
    comps = parts(me)
    comp_of = {weld[i]: ci for ci, c in enumerate(comps) for i in c}
    centre = {ci: sum((me.vertices[i].co for i in c), Vector()) / len(c) for ci, c in enumerate(comps)}
    uv = me.uv_layers.active.data
    corner_uv = {}
    count = collections.Counter()
    for p in me.polygons:
        ids = [weld[i] for i in p.vertices]
        for li, a in zip(p.loop_indices, ids):
            corner_uv.setdefault(a, uv[li].uv.copy())
        for a, b in zip(ids, ids[1:] + ids[:1]):
            count[tuple(sorted((a, b)))] += 1
    link = collections.defaultdict(list)
    for (a, b), n in count.items():
        if n == 1:
            link[a].append(b)
            link[b].append(a)
    loops, seen = [], set()
    for start in link:
        if start in seen or len(link[start]) != 2:
            continue
        loop, prev, at = [start], None, start
        while True:
            seen.add(at)
            nxt = [q for q in link[at] if q != prev]
            if not nxt or nxt[0] == start or len(link[nxt[0]]) != 2:
                closed = bool(nxt) and nxt[0] == start
                break
            prev, at = at, nxt[0]
            loop.append(at)
        if closed and len(loop) >= 4:
            loops.append(loop)
    normals = [n.vector.copy() for n in me.corner_normals]
    old_loops = len(me.loops)
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    layer = bm.loops.layers.uv.active
    made, new_faces = [], []
    for loop in loops:
        zs = [me.vertices[i].co.z for i in loop]
        if max(zs) - min(zs) > FLAT_CM:
            continue
        ci = comp_of[loop[0]]
        mid = sum((me.vertices[i].co for i in loop), Vector()) / len(loop)
        want = Vector((0, 0, 1 if mid.z > centre[ci].z else -1))
        heights = [me.vertices[i].co.z for i in comps[ci]]
        # Only undersides, and not the thin trim bands, whose openings no view reaches.
        if want.z > 0 or max(heights) - min(heights) < BAND_CM:
            continue
        try:
            face = bm.faces.new([bm.verts[i] for i in loop])
        except ValueError:
            continue
        face.normal_update()
        if face.normal.dot(want) < 0:
            face.normal_flip()
        for l in face.loops:
            l[layer].uv = corner_uv[l.vert.index]
        tris = bmesh.ops.triangulate(bm, faces=[face])['faces']
        new_faces.extend((f, want) for f in tris)
        made.append({'part_vertices': len(comps[ci]), 'edges': len(loop), 'height_cm': round(mid.z, 3),
                     'faces': 'up' if want.z > 0 else 'down'})
    bm.faces.index_update()
    flat = {f.index: want for f, want in new_faces}
    bm.to_mesh(me)
    bm.free()
    me.update()
    out = []
    for p in me.polygons:
        for li in p.loop_indices:
            out.append(flat[p.index].copy() if p.index in flat else None)
    # Existing faces keep their loops in order ahead of the new ones.
    for i in range(old_loops):
        if out[i] is None:
            out[i] = normals[i]
    for i, n in enumerate(out):
        if n is None:
            raise RuntimeError('A loop lost its normal while capping')
    for p in me.polygons:
        p.use_smooth = True
    me.normals_split_custom_set(out)
    return made


def main(revision):
    import bpy
    seat = runpy.run_path(str(ROOT / 'tools/seat_watch_keepers.py'), run_name='asset_source')
    runtime = ART / revision / 'runtime'
    report_path = runtime / 'watch-underside-caps.json'
    if report_path.exists():
        raise RuntimeError('This candidate was already capped; preserve it and start a new revision.')
    runtime.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.context.scene.unit_settings.system = 'METRIC'
    bpy.context.scene.unit_settings.scale_length = 0.01
    watch = seat['load_watch'](STAGED)
    watch.data.calc_loop_triangles()
    report = {'base_sha256': seat['digest'](STAGED), 'base_triangles': len(watch.data.loop_triangles)}
    report['caps'] = close(watch.data, seat['parts'])
    watch.data.calc_loop_triangles()
    report['triangles'] = len(watch.data.loop_triangles)
    seat['export'](watch, runtime / 'VRWristwatch.fbx')
    check = seat['roundtrip'](watch, runtime / 'VRWristwatch.fbx')
    (runtime / 'fbx-roundtrip.json').write_text(json.dumps(check, indent=2))
    if not check['passed']:
        raise RuntimeError('FBX roundtrip differs: ' + str(check))
    report_path.write_text(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    print('WATCH_UNDERSIDES_CLOSED', json.dumps(main(args[0])), flush=True)
