"""The right arm's end: tidied inside the glove's hem, or a short leather cuff (Blender).

What ships is --tidy-end (Kvasir94, 2026-11-11: "C-c, just clean up the end"). The
right arm's skin was cut on a plane square to the arm, 0.35 cm inside the
middle of the glove's hem. The hem is not square to the arm, so on one side the
dark inner end stood up to a centimetre proud of it. --tidy-end follows the hem
itself: the arm is cut on a plane just inside the hem's deepest point, then the
cut edge is drawn out along the arm, angle by angle, until it sits TIDY_TUCK_CM
inside the hem all the way round, with the same rolled edge, lining and end
plate as before. Skin the old cut removed is taken from the left arm, mirrored.

Without --tidy-end it builds the cuff Kvasir94 first picked (R-b) and then
dropped, because it runs into straight stocks (issue #236). That path is kept
for the record. The right arm stopped at the glove's own cuff while the left
carried a bracer and the watch, so the arms did not read as a pair. The cuff
gives the right about CUFF_CM of the same leather past the glove:

- The left bracer is the left hand's skin shell painted as leather, and the two
  hands are mirror images that share one texture layout. So the cuff is the
  stretch of the left bracer from just inside the glove cuff to CUFF_CM past
  it, cut on two planes, mirrored into the right hand's frame. It needs no new
  texels: it shows the leather the left bracer already has there.
- Its open end gets the same finish `build_forearm_bracer.py` gives the left:
  a slightly raised hem, a rolled edge, a lining that follows the arm's taper
  and a recessed end plate, mapped to the three end blocks both arms share.
- The right arm's old end (roll, lining and plate just inside the glove cuff)
  is removed; the cuff starts TUCK_CM deeper than that end did, under the glove.

- One strap with its two buckles, to match the left arm's: the watch's front
  strap (webbing ring, thumb-side buckle, underside buckle) is taken from the
  watch mesh, slid STRAP_BEHIND_RIM_CM behind the glove rim and refitted to the
  arm there (the webbing vertex by vertex, each buckle part as a rigid piece),
  then mirrored like the cuff. It becomes part of the hand mesh, so it needs
  no script: its texels are copied from the watch's maps into free space in
  the hands' atlas at STRAP_TEXEL_SCALE by the paint step.

  On the left the webbing crosses the back of the arm under the watch's
  saddle, held clear of the leather; here that stretch is pressed down onto
  the cuff. The webbing under the two buckles is left as it was seated.
- The left bracer carries a pressed HORZINE mark that the mirrored cuff would
  show cut off and backwards. The cuff faces over it are given their own
  texels: a copy of that leather with the mark blended out.

New points are weighted to the right hand bone, like the left bracer's are to
the left. Nothing else in the mesh changes: other faces keep their rows.

    blender --background --python tools/build_right_cuff.py -- <revision> --tidy-end
    blender --background --python tools/build_right_cuff.py -- <revision> [--stock-side-cm N] [--no-strap]
    python tools/build_right_cuff.py --paint <revision>

The first (it needs the PSK add-on, so no --factory-startup) reads the staged
set in build/hand-meshes and writes the candidate to
build/watch-detail-20260924/<revision>/runtime (PSK, FBX and right-cuff.json).
The second paints that candidate's hand maps: leather over the sliver of arm the
tidied end can show inside the hem, or, for the cuff, the strap's texels.
"""
import hashlib, json, math, runpy, shutil, struct, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'build/watch-detail-20260924'
STAGED = ROOT / 'build/hand-meshes'
CUFF_CM = 5.0            # leather past the glove's cuff rim
# A straight stock lies along the thumb-and-palm side of the firing wrist. With --stock-side-cm the cuff's end is
# cut on a slant: CUFF_CM long on the far side, that many cm on the stock's side. STOCK_SIDE is that side in the
# left hand's frame (fingers +X, thumb -Y, back of hand +Z); the mirror keeps it on the right arm's thumb side.
STOCK_SIDE = (0.0, -1.0, -1.0)
TUCK_CM = 0.15           # how much deeper under the glove the cuff starts than the old end did
RIM_FAIR_CM = 1.0
END = {'roll': 0.26, 'depth': 1.8, 'swell': 0.05, 'hem': 0.6}
TIDY_END = {'roll': 0.22, 'depth': 1.6, 'swell': 0.0, 'hem': 0.0}     # the right end's finish since revision 71
TIDY_TUCK_CM = 0.3       # how far inside the glove's hem the tidied end sits
TIDY_BLEND_CM = 1.6      # the stretch of arm behind the end that is drawn out with it
# End-part texel blocks in the 4096 atlas (x, y, w, h), as build_forearm_bracer.py placed them.
BLOCKS = {'roll': (2704, 2848, 64, 48), 'lining': (2784, 2848, 64, 192), 'plate': (2864, 2848, 176, 176)}
KINDS = (None, 'roll', 'lining', 'plate')
SIZE = 4096
STRAP_BEHIND_RIM_CM = 2.3        # the strap's centre line, measured back from the glove's cuff rim
STRAP_X = (-2.15, 0.2)           # hand-frame span (cm) that holds the watch's front strap and its buckles
STRAP_TEXEL_SCALE = 0.5          # watch atlas texels to hand atlas texels
CELL, STRAP_PAD = 16, 6          # packing grid and the gutter kept round each copied island (hand atlas px)
STRAP_GLOSS = {'metal': 78, 'soft': 14}   # specular-alpha gloss for the gloss-mapped hand material
STRAP_BINS, STRAP_SLACK_CM = 72, 0.03    # angular steps round the arm; lift above the seated level that is left alone
# The HORZINE mark pressed into the left bracer (detail_hand_surfaces.py's reported atlas box, x0 y0 x1 y1).
# The right cuff shows the same texels mirrored, so its faces there get a copy of the leather without the mark.
MARK_BOX = (2084, 3135, 2156, 3402)
MARK_PLAIN_SHIFT = (-95, 0)      # where, from the mark, the same leather island is plain
MARK_FEATHER = 10


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def block_kind(uvs):
    """Which end block a face's three UVs sit in, if any."""
    for name, (x, y, w, h) in BLOCKS.items():
        if all(x - 1 <= u * SIZE <= x + w + 1 and y - 1 <= v * SIZE <= y + h + 1 for u, v in uvs):
            return name
    return None


