"""Offline grapple hand poses for held Zed parts (melee roadmap item 15).

Run inside Blender (MCP runpy, then review()/emit_runtime()). The floating
hand (build/hand-meshes/VRFloatingHands.psk, the grenade-grip reference
skeleton) is placed on a stock Zed mesh exported with the pinned UModel the
way a VR player standing in front of the upright Zed would reach it: the
fingers point along the reach from the player's shoulder to the grab point,
the wrist rolled per region and tilted a little, then the palm is seated on
the part. Each finger wraps it phalanx by phalanx as a real hand closes:
the knuckle curls until the first phalanx meets the part, then the middle
joint, then the last joint until the pad does (B&S closes a grapple until
finger contact, at most 0.9 of a full close), so the pads follow the part;
the thumb opposes the fingers on the near side the player sees. Only the shape
is emitted, as fixed additive bone-local quaternions, to
script/KF2VR/Classes/VRGrapplePose.uc; in game the held part stays where the
palm met it, so placement here only serves the solve and the review.
"""
import json, math, runpy
from pathlib import Path
from mathutils import Vector, Matrix, Quaternion
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

ROOT = Path(__file__).resolve().parents[1]
GRENADE = runpy.run_path(str(ROOT / 'tools/author_grenade_grips.py'), run_name='grapple_grenade_tools')
DIGITS = GRENADE['DIGITS']
# Absolute finger flexion limits (degrees from a straight digit) for the
# knuckle, middle and last joint, and the B&S close cap.
LIMITS = (90.0, 100.0, 75.0)
CLOSE = 0.9
DIG = 0.6      # how far skin may sink into the Zed (uu): glove pads and flesh give
TOUCH = 0.3    # how far a closing segment presses in before it stops
PRESS = 0.5    # how far the palm is pressed into the part

# The player stands facing the Zed's front this far from it, eyes at the
# Clot's eye height; the right hand reaches from a shoulder this far right of
# and below the eye (the left hand mirrors it).
PLAYER_DISTANCE = 60.0
SHOULDER = (18.0, 25.0)

# Region: the grab point on the stock Clot (a point between two bones, moved
# by an optional offset of (up, face, left) uu; the
# right hand takes the Zed's left side, which is on the player's right),
# optionally a finger direction as weights of (up, face, left, reach) where
# the wrist bends the hand off the reach, or a bone the fingers turn to cross, the palm normal as weights of (up,
# face, left), rolled about the reach so it
# stays a real wrist roll, the places along the palm (hand X, uu from the
# wrist) tried over the grab point, the wrist tilt and roll searched, knuckle
# spread (index..pinky, degrees, positive towards the thumb), how hard the
# palm presses in, how the thumb is scored (weights on reaching round the
# part, hand +Z; on the near side away from the fingers, hand -X; out along
# the index edge, hand +Y), its opposition range and optionally how far its
# tip must reach round past the palm, how much its middle and tip joints must
# bend (thumb_flex) and a final swing round the part at its base (thumb_turn). A choke anchors the thumb-index web on the grab point. Order matches VRGrapplePose REGION_* minus one.
REGIONS = {
    # Throat, a one-handed front choke: the forearm in level from the front
    # (a handshake with the wrist bent back), so the palm faces the throat
    # with the fingers together and level round the Zed's left side of the
    # neck; the palm tipped a little down so its pinky edge lifts off the
    # collarbone while the thumb-index web presses the windpipe just under
    # the jaw, the hand set slightly to the Zed's right so the thumb wraps
    # that side of the neck. The palm is held just off the throat: pressed
    # flat, the index digs into the jaw. The left hand's review spot is
    # lower.
    'Neck': dict(centre=('neck', 'head', 0.45), fingers=(0.15, 0.0, 1.0, 0.25), into=(-0.3, -1, 0), anchor='web',
                 slides=(1.5,), tilt=(-15, 15), roll=(-15, 15), within=12, spread=(-2, 0, 2, 5),
                 press=-0.5, thumb=(0.8, 1.0, -0.2), opposition=(-60, 20), left_offset=(-4.0, 0.0, 0.0)),
    # Face: a palm shove to the forehead, the forearm in from the front with
    # the wrist bent back, the palm on the forehead and brow, fingers spread
    # up and back over the crown, thumb on the temple.
    'Skull': dict(centre=('head', 'Face_EyeBrow', 0.5), offset=(6.0, 0.0, 0.0), fingers=(1.0, -0.2, 0.0, 0.3),
                  into=(0, -1, 0), slides=(3.0, 4.5, 6.0), tilt=(-20, 20), roll=(-15, 15), spread=(14, 4, -6, -16),
                  press=0.6, thumb=(0.6, 0.4, 0.6), opposition=(-40, 40)),
    # Shoulder: the Zed's left shoulder (on the player's right), palm down
    # over its top from the front, cupped a little (pressed flat, the thumb
    # cannot reach the front), fingers hooked over the back, thumb bent at its
    # middle and tip joints, pressed into the hollow above the collarbone.
    'Shoulder': dict(centre=('LeftShoulder', 'LeftArm', 0.45), into=(-1, 0, 0), slides=(4.5, 6.0),
                     tilt=(-40, 10), roll=(-15, 15), spread=(-5, -1, 2, 6), press=-0.5, thumb=(0.5, 0.6, 0.8),
                     thumb_flex=40.0, opposition=(-40, 60)),
    # Forearm: the Zed's left arm raised towards the player and swiping
    # across; palm on top of mid-forearm, fingers crossing it square and
    # curled round underneath to meet the thumb coming round the near side.
    'Limb': dict(centre=('LeftForearm', 'LeftHand', 0.55), into=(-1, 0, 0), slides=(9.5,),
                 tilt=(-25, 15), roll=(-15, 15), spread=(2, 0, -1, -2), press=0.5, thumb=(0.8, 0.6, -0.3),
                 thumb_turn=15.0, opposition=(-40, 40), pose_arm=True, across=('LeftForearm', 'LeftHand')),
}
ORDER = ('Neck', 'Skull', 'Shoulder', 'Limb')


