"""Leather forearm bracer and finished cuff ends for a runtime hand revision (Blender).

Run inside Blender with KF2VR_ART_REVISION=<new>. Geometry starts from revision
GEOMETRY_BASE's untrimmed forearms; every other runtime file (textures, watch)
comes from TEXTURE_BASE. Replaces revision 70's folded forearm "dish":

- Left: the forearm skin under the watch becomes a leather bracer, cut
  CUT_PAST_WATCH_CM beyond the watch's far end. Its last HEM band is raised
  slightly for a folded hem. The watch straps keep sitting on that surface.
- Right: the skin is cut just inside the glove cuff, as in revision 70.
- Both ends: a rolled edge turns into a dark lining that ends in a flat,
  recessed end plate (its own UV block, so it could later carry a display).

The cut is a clean plane (bmesh bisect); new rings are built from the cut edge.
Points, wedges and faces outside the edited forearms keep their original rows;
unused points/wedges are compacted. New points are weighted to the hand bone,
like the forearm skin they replace. `tools/paint_forearm_bracer.py` then paints
the leather, lining and plate texels from `forearm-bracer.json`.
"""
import hashlib, json, math, os, runpy, shutil, struct
from pathlib import Path
import bmesh, bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'build/watch-detail-20260924'
GEOMETRY_BASE, TEXTURE_BASE = '68', '70'
CUT_PAST_WATCH_CM = 0.9
RIGHT_TUCK_CM = 0.35
# Leather is painted up to this far under the glove cuff (hidden there).
PAINT_UNDER_GLOVE_CM = 0.75
RIM_FAIR_CM = 1.0
END = {'Left': {'roll': 0.30, 'depth': 2.2, 'swell': 0.06, 'hem': 0.7},
       'Right': {'roll': 0.22, 'depth': 1.6, 'swell': 0.0, 'hem': 0.0}}
# End-part texel blocks (width, height) in 4096 atlas pixels; placed in free
# atlas space. The roll and lining are uniform around the ring.
BLOCKS = {'roll': (64, 48), 'lining': (64, 192), 'plate': (176, 176)}
KINDS = (None, 'roll', 'lining', 'plate')
# The watch export frame used by bake_watch_components.py / render_watch_runtime.py.
WATCH_FRAME = Matrix(((0, 0, -1, 3.72), (-1, 0, 0, -3.9), (0, 1, 0, 0), (0, 0, 0, 1)))


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def side_frame(bind, names, side):
    B = {n: bind[i] for i, n in enumerate(names)}
    o = B[side + 'Hand_1stP']
    f = (B[side + 'HandMiddle1_1stP'] - o).normalized()
    t = B[side + 'HandIndex1_1stP'] - B[side + 'HandPinky1_1stP']
    t = (t - f * t.dot(f)).normalized()
    return o, Matrix((f, -t, -f.cross(t).normalized()))


def watch_points():
    """Watch vertices in the left hand frame (fingers +X, dorsal +Z)."""
    scene = bpy.data.scenes.new('KF2VR bracer watch probe')
    scene.unit_settings.system = 'METRIC'
    scene.unit_settings.scale_length = 0.01
    previous = bpy.context.window.scene
    bpy.context.window.scene = scene
    try:
        before = set(bpy.data.objects)
        bpy.ops.import_scene.fbx(filepath=str(ART / TEXTURE_BASE / 'runtime/VRWristwatch.fbx'))
        mesh = [o for o in bpy.data.objects if o not in before and o.type == 'MESH']
        m = WATCH_FRAME.inverted() @ mesh[0].matrix_world
        pts = [m @ v.co for v in mesh[0].data.vertices]
        for o in [o for o in bpy.data.objects if o not in before]:
            bpy.data.objects.remove(o, do_unlink=True)
        return pts
    finally:
        bpy.context.window.scene = previous
        bpy.data.scenes.remove(scene)


