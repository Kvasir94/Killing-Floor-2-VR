"""Move the wrist panel up the forearm and lengthen the left bracer under it (Blender).

Kvasir94's pick W-b (2026-11-11). The watch case is a rigid slab 13.5 cm long
that lay across the wrist joint: its front ran onto the back of the hand and
was buried up to 11 mm in the glove's wrist pad. This moves the whole panel
MOVE_CM toward the elbow, so the case stops at the wrist, and makes the bracer
that much longer so the panel still sits on leather.

- Bracer: the left arm's skin shell behind the glove's hem is stretched along
  the arm by MOVE_CM (its stitched hem and its end parts, the roll, lining and
  plate, move as one piece). No triangles, UVs or weights change, only point
  positions, so the leather's texels stretch by about a quarter along the arm.
- Watch: the case and everything fixed to it move as one body, along the arm
  and out or in by as much as the arm's back does between the two places. The
  two strap rings and the cradle under the case are refitted to the arm vertex
  by vertex (each keeps its clearance from the leather, since the forearm is
  thicker there), each buckle moves as a rigid piece with the
  leather under it, and the two cables bend so their plugs rest on the leather
  instead of ending inside it.
- Two fixes from the glove review ride along, because both shapes are refitted
  here anyway. Fix 3: the bracer is the arm's own skin painted as leather, and
  its tendon lines read as hard creases in a sleeve; the stretched bracer is
  smoothed (each point's distance from the arm's axis is eased toward its
  neighbours', outward only, so grooves fill and nothing sinks; the hem and
  the rolled end keep their shape), and the straps follow.
  Fix 5: the short strap tail under each thumb-side buckle had a wave across
  it; its columns are levelled.
- The watch mesh keeps its own frame, anchored at the screen. What changes is
  where that frame sits on the hand: `seat_watch_keepers.EXPORT_FRAME` and
  `VRSpatialHUD.GetWristwatchTransform` carry the new offsets (the report
  prints them).

    blender --background --python tools/move_watch_up_forearm.py -- <revision> --base <revision> [--analyse]
    python tools/move_watch_up_forearm.py --paint <revision>

Reads build/watch-detail-20260924/<base>/runtime and writes <revision>/runtime
(hand PSK and FBX, watch FBX, watch-move.json). --analyse only prints how far
the case would stand into the glove and the bracer at several moves. --paint
(plain Python) then moves the bracer's pressed HORZINE mark: the old one is
blended out of the hand maps and the mark is pressed again, at its true
proportions, midway between the straps' new places.
"""
import hashlib, json, math, runpy, shutil, struct, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'build/watch-detail-20260924'
MOVE_CM = 2.5
STRETCH_FROM_HEM_CM = 0.3        # the bracer is stretched from this far behind the glove's hem
RIGID_END_CM = 1.8               # the bracer's last stretch, with its stitched hem, is moved, not stretched
STRAP_X = (-6.83, -0.99)         # the two straps' centre lines before the move (hand frame, cm)
# The HORZINE mark pressed into the bracer's underside (detail_hand_surfaces.py) sat between the straps. The
# straps move and the leather stretches, so the old mark is blended out and pressed again between them.
MARK_BOX = (2084, 3135, 2156, 3402)      # the old mark in the atlas (x0, y0, x1, y1)
MARK_PLAIN_SHIFT = (-95, 0)              # where, from the mark, the same leather island is plain
MARK_FEATHER = 10
REST_CM = 0.02                   # a plug or pushed-out vertex rests this far off the leather
SMOOTH_PASSES, SMOOTH_EASE = 14, 0.5     # fix 3: how hard the bracer's creases are smoothed
SMOOTH_SINK_CM = 0.04             # the most any point may move toward the arm's axis
SMOOTH_MARGIN_CM = 1.0           # the hem and the rolled end keep their shape; smoothing fades in over this
SMOOTH_END_CM = 1.6              # the stretch before the rolled end that is left alone (its hem and the lining inside)
TAIL_CM = 0.62                   # fix 5: the length of strap tail under a thumb-side buckle that is levelled
MARK_WIDTH_CM = 3.6              # the pressed mark, a little narrower than before so it clears both straps
BLOCKS = {'roll': (2704, 2848, 64, 48), 'lining': (2784, 2848, 64, 192), 'plate': (2864, 2848, 176, 176)}
SIZE = 4096


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def in_end_block(uvs):
    for x, y, w, h in BLOCKS.values():
        if all(x - 1 <= u * SIZE <= x + w + 1 and y - 1 <= v * SIZE <= y + h + 1 for u, v in uvs):
            return True
    return False