def zed(psk):
    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='grapple_zed_reader')
    c = g['read_psk'](psk)
    bones, names = g['bone_data'](c)
    points, wedges, faces, weights = g['decode_geometry'](c)
    p0 = []; q0 = []
    for i, b in enumerate(bones):
        q = Quaternion((b[7], b[4], b[5], b[6])); p = Vector(b[8:11])
        if i: p = p0[b[3]] + q0[b[3]] @ p; q = q0[b[3]] @ q.conjugated()
        p0.append(p); q0.append(q)
    tris = [[wedges[w][0] for w in reversed(f[:3])] for f in faces]
    return dict(names=names, p0=p0, points=[Vector(p) for p in points], tris=tris, weights=weights)


def mirrored(z):
    """The Zed reflected across its midline, for solving the left hand (whose
    hand frame is the mirror of the right one's)."""
    m = lambda v: Vector((-v.x, v.y, v.z))
    return dict(z, p0=[m(p) for p in z['p0']], points=[m(p) for p in z['points']], tris=[t[::-1] for t in z['tris']])


class Hand:
    """One side of the reference hand. Only that hand's vertices are skinned,
    and only the subsets a test needs, so the solver can try many poses."""
    def __init__(self, ctx, side):
        g, bones, names, weights, p0, q0, points = (ctx[k] for k in ('g', 'bones', 'names', 'weights', 'p0', 'q0', 'points'))
        self.ctx, self.side = ctx, side
        wrist = names.index(side + 'Hand_1stP'); self.wrist = wrist
        self.members = set(g['descendants'](bones, wrist)) | {wrist}
        self.finger = lambda f, j: names.index(side + 'Hand' + f + str(j) + '_1stP')
        F = (p0[self.finger('Middle', 1)] - p0[wrist]).normalized()
        T = p0[self.finger('Index', 1)] - p0[self.finger('Pinky', 1)]; T = (T - F * T.dot(F)).normalized()
        P = F.cross(T).normalized()
        a = (p0[self.finger('Middle', 2)] - p0[self.finger('Middle', 1)]).normalized()
        b = (p0[self.finger('Middle', 3)] - p0[self.finger('Middle', 2)]).normalized()
        if (b - a * b.dot(a)).dot(P) < 0: P = -P
        self.P = P; self.frame = Matrix((F, T, P))
        self.ids = [i for i, w in enumerate(weights) if w and max(w, key=w.get) in self.members]
        self.bind = {i: [(bone, w, q0[bone].inverted() @ (Vector(points[i]) - p0[bone])) for bone, w in weights[i].items()]
                     for i in self.ids}
        dom = {i: max(weights[i], key=weights[i].get) for i in self.ids}
        self.palm = [i for i in self.ids if dom[i] == wrist]
        self.segments = {}
        for f in DIGITS:
            for j in range(1, 4):
                later = {self.finger(f, k) for k in range(j, 4)}
                self.segments[(f, j)] = [i for i in self.ids if dom[i] in later]
        self.own = {(f, j): [i for i in self.ids if dom[i] == self.finger(f, j)] for f in DIGITS for j in range(1, 4)}
        self.tip = {f: [i for i in self.ids if weights[i].get(self.finger(f, 3), 0) > .8] for f in DIGITS}
        wedges, faces = ctx['wedges'], ctx['faces']
        self.triangles = [[wedges[w][0] for w in reversed(face[:3])] for face in faces
                          if max(weights[wedges[face[0]][0]], key=weights[wedges[face[0]][0]].get) in self.members]
        if self.frame.determinant() < 0: self.triangles = [t[::-1] for t in self.triangles]
        # Rest flexion of each finger joint, measured from the skeleton, so
        # limits and couplings are in absolute anatomical angles.
        rest = self.skin([[0, 0, 0]] * 5 + [0])
        self.rest = {}
        for f in DIGITS[1:]:
            pts = [Vector()] + [self.frame @ (p0[self.finger(f, j)] - p0[wrist]) for j in (1, 2, 3)]
            pts.append(sum((rest[i] for i in self.tip[f]), Vector()) / len(self.tip[f]))
            angles = []
            for j in range(1, 4):
                u = (pts[j] - pts[j - 1]); v = (pts[j + 1] - pts[j])
                angles.append(math.degrees(math.atan2(v.z, v.x) - math.atan2(u.z, u.x)))
            self.rest[f] = angles
        # The palm surface, with the fingers straight: skin from the heel up
        # to just past each knuckle (the finger roots bear on a held part as
        # much as the palm does) that is outermost on the palm side (+Z) in
        # its column, so the back of the hand and inner layers are left out.
        straight = [[0, 0, 0]] + [[-a for a in self.rest[f]] for f in DIGITS[1:]] + [0]
        flat = self.skin(straight)
        knuckles = {self.finger(f, 1): self.frame @ (p0[self.finger(f, 1)] - p0[wrist]) for f in DIGITS[1:]}
        roots = {i for f in DIGITS[1:] for i in self.own[(f, 1)]
                 if flat[i].x - knuckles[self.finger(f, 1)].x < 1.2}
        candidates = [i for i in self.palm if flat[i].x > 0.8] + [i for i in roots]
        cells = {}
        for i in candidates:
            key = (round(flat[i].x / 0.6), round(flat[i].y / 0.6))
            cells[key] = max(cells.get(key, -99), flat[i].z)
        self.palm_surface = [i for i in candidates
                             if flat[i].z > cells[(round(flat[i].x / 0.6), round(flat[i].y / 0.6))] - 0.5]
        self.palm_z = sum(flat[i].z for i in self.palm_surface) / len(self.palm_surface)
        self.palm_x = sum(flat[i].x for i in self.palm_surface) / len(self.palm_surface)
        # The thumb-index web, where a choke presses the windpipe.
        web = (self.frame @ (p0[self.finger('Thumb', 2)] - p0[wrist]) + self.frame @ (p0[self.finger('Index', 1)] - p0[wrist])) * 0.5
        self.web = Vector((web.x, web.y, self.palm_z))
        # The pad side of each segment: only that side holding the part is
        # contact; a curled finger resting on its knuckles is not a grip.
        # Fingers: above their bone line with the finger straight. Thumb:
        # facing the middle of the palm's grip space in the rest pose.
        joint = lambda f, j: self.frame @ (p0[self.finger(f, j)] - p0[wrist])
        self.pad = {}
        for f in DIGITS[1:]:
            k = joint(f, 1)   # straight, the finger runs on along wrist -> knuckle
            for j in (1, 2, 3):
                self.pad[(f, j)] = [i for i in self.own[(f, j)] if flat[i].z > k.z + (flat[i].x - k.x) * k.z / k.x + 0.2]
        aim = Vector((6.0, -1.0, 4.0))
        for j in (1, 2, 3):
            a = joint('Thumb', j); b = joint('Thumb', j + 1) if j < 3 else a + (a - joint('Thumb', j - 1))
            axis = (b - a).normalized()
            towards = aim - a; towards = (towards - axis * towards.dot(axis)).normalized()
            self.pad[('Thumb', j)] = [i for i in self.own[('Thumb', j)]
                                      if ((rest[i] - a) - axis * (rest[i] - a).dot(axis)).dot(towards) > 0.2]

    def deltas(self, values, spread):
        p0, q0 = self.ctx['p0'], self.ctx['q0']
        P = self.P; out = {}
        for fi, f in enumerate(DIGITS):
            for j in range(1, 4):
                i = self.finger(f, j)
                direction = p0[self.finger(f, j + 1)] - p0[i] if j < 3 else p0[i] - p0[self.finger(f, j - 1)]
                axis = q0[i].inverted() @ direction.cross(P).normalized()
                delta = Quaternion(axis, math.radians(values[fi][j - 1]))
                if j == 1 and fi == 0:
                    side = P.copy()
                    if direction.cross(p0[self.finger('Index', 1)] - p0[i]).dot(P) < 0: side = -side
                    delta = Quaternion(q0[i].inverted() @ side, math.radians(values[5])) @ delta
                elif j == 1 and spread[fi - 1]:
                    # Knuckle spread about the palm normal, positive toward the thumb.
                    side = P.copy()
                    if direction.cross(p0[self.finger('Index', 1)] - p0[self.finger('Pinky', 1)]).dot(P) < 0: side = -side
                    delta = Quaternion(q0[i].inverted() @ side, math.radians(spread[fi - 1])) @ delta
                out[i] = delta
        return out

    def skin(self, values, spread=(0, 0, 0, 0), ids=None):
        bones, p0, q0 = (self.ctx[k] for k in ('bones', 'p0', 'q0'))
        deltas = self.deltas(values, spread)
        pp = {}; pq = {}
        for i in sorted(self.members):
            par = bones[i][3]
            if i == self.wrist or par not in pp:
                p = p0[i].copy(); q = q0[i].copy()
            else:
                p = pp[par] + pq[par] @ (q0[par].inverted() @ (p0[i] - p0[par])); q = pq[par] @ (q0[par].inverted() @ q0[i])
            if i in deltas: q = q @ deltas[i]
            pp[i] = p; pq[i] = q
        w0 = p0[self.wrist]
        moved = {b: (self.frame @ (pp[b] - w0), self.frame @ pq[b].to_matrix()) for b in pp}
        verts = {}
        for i in (self.ids if ids is None else ids):
            p = Vector()
            for bone, weight, offset in self.bind[i]:
                if bone in moved:
                    t, r = moved[bone]; p += weight * (t + r @ offset)
                else:
                    p += weight * (self.frame @ (p0[bone] + q0[bone] @ offset - w0))
            verts[i] = p
        self.last = deltas
        return verts