def build(chunks, g, shells_of, stock_side_cm=None, tidy=False):
    import bmesh
    import numpy as np
    from mathutils import Matrix, Vector
    from mathutils.bvhtree import BVHTree
    points, wedges, faces, weights = g['decode_geometry'](chunks)
    bones, names = g['bone_data'](chunks)
    bind = g['bind_positions'](bones)
    shell = shells_of(points, wedges, faces)
    B = {n: bind[i] for i, n in enumerate(names)}

    def side_frame(side):
        o = B[side + 'Hand_1stP']
        f = (B[side + 'HandMiddle1_1stP'] - o).normalized()
        t = B[side + 'HandIndex1_1stP'] - B[side + 'HandPinky1_1stP']
        t = (t - f * t.dot(f)).normalized()
        return o, Matrix((f, -t, -f.cross(t).normalized()))
    oL, FL = side_frame('Left')
    oR, FR = side_frame('Right')
    to_left = lambda p: FL @ (Vector(p) - oL)
    # The right hand is the left one mirrored across the hand plane: same frame rows, third axis flipped.
    from_mirror = lambda q: FR.transposed() @ Vector((q.x, q.y, -q.z)) + oR
    to_mirror = lambda p: (lambda r: Vector((r.x, r.y, -r.z)))(FR @ (Vector(p) - oR))

    side_of = [''] * len(points)
    for p, w in enumerate(weights):
        n = names[max(w, key=w.get)]
        side_of[p] = 'Left' if n.startswith('Left') else ('Right' if n.startswith('Right') else '')
    kind_of = [block_kind([(wedges[w][1], wedges[w][2]) for w in f[:3]]) for f in faces]
    face_side = [side_of[wedges[f[0]][0]] for f in faces]

    members = {}
    for p in range(len(points)):
        if side_of[p] == 'Left':
            members.setdefault(shell[p], []).append(p)
    skin = max((s for s in members if min(to_left(points[p]).x for p in members[s]) < -5), key=lambda s: len(members[s]))
    glove = max((s for s in members if s != skin), key=lambda s: len(members[s]))
    skin_faces = [i for i, f in enumerate(faces) if shell[wedges[f[0]][0]] == skin and kind_of[i] is None]
    local = {}
    for i in skin_faces:
        for w in faces[i][:3]:
            p = wedges[w][0]
            if p not in local:
                local[p] = to_left(points[p])

    # Arm centre line through the cuff's stretch of forearm.
    rings = {}
    for q in local.values():
        if -7.0 < q.x < 1.5:
            rings.setdefault(round(q.x), []).append(q)
    cents = [sum(r, Vector()) / len(r) for _, r in sorted(rings.items()) if len(r) >= 8]
    c = sum(cents, Vector()) / len(cents)
    a = Vector(np.linalg.svd(np.array([tuple(q - c) for q in cents]))[2][0])
    a = (a if a.x > 0 else -a).normalized()
    along = lambda q: (q - c).dot(a)
    ref = Vector((0, 0, 1)) - a * a.z
    ref.normalize()
    side_ref = a.cross(ref)

    def theta(q):
        r = q - c
        r -= a * r.dot(a)
        return (math.atan2(r.dot(side_ref), r.dot(ref)) / (2 * math.pi)) % 1.0
    rim = {}
    for p in members[glove]:
        q = to_left(points[p])
        k = int(theta(q) * 24)
        rim[k] = min(rim.get(k, math.inf), along(q))
    rim_s = sorted(rim.values())[len(rim) // 2]
    # Where the right arm's old end was cut, read from its roll (its first ring lies in the cut plane).
    old_end = [i for i, f in enumerate(faces) if face_side[i] == 'Right' and kind_of[i]]
    old_roll = [along(to_mirror(points[wedges[w][0]])) for i in old_end if kind_of[i] == 'roll' for w in faces[i][:3]]
    if not old_roll:
        raise RuntimeError('The right arm has no end blocks to replace; is this mesh already cuffed?')
    old_cut = max(old_roll)
    s_new, s_in = rim_s - CUFF_CM, old_cut + TUCK_CM
    # The end plane: square to the arm, or slanted so the stock's side is shorter. cut_at(q) is where the
    # plane crosses the line through q along the arm.
    slope, lean = 0.0, Vector((0, 0, 0))
    if stock_side_cm is not None:
        lean = Vector(STOCK_SIDE) - a * Vector(STOCK_SIDE).dot(a)
        lean.normalize()
        reach = [abs((q - c).dot(lean)) for q in local.values() if abs(along(q) - (rim_s - CUFF_CM / 2)) < 1.5]
        half_width = sorted(reach)[int(len(reach) * 0.9)]
        slope = (CUFF_CM - stock_side_cm) / (2 * half_width)
        s_new = rim_s - (CUFF_CM + stock_side_cm) / 2
    end = TIDY_END if tidy else END
    hem_fit = None
    if tidy:
        # The glove's hem, one point per angle, and the plane through it: along = s0 + gu * u + gv * v.
        hem = {}
        for p in members[glove]:
            q = to_left(points[p])
            k = int(theta(q) * 48)
            if k not in hem or along(q) < along(hem[k]):
                hem[k] = q
        rows_ = np.array([[1.0, (q - c).dot(ref), (q - c).dot(side_ref)] for q in hem.values()])
        height = np.array([along(q) for q in hem.values()])
        s0, gu, gv = np.linalg.lstsq(rows_, height, rcond=None)[0]
        proud = float((height - rows_ @ np.array([s0, gu, gv])).max())     # how far the hem dips inside the plane
        grad = ref * gu + side_ref * gv
        slope, lean = grad.length, grad.normalized()
        s_new = s0 + proud + TIDY_TUCK_CM
        hem_fit = {'hem_points': len(hem), 'hem_slope': slope, 'hem_dips_inside_plane_cm': proud}
        # The hem's own line round the arm: never outside the hem (largest of each bin and its neighbours), smoothed.
        line = [along(hem[k]) if k in hem else None for k in range(48)]
        line = [v if v is not None else next(line[(k + j) % 48] for j in range(1, 48) if line[(k + j) % 48] is not None)
                for k, v in enumerate(line)]
        line = [max(line[(k + j) % 48] for j in (-1, 0, 1)) for k in range(48)]
        for _ in range(2):
            line = [(line[k - 1] + 2 * line[k] + line[(k + 1) % 48]) / 4 for k in range(48)]
        reach = max(abs((q - c).dot(lean)) for q in hem.values())
        s_in = max(s_in, s_new + slope * reach + 0.6)
    cut_at = lambda q: s_new + slope * (q - c).dot(lean)
    cut_normal = (a - lean * slope).normalized()

    bm = bmesh.new()
    uvl = bm.loops.layers.uv.new('UV')
    kind_layer = bm.faces.layers.int.new('cuff_part')
    vert = {p: bm.verts.new(q) for p, q in local.items()}
    for i in skin_faces:
        f = faces[i]
        corners = [f[2], f[1], f[0]]            # Blender winding = reversed ActorX
        try:
            bf = bm.faces.new([vert[wedges[w][0]] for w in corners])
        except ValueError:
            continue
        for loop, w in zip(bf.loops, corners):
            loop[uvl].uv = (wedges[w][1], wedges[w][2])
    everything = lambda: bm.verts[:] + bm.edges[:] + bm.faces[:]
    whole = BVHTree.FromBMesh(bm)          # the uncut arm, to keep moved points on its surface
    bmesh.ops.bisect_plane(bm, geom=everything(), dist=1e-5, plane_co=c + a * s_new, plane_no=cut_normal, clear_inner=True)
    bmesh.ops.bisect_plane(bm, geom=everything(), dist=1e-5, plane_co=c + a * s_in, plane_no=a, clear_outer=True)
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context='VERTS')
    tube_faces = len(bm.faces)
    ring_edges = [e for e in bm.edges if e.is_boundary and all(abs(along(v.co) - cut_at(v.co)) < 1e-3 for v in e.verts)]
    nxt = {}
    for e in ring_edges:
        v0, v1 = e.verts
        nxt.setdefault(v0, []).append(v1)
        nxt.setdefault(v1, []).append(v0)
    ring, prev = [ring_edges[0].verts[0]], None
    while True:
        options = [v for v in nxt[ring[-1]] if v is not prev]
        if not options or options[0] is ring[0]:
            break
        prev = ring[-1]
        ring.append(options[0])
    if len(ring) != len(ring_edges):
        raise RuntimeError(f'The cuff end is not a single loop ({len(ring)} of {len(ring_edges)})')
    if (theta(ring[1].co) - theta(ring[0].co)) % 1.0 > 0.5:
        ring.reverse()

    if tidy:
        def hem_line(q):
            x = theta(q) * 48 - 0.5
            k = math.floor(x)
            t = x - k
            return line[k % 48] * (1 - t) + line[(k + 1) % 48] * t + TIDY_TUCK_CM
        drawn = 0.0
        for v in bm.verts:
            ds = along(v.co) - cut_at(v.co)
            if ds < TIDY_BLEND_CM:
                w = 1 - max(0.0, ds) / TIDY_BLEND_CM
                move = (hem_line(v.co) - cut_at(v.co)) * w * w * (3 - 2 * w)
                r = (v.co - c) - a * (v.co - c).dot(a)
                e = r.normalized()
                s_to = along(v.co) + move
                hit = whole.ray_cast(c + a * s_to, e)
                v.co = c + a * s_to + e * ((hit[0] - (c + a * s_to)).dot(e) if hit[0] is not None else r.length)
                drawn = max(drawn, abs(move))
        hem_fit['largest_draw_cm'] = drawn
        cut_at = hem_line
    # From here the end is built as build_forearm_bracer.py builds the left one.
    for v in bm.verts:
        ds = along(v.co) - cut_at(v.co)
        if ds < end['hem']:
            r = v.co - c
            r -= a * r.dot(a)
            v.co += r.normalized() * end['swell'] * max(0.0, min(1.0, (end['hem'] - ds) / 0.25))
    centre = c + a * s_new
    radial = lambda p: (p - c) - a * (p - c).dot(a)
    rad = [radial(v.co).length for v in ring]
    smooth = rad
    for _ in range(3):
        smooth = [sum(smooth[(k + j) % len(rad)] for j in range(-4, 5)) / 9 for k in range(len(rad))]
    ring_theta = [theta(v.co) for v in ring]
    for v in bm.verts:
        ds = along(v.co) - cut_at(v.co)
        if ds < RIM_FAIR_CM:
            tv = theta(v.co)
            k = min(range(len(ring)), key=lambda i: min(abs(ring_theta[i] - tv), 1 - abs(ring_theta[i] - tv)))
            w = 1 - ds / RIM_FAIR_CM
            v.co += radial(v.co).normalized() * (smooth[k] - rad[k]) * w * w * (3 - 2 * w)
    t_wall = end['roll']
    r_roll = t_wall / 2
    profile = [(-r_roll * math.sin(j * math.pi / 4), -r_roll * (1 - math.cos(j * math.pi / 4))) for j in range(1, 5)]
    depth = end['depth']
    lining = [(0.35, t_wall + 0.03), (depth * 0.55, t_wall + 0.08), (depth, t_wall + 0.14)]
    base = [(v.co.copy(), ((v.co - centre) - a * (v.co - centre).dot(a)).normalized()) for v in ring]
    tree = BVHTree.FromBMesh(bm)

    def skin_radius(along_cm, e, fallback):
        origin = c + a * along_cm
        hit = tree.ray_cast(origin, e)
        return (hit[0] - origin).dot(e) if hit[0] is not None else fallback
    rows = [ring]
    for da, dr in profile:
        rows.append([bm.verts.new(q + a * da + e * dr) for q, e in base])
    # The rim may wave round the arm (it follows the glove's hem); the lining evens that out with depth so
    # the end plate is flat.
    floor = max(along(q) for q, _ in base) + depth
    for step, (da, inset) in enumerate(lining):
        row = []
        level = (step / (len(lining) - 1)) ** 2
        for q, e in base:
            r0 = (q - centre).dot(e)
            deep = (along(q) + da) * (1 - level) + floor * level
            row.append(bm.verts.new(c + a * deep + e * (min(r0, skin_radius(deep, e, r0)) - inset)))
        rows.append(row)
    plate_ring = [bm.verts.new(v.co) for v in rows[-1]]
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
            u0, u1 = k / n, (k + 1) / n
            add_face([r0[k], r0[k1], r1[k1], r1[k]], [(u0, v0), (u1, v0), (u1, v1), (u0, v1)], kind, want(k))
    for j in range(4):
        strip(rows[j], rows[j + 1], 'roll', j / 4, (j + 1) / 4,
              lambda k, j=j: (rows[j][k].co + rows[j + 1][k].co) / 2 - roll_mid[k])
    dsum = [0.0]
    for j in range(4, 4 + len(lining)):
        dsum.append(dsum[-1] + (rows[j + 1][0].co - rows[j][0].co).length)
    for j in range(4, 4 + len(lining)):
        strip(rows[j], rows[j + 1], 'lining', dsum[j - 4] / dsum[-1], dsum[j - 3] / dsum[-1], lambda k: -base[k][1])
    radius = max((v.co - plate_centre.co).length for v in plate_ring)

    def plate_uv(v):
        r = v.co - plate_centre.co
        r -= a * r.dot(a)
        return (0.5 + 0.5 * r.dot(ref) / radius, 0.5 + 0.5 * r.dot(side_ref) / radius)
    for k in range(n):
        tri = [plate_ring[k], plate_ring[(k + 1) % n], plate_centre]
        add_face(tri, [plate_uv(v) for v in tri], 'plate', -a)

    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bm.verts.index_update()
    new_points = [from_mirror(v.co) for v in bm.verts]
    new_faces, marked, under_glove = [], [], []
    for bf in bm.faces:
        kind = KINDS[bf[kind_layer]]
        corners = []
        # Mirroring turns the winding over once and Blender-to-ActorX turns it back: loop order as it stands.
        for loop in bf.loops:
            u, v = loop[uvl].uv
            if kind:
                bx, by, bw, bh = BLOCKS[kind]
                u, v = (bx + u * bw) / SIZE, (by + v * bh) / SIZE
            corners.append((loop.vert.index, u, v))
        if not kind and tidy:
            under_glove.append([[round(u * SIZE, 2), round(v * SIZE, 2)] for _, u, v in corners])
        if not kind:
            us, vs = [u * SIZE for _, u, _ in corners], [v * SIZE for _, _, v in corners]
            if max(us) > MARK_BOX[0] - 4 and min(us) < MARK_BOX[2] + 4 and max(vs) > MARK_BOX[1] - 4 and min(vs) < MARK_BOX[3] + 4:
                marked.append(len(new_faces))
        new_faces.append(corners)
    # The mirrored cuff must face outward the way the right hand's own skin does.
    outward = 0
    for corners in new_faces[:tube_faces]:
        p0, p1, p2 = (new_points[i] for i, _, _ in corners)
        centre_r = from_mirror(c + a * along(to_mirror((p0 + p1 + p2) / 3)))
        outward += 1 if (p1 - p0).cross(p2 - p0).dot((p0 + p1 + p2) / 3 - centre_r) > 0 else -1
    reference, right_skin = 0, shell[wedges[faces[old_end[0]][0]][0]]
    for i, f in enumerate(faces):
        if kind_of[i] is None and shell[wedges[f[0]][0]] == right_skin:
            p0, p1, p2 = (Vector(points[wedges[w][0]]) for w in f[:3])
            mid = (p0 + p1 + p2) / 3
            q = to_mirror(mid)
            if not (old_cut < along(q) < old_cut + 2.0):
                continue
            reference += 1 if (p1 - p0).cross(p2 - p0).dot(mid - from_mirror(c + a * along(q))) > 0 else -1
    if reference and (outward > 0) != (reference > 0):
        raise RuntimeError(f'The mirrored cuff faces the wrong way (cuff {outward}, right skin {reference})')
    report = {'frame_left_origin': list(oL), 'axis_point': list(c), 'axis_dir': list(a),
              'glove_rim_along_cm': rim_s, 'old_right_end_along_cm': old_cut, 'cuff_end_along_cm': s_new,
              'cuff_start_along_cm': s_in, 'stock_side_cm': stock_side_cm, 'end_slope': slope,
              'ring_vertices': n, 'plate_radius_cm': radius,
              'winding_votes': {'cuff': outward, 'right_skin': reference}, 'tidy': hem_fit, **end}
    # The right arm's own skin behind the new start is replaced by the mirrored piece.
    stale = []
    for i, f in enumerate(faces):
        if kind_of[i] is None and shell[wedges[f[0]][0]] == right_skin:
            mid = sum((to_mirror(points[wedges[w][0]]) for w in f[:3]), Vector()) / 3
            if along(mid) < s_in:
                stale.append(i)
    old_end = old_end + stale
    report['right_skin_triangles_replaced'] = len(stale)
    bm.free()
    fit = {'c': c, 'a': a, 'along': along, 'tree': tree, 'rim_s': rim_s, 'from_mirror': from_mirror, 'theta': theta,
           'marked': marked, 'under_glove': under_glove}
    return points, wedges, faces, weights, names, old_end, new_points, new_faces, report, fit