def fit_axis(pts):
    """Arm centre line from 1 cm ring centroids (least squares)."""
    rings = {}
    for p in pts:
        rings.setdefault(round(p.x), []).append(p)
    cents = [sum(r, Vector()) / len(r) for k, r in sorted(rings.items()) if len(r) >= 8]
    c = sum(cents, Vector()) / len(cents)
    import numpy as np
    m = np.array([tuple(q - c) for q in cents])
    a = Vector(np.linalg.svd(m)[2][0])
    return c, (a if a.x > 0 else -a).normalized()


def build(chunks, g, shells_of):
    points, wedges, faces, weights = g['decode_geometry'](chunks)
    bones, names = g['bone_data'](chunks)
    bind = g['bind_positions'](bones)
    shell = shells_of(points, wedges, faces)
    dom = [names[max(w, key=w.get)] for w in weights]
    new_points = [Vector(p) for p in points]
    extra_points, extra_weights = [], []   # (position), bone
    kept_faces = {}                        # original face index -> row (unchanged)
    new_faces = []                         # [(point or ('new', i), u, v)] * 3, ActorX order
    edited = set()
    report = {}
    watch = watch_points()
    for side in ('Left', 'Right'):
        o, frame = side_frame(bind, names, side)
        to_f = lambda p: frame @ (Vector(p) - o)
        mine = {i for i, n in enumerate(names) if n.startswith(side)}
        hand_bone = names.index(side + 'Hand_1stP')
        members = {}
        for p in range(len(points)):
            if max(weights[p], key=weights[p].get) in mine:
                members.setdefault(shell[p], []).append(p)
        skin = max((s for s in members if min(to_f(points[p]).x for p in members[s]) < -5),
                   key=lambda s: len(members[s]))
        glove = max((s for s in members if s != skin), key=lambda s: len(members[s]))
        local = {p: to_f(points[p]) for p in members[skin]}
        c, a = fit_axis([q for q in local.values() if q.x < 1.5])
        along = lambda q: (q - c).dot(a)
        ref = Vector((0, 0, 1)) - a * a.z
        ref.normalize()
        side_ref = a.cross(ref)

        def theta(q):
            r = q - c
            r -= a * r.dot(a)
            return (math.atan2(r.dot(side_ref), r.dot(ref)) / (2 * math.pi)) % 1.0
        gl = [to_f(points[p]) for p in members[glove]]
        rim = {}
        for q in gl:
            k = int(theta(q) * 24)
            rim[k] = min(rim.get(k, math.inf), along(q))
        rim_s = sorted(rim.values())[len(rim) // 2]
        if side == 'Left':
            s_cut = min(along(q) for q in watch) - CUT_PAST_WATCH_CM
        else:
            s_cut = rim_s + RIGHT_TUCK_CM
        spec = END[side]

        # Skin shell as a bmesh in the side frame (Blender winding = reversed ActorX).
        shell_faces = [i for i, f in enumerate(faces) if shell[wedges[f[0]][0]] == skin]
        bm = bmesh.new()
        uvl = bm.loops.layers.uv.new('UV')
        kind_layer = bm.faces.layers.int.new('cuff_part')
        vert, pid = {}, {}
        for p in members[skin]:
            v = bm.verts.new(local[p])
            vert[p], pid[v] = v, p
        origin_face = {}
        for i in shell_faces:
            f = faces[i]
            corners = [f[2], f[1], f[0]]
            try:
                bf = bm.faces.new([vert[wedges[w][0]] for w in corners])
            except ValueError:
                kept_faces[i] = chunks['FACE0000'].rows[i]
                continue
            for loop, w in zip(bf.loops, corners):
                loop[uvl].uv = (wedges[w][1], wedges[w][2])
            origin_face[bf] = i
        bm.verts.ensure_lookup_table()
        bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], dist=1e-5,
                               plane_co=c + a * s_cut, plane_no=a, clear_inner=True)
        assert min(along(v.co) for v in bm.verts) > s_cut - 1e-3
        ring_edges = [e for e in bm.edges if e.is_boundary and all(abs(along(v.co) - s_cut) < 1e-3 for v in e.verts)]
        # Order the cut edge into one loop.
        nxt = {}
        for e in ring_edges:
            v0, v1 = e.verts
            nxt.setdefault(v0, []).append(v1)
            nxt.setdefault(v1, []).append(v0)
        ring = [ring_edges[0].verts[0]]
        prev = None
        while True:
            options = [v for v in nxt[ring[-1]] if v is not prev]
            if not options or options[0] is ring[0]:
                break
            prev = ring[-1]
            ring.append(options[0])
        if len(ring) != len(ring_edges):
            raise RuntimeError(f'{side}: cut edge is not a single loop ({len(ring)} of {len(ring_edges)})')
        if (theta(ring[1].co) - theta(ring[0].co)) % 1.0 > 0.5:
            ring.reverse()
        # Raised hem band (left): push the last HEM cm outward.
        if spec['swell']:
            for v in bm.verts:
                ds = along(v.co) - s_cut
                if ds < spec['hem']:
                    r = v.co - c
                    r -= a * r.dot(a)
                    v.co += r.normalized() * spec['swell'] * max(0.0, min(1.0, (spec['hem'] - ds) / 0.25))
        centre = c + a * s_cut
        # A cut through anatomy leaves a lumpy rim: smooth its radius around the
        # ring and fade that correction out over the last RIM_FAIR_CM.
        radial = lambda p: (p - c) - a * (p - c).dot(a)
        rad = [radial(v.co).length for v in ring]
        smooth = rad
        for _ in range(3):
            smooth = [sum(smooth[(k + j) % len(rad)] for j in range(-4, 5)) / 9 for k in range(len(rad))]
        ring_theta = [theta(v.co) for v in ring]
        for v in bm.verts:
            ds = along(v.co) - s_cut
            if ds < RIM_FAIR_CM:
                tv = theta(v.co)
                k = min(range(len(ring)), key=lambda i: min(abs(ring_theta[i] - tv), 1 - abs(ring_theta[i] - tv)))
                w = 1 - ds / RIM_FAIR_CM
                v.co += radial(v.co).normalized() * (smooth[k] - rad[k]) * w * w * (3 - 2 * w)
        t_wall = spec['roll']
        r_roll = t_wall / 2
        profile = [('roll', -r_roll * math.sin(j * math.pi / 4), -r_roll * (1 - math.cos(j * math.pi / 4)), j / 4)
                   for j in range(1, 5)]
        depth = spec['depth']
        lining = [(0.35, t_wall + 0.03), (depth * 0.55, t_wall + 0.08), (depth, t_wall + 0.14)]
        base = [(v.co.copy(), ((v.co - centre) - a * (v.co - centre).dot(a)).normalized()) for v in ring]
        # The arm narrows toward the wrist: the lining follows the skin's own
        # radius at each depth and angle (ray from the axis), minus the wall.
        tree = BVHTree.FromBMesh(bm)

        def skin_radius(along_cm, e, fallback):
            origin = c + a * along_cm
            hit = tree.ray_cast(origin, e)
            return (hit[0] - origin).dot(e) if hit[0] is not None else fallback
        rings = [ring]
        for _, da, dr, _ in profile:
            rings.append([bm.verts.new(q + a * da + e * dr) for q, e in base])
        for da, inset in lining:
            row = []
            for q, e in base:
                r0 = (q - centre).dot(e)
                row.append(bm.verts.new(c + a * (s_cut + da) + e * (min(r0, skin_radius(s_cut + da, e, r0)) - inset)))
            rings.append(row)
        plate_ring = [bm.verts.new(v.co) for v in rings[-1]]
        plate_centre = bm.verts.new(sum((v.co for v in plate_ring), Vector()) / len(plate_ring))
        n = len(ring)
        roll_mid = [q + e * -r_roll for q, e in base]

        def add_face(verts, uvs, kind, want):
            f = bm.faces.new(verts)
            f.normal_update()
            if f.normal.dot(want) < 0:
                f.normal_flip()
            f[kind_layer] = KINDS.index(kind)
            by_vert = dict(zip(verts, uvs))
            for loop in f.loops:
                loop[uvl].uv = by_vert[loop.vert]

        def strip(r0, r1, kind, v0, v1, want):
            for k in range(n):
                k1 = (k + 1) % n
                u0, u1 = k / n, (k + 1) / n   # u = 1.0 closes the loop on its own wedges
                add_face([r0[k], r0[k1], r1[k1], r1[k]], [(u0, v0), (u1, v0), (u1, v1), (u0, v1)], kind, want(k))
        for j in range(4):
            strip(rings[j], rings[j + 1], 'roll', j / 4, (j + 1) / 4,
                  lambda k, j=j: (rings[j][k].co + rings[j + 1][k].co) / 2 - roll_mid[k])
        dsum = [0.0]
        for j in range(4, 4 + len(lining)):
            dsum.append(dsum[-1] + (rings[j + 1][0].co - rings[j][0].co).length)
        for j in range(4, 4 + len(lining)):
            strip(rings[j], rings[j + 1], 'lining', dsum[j - 4] / dsum[-1], dsum[j - 3] / dsum[-1],
                  lambda k: -base[k][1])
        radius = max((v.co - plate_centre.co).length for v in plate_ring)

        def plate_uv(v):
            r = v.co - plate_centre.co
            r -= a * r.dot(a)
            return (0.5 + 0.5 * r.dot(ref) / radius, 0.5 + 0.5 * r.dot(side_ref) / radius)
        for k in range(n):
            tri = [plate_ring[k], plate_ring[(k + 1) % n], plate_centre]
            add_face(tri, [plate_uv(v) for v in tri], 'plate', -a)
        # Unchanged original triangles keep their rows; everything else is emitted anew.
        kept = set()
        for bf in bm.faces:
            i = origin_face.get(bf)
            if i is not None and bf[kind_layer] == 0 and len(bf.verts) == 3 and all(v in pid for v in bf.verts) \
                    and {pid[v] for v in bf.verts} == {wedges[w][0] for w in faces[i][:3]}:
                kept_faces[i] = chunks['FACE0000'].rows[i]
                kept.add(bf)
        bmesh.ops.triangulate(bm, faces=[bf for bf in bm.faces if bf not in kept])
        bm.verts.index_update()
        for bf in bm.faces:
            if bf in kept:
                continue
            kind = KINDS[bf[kind_layer]]
            corners = []
            for loop in reversed(bf.loops):   # back to ActorX winding
                v = loop.vert
                corners.append((pid[v] if v in pid else ('new', side, v.index), kind, loop[uvl].uv.x, loop[uvl].uv.y))
            new_faces.append((side, corners))
        # Positions of this side's new vertices, and moved original ones.
        for v in bm.verts:
            if v in pid:
                new_points[pid[v]] = frame.transposed() @ v.co + o
        extra = {('new', side, v.index): frame.transposed() @ v.co + o for v in bm.verts if v not in pid}
        extra_points.append((side, hand_bone, extra))
        edited.update(shell_faces)
        report[side] = {'frame_origin': list(o), 'frame_rows': [list(r) for r in frame],
                        'axis_point': list(c), 'axis_dir': list(a), 'ref': list(ref), 'side_ref': list(side_ref),
                        'cut_along_cm': s_cut, 'glove_rim_along_cm': rim_s,
                        'paint_limit_along_cm': rim_s + PAINT_UNDER_GLOVE_CM, 'ring_vertices': n,
                        'plate_radius_cm': radius, **spec}
        if side == 'Left':
            report[side]['watch_far_end_along_cm'] = min(along(q) for q in watch)
        bm.free()
    return points, wedges, faces, weights, names, new_points, extra_points, kept_faces, new_faces, edited, report