def body(z):
    """A bone lookup and the Zed's up, face and left directions."""
    n = z['names']; P = lambda b: z['p0'][n.index(b)]
    up = (P('head') - P('hips')).normalized()
    face = (P('Eye_L') + P('Eye_R')) * 0.5 - P('head'); face = (face - up * face.dot(up)).normalized()
    left = P('LeftArm') - P('RightArm'); left = (left - up * left.dot(up) - face * left.dot(face)).normalized()
    return P, up, face, left


def player(z):
    """The standing player's eye and right shoulder, in front of the Zed."""
    P, up, face, left = body(z)
    eye = (P('Eye_L') + P('Eye_R')) * 0.5
    front = max((p - eye).dot(face) for p in z['points'] if (p - eye).dot(up) > -30)  # the face, not the hands
    eye = eye + face * (front + PLAYER_DISTANCE)
    # Facing the Zed, the player's right is the Zed's left.
    return eye, eye + left * SHOULDER[0] - up * SHOULDER[1]


def posed(z):
    """The Zed with its left arm raised towards the player and the forearm
    swiping across in front of its chest, as in an attack: the upper arm
    turned at the shoulder and the forearm at the elbow, blended by the skin
    weights."""
    P, up, face, left = body(z)
    n = z['names']
    upper = {n.index(b) for b in ('LeftArm', 'LeftArmTwist1') if b in n}
    lower = {i for i, b in enumerate(n) if b.startswith(('LeftForeArm', 'LeftForearm', 'LeftHand'))}
    s, e, h = P('LeftArm'), P('LeftForearm'), P('LeftHand')
    r1 = (e - s).rotation_difference((face * 0.85 - up * 0.35 + left * 0.25).normalized()).to_matrix()
    e1 = s + r1 @ (e - s)
    r2 = (r1 @ (h - e)).rotation_difference((-left * 0.85 + face * 0.35 + up * 0.05).normalized()).to_matrix()
    one = lambda p: s + r1 @ (p - s)
    two = lambda p: e1 + r2 @ (one(p) - e1)
    points = []
    for p, w in zip(z['points'], z['weights']):
        wu = sum(v for b, v in w.items() if b in upper); wl = sum(v for b, v in w.items() if b in lower)
        points.append(p * (1 - wu - wl) + one(p) * wu + two(p) * wl)
    p0 = [two(q) if i in lower else one(q) if i in upper else q for i, q in enumerate(z['p0'])]
    return dict(z, points=points, p0=p0)