def strap(fit, seat):
    """The watch's front strap and buckles, refitted to the cuff and mirrored: points, corners and UV islands."""
    import math
    import numpy as np
    from mathutils import Vector
    c, a, along, tree = fit['c'], fit['a'], fit['along'], fit['tree']
    watch = seat['load_watch'](STAGED / 'VRWristwatch.fbx')
    me = watch.data
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
    for p in me.polygons:
        groups.setdefault(find(vid[p.vertices[0]]), []).append(p.index)
    chosen = []
    for polys in groups.values():
        idx = sorted({v for pi in polys for v in me.polygons[pi].vertices})
        P = np.array([V[i] for i in idx])
        lo, hi = P.min(0), P.max(0)
        mid = (lo + hi) / 2
        if lo[0] < STRAP_X[0] or hi[0] > STRAP_X[1]:
            continue
        ring = hi[1] - lo[1] > 7 and hi[2] - lo[2] > 5
        if ring or mid[1] < -3.95 or mid[2] < -2.5:      # the webbing, the thumb-side buckle, the underside buckle
            chosen.append((polys, idx, ring, Vector(mid)))
    if not any(ring for _, _, ring, _ in chosen):
        raise RuntimeError('The watch has no front strap ring where one was expected.')

    def radial(q):
        r = (q - c) - a * (q - c).dot(a)
        return r.length, r.normalized()

    def surface(s, e, fallback):
        origin = c + a * s
        hit = tree.ray_cast(origin, e)
        return (hit[0] - origin).dot(e) if hit[0] is not None else fallback
    webbing = [Vector(V[i]) for _, idx, ring, _ in chosen if ring for i in idx]
    centre_s = (min(along(q) for q in webbing) + max(along(q) for q in webbing)) / 2
    shift = (fit['rim_s'] - STRAP_BEHIND_RIM_CM) - centre_s
    # How far the webbing's inner face stands off the arm at each angle. Under the watch's saddle it is
    # held up; that stretch is pressed down to the seated level. Under a buckle it stays as it was seated.
    theta = fit['theta']
    inner = [math.inf] * STRAP_BINS
    for q in webbing:
        r, e = radial(q)
        k = int(theta(q) * STRAP_BINS) % STRAP_BINS
        inner[k] = min(inner[k], r - surface(along(q), e, r))
    known = [d for d in inner if d < math.inf]
    seated = sorted(known)[len(known) // 5]
    inner = [d if d < math.inf else seated for d in inner]
    held = [False] * STRAP_BINS
    for _, idx, ring, _ in chosen:
        if not ring:
            for i in idx:
                k = int(theta(V[i]) * STRAP_BINS) % STRAP_BINS
                for j in (-2, -1, 0, 1, 2):
                    held[(k + j) % STRAP_BINS] = True
    press = [0.0 if held[k] else max(0.0, inner[k] - seated - STRAP_SLACK_CM) for k in range(STRAP_BINS)]
    for _ in range(2):
        press = [(press[k - 1] + 2 * press[k] + press[(k + 1) % STRAP_BINS]) / 4 for k in range(STRAP_BINS)]

    def pressed(q):
        x = theta(q) * STRAP_BINS - 0.5
        k = math.floor(x)
        t = x - k
        return press[k % STRAP_BINS] * (1 - t) + press[(k + 1) % STRAP_BINS] * t
    moved, worst = {}, 0.0
    for polys, idx, ring, mid in chosen:
        if ring:
            for i in idx:
                r, e = radial(V[i])
                s = along(V[i])
                here = surface(s, e, r)
                there = surface(s + shift, e, here)
                moved[i] = c + a * (s + shift) + e * (there + (r - here) - pressed(V[i]))
                worst = max(worst, abs(there - here))
        else:
            r, e = radial(mid)
            s = along(mid)
            here = surface(s, e, r)
            step = a * shift + e * (surface(s + shift, e, here) - here)
            for i in idx:
                moved[i] = V[i] + step
    uv = me.uv_layers.active.data
    # UV islands, so each can be copied to its own place in the hand atlas.
    ukey, up = {}, []

    def ufind(i):
        while up[i] != i:
            up[i] = up[up[i]]
            i = up[i]
        return i
    loop_node = {}
    for part, (polys, _, _, _) in enumerate(chosen):
        for pi in polys:
            ids = []
            for li in me.polygons[pi].loop_indices:
                k = (part, round(uv[li].uv.x * SIZE, 2), round((1 - uv[li].uv.y) * SIZE, 2))
                if k not in ukey:
                    ukey[k] = len(up)
                    up.append(len(up))
                loop_node[li] = ukey[k]
                ids.append(ukey[k])
            for j in ids[1:]:
                ra, rb = ufind(ids[0]), ufind(j)
                if ra != rb:
                    up[ra] = rb
    island_id, boxes = {}, []
    for (part, x, y), node in ukey.items():
        root = ufind(node)
        if root not in island_id:
            island_id[root] = len(boxes)
            boxes.append([x, y, x, y])
        b = boxes[island_id[root]]
        b[0], b[1], b[2], b[3] = min(b[0], x), min(b[1], y), max(b[2], x), max(b[3], y)
    order = sorted(moved)
    index = {v: i for i, v in enumerate(order)}
    points = [fit['from_mirror'](moved[v]) for v in order]
    corners = []
    for polys, _, _, _ in chosen:
        for pi in polys:
            loops = list(me.polygons[pi].loop_indices)
            for j in range(1, len(loops) - 1):       # fan; the export is triangles already
                tri = (loops[0], loops[j], loops[j + 1])
                # Mirrored, so Blender's loop order is already ActorX's.
                corners.append([(index[me.loops[li].vertex_index], uv[li].uv.x * SIZE, (1 - uv[li].uv.y) * SIZE,
                                 island_id[ufind(loop_node[li])]) for li in tri])
    report = {'parts': len(chosen), 'triangles': len(corners), 'points': len(points), 'islands': len(boxes),
              'slid_cm': shift, 'largest_radius_change_cm': worst, 'seated_clearance_cm': seated,
              'largest_press_cm': max(press)}
    return points, corners, boxes, report


def pack(boxes, scales, occupied_uv_tris):
    """A free place in the hand atlas for each box (source px, copied at its scale), tallest first, on a CELL grid."""
    import numpy as np
    n = SIZE // CELL
    occ = np.zeros((n, n), bool)
    for tri in occupied_uv_tris:
        xs = [u * n for u, _ in tri]
        ys = [v * n for _, v in tri]
        occ[max(0, int(min(ys)) - 1):min(n, int(max(ys)) + 2), max(0, int(min(xs)) - 1):min(n, int(max(xs)) + 2)] = True
    occ[0, :] = occ[-1, :] = occ[:, 0] = occ[:, -1] = True
    places = [None] * len(boxes)
    sizes = [((b[2] - b[0]) * k + 2 * STRAP_PAD, (b[3] - b[1]) * k + 2 * STRAP_PAD) for b, k in zip(boxes, scales)]
    for i in sorted(range(len(boxes)), key=lambda i: -sizes[i][1]):
        cw, ch = int(-(-sizes[i][0] // CELL)), int(-(-sizes[i][1] // CELL))
        total = np.pad(occ.astype(np.int32).cumsum(0).cumsum(1), ((1, 0), (1, 0)))
        full = total[ch:, cw:] - total[:-ch, cw:] - total[ch:, :-cw] + total[:-ch, :-cw]
        free = np.argwhere(full == 0)
        if not len(free):
            raise RuntimeError('The hand atlas has no room left for the strap texels.')
        y, x = free[0]
        occ[y:y + ch, x:x + cw] = True
        places[i] = (x * CELL + STRAP_PAD, y * CELL + STRAP_PAD)
    return places


def main(revision, stock_side_cm=None, with_strap=True, tidy=False):
    out = ART / revision / 'runtime'
    if (out / 'right-cuff.json').exists():
        raise RuntimeError('This candidate already has a right cuff; preserve it and start a new revision.')
    out.mkdir(parents=True, exist_ok=True)
    for p in STAGED.iterdir():
        if p.is_file() and (p.name == 'WatchPBRMetallic.png' or (p.name.startswith(('VRWristwatch.', 'VRHorzine')) and p.suffix.lower() in {'.fbx', '.tga'})):
            shutil.copy2(p, out / p.name)
    import bpy
    bpy.context.scene.unit_settings.system = 'METRIC'
    bpy.context.scene.unit_settings.scale_length = 0.01
    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    shells_of = runpy.run_path(str(ROOT / 'tools/trim_hand_forearms.py'), run_name='asset_source')['shells']
    source = STAGED / 'VRFloatingHands.psk'
    chunks = g['read_psk'](source)
    points, wedges, faces, weights, names, old_end, new_points, new_faces, report, fit = build(chunks, g, shells_of, stock_side_cm, tidy)
    removed = set(old_end)
    face_rows = [chunks['FACE0000'].rows[i] for i in range(len(faces)) if i not in removed]
    # The strap: geometry from the watch, texels to be copied into free atlas space.
    seat = runpy.run_path(str(ROOT / 'tools/seat_watch_keepers.py'), run_name='asset_source')
    if with_strap and not tidy:
        strap_points, strap_corners, boxes, strap_report = strap(fit, seat)
    else:
        strap_points, strap_corners, boxes, strap_report = [], [], [], None
    used_uv = [[(wedges[w][1], wedges[w][2]) for w in faces[i][:3]] for i in range(len(faces)) if i not in removed]
    used_uv += [[(u, v) for _, u, v in corners] for corners in new_faces]
    # The cuff faces over the left bracer's wordmark: one box round them all, copied at full size.
    marked = fit['marked']
    mark_patch = None
    if marked:
        us = [u * SIZE for f in marked for _, u, _ in new_faces[f]]
        vs = [v * SIZE for f in marked for _, _, v in new_faces[f]]
        boxes.append([math.floor(min(us)), math.floor(min(vs)), math.ceil(max(us)), math.ceil(max(vs))])
    places = pack(boxes, [STRAP_TEXEL_SCALE] * (len(boxes) - bool(marked)) + [1.0] * bool(marked), used_uv)
    if marked:
        b, at = boxes.pop(), places.pop()
        mark_patch = {'from': [b[0], b[1], b[2] - b[0], b[3] - b[1]], 'to': list(map(int, at)), 'faces': len(marked)}
        for f in marked:
            new_faces[f] = [(i, (at[0] + u * SIZE - b[0]) / SIZE, (at[1] + v * SIZE - b[1]) / SIZE) for i, u, v in new_faces[f]]
    copies = [{'from': [b[0], b[1], b[2] - b[0], b[3] - b[1]], 'to': list(map(int, at))} for b, at in zip(boxes, places)]
    cuff_points = len(new_points)
    for corners in strap_corners:
        tri = []
        for point, x, y, island in corners:
            b, at = boxes[island], places[island]
            tri.append((cuff_points + point, (at[0] + (x - b[0]) * STRAP_TEXEL_SCALE) / SIZE, (at[1] + (y - b[1]) * STRAP_TEXEL_SCALE) / SIZE))
        new_faces.append(tri)
    new_points = list(new_points) + list(strap_points)
    all_points = [tuple(p) for p in points]
    point_weights = [dict(w) for w in weights]
    hand_bone = names.index('RightHand_1stP')
    first_new = len(all_points)
    for p in new_points:
        all_points.append(tuple(p))
        point_weights.append({hand_bone: 1.0})
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
    for corners in new_faces:
        ids = [wedge(first_new + i, u, v) for i, u, v in corners]
        face_rows.append(g['FACE'].pack(*ids, material, 0, smoothing))
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
    chunks['RAWWEIGHTS'].rows = [g['WEIGHT'].pack(wt, pmap[p], b) for p in used_p for b, wt in sorted(point_weights[p].items())]
    preserved = {k: hashlib.sha256(b''.join(ch.rows)).hexdigest() for k, ch in chunks.items() if k in ('ACTRHEAD', 'MATT0000', 'REFSKELT')}
    psk = out / 'VRFloatingHands.psk'
    psk.write_bytes(b''.join(ch.encode() for ch in chunks.values()))
    g['decode_geometry'](g['read_psk'](psk))
    export = g['export_fbx'](psk, out / 'VRFloatingHands.fbx')
    result = {'change': 'Right arm end finished just inside the glove hem' if tidy else
              'Short leather cuff with one strap on the right arm, mirrored from the left bracer and the watch',
              'source_psk_sha256': digest(source), **report, 'strap': strap_report, 'strap_texel_scale': STRAP_TEXEL_SCALE,
              'strap_texels': copies, 'mark_patch': mark_patch, 'under_glove_px': fit['under_glove'],
              'watch_sha256': digest(STAGED / 'VRWristwatch.fbx'),
              'old_end_triangles_removed': len(removed),
              'new_triangles': len(new_faces), 'triangles': len(frows), 'base_triangles': len(faces),
              'points': len(used_p), 'wedges': len(used_w), 'preserved_chunks_sha256': preserved,
              'psk_sha256': digest(psk), 'fbx_sha256': digest(out / 'VRFloatingHands.fbx'),
              'generator_sha256': digest(Path(__file__)), **export}
    (out / 'right-cuff.json').write_text(json.dumps(result, indent=2))
    return result


def paint(revision):
    """Copy the strap's texels from the watch's maps into the candidate's hand maps."""
    import numpy as np
    from PIL import Image, ImageDraw
    runtime = ART / revision / 'runtime'
    report_path = runtime / 'right-cuff-paint.json'
    if report_path.exists():
        raise RuntimeError('This candidate already has its strap texels; preserve it and start a new revision.')
    built = json.loads((runtime / 'right-cuff.json').read_text())
    if built['psk_sha256'] != digest(runtime / 'VRFloatingHands.psk'):
        raise SystemExit('right-cuff.json does not describe this PSK.')
    hands = {n: f'VRHorzineHands_{n}.tga' for n in 'DNS'}
    report = {'base_sha256': {f: digest(runtime / f) for f in hands.values()}}
    watch = {n: Image.open(runtime / f'VRHorzineWatch_{n}.tga').convert('RGB') for n in 'DNS'}
    metal = Image.open(runtime / 'WatchPBRMetallic.png').convert('L').resize((SIZE, SIZE), Image.BILINEAR)
    out = {'D': Image.open(runtime / hands['D']).convert('RGB'), 'N': Image.open(runtime / hands['N']).convert('RGB'),
           'S': Image.open(runtime / hands['S']).convert('RGBA')}
    spots = []
    shown = built.get('under_glove_px') or []
    if shown:
        # The arm just inside the glove's hem was never painted (it was hidden); the tidied end can show a
        # sliver of it. Paint it as the roll's own dark leather, dull, with no skin transmission.
        mask = Image.new('L', (SIZE, SIZE), 0)
        draw = ImageDraw.Draw(mask)
        for tri in shown:
            draw.polygon([tuple(c) for c in tri], fill=255, outline=255)
        from PIL import ImageFilter
        mask = mask.filter(ImageFilter.MaxFilter(9))
        m = np.asarray(mask) > 0
        bx, by, bw, bh = BLOCKS['roll']
        D = np.asarray(out['D']).copy()
        SA = np.asarray(out['S']).copy()
        skin = m & (D[..., 0].astype(int) - D[..., 2] > 18) & (D[..., 0] > 60)
        leather = np.median(D[by + 4:by + bh - 4, bx + 4:bx + bw - 4].reshape(-1, 3), axis=0)
        grain = (D[skin].astype(np.float32).mean(-1, keepdims=True) / max(1.0, float(D[skin].mean()))) if skin.any() else 1.0
        D[skin] = np.clip(leather * (0.75 + 0.25 * grain), 0, 255).astype(np.uint8)
        SA[skin] = (30, 30, 30, 28)
        out['D'], out['S'] = Image.fromarray(D, 'RGB'), Image.fromarray(SA, 'RGBA')
        ys, xs = np.nonzero(skin)
        report['under_glove'] = {'texels_painted': int(skin.sum())}
        under = skin
    else:
        under = None
    patch = built.get('mark_patch')
    if patch:
        from PIL import ImageFilter
        x, y, w, h = patch['from']
        box = (x - STRAP_PAD, y - STRAP_PAD, x + w + STRAP_PAD, y + h + STRAP_PAD)
        at = (patch['to'][0] - STRAP_PAD, patch['to'][1] - STRAP_PAD)
        # 1 over the mark, fading to 0 just outside it: there the plain leather beside the mark shows instead.
        fade = Image.new('L', (box[2] - box[0], box[3] - box[1]), 0)
        ImageDraw.Draw(fade).rectangle([MARK_BOX[0] - 4 - box[0], MARK_BOX[1] - 4 - box[1], MARK_BOX[2] + 4 - box[0], MARK_BOX[3] + 4 - box[1]], fill=255)
        fade = fade.filter(ImageFilter.GaussianBlur(MARK_FEATHER / 2))
        plain = tuple(v + MARK_PLAIN_SHIFT[i % 2] for i, v in enumerate(box))
        for n in out:
            piece = out[n].crop(box)
            piece.paste(out[n].crop(plain), (0, 0), fade)
            out[n].paste(piece, at)
        spots.append((patch['to'][0], patch['to'][1], w, h))
        report['mark_patch'] = {'faces': patch['faces'], 'box': list(box)}
    scale = built['strap_texel_scale']
    margin = int(round(STRAP_PAD / scale))
    for copy in built['strap_texels']:
        x, y, w, h = copy['from']
        box = (int(x) - margin, int(y) - margin, int(-(-(x + w) // 1)) + margin, int(-(-(y + h) // 1)) + margin)
        size = (max(1, round((box[2] - box[0]) * scale)), max(1, round((box[3] - box[1]) * scale)))
        # The island's own corner must land exactly where the mesh's UVs expect it.
        at = (round(copy['to'][0] - (x - box[0]) * scale), round(copy['to'][1] - (y - box[1]) * scale))
        for n in 'DN':
            out[n].paste(watch[n].crop(box).resize(size, Image.LANCZOS), at)
        m = np.asarray(metal.crop(box).resize(size, Image.BILINEAR), dtype=np.float32) / 255.0
        gloss = STRAP_GLOSS['soft'] + (STRAP_GLOSS['metal'] - STRAP_GLOSS['soft']) * m
        spec = np.asarray(watch['S'].crop(box).resize(size, Image.LANCZOS), dtype=np.uint8)
        out['S'].paste(Image.fromarray(np.dstack([spec, gloss.round().astype(np.uint8)]), 'RGBA'), at)
    # The watch atlas has black gutters: grow each island's own colour into its gutter so mips stay clean.
    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    points, wedges, faces, _ = g['decode_geometry'](g['read_psk'](runtime / 'VRFloatingHands.psk'))
    strap_spots = [(c['to'][0], c['to'][1], c['from'][2] * scale, c['from'][3] * scale) for c in built['strap_texels']]
    spots += strap_spots
    region = Image.new('L', (SIZE, SIZE), 0)
    draw = ImageDraw.Draw(region)
    for x, y, w, h in strap_spots:
        draw.rectangle([x - STRAP_PAD, y - STRAP_PAD, x + w + STRAP_PAD, y + h + STRAP_PAD], fill=255)
    region = np.asarray(region) > 0
    owned = Image.new('L', (SIZE, SIZE), 0)
    draw = ImageDraw.Draw(owned)
    for f in faces:
        tri = [(wedges[w][1] * SIZE, wedges[w][2] * SIZE) for w in f[:3]]
        if all(region[min(SIZE - 1, int(v)), min(SIZE - 1, int(u))] for u, v in tri):
            draw.polygon(tri, fill=255, outline=255)
    filled = np.asarray(owned) > 0
    maps = {n: np.asarray(out[n]).copy() for n in out}
    for _ in range(STRAP_PAD + 2 if strap_spots else 0):
        grow = np.zeros_like(filled)
        acc = {n: np.zeros(maps[n].shape, np.float32) for n in maps}
        count = np.zeros(filled.shape, np.float32)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            src = np.roll(filled, (dy, dx), (0, 1))
            grow |= src
            count += src
            for n in maps:
                acc[n] += np.roll(maps[n], (dy, dx), (0, 1)).astype(np.float32) * src[..., None]
        new = grow & ~filled & region
        for n in maps:
            maps[n][new] = (acc[n][new] / count[new][:, None]).round().astype(np.uint8)
        filled = filled | new
    Image.fromarray(maps['D'], 'RGB').save(runtime / hands['D'])
    Image.fromarray(maps['N'], 'RGB').save(runtime / hands['N'])
    Image.fromarray(maps['S'], 'RGBA').save(runtime / hands['S'])
    # The skin transmission mask must stay clear under the new texels.
    t_path = runtime / 'VRHorzineHands_T.tga'
    T = Image.open(t_path).convert('RGB')      # the importer refuses a greyscale TGA
    k = T.width / SIZE
    draw = ImageDraw.Draw(T)
    for x, y, w, h in spots:
        draw.rectangle([int((x - STRAP_PAD) * k), int((y - STRAP_PAD) * k), int((x + w + STRAP_PAD) * k) + 1, int((y + h + STRAP_PAD) * k) + 1], fill=(0, 0, 0))
    if under is not None:
        keep = Image.fromarray((~under).astype(np.uint8) * 255, 'L').resize(T.size, Image.BILINEAR).point(lambda v: 255 if v > 250 else 0)
        T = Image.composite(T, Image.new('RGB', T.size, (0, 0, 0)), keep)
    T.save(t_path)
    report.update({'islands': len(spots), 'maps_sha256': {f: digest(runtime / f) for f in list(hands.values()) + [t_path.name]}})
    report_path.write_text(json.dumps(report, indent=1))
    return report


if __name__ == '__main__':
    if sys.argv[1:2] == ['--paint']:
        print('HAND_RIGHT_CUFF_PAINTED', json.dumps(paint(sys.argv[2])), flush=True)
    else:
        args = sys.argv[sys.argv.index('--') + 1:]
        slant = float(args[args.index('--stock-side-cm') + 1]) if '--stock-side-cm' in args else None
        print('HAND_RIGHT_CUFF', json.dumps(main(args[0], slant, '--no-strap' not in args, '--tidy-end' in args)), flush=True)