def triangle_area(u):
    return abs((u[1][0] - u[0][0]) * (u[2][1] - u[0][1]) - (u[2][0] - u[0][0]) * (u[1][1] - u[0][1])) / 2


def place_blocks(used_uv_tris, size=4096, cell=16, pad_cells=2):
    """Pack BLOCKS into the largest free atlas rectangle (UV y is from the top)."""
    import numpy as np
    n = size // cell
    occ = np.zeros((n, n), bool)
    for tri in used_uv_tris:
        xs = [u * n for u, _ in tri]
        ys = [v * n for _, v in tri]
        occ[max(0, int(min(ys))):min(n, int(max(ys)) + 1), max(0, int(min(xs))):min(n, int(max(xs)) + 1)] = True
    padded = np.pad(occ, pad_cells)
    from numpy.lib.stride_tricks import sliding_window_view
    free = ~sliding_window_view(padded, (2 * pad_cells + 1,) * 2).any(axis=(2, 3))
    best, h = (0, None), np.zeros(n, int)
    for y in range(n):
        h = np.where(free[y], h + 1, 0)
        stack = []
        for x in range(n + 1):
            cur = h[x] if x < n else 0
            start = x
            while stack and stack[-1][1] >= cur:
                s0, hh = stack.pop()
                if hh * (x - s0) > best[0] and hh * cell >= max(b[1] for b in BLOCKS.values()):
                    best = (hh * (x - s0), (s0 * cell, (y - hh + 1) * cell, (x - s0) * cell, int(hh) * cell))
                start = s0
            stack.append((start, cur))
    x, y, w, h = (int(c) for c in best[1])
    need = sum(b[0] for b in BLOCKS.values()) + 16 * (len(BLOCKS) - 1)
    if w < need:
        raise RuntimeError(f'No free atlas rectangle for the cuff blocks ({best[1]})')
    blocks, cx = {}, x
    for name, (bw, bh) in BLOCKS.items():
        blocks[name] = [cx, y, bw, bh]
        cx += bw + 16
    return blocks, [x, y, w, h]