def left_arm(chunks, g, shells_of):
    """The left hand's shells in its own frame (fingers +X, thumb -Y, back of hand +Z), the arm's axis and hem."""
    import numpy as np
    from mathutils import Matrix, Vector
    points, wedges, faces, weights = g['decode_geometry'](chunks)
    bones, names = g['bone_data'](chunks)
    bind = g['bind_positions'](bones)
    B = {n: bind[i] for i, n in enumerate(names)}
    o = B['LeftHand_1stP']
    f = (B['LeftHandMiddle1_1stP'] - o).normalized()
    t = B['LeftHandIndex1_1stP'] - B['LeftHandPinky1_1stP']
    t = (t - f * t.dot(f)).normalized()
    frame = Matrix((f, -t, -f.cross(t).normalized()))
    shell = shells_of(points, wedges, faces)
    left = [names[max(w, key=w.get)].startswith('Left') for w in weights]
    local = {p: frame @ (Vector(points[p]) - o) for p in range(len(points)) if left[p]}
    members = {}
    for p in local:
        members.setdefault(shell[p], []).append(p)
    skin = max((s for s in members if min(local[p].x for p in members[s]) < -5), key=lambda s: len(members[s]))
    end_points, skin_faces, glove_faces = set(), [], []
    for i, face in enumerate(faces):
        p0 = wedges[face[0]][0]
        if not left[p0]:
            continue
        if in_end_block([(wedges[w][1], wedges[w][2]) for w in face[:3]]):
            end_points.update(wedges[w][0] for w in face[:3])       # the end plate is a shell of its own
        elif shell[p0] != skin:
            glove_faces.append(i)
        else:
            skin_faces.append(i)
    rings = {}
    for p in members[skin]:
        if p not in end_points and local[p].x < 1.5:
            rings.setdefault(round(local[p].x), []).append(local[p])
    cents = [sum(r, Vector()) / len(r) for _, r in sorted(rings.items()) if len(r) >= 8]
    c = sum(cents, Vector()) / len(cents)
    a = Vector(np.linalg.svd(np.array([tuple(q - c) for q in cents]))[2][0])
    a = (a if a.x > 0 else -a).normalized()
    along = lambda q: (q - c).dot(a)
    ref = (Vector((0, 0, 1)) - a * a.z).normalized()
    side = a.cross(ref)
    theta = lambda q: (math.atan2((q - c).dot(side), (q - c).dot(ref)) / (2 * math.pi)) % 1.0
    hem = {}
    for i in glove_faces:
        for w in faces[i][:3]:
            q = local[wedges[w][0]]
            k = int(theta(q) * 24)
            hem[k] = min(hem.get(k, math.inf), along(q))
    hem_s = sorted(hem.values())[len(hem) // 2]
    return {'points': points, 'wedges': wedges, 'faces': faces, 'origin': o, 'frame': frame, 'local': local,
            'skin': set(members[skin]) | end_points, 'end_points': end_points, 'skin_faces': skin_faces, 'glove_faces': glove_faces,
            'c': c, 'a': a, 'along': along, 'theta': theta, 'hem_s': hem_s}


def stretched(arm, move):
    """Left skin points after the bracer is lengthened by `move` cm behind the hem."""
    c, a, along, local = arm['c'], arm['a'], arm['along'], arm['local']
    s0 = arm['hem_s'] - STRETCH_FROM_HEM_CM
    body = [p for p in arm['skin'] if p not in arm['end_points']]
    s_end = min(along(local[p]) for p in body)
    # The last stretch before the rolled end (its raised, stitched hem) moves as one piece with the end, so
    # the hem keeps its shape; the leather between it and the glove takes all of the stretch.
    s_hem = s_end + RIGID_END_CM
    k = (s0 - s_hem + move) / (s0 - s_hem)
    out = {}
    for p in arm['skin']:
        q = local[p]
        if p in arm['end_points'] or along(q) < s_hem:
            out[p] = q - a * move
        elif along(q) < s0:
            out[p] = q + a * ((along(q) - s0) * (k - 1))
        else:
            out[p] = q
    # Fix 3: ease each bracer point's distance from the axis toward its neighbours'.
    neighbours = {}
    for i in arm['skin_faces']:
        tri = [arm['wedges'][w][0] for w in arm['faces'][i][:3]]
        for p0 in tri:
            neighbours.setdefault(p0, set()).update(q0 for q0 in tri if q0 != p0)
    s_far = s_end - move
    weight, radius, unit = {}, {}, {}
    for p in body:
        s_p = (out[p] - c).dot(a)
        w = min((s0 - s_p) / SMOOTH_MARGIN_CM, (s_p - s_far - SMOOTH_END_CM) / SMOOTH_MARGIN_CM)
        r = (out[p] - c) - a * s_p
        radius[p], unit[p] = r.length, r.normalized()
        # A point lying under another layer of the bracer (its seam is a lapped fold) stays where it is.
        weight[p] = 0.0 if p in arm.get('covered', ()) else max(0.0, min(1.0, w))
    start = dict(radius)
    for _ in range(SMOOTH_PASSES):
        eased = {}
        for p in body:
            near = [radius[q0] for q0 in neighbours.get(p, ()) if q0 in radius]
            eased[p] = radius[p] + SMOOTH_EASE * weight[p] * (sum(near) / len(near) - radius[p]) if near else radius[p]
            # Fill the grooves, do not plane the ridges: a point that sank would bare the lining inside the
            # rolled end, or open a gap under the glove's hem.
            eased[p] = max(start[p] - SMOOTH_SINK_CM, eased[p])
        radius = eased
    for p in body:
        if weight[p] > 0:
            out[p] = c + a * (out[p] - c).dot(a) + unit[p] * radius[p]
    largest = max(abs(radius[p] - start[p]) for p in body)
    return out, {'stretch_from_along_cm': s0, 'bracer_end_along_cm': s_end, 'stretch_factor': k,
                 'largest_smoothing_cm': largest}


def surface(arm, positions, which):
    from mathutils.bvhtree import BVHTree
    verts, index, polys = [], {}, []
    for i in arm[which]:
        tri = []
        for w in arm['faces'][i][:3]:
            p = arm['wedges'][w][0]
            if p not in index:
                index[p] = len(verts)
                verts.append(positions[p])
            tri.append(index[p])
        if len(set(tri)) == 3:
            polys.append(tri)
    return BVHTree.FromPolygons(verts, polys)


def watch_parts(me):
    """Connected parts of the watch (welded by position) with what each is."""
    import numpy as np
    V = [v.co.copy() for v in me.vertices]
    key = {}
    vid = [key.setdefault(tuple(round(x, 3) for x in p), len(key)) for p in V]
    parent = list(range(len(key)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    for p in me.polygons:
        r0 = find(vid[p.vertices[0]])
        for v in p.vertices[1:]:
            r1 = find(vid[v])
            if r1 != r0:
                parent[r1] = r0
    groups = {}
    for i in range(len(V)):
        groups.setdefault(find(vid[i]), []).append(i)
    parts = []
    for idx in groups.values():
        P = np.array([V[i] for i in idx])
        lo, hi = P.min(0), P.max(0)
        mid = (lo + hi) / 2
        strap = min(range(2), key=lambda j: abs(mid[0] - STRAP_X[j]))
        near_strap = abs(mid[0] - STRAP_X[strap]) < 1.25 and hi[0] - lo[0] < 2.3
        if hi[1] - lo[1] > 7 and hi[2] - lo[2] > 5 and hi[0] - lo[0] < 2.0:
            kind = ('ring', strap)
        elif hi[1] - lo[1] > 6 and hi[2] - lo[2] > 2.5:
            kind = ('saddle',)           # the cradle that wraps the thumb side of the arm under the case
        elif near_strap and mid[1] < -3.95 and lo[2] < 2.0:
            kind = ('buckle', strap, 'thumb')
        elif near_strap and mid[2] < -2.5:
            kind = ('buckle', strap, 'under')
        elif mid[1] < -2.9 and (lo[2] < 2.45 or (hi[2] < 3.4 and lo[1] < -3.1 and hi[0] - lo[0] < 1.0 and mid[2] < 3.2)) \
                and not (hi[1] - lo[1] > 4):
            kind = ('cable', 0 if mid[0] < -2.5 else 1)
        else:
            kind = ('body',)
        parts.append({'idx': idx, 'kind': kind, 'lo': lo, 'hi': hi, 'mid': mid})
    return V, parts


def straighten_tails(V, parts):
    """Fix 5: level the wave across the strap tail under each thumb-side buckle (in place)."""
    report = {}
    for strap in (0, 1):
        webbing = max((p for p in parts if p['kind'] == ('buckle', strap, 'thumb')), key=lambda p: len(p['idx']))
        tail = [i for i in webbing['idx'] if V[i].z < webbing['lo'][2] + TAIL_CM]

        def clusters(values, gap):
            groups, last = [], None
            for v in sorted(set(round(x, 3) for x in values)):
                if last is None or v - last > gap:
                    groups.append([])
                groups[-1].append(v)
                last = v
            centres = [sum(grp) / len(grp) for grp in groups]
            return lambda x: min(range(len(centres)), key=lambda j: abs(centres[j] - x))
        column, row = clusters([V[i].x for i in tail], 0.08), clusters([V[i].z for i in tail], 0.05)
        cells = {}
        for i in tail:
            cells.setdefault((row(V[i].z), column(V[i].x)), []).append(i)
        worst = 0.0
        for r in {k[0] for k in cells}:
            means = {k[1]: sum(V[i].y for i in cells[k]) / len(cells[k]) for k in cells if k[0] == r}
            level = sorted(means.values())[len(means) // 2]
            for col, mean in means.items():
                for i in cells[(r, col)]:
                    V[i].y -= mean - level
                worst = max(worst, abs(mean - level))
        report['rear' if strap == 0 else 'front'] = {'vertices': len(tail), 'largest_wave_cm': round(worst, 3)}
    return report


def main(revision, base, analyse=False):
    import bpy
    import numpy as np
    from mathutils import Matrix, Vector
    source = ART / base / 'runtime'
    out = ART / revision / 'runtime'
    if (out / 'watch-move.json').exists():
        raise RuntimeError('This candidate already has the watch moved; preserve it and start a new revision.')
    bpy.context.scene.unit_settings.system = 'METRIC'
    bpy.context.scene.unit_settings.scale_length = 0.01
    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    shells_of = runpy.run_path(str(ROOT / 'tools/trim_hand_forearms.py'), run_name='asset_source')['shells']
    seat = runpy.run_path(str(ROOT / 'tools/seat_watch_keepers.py'), run_name='asset_source')
    chunks = g['read_psk'](source / 'VRFloatingHands.psk')
    arm = left_arm(chunks, g, shells_of)
    c, a, along = arm['c'], arm['a'], arm['along']
    watch = seat['load_watch'](source / 'VRWristwatch.fbx')
    me = watch.data
    V, parts = watch_parts(me)
    kinds = {}
    for p in parts:
        kinds[p['kind'][0]] = kinds.get(p['kind'][0], 0) + 1
    tails = straighten_tails(V, parts)
    old_skin = surface(arm, arm['local'], 'skin_faces')
    glove = surface(arm, arm['local'], 'glove_faces')

    def radial(q):
        r = (q - c) - a * (q - c).dot(a)
        return r.length, r.normalized()

    def height(tree, s, e, fallback=None, outer=False):
        """How far from the arm's axis the surface lies at `s` along it, in direction `e` (the outermost layer if asked)."""
        origin, far = c + a * s, None
        start = origin
        for _ in range(8 if outer else 1):
            hit = tree.ray_cast(start, e)
            if hit[0] is None:
                break
            far = (hit[0] - origin).dot(e)
            start = hit[0] + e * 1e-3
        return far if far is not None else fallback

    def clearance(tree, q, outer=False):
        r, e = radial(q)
        h = height(tree, along(q), e, None, outer)
        return None if h is None else r - h

    body = [i for p in parts if p['kind'][0] == 'body' for i in p['idx']]
    # The back of the arm under the case: how far it lies from the axis before and after the move.
    back = [i for i in body if V[i].z < 3.2]
    covered = set()
    for p in arm['skin']:
        if p in arm['end_points']:
            continue
        r, e = radial(arm['local'][p])
        top = height(old_skin, along(arm['local'][p]), e, r, True)
        if top - r > 0.05:
            covered.add(p)
    arm['covered'] = covered

    def body_move(move):
        new_local, info = stretched(arm, move)
        new_skin = surface(arm, new_local, 'skin_faces')
        rise = []
        for i in back[::7]:
            r, e = radial(V[i])
            if e.z < 0.8:
                continue
            h0, h1 = height(old_skin, along(V[i]), e), height(new_skin, along(V[i]) - move, e)
            if h0 is not None and h1 is not None:
                rise.append(h1 - h0)
        lift = float(np.median(rise)) if rise else 0.0
        dorsal = (Vector((0, 0, 1)) - a * a.z).normalized()
        m = -a * move + dorsal * lift
        return Vector((m.x, 0.0, m.z)), new_local, new_skin, info, lift

    if analyse:
        rows = []
        for move in (0.0, 2.0, 2.25, 2.5, 2.75, 3.0, 3.5):
            m, new_local, new_skin, info, lift = body_move(move) if move else (Vector((0, 0, 0)), arm['local'], old_skin, {}, 0.0)
            in_glove = [-(clearance(glove, V[i] + m, True) or 0) for i in body[::3]]
            in_skin = [-(clearance(new_skin, V[i] + m) or 0) for i in body[::3]]
            rows.append({'move': move, 'lift': round(lift, 3), 'body_into_glove_cm': round(max(in_glove), 3),
                         'body_into_bracer_cm': round(max(in_skin), 3),
                         'vertices_in_glove': sum(1 for d in in_glove if d > 0.02), 'vertices_in_bracer': sum(1 for d in in_skin if d > 0.02)})
        listing = [[p['kind'], len(p['idx']), [round(float(x), 2) for x in p['lo']], [round(float(x), 2) for x in p['hi']]]
                   for p in parts if p['kind'][0] != 'body' or p['lo'][2] < 2.5]
        return {'listing': listing, 'parts': kinds, 'hem_along_cm': arm['hem_s'], 'case_front_along_cm': max(along(V[i]) for i in body), 'rows': rows}

    out.mkdir(parents=True, exist_ok=True)
    for p in source.iterdir():
        if p.is_file() and p.suffix.lower() in {'.tga', '.png'}:
            shutil.copy2(p, out / p.name)
    m, new_local, new_skin, info, lift = body_move(MOVE_CM)
    report = {'base_revision': base, 'base_sha256': {n: digest(source / n) for n in ('VRFloatingHands.psk', 'VRWristwatch.fbx')},
              'move_cm': MOVE_CM, 'watch_parts': kinds, **info, 'bracer_points_under_a_fold': len(covered),
              'back_of_arm_rise_cm': lift,
              'body_move_hand_frame_cm': [round(x, 4) for x in m]}

    # ---- Watch ----
    step = (m.dot(a))            # how far along the arm the body goes (negative: toward the elbow)
    moved = {}
    for i in body:
        moved[i] = V[i] + m
    for p in parts:
        if p['kind'][0] in ('ring', 'saddle'):
            for i in p['idx']:
                r, e = radial(V[i])
                s = along(V[i])
                here = height(old_skin, s, e, r)
                there = height(new_skin, s + step, e, here)
                moved[i] = c + a * (s + step) + e * (there + (r - here))
    assemblies = {}
    for p in parts:
        if p['kind'][0] == 'buckle':
            assemblies.setdefault(p['kind'][1:], []).extend(p['idx'])
    buckles = {}
    for name, idx in assemblies.items():
        mid = sum((V[i] for i in idx), Vector()) / len(idx)
        r, e = radial(mid)
        s = along(mid)
        here = height(old_skin, s, e, r)
        shift = a * step + e * (height(new_skin, s + step, e, here) - here)
        for i in idx:
            moved[i] = V[i] + shift
        buckles['%s strap, %s' % ('rear' if name[0] == 0 else 'front', name[1])] = [round(x, 3) for x in shift]
    cables = {}
    for which in (0, 1):
        idx = [i for p in parts if p['kind'] == ('cable', which) for i in p['idx']]
        if not idx:
            continue
        top, bottom = max(V[i].z for i in idx), min(V[i].z for i in idx)
        low = [i for p in parts if p['kind'] == ('cable', which) and p['mid'][2] < (top + bottom) / 2 and p['hi'][2] - p['lo'][2] < 1.2
               for i in p['idx']]
        # Where it leaves the case the cable goes with the case; toward its plug it keeps the clearance it had
        # from the arm, as the straps do. The plug ended inside the leather: the lower cable comes out by
        # that much so the plug rests on it.
        placed = {}
        for i in idx:
            w = max(0.0, min(1.0, (top - V[i].z) / max(1e-6, top - bottom - 0.6)))
            w = w * w * (3 - 2 * w)
            r, e = radial(V[i])
            s_ = along(V[i])
            here = height(old_skin, s_, e, r)
            there = height(new_skin, s_ + step, e, here)
            fitted = c + a * (s_ + step) + e * (there + (r - here))
            placed[i] = ((V[i] + m).lerp(fitted, w), w)
        sunk = min((clearance(new_skin, placed[i][0]) or REST_CM) for i in low) if low else REST_CM
        need = REST_CM - sunk
        worst = 0.0
        for i in idx:
            q, w = placed[i]
            _, e = radial(q)
            q = q + e * (need * w)
            gap = clearance(new_skin, q)
            if gap is not None and gap < REST_CM:
                worst = max(worst, REST_CM - gap)
                q = q + e * (REST_CM - gap)
            moved[i] = q
        cables['rear' if which == 0 else 'front'] = {'plug_was_in_leather_cm': round(-sunk, 3), 'plug_brought_out_cm': round(need, 3),
                                                      'largest_extra_push_cm': round(worst, 3)}
    missing = [i for i in range(len(V)) if i not in moved]
    if missing:
        raise RuntimeError(f'{len(missing)} watch vertices were not placed')
    report.update({'buckle_moves_cm': buckles, 'cables': cables, 'strap_tails': tails})

    # The mesh keeps its frame at the screen: positions go back by the body's move, the frame's offsets carry it.
    normals = [n.vector.copy() for n in me.corner_normals]
    for v in me.vertices:
        v.co = moved[v.index]
    me.update()
    for p in me.polygons:
        p.use_smooth = True
    me.normals_split_custom_set(normals)
    old_frame = Matrix(seat['EXPORT_FRAME'])
    new_frame = old_frame @ Matrix.Translation(-m)
    seat['export'].__globals__['EXPORT_FRAME'] = tuple(tuple(row) for row in new_frame)
    seat['export'](watch, out / 'VRWristwatch.fbx')
    check = seat['roundtrip'](watch, out / 'VRWristwatch.fbx')
    (out / 'fbx-roundtrip.json').write_text(json.dumps(check, indent=2))
    report['watch_roundtrip'] = check
    report['export_frame'] = [[round(x, 4) for x in row] for row in new_frame]
    report['script_offsets_cm'] = {'toward_elbow_along_Fwd': round(-new_frame[1][3], 4), 'dorsal_along_minus_Plm': round(new_frame[0][3], 4)}

    # ---- Hands ----
    rows = list(chunks['PNTS0000'].rows)
    changed = 0
    back_to_world = arm['frame'].transposed()
    for p, q in new_local.items():
        if (q - arm['local'][p]).length > 1e-7:
            rows[p] = struct.pack('<3f', *(back_to_world @ q + arm['origin']))
            changed += 1
    chunks['PNTS0000'].rows = rows
    psk = out / 'VRFloatingHands.psk'
    psk.write_bytes(b''.join(ch.encode() for ch in chunks.values()))
    g['decode_geometry'](g['read_psk'](psk))
    export = g['export_fbx'](psk, out / 'VRFloatingHands.fbx')
    # What still stands into what, for the record.
    in_glove = [-(clearance(glove, moved[i], True) or 0) for i in body[::3]]
    in_skin = [-(clearance(new_skin, moved[i]) or 0) for i in body[::3]]
    report.update({'hand_points_moved': changed, 'body_into_glove_cm': round(max(in_glove), 3),
                   'body_into_bracer_cm': round(max(in_skin), 3), 'psk_sha256': digest(psk),
                   'fbx_sha256': digest(out / 'VRFloatingHands.fbx'), 'watch_sha256': digest(out / 'VRWristwatch.fbx'),
                   'generator_sha256': digest(Path(__file__)), **export})
    (out / 'watch-move.json').write_text(json.dumps(report, indent=2))
    return report


def paint(revision):
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
    runtime = ART / revision / 'runtime'
    report_path = runtime / 'watch-move-paint.json'
    if report_path.exists():
        raise RuntimeError('This candidate already has its mark moved; preserve it and start a new revision.')
    built = json.loads((runtime / 'watch-move.json').read_text())
    if built['psk_sha256'] != digest(runtime / 'VRFloatingHands.psk'):
        raise SystemExit('watch-move.json does not describe this PSK.')
    detail = runpy.run_path(str(ROOT / 'tools/detail_hand_surfaces.py'), run_name='asset_source')
    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    names = ('VRHorzineHands_D.tga', 'VRHorzineHands_S.tga', 'VRHorzineHands_N.tga')
    report = {'base_sha256': {n: digest(runtime / n) for n in names}}
    maps = {'D': Image.open(runtime / names[0]).convert('RGB'), 'S': Image.open(runtime / names[1]).convert('RGBA'),
            'N': Image.open(runtime / names[2]).convert('RGB')}
    # Blend the old mark out with the plain leather beside it.
    pad = 3 * MARK_FEATHER
    box = (MARK_BOX[0] - pad, MARK_BOX[1] - pad, MARK_BOX[2] + pad, MARK_BOX[3] + pad)
    fade = Image.new('L', (box[2] - box[0], box[3] - box[1]), 0)
    ImageDraw.Draw(fade).rectangle([pad - 4, pad - 4, fade.width - pad + 4, fade.height - pad + 4], fill=255)
    fade = fade.filter(ImageFilter.GaussianBlur(MARK_FEATHER / 2))
    plain = tuple(v + MARK_PLAIN_SHIFT[i % 2] for i, v in enumerate(box))
    for im in maps.values():
        piece = im.crop(box)
        piece.paste(im.crop(plain), (0, 0), fade)
        im.paste(piece, box[:2])
    # Press it again where the straps now leave room.
    chunks = g['read_psk'](runtime / 'VRFloatingHands.psk')
    points, wedges, faces, _ = g['decode_geometry'](chunks)
    P = np.array(points)
    wedge_point = np.array([w[0] for w in wedges])
    uv = np.array([(w[1], w[2]) for w in wedges]) * SIZE
    F = np.array([f[:3] for f in faces])
    D = np.asarray(maps['D']).astype(np.float32)
    SA = np.asarray(maps['S']).astype(np.float32)
    N = np.asarray(maps['N']).astype(np.float32)
    T = np.asarray(Image.open(runtime / 'VRHorzineHands_T.tga').convert('L').resize((SIZE, SIZE), Image.BILINEAR)) > 128
    thread = ~T & (D[..., 0] > 90) & (D[..., 0] - D[..., 2] > 20)
    leather = ~T & ~thread & (D.mean(-1) >= 18)
    step = built['body_move_hand_frame_cm'][0]
    old = detail['MARK_CENTRE']
    # Midway between the straps, as before; the arm is thicker there, so the point goes out with it.
    grow = 1.0 + 0.045 * abs(step)
    centre = (old[0] + step, old[1] * grow, old[2] * grow)
    pressed, mark_faces = detail['wordmark_pressed'](np, Image, ImageFilter, runtime, chunks, P, wedge_point, uv, F, leather,
                                                     centre, MARK_WIDTH_CM)
    spec, gloss = SA[..., 0].copy(), SA[..., 3].copy()
    D, spec, gloss, N = detail['press'](np, D, spec, gloss, N, pressed)
    Image.fromarray(D.clip(0, 255).astype(np.uint8)).save(runtime / names[0])
    Image.fromarray(np.dstack([spec, spec, spec, gloss]).clip(0, 255).astype(np.uint8), 'RGBA').save(runtime / names[1])
    Image.fromarray(N.clip(0, 255).astype(np.uint8)).save(runtime / names[2])
    ys, xs = np.nonzero(pressed > 0.3)
    report.update({'old_mark_box': list(MARK_BOX), 'mark_centre_hand_frame_cm': [round(v, 3) for v in centre],
                   'wordmark': {'texels': int((pressed > 0.3).sum()), 'faces': mark_faces,
                                'atlas_box': [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]},
                   'maps_sha256': {n: digest(runtime / n) for n in names}})
    report_path.write_text(json.dumps(report, indent=1))
    return report


if __name__ == '__main__':
    if sys.argv[1:2] == ['--paint']:
        print('WATCH_MOVE_PAINTED', json.dumps(paint(sys.argv[2])), flush=True)
    else:
        args = sys.argv[sys.argv.index('--') + 1:]
        print('WATCH_MOVED', json.dumps(main(args[0], args[args.index('--base') + 1], '--analyse' in args)), flush=True)