def placement(z, region):
    """Review placement on the unmirrored Zed for the right hand: the grab
    point and the hand axes in Zed space (columns X fingers, Y thumb side, Z
    palm normal into the part) before the wrist tilt. X follows the reach
    from the player's right shoulder, or a region's finger direction blended
    with it; Z is the region's palm normal rolled about it. The right hand frame is left-handed in mesh space, so Y = X x Z."""
    r = REGIONS[region]; P, up, face, left = body(z)
    a, b, at = r['centre']; centre = P(a) + (P(b) - P(a)) * at
    if 'offset' in r: centre = centre + up * r['offset'][0] + face * r['offset'][1] + left * r['offset'][2]
    eye, shoulder = player(z)
    X = (centre - shoulder).normalized()
    if 'fingers' in r:
        # Where the wrist bends or the forearm turns the fingers off the
        # reach (a choke's extended wrist, a hand laid across the crown).
        f = r['fingers']
        X = (X * f[3] + up * f[0] + face * f[1] + left * f[2]).normalized()
    if 'across' in r:
        # Turn the wrist a little so the fingers cross the held bone square
        # and wrap it, rather than run along it.
        axis = (P(r['across'][1]) - P(r['across'][0])).normalized()
        X = (X - axis * X.dot(axis)).normalized()
    into = up * r['into'][0] + face * r['into'][1] + left * r['into'][2]
    Z = (into - X * into.dot(X)).normalized()
    Y = X.cross(Z).normalized()
    return centre, Matrix((X, Y, Z)).transposed()


def signed(bvh, p):
    loc, nrm, _, d = bvh.find_nearest(p)
    if loc is None: return 99.0
    return d if (p - loc).dot(nrm) >= 0 else -d