def main():
    new = os.environ['KF2VR_ART_REVISION']
    out = ART / new / 'runtime'
    if (out / 'forearm-bracer.json').exists():
        raise RuntimeError('This candidate already has a bracer; preserve it and start a new version.')
    out.mkdir(parents=True, exist_ok=True)
    skip = {'forearm-trim.json', 'hand-fbx-roundtrip.json', 'VRFloatingHands.fbx', 'VRFloatingHands.psk'}
    for p in (ART / TEXTURE_BASE / 'runtime').iterdir():
        if p.is_file() and p.suffix.lower() in {'.fbx', '.tga', '.json'} and p.name not in skip:
            shutil.copy2(p, out / p.name)
    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    shells_of = runpy.run_path(str(ROOT / 'tools/trim_hand_forearms.py'), run_name='asset_source')['shells']
    source = ART / GEOMETRY_BASE / 'runtime/VRFloatingHands.psk'
    chunks = g['read_psk'](source)
    (points, wedges, faces, weights, names, new_points, extra_points, kept_faces,
     new_faces, edited, report) = build(chunks, g, shells_of)
    # Faces outside the edited skin shells are untouched.
    rows = [(i, chunks['FACE0000'].rows[i]) for i in range(len(faces)) if i not in edited or i in kept_faces]
    used_uv = [[(wedges[w][1], wedges[w][2]) for w in g['FACE'].unpack(r)[:3]] for _, r in rows]
    blocks, free_rect = place_blocks(used_uv)
    # Assemble points: originals first (moved where edited), then new ones.
    all_points = list(new_points)
    point_weights = [dict(w) for w in weights]
    key_to_point = {}
    for side, bone, extra in extra_points:
        for key, pos in extra.items():
            key_to_point[key] = len(all_points)
            all_points.append(pos)
            point_weights.append({bone: 1.0})
    wedge_rows = list(chunks['VTXW0000'].rows)
    material, reserved = wedges[0][3], wedges[0][4]
    wedge_of = {}

    def wedge(point, u, v):
        key = (point, round(u, 7), round(v, 7))
        if key not in wedge_of:
            wedge_of[key] = len(wedge_rows)
            wedge_rows.append(g['WEDGE'].pack(point, u, v, material, reserved, 0))
        return wedge_of[key]
    smoothing = g['FACE'].unpack(chunks['FACE0000'].rows[0])[5]
    face_rows = [r for _, r in rows]
    counts = {}
    for side, corners in new_faces:
        ids = []
        for key, kind, u, v in corners:
            point = key if isinstance(key, int) else key_to_point[key]
            if kind:
                bx, by, bw, bh = blocks[kind]
                u, v = (bx + u * bw) / 4096, (by + v * bh) / 4096
            ids.append(wedge(point, u, v))
        face_rows.append(g['FACE'].pack(*ids, material, 0, smoothing))
        counts[side] = counts.get(side, 0) + 1
    # Compact unused wedges and points.
    used_w = sorted({w for r in face_rows for w in g['FACE'].unpack(r)[:3]})
    wmap = {w: i for i, w in enumerate(used_w)}
    used_p = sorted({g['WEDGE'].unpack(wedge_rows[w])[0] for w in used_w})
    pmap = {p: i for i, p in enumerate(used_p)}
    if len(used_w) > 65535:
        raise RuntimeError('Wedges exceed the 16-bit ActorX face index range')
    chunks['PNTS0000'].rows = [struct.pack('<3f', *all_points[p]) for p in used_p]
    wrows = []
    for w in used_w:
        point, u, v, m, r1, r2 = g['WEDGE'].unpack(wedge_rows[w])
        wrows.append(g['WEDGE'].pack(pmap[point], u, v, m, r1, r2))
    chunks['VTXW0000'].rows = wrows
    frows = []
    for r in face_rows:
        f = g['FACE'].unpack(r)
        frows.append(g['FACE'].pack(wmap[f[0]], wmap[f[1]], wmap[f[2]], *f[3:]))
    chunks['FACE0000'].rows = frows
    chunks['RAWWEIGHTS'].rows = [g['WEIGHT'].pack(wt, pmap[p], b) for p in used_p
                                 for b, wt in sorted(point_weights[p].items())]
    preserved = {k: hashlib.sha256(b''.join(c.rows)).hexdigest() for k, c in chunks.items()
                 if k in ('ACTRHEAD', 'MATT0000', 'REFSKELT')}
    psk = out / 'VRFloatingHands.psk'
    psk.write_bytes(b''.join(c.encode() for c in chunks.values()))
    check = g['read_psk'](psk)
    g['decode_geometry'](check)
    export = g['export_fbx'](psk, out / 'VRFloatingHands.fbx')
    result = {'change': 'Leather forearm bracer (left) and finished cuff ends with rolled hem, lining and end plate',
              'geometry_base_revision': int(GEOMETRY_BASE), 'texture_base_revision': int(TEXTURE_BASE),
              'source_psk_sha256': digest(source), 'sides': report, 'blocks_px': blocks, 'free_rect_px': free_rect,
              'new_triangles': counts, 'triangles': len(frows), 'base_triangles': len(faces),
              'points': len(used_p), 'wedges': len(used_w), 'preserved_chunks_sha256': preserved,
              'psk_sha256': digest(psk), 'fbx_sha256': digest(out / 'VRFloatingHands.fbx'),
              'generator_sha256': digest(Path(__file__)), **export}
    (out / 'forearm-bracer.json').write_text(json.dumps(result, indent=2))
    return result


if __name__ == '__main__':
    print('HAND_FOREARM_BRACER', json.dumps(main()), flush=True)