class Grip:
    """One hand on one region: the seated placement and the Zed's collision."""
    def __init__(self, ctx, z, side, region, slide):
        self.region = region; r = REGIONS[region]; self.r = r; self.slide = slide
        self.hand = hand = Hand(ctx, side)
        if r.get('pose_arm'): z = posed(z)
        centre, A = placement(z, region)
        self.eye, self.shoulder = player(z)
        if side == 'Left':
            M = Matrix(((-1, 0, 0), (0, 1, 0), (0, 0, 1)))
            z = mirrored(z); centre = M @ centre; A = M @ A
            self.eye = M @ self.eye; self.shoulder = M @ self.shoulder
            # Where both hands could take the same spot, the left one takes
            # its own (only the review placement; the shape is the right's
            # mirrored).
            if 'left_offset' in r:
                P, up, face, left = body(z)
                o = r['left_offset']; centre = centre + up * o[0] + face * o[1] + left * o[2]
        self.z = z
        # Only the Zed's surface around the gripped part collides; the radius
        # must take in the whole part, or open edges flip the inside test.
        self.tris = [t for t in z['tris'] if min((z['points'][k] - centre).length for k in t) < 26]
        self.bvh = BVHTree.FromPolygons(z['points'], self.tris, all_triangles=True)
        self.values = [[0.0, 0.0, 0.0] for _ in range(5)] + [0.0]
        for fi, f in enumerate(DIGITS[1:], 1):
            self.values[fi] = [-hand.rest[f][0], -hand.rest[f][1], -hand.rest[f][2]]
        self.values[0] = [-30.0, -20.0, -20.0]
        self.spread = r['spread']
        self.seat(centre, A)

    def world(self, p):
        return self.A @ p + self.t

    def seat(self, centre, A0):
        """Lay the whole palm surface on the part: for each tilt, lower the
        open hand along its palm normal until the palm presses in, and keep
        the tilt that brings the most of the palm into contact."""
        hand = self.hand; r = self.r
        open_hand = hand.skin(self.values, self.spread, hand.palm_surface)
        # The point laid over the grab point: on the palm's centre line at
        # the slide, or for a choke the web moved along the fingers by it.
        pivot = hand.web + Vector((self.slide, 0, 0)) if r.get('anchor') == 'web' else Vector((self.slide, 0, hand.palm_z))
        palm = [open_hand[i] for i in hand.palm_surface[::3]]
        # Straight fingers and the open thumb must not be buried either (a
        # slope or hump beside the palm has to roll or shift the hand).
        reach = [i for f in DIGITS for j in (1, 2, 3) for i in hand.own[(f, j)][::12]]
        straight = hand.skin(self.values, self.spread, reach)
        straight = [straight[i] for i in reach]
        best = None
        for tilt in range(r['tilt'][0], r['tilt'][1] + 1, 5):
            for roll in range(r['roll'][0], r['roll'][1] + 1, 5):
                local = Matrix.Rotation(math.radians(tilt), 3, 'Y') @ Matrix.Rotation(math.radians(roll), 3, 'X')
                A = A0 @ local
                Z = A.col[2].copy()
                t = centre - A @ pivot - Z * 30
                d = []
                for p in palm:
                    hit = self.bvh.ray_cast(A @ p + t - Z * 10, Z, 120)
                    if hit[0] is not None: d.append(hit[3] - 10)
                if len(d) < 10: continue
                d.sort(); shift = d[len(d) // 30] + r.get('press', PRESS)
                # The palm must land on the part itself, not on a shoulder
                # beyond it (a thin neck lets a low palm miss it).
                if (A @ pivot + t + Z * shift - centre).length > r.get('within', 40): continue
                contact = sum(1 for x in d if x - shift < 0.8) / len(palm)
                buried = sum(1 for p in straight if signed(self.bvh, A @ p + t + Z * shift) < -0.6) / len(straight)
                score = contact - 3.0 * buried - 0.002 * (abs(tilt) + abs(roll))
                if best is None or score > best[0]: best = (score, A, t + Z * shift, contact, tilt, roll)
        _, self.A, self.t, self.palm_contact, self.tilt, self.roll = best

    def distances(self, ids):
        verts = self.hand.skin(self.values, self.spread, ids)
        return {i: signed(self.bvh, self.world(v)) for i, v in verts.items()}, verts

    def finger_score(self, subsets, pads, weights=(3.0, 6.0, 10.0)):
        """Contact counts each segment's pad side on the surface (the tip
        and middle segments most, as their pressing is what reads as a
        grip); any skin digging in deeper than DIG costs."""
        allids = list({i for s in subsets + pads for i in s})
        d, verts = self.distances(allids)
        score = 0.0
        for w, s in zip(weights, pads):
            if s: score += w * sum(1 for i in s if -DIG - 0.3 < d[i] < 0.5) / len(s)
        pen = sum(max(0.0, max(-d[i] for i in s) - DIG) for s in subsets if s)
        return score - 25.0 * pen, pen, d, verts

    def wrap(self, digit, joints, ranges, checks, couple, step=1.5):
        """Close a digit one joint at a time, the way a hand wraps an object:
        each joint in turn curls from where it is (the joints after it
        following at couple[k] of its motion, as tendons link them) until any
        segment it moves (checks[k], indices into the digit's three segments)
        sinks past TOUCH, backs off one step and locks; the next joint then
        curls on from there. A joint meeting nothing stops at its range end
        (a 0.9 fist). Returns the per-segment vertex subsets."""
        hand = self.hand; values = self.values[joints[0]]; index = joints[1]
        subsets = [hand.own[(digit, j)][::max(1, len(hand.own[(digit, j)]) // 40)] for j in (1, 2, 3)]
        for k, (lo, hi) in enumerate(ranges):
            ids = [i for seg in checks[k] for i in subsets[seg]]
            d, _ = self.distances(ids)
            if max(-x for x in d.values()) > TOUCH: continue    # already pressing here: stay
            base = list(values); a = 0.0
            while base[index[k]] + a < hi:
                b = min(hi - base[index[k]], a + step)
                values[index[k]] = base[index[k]] + b
                for m, c in zip(range(k + 1, len(index)), couple[k]):
                    values[index[m]] = min(ranges[m][1], base[index[m]] + c * b)
                d, _ = self.distances(ids)
                if max(-x for x in d.values()) > TOUCH:
                    values[index[k]] = base[index[k]] + a
                    for m, c in zip(range(k + 1, len(index)), couple[k]):
                        values[index[m]] = min(ranges[m][1], base[index[m]] + c * a)
                    break
                a = b
        return subsets

    def close_finger(self, fi):
        """Wrap a finger phalanx by phalanx (B&S closes a grapple until finger
        contact, at most 0.9 of a full close): the knuckle curls, the outer
        joints following at half and a third, until any phalanx meets the
        part; then the middle joint, the last following, until the middle or
        last phalanx does; then the last joint until the pad does. The pads
        follow the part's curve instead of a tip stabbing in."""
        hand = self.hand; f = DIGITS[fi]; rest = hand.rest[f]
        end = [CLOSE * x for x in LIMITS]
        absolute = [0.0, 0.0, 0.0]
        self.values[fi] = [absolute[j] - rest[j] for j in range(3)]
        ranges = [(-rest[j], end[j] - rest[j]) for j in range(3)]
        subsets = self.wrap(f, (fi, (0, 1, 2)), ranges, ((0, 1, 2), (1, 2), (2,)), ((0.5, 0.35), (0.65,), ()))
        pads = [hand.pad[(f, j)][::max(1, len(hand.pad[(f, j)]) // 30)] for j in (1, 2, 3)]
        # Placement is chosen on what the finger holds.
        return self.finger_score(subsets, pads)[0]

    def close_thumb(self):
        """Thumb: for each opposition (about the palm normal), wrap the base
        swing, middle and tip joints in turn, keeping the wrap whose pad lies
        on the part, reaching round it on the side away from the fingers, and
        not crossing through the index finger. A thumb
        tucked under the palm or hanging off the part is rejected, and one the
        player's eye can see on the near side is preferred."""
        hand = self.hand; r = self.r
        subsets = [hand.own[('Thumb', j)][::max(1, len(hand.own[('Thumb', j)]) // 50)] for j in (1, 2, 3)]
        pads = [hand.pad[('Thumb', j)][::max(1, len(hand.pad[('Thumb', j)]) // 30)] for j in (1, 2, 3)]
        tips = hand.tip['Thumb'][::max(1, len(hand.tip['Thumb']) // 25)]
        fingers = hand.skin(self.values, self.spread, [i for f in DIGITS[1:] for j in (1, 2, 3) for i in hand.own[(f, j)][::4]])
        kd = KDTree(len(fingers))
        for k, (i, v) in enumerate(fingers.items()): kd.insert(v, k)
        kd.balance()
        wz, wx, wy = r['thumb']; slide = self.slide

        def evaluate():
            score, pen, d, verts = self.finger_score(subsets + [tips], pads, (3.0, 10.0, 10.0))
            tip = sum((verts[i] for i in tips), Vector()) / len(tips)
            clash = sum(1 for i in tips if kd.find(verts[i])[2] < 0.6) / len(tips)
            reach = wz * (tip.z - hand.palm_z) + wx * (slide - tip.x) + wy * tip.y
            gap = min(abs(d[i]) for i in tips)
            # Tucked: folded across past the index line and lying under the
            # palm rather than out on the part.
            tucked = tip.y < 1.0 and tip.z < hand.palm_z + 3.0
            # Lying flat on top beside the palm instead of pressing round the
            # part's near side.
            flat = tip.z < hand.palm_z + r.get('thumb_reach', 0.0)
            # Buried: the thumb's own segments must not pass through the part.
            buried = max(-d[i] for i in subsets[1] + subsets[2]) > 1.0
            # Straight: a thumb pressing in bends at its middle and tip joints.
            straight = self.values[0][1] + self.values[0][2] < r.get('thumb_flex', -999.0)
            if tucked or flat or buried or straight or gap > 1.5: return -100.0 + score
            world = self.world(tip); ray = world - self.eye
            hit = self.bvh.ray_cast(self.eye, ray.normalized(), ray.length)
            seen = hit[0] is None or hit[3] > ray.length - 1.0
            return score - 15.0 * clash + reach + (5.0 if gap < 0.8 else 0.0) + (6.0 if seen else 0.0)

        # For each opposition, wrap the thumb joint by joint: the base swings
        # in until the thumb meets the part, then the middle joint, then the
        # tip joint until its pad does; keep the best-scoring wrap.
        best = None
        for opp in frange(*r.get('opposition', (-30, 90)), 5):
            self.values[5] = opp; self.values[0] = [-40.0, -20.0, -20.0]
            self.wrap('Thumb', (0, (0, 1, 2)), ((-40.0, 85.0), (-20.0, 60.0), (-20.0, 70.0)), ((1, 2), (1, 2), (2,)),
                      ((0.3, 0.3), (0.8,), ()), step=2.5)
            s = evaluate()
            if best is None or s > best[0]: best = (s, opp, list(self.values[0]))
        if best[0] < -50:
            # Every wrap stopped on the part's near surface before the thumb
            # could get round it (a broad shoulder): search the thumb's joints
            # directly, the same rejections applying.
            for opp in frange(*r.get('opposition', (-30, 90)), 10):
                for cmc in frange(-40, 80, 10):
                    for mcp in frange(-20, 50, 10):
                        for ip in frange(-20, 60, 20):
                            self.values[5] = opp; self.values[0] = [cmc, mcp, ip]
                            s = evaluate()
                            if s > best[0]: best = (s, opp, list(self.values[0]))
        self.values[5] = best[1]; self.values[0] = best[2]
        if r.get('thumb_turn'):
            # Swing the thumb further round the part at its base, towards
            # the fingertips, if it stays out of the part.
            self.values[0][0] += r['thumb_turn']
            d, _ = self.distances(subsets[1] + subsets[2])
            if max(-x for x in d.values()) > 1.0: self.values[0][0] -= r['thumb_turn']
        return best[0]


def frange(a, b, step):
    out = []; x = a
    while x <= b + 1e-6: out.append(float(x)); x += step
    return out


def solve(ctx, z, side, region):
    """Try each place along the palm for the part (a thin forearm sits by
    the finger roots, a thick neck in the middle of the palm) and keep the
    one where palm, fingers and thumb together hold the most of it. The left
    hand takes the right hand's joint angles, which on its mirrored skeleton
    give the mirrored grip: the stock Zed is not quite symmetric, and a
    separate left solve can land a different shape."""
    if side == 'Left':
        right = solve(ctx, z, 'Right', region)['grip']
        g = Grip(ctx, z, side, region, right.slide)
        g.values = [list(v) for v in right.values[:5]] + [right.values[5]]
    else:
        best = None
        for slide in REGIONS[region]['slides']:
            g = Grip(ctx, z, side, region, slide)
            score = 10.0 * g.palm_contact + sum(g.close_finger(fi) for fi in range(1, 5)) + g.close_thumb()
            if best is None or score > best[0]: best = (score, g)
        g = best[1]
    hand = g.hand
    skinned = hand.skin(g.values, g.spread)
    deltas = [hand.last[hand.finger(f, j)] for f in DIGITS for j in range(1, 4)]
    world = {i: g.world(v) for i, v in skinned.items()}
    pen = {f: max(0.0, max(-signed(g.bvh, world[i]) for i in hand.segments[(f, 1)])) for f in DIGITS}
    absolute = [[round(v) for v in g.values[0]]] + [[round(g.values[fi][j] + hand.rest[f][j]) for j in range(3)]
                                                    for fi, f in enumerate(DIGITS[1:], 1)]
    return dict(grip=g, hand=hand, verts=skinned, world=world, values=g.values, deltas=deltas, absolute=absolute,
                penetration=pen, palm_contact=g.palm_contact, tilt=g.tilt, roll=g.roll, slide=g.slide,
                thumb_gap=min(abs(signed(g.bvh, world[i])) for i in hand.tip['Thumb']))


def look(cam, location, target, up):
    d = (target - location).normalized(); x = d.cross(up).normalized(); y = x.cross(d)
    cam.matrix_world = Matrix.Translation(location) @ Matrix((x, y, -d)).transposed().to_4x4()


def tube(a, b, radius, sides=12):
    """A closed cylinder from a to b: the review's stand-in for a forearm."""
    axis = (b - a).normalized(); u = axis.orthogonal().normalized(); v = axis.cross(u)
    ring = [u * math.cos(2 * math.pi * k / sides) * radius + v * math.sin(2 * math.pi * k / sides) * radius
            for k in range(sides)]
    verts = [a + o for o in ring] + [b + o for o in ring] + [a, b]
    faces = [(k, (k + 1) % sides, sides + (k + 1) % sides, sides + k) for k in range(sides)]
    faces += [(2 * sides, (k + 1) % sides, k) for k in range(sides)]
    faces += [(2 * sides + 1, sides + k, sides + (k + 1) % sides) for k in range(sides)]
    return verts, faces


def ball(c, radius, rings=10, sides=16):
    verts = [c + Vector((math.sin(math.pi * i / rings) * math.cos(2 * math.pi * k / sides),
                         math.sin(math.pi * i / rings) * math.sin(2 * math.pi * k / sides),
                         math.cos(math.pi * i / rings))) * radius for i in range(rings + 1) for k in range(sides)]
    faces = [(i * sides + k, i * sides + (k + 1) % sides, (i + 1) * sides + (k + 1) % sides, (i + 1) * sides + k)
             for i in range(rings) for k in range(sides)]
    return verts, faces


def review(ctx, z, output, side='Right', tag='', regions=ORDER):
    """Per region: sections across the part and across the fingers, views of
    the back of the hand and the fingertips, the player's own view from the
    standing eye, and a third-person side view of the reach with a forearm
    tube back to the shoulder. The neck shows both hands."""
    import bpy, bmesh
    output = Path(output); output.mkdir(parents=True, exist_ok=True)
    report = {}
    for region in regions:
        s = solve(ctx, z, side, region); g = s['grip']
        report[region] = dict(absolute=s['absolute'], additive=[[round(a) for a in v] for v in s['values'][:5]],
                              opposition=s['values'][5], palm_contact=round(s['palm_contact'], 2),
                              tilt=s['tilt'], roll=s['roll'], slide=s['slide'], thumb_gap=round(s['thumb_gap'], 2),
                              penetration={k: round(v, 2) for k, v in s['penetration'].items()})
        name = 'KF2VR grapple ' + region
        if name in bpy.data.scenes: bpy.data.scenes.remove(bpy.data.scenes[name])
        scene = bpy.data.scenes.new(name)
        hands = [(s, False)]
        if region == 'Neck':
            other = solve(ctx, z, 'Left' if side == 'Right' else 'Right', region)
            hands.append((other, True))
            report[region]['other_hand'] = other['absolute'] + [other['values'][5]]
        zp = g.z['points']
        hand = s['hand']
        target = sum((s['world'][i] for i in hand.ids), Vector()) / len(hand.ids)
        X, Y, Z = (g.A.col[k].copy() for k in range(3))
        thumb = sum((s['world'][i] for i in hand.tip['Thumb']), Vector()) / len(hand.tip['Thumb'])
        whole = [t for t in g.z['tris'] if (zp[t[0]] - target).length < 30]
        objects = {}

        def add(label, verts, faces, colour, smooth=True):
            me = bpy.data.meshes.new(region + label); me.from_pydata(verts, [], faces); me.update()
            for poly in me.polygons: poly.use_smooth = smooth
            ob = bpy.data.objects.new(me.name, me); scene.collection.objects.link(ob)
            mat = bpy.data.materials.new(me.name); mat.diffuse_color = (*colour, 1); me.materials.append(mat)
            objects[label] = ob
            return ob

        for k, (h, _) in enumerate(hands):
            hh = h['hand']; gg = h['grip']; index = {i: n for n, i in enumerate(hh.ids)}
            verts = [h['world'][i] for i in hh.ids]
            tris = [[index[a], index[b], index[c]] for a, b, c in hh.triangles if a in index and b in index and c in index]
            if gg.A.determinant() < 0: tris = [t[::-1] for t in tris]
            wrist, shoulder = gg.world(Vector()), gg.shoulder
            # The other hand was solved on the mirrored Zed, which (the Zed
            # being symmetric) already stands where the real one does.
            add('hand%d' % k, verts, tris, (.42, .3, .22))
            add('arm%d' % k, *tube(wrist, shoulder, 3.5), (.5, .42, .36), smooth=False)
        add('whole', zp, whole, (.33, .36, .3))
        add('body', zp, g.z['tris'], (.33, .36, .3))
        eye = g.eye
        add('head', *ball(eye + Vector((0, 0, 4)), 10), (.5, .42, .36))
        cam = bpy.data.objects.new(region + 'cam', bpy.data.cameras.new(region + 'cam'))
        scene.collection.objects.link(cam); scene.camera = cam
        cam.data.clip_start = .1
        scene.render.engine = 'BLENDER_WORKBENCH'
        scene.display.shading.light = 'STUDIO'; scene.display.shading.color_type = 'MATERIAL'
        scene.display.shading.show_cavity = True
        scene.render.resolution_x = 700; scene.render.resolution_y = 560
        P, up, face, left = body(g.z)
        middle = (eye + target) * 0.5
        # Views: (name, camera, aim, up, lens, Zed shown, section cut, extras shown)
        views = (('section', target - Y * 42, target, -Z, 50, 'whole', (target, Y), False),
                 ('section2', target + Y * 42, target, -Z, 50, 'whole', (target, -Y), False),
                 ('back', target - Z * 38 - X * 12 + Y * 8, target, X, 50, 'whole', None, False),
                 ('fingers', target + (X * 0.6 - Z * 0.3 + face * 0.7).normalized() * 38, target, up, 50, 'whole', None, False),
                 ('thumb', thumb - X * 40, thumb, -Z, 50, 'whole', (thumb, X), False),
                 ('player', eye, target, up, 40, 'body', None, False),
                 ('player2', eye, target, up, 40, 'body', None, False),
                 ('third2', middle - left * 150 + up * 10, middle, up, 35, 'body', None, True),
                 ('third', middle + left * 150 + up * 10, middle, up, 35, 'body', None, True))
        if len(hands) == 1: views = tuple(v for v in views if v[0] not in ('player2', 'third2'))
        for view, location, aim, vup, lens, shown, cut, extras in views:
            for ob in [o for o in scene.collection.objects if o.name.startswith(region + 'half')]:
                bpy.data.objects.remove(ob)
            objects['whole'].hide_render = shown != 'whole' or cut is not None
            objects['body'].hide_render = shown != 'body'
            objects['head'].hide_render = not extras
            for label, ob in objects.items():
                # The arm shows only in the third-person view: in game the
                # player sees floating hands.
                if label == 'arm0': ob.hide_render = view != 'third'
                elif label.startswith('arm'): ob.hide_render = view != 'third2'
                # Each hand alone in its own player and third-person views:
                # two one-handed chokes would take the same spot.
                if label == 'hand0': ob.hide_render = view in ('player2', 'third2')
                elif label.startswith('hand'): ob.hide_render = view not in ('player2', 'third2')
            if cut is not None:
                me = objects['whole'].data.copy(); me.name = region + 'half'
                bm = bmesh.new(); bm.from_mesh(me)
                bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:],
                                       plane_co=cut[0], plane_no=-cut[1], clear_outer=True)
                bm.to_mesh(me); bm.free()
                scene.collection.objects.link(bpy.data.objects.new(region + 'half', me))
            cam.data.lens = lens
            look(cam, location, aim, vup)
            scene.render.filepath = str(output / ('grapple-%s-%s%s.png' % (region, view, tag)))
            bpy.ops.render.render(write_still=True, scene=scene.name)
    (output / ('grapple-report%s.json' % tag)).write_text(json.dumps(report, indent=2))
    return report


def emit_runtime(ctx, z):
    text = ['// Melee item 15: Blade & Sorcery grapple hand poses on held Zed parts.',
            '// Generated by tools/author_grapple_grips.py: the floating hand seated palm',
            '// first on the stock Clot mesh, each finger closed to keep its segments on the',
            '// part (knuckle leading, at most 0.9 of a full close), the thumb opposing on',
            '// the far side, as B&S closes a grapple until finger contact. Fixed additive',
            '// bone-local rotations; no runtime contact solver.',
            '// Order: region (Neck, Skull, Shoulder, Limb), Left/Right, Thumb/Index/Middle/',
            '// Ring/Pinky, joints 1..3. B&S has no torso grapple; the torso uses Shoulder.',
            'class VRGrapplePose extends Object;', '',
            'const REGION_NONE = 0;', 'const REGION_NECK = 1;', 'const REGION_SKULL = 2;',
            'const REGION_SHOULDER = 3;', 'const REGION_LIMB = 4;', '',
            'var array<quat> Rotations;', '',
            'static function byte RegionForBone(name Bone)', '{', '    local string S;',
            "    if (Bone == '') return REGION_NONE;", '    S = Locs(string(Bone));',
            '    if (InStr(S, "neck") >= 0) return REGION_NECK;',
            '    if (InStr(S, "head") >= 0 || InStr(S, "jaw") >= 0) return REGION_SKULL;',
            '    if (InStr(S, "shoulder") >= 0 || InStr(S, "spine") >= 0 || InStr(S, "hips") >= 0',
            '        || InStr(S, "pelvis") >= 0 || InStr(S, "chest") >= 0) return REGION_SHOULDER;',
            '    return REGION_LIMB;', '}', '',
            'static function bool Read(byte Region, int Hand, int Joint, out quat Rotation)', '{',
            '    local int Index;',
            '    if (Region == REGION_NONE || Hand < 0 || Hand > 1 || Joint < 0 || Joint >= 15) return false;',
            '    Index = (Region - 1) * 30 + Hand * 15 + Joint;',
            '    if (Index >= default.Rotations.Length) return false;',
            '    Rotation = default.Rotations[Index];',
            "    return class'VRHandRolePose'.static.ValidQuaternion(Rotation);", '}', '',
            'defaultproperties', '{']
    index = 0; report = {}
    for region in ORDER:
        text.append('    // ' + region)
        for side in ('Left', 'Right'):
            s = solve(ctx, z, side, region)
            report[region + side] = s['absolute'] + [s['values'][5]]
            for q in s['deltas']:
                assert abs(q.magnitude - 1) < .00001
                text.append('    Rotations(%d)=(X=%.9f,Y=%.9f,Z=%.9f,W=%.9f)' % (index, q.x, q.y, q.z, q.w)); index += 1
    text += ['}', '']
    (ROOT / 'script/KF2VR/Classes/VRGrapplePose.uc').write_text('\n'.join(text), encoding='utf-8')
    return report
