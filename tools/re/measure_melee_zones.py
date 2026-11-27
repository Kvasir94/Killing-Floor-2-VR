"""Fit every melee weapon's contact zones from its stock 1P mesh.

Reads the CLI-only UModel exports under build/<slug>-audit/export (PSK, plus
the 1P PSA for the Idle hands); no game, SDK, editor or tests. Works on the
vertices used by triangles and skinned to the weapon bones (RW_* or LW_*, arms
and hands excluded), skinned into Idle frame 0 so moving parts sit where the
game shows them (the Scythe is measured folded and unfolded), in that weapon
bone's space, game convention (UModel's PSK mirrors Y; see melee_rig.py).

Method. The weapon is cut by planes along its long axis (+Z for hafted and
bladed weapons) every 0.5 uu, intersecting triangles, so each cut is the true
cross-section. Per cut: width (larger extent across), thickness (smaller
extent), centroid and radius. The Idle hands seed the handle; the zones then
follow the mesh:

- handle: the contiguous run of cuts around the Idle fists whose width stays
  within 1.5x+1 uu of the gripped width and whose thickness stays above half
  of it (the slide track).
- blade (sword, knife, scythe): the first run above the handle that is flat
  (thickness under half the handle's) for 3 uu or more; it runs to the tip.
- guard: wide runs between the handle top and the blade start; narrow runs
  between two guards are a ricasso.
- head (axe, blunt): the run around the widest cut above the handle where the
  width stays at least half of that maximum; fitted along its own principal
  axis (so an axe head runs across the shaft).
- edge (axe): each bit at an end of the head whose end cut is at least half
  the head's height, as a capsule along the bit.
- point: the blade tip, or a spike above an axe head, or an axe's back pick;
  tip is the mean of the vertices within 0.5 uu of the farthest one and the
  stab axis runs from the centroid of the last 6 uu to it.
- pommel: from the butt end to the bottom of the lower Idle fist (at least
  the last 2.5 uu); `knob` when the butt is wider than the handle.
- shaft: from the top of the upper Idle fist to the head, guard or blade.
- reach: extent along the axis and the farthest vertex from the Idle grip.
Gauntlets use +X (forward along the forearm): the head is the knuckle face
(the front 6 uu). The shield is fitted as a disc.

Capsules are {start, end, radius}: the segment ends sit at the zone's
geometric extremes along its axis and the radius is the 80th percentile of the
per-cut (or per-vertex for heads) distance from that segment, as in
measure_melee_head.py. Curved blades also get `segments`, shorter capsules
that follow the centroid curve within 1 uu.

Manual overrides found by checking renders in Blender are in OVERRIDES below,
each with its reason, and are copied into the JSON.

  python -I tools/re/measure_melee_zones.py [slug ...]   (default: all)
writes build/<slug>-audit/melee_zones.json.
"""
from pathlib import Path
import json
import math
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from melee_rig import (BUILD, Rig, Anim, anim_path, dot, sub, add, scale, norm, unit,  # noqa: E402
                       cross, r, principal, basis, slice_mesh, section_stats)

KNIVES = ("knife-berserker", "knife-commando", "knife-demolitionist", "knife-fieldmedic",
          "knife-firebug", "knife-gunslinger", "knife-sharpshooter", "knife-support",
          "knife-survivalist", "knife-swat")

# slug -> [(weapon bone, kind)]
WEAPONS = {
    "edged-katana": [("RW_Weapon", "sword")],
    "edged-zweihander": [("RW_Weapon", "sword")],
    "edged-ionthruster": [("RW_Weapon", "sword")],
    "edged-fireaxe": [("RW_Weapon", "axe")],
    "edged-abominationaxe": [("RW_Weapon", "axe")],
    # Stock starts folded (bIsFolded=true): a per-bone blend holds RW_Fold at
    # idle_folded (140 deg from bind); unfolded it follows the attack anims
    # (45 deg, as idle_unfolded). Measure both.
    "edged-scythe": [("RW_Weapon", "scythe", "idle_unfolded"), ("RW_Weapon", "scythe", "idle_folded")],
    "crovel": [("RW_Weapon", "blunt")],
    "pulverizer": [("RW_Weapon", "blunt")],
    "blunt-chainbat": [("RW_Weapon", "blunt")],
    "blunt-medicbat": [("RW_Weapon", "blunt")],
    "blunt-maceandshield": [("RW_Weapon", "blunt"), ("LW_Weapon", "shield")],
    "blunt-powergloves": [("RW_Weapon", "gauntlet"), ("LW_Weapon", "gauntlet")],
    "blastbrawlers": [("RW_Weapon", "gauntlet"), ("LW_Weapon", "gauntlet")],
    **{k: [("RW_Weapon", "knife")] for k in KNIVES},
}

# (slug, bone) -> {zone: replacement or None, "reason": text}. Filled from the
# Blender review; every entry is copied into the JSON under "overrides".
OVERRIDES = {}

STEP = 0.5
FINGERS = ("Index", "Middle", "Ring", "Pinky")


def fist(rig, side, bone, pos, rot):
    """Idle fist centre (mean of the finger 1 and 2 joints) and the span of the
    knuckles along the weapon's long axis, in weapon-bone game space."""
    pts = [rig.to_local(bone, pos[rig.index[f"{side}Hand{f}{j}_1stP"]], pos, rot)
           for f in FINGERS for j in (1, 2)]
    return scale(tuple(map(sum, zip(*pts))), 1.0 / len(pts)), pts


def line_fit(centroids):
    if len(centroids) < 3:
        return scale(tuple(map(sum, zip(*centroids))), 1.0 / len(centroids)), (0.0, 0.0, 1.0)
    c, v = principal(centroids)
    return c, (v if v[2] >= 0 else scale(v, -1))


def seg_dist(p, a, b):
    ab = sub(b, a); L = dot(ab, ab)
    t = 0.0 if L == 0 else max(0.0, min(1.0, dot(sub(p, a), ab) / L))
    return norm(sub(p, add(a, scale(ab, t))))


def pct(values, q):
    v = sorted(values)
    return v[int(q * (len(v) - 1))] if v else 0.0


class Part:
    def __init__(self, rig, bone, kind, pose=None, axis=None, skip=(), only=None):
        self.rig, self.bone, self.kind = rig, bone, kind
        pts = rig.weapon_points(bone, pose=pose, skip=skip, only=only)
        assert pts, f"{rig.slug}: no vertices skinned to {bone[:3]} bones"
        self.local = {p: v for v, p, _ in pts}
        self.material = {p: m for _, p, m in pts}
        self.tris = [t for t, _ in rig.weapon_triangles(set(self.local))]
        self.axis = (1.0, 0.0, 0.0) if kind == "gauntlet" else (0.0, 0.0, 1.0)
        if axis is not None:
            self.axis = axis
        self.t0, self.planes = slice_mesh(self.local, self.tris, self.axis, step=STEP)
        self.cuts = [section_stats(p, self.axis) for p in self.planes]
        self.z = [self.t0 + k * STEP for k in range(len(self.planes))]
        for k, c in enumerate(self.cuts):
            if c:
                c["thickness"] = min(c["width1"], c["width2"])

    def k_of(self, z):
        return max(0, min(len(self.cuts) - 1, int(round((z - self.t0) / STEP))))

    def points_between(self, a, b):
        """Section points and vertices with axis coordinate in [a, b]."""
        out = [q for k in range(self.k_of(a), self.k_of(b) + 1) for q in self.planes[k]]
        out += [v for v in self.local.values() if a <= dot(v, self.axis) <= b]
        return out

    def capsule(self, a, b, note=""):
        """Capsule along the centroid line of the cuts in [a, b]."""
        ks = [k for k in range(self.k_of(a), self.k_of(b) + 1) if self.cuts[k]]
        cents = [self.cuts[k]["centroid"] for k in ks]
        c, v = line_fit(cents)
        if dot(v, self.axis) < 0.5:
            v = self.axis
        def at(z):
            return add(c, scale(v, (z - dot(c, self.axis)) / dot(v, self.axis)))
        start, end = at(a), at(b)
        radial = [max(seg_dist(q, start, end) for q in self.planes[k]) for k in ks]
        out = dict(start=r(start), end=r(end), radius=round(pct(radial, 0.8), 2),
                   length=round(b - a, 2), axis_range=[round(a, 2), round(b, 2)])
        if note:
            out["evidence"] = note
        segs = blade_segments(self, ks, cents[0], cents[-1]) if len(ks) > 4 else None
        if segs:
            out["segments"] = segs
        return out

    def head_capsule(self, pts, toward=None, across=None):  # self unused; callable unbound
        """Capsule along the region's own principal axis (measure_melee_head);
        `across` keeps that axis perpendicular to a given direction (an axe
        head across its haft). Also records the region's extents along its
        three principal axes, so a flat part (a shovel blade) is visible."""
        c, axis = principal(pts, remove=(across,) if across else ())
        if toward is not None and dot(axis, toward) < 0:
            axis = scale(axis, -1)
        proj = [dot(sub(p, c), axis) for p in pts]
        start, end = add(c, scale(axis, min(proj))), add(c, scale(axis, max(proj)))
        radial = [norm(sub(sub(p, c), scale(axis, dot(sub(p, c), axis)))) for p in pts]
        _, a2 = principal(pts, remove=(axis,))
        a3 = unit(cross(axis, a2))
        ext = [max(dot(p, a) for p in pts) - min(dot(p, a) for p in pts) for a in (axis, a2, a3)]
        return dict(start=r(start), end=r(end), radius=round(pct(radial, 0.8), 2),
                    axis=r(axis, 3), length=round(max(proj) - min(proj), 2),
                    extents=[round(e, 2) for e in ext], extent_axes=[r(axis, 3), r(a2, 3), r(a3, 3)]), c, axis

    def point(self, direction, length=6.0, region=None):
        pts = region if region is not None else list(self.local.values())
        far = max(dot(p, direction) for p in pts)
        tipv = [p for p in pts if dot(p, direction) >= far - 0.5]
        tip = scale(tuple(map(sum, zip(*tipv))), 1.0 / len(tipv))
        back = [p for p in pts if far - length <= dot(p, direction) <= far - 0.5]
        base = scale(tuple(map(sum, zip(*back))), 1.0 / len(back)) if back else sub(tip, direction)
        axis = unit(sub(tip, base))
        near = [norm(sub(sub(p, tip), scale(axis, dot(sub(p, tip), axis)))) for p in back
                if dot(sub(p, tip), axis) > -2.0]
        return dict(tip=r(tip), axis=r(axis, 3), base=r(base),
                    radius_2uu_from_tip=round(max(near), 2) if near else 0.0)

    def profile(self):
        rows = []
        for k in range(0, len(self.cuts), 2):
            c = self.cuts[k]
            if c:
                rows.append([round(self.z[k], 1), round(c["width"], 2), round(c["thickness"], 2),
                             round(c["centroid"][0], 2), round(c["centroid"][1], 2), round(c["centroid"][2], 2)])
        return rows


def idle_fists(rig, bone):
    path, source = anim_path(rig.slug)
    if not path:
        return None, None
    anim = Anim(path)
    pos, rot = anim.pose(rig, "Idle", 0)
    return {side: fist(rig, side, bone, pos, rot) for side in ("Right", "Left")}, source


def fit_long(part, fists, kind):
    """Handle, guard, blade/head, point, pommel, shaft and reach for a long weapon."""
    cuts, z = part.cuts, part.z
    valid = [k for k, c in enumerate(cuts) if c]
    lo_k, hi_k = valid[0], valid[-1]
    zones, notes = {}, []
    on = {}
    for side, (centre, pts) in fists.items():
        k = part.k_of(centre[2])
        c = cuts[k]
        off = norm(sub((centre[0], centre[1], 0), (c["centroid"][0], c["centroid"][1], 0))) if c else 1e9
        on[side] = bool(c) and off <= c["radius"] + 3.5
    gripped = [s for s in fists if on[s]] or ["Right"]
    spans = [(min(p[2] for p in fists[s][1]), max(p[2] for p in fists[s][1])) for s in gripped]
    seed = [k for a, b in spans for k in range(part.k_of(a), part.k_of(b) + 1) if cuts[k]]
    w_h = pct([cuts[k]["width"] for k in seed], 0.5)
    th_h = pct([cuts[k]["thickness"] for k in seed], 0.5)
    # A bladed weapon's guard can be a small step (a knife's is ~1.7x the
    # grip); a haft's rings and wraps are not a head.
    wide_at = (1.3 * w_h + 0.5) if kind in ("sword", "knife") else (1.5 * w_h + 1.0)
    # Flat: a sword blade is under half the grip's thickness. Knife
    # handles are slim, so a knife blade is under 3/4 of it and at least
    # 3x as wide as thick.
    def flat(c):
        if not c or kind not in ("sword", "knife", "scythe"):
            return False
        if kind == "knife":
            return c["thickness"] < 0.75 * th_h and c["width"] >= 3.0 * c["thickness"]
        return c["thickness"] < 0.5 * th_h
    def handle_like(k):
        c = cuts[k]
        return (c is not None and c["width"] <= wide_at and c["thickness"] >= 0.5 * th_h
                and not flat(c))
    k0 = k1 = int(round(sum(seed) / len(seed)))
    while k0 - 1 >= lo_k and handle_like(k0 - 1):
        k0 -= 1
    while k1 + 1 <= hi_k and handle_like(k1 + 1):
        k1 += 1
    zones["handle"] = part.capsule(z[k0], z[k1], f"gripped width {w_h:.1f}, thickness {th_h:.1f} uu")
    lower = min(gripped, key=lambda s: fists[s][0][2])
    upper = max(gripped, key=lambda s: fists[s][0][2])
    lower_bottom = min(p[2] for p in fists[lower][1])
    upper_top = max(p[2] for p in fists[upper][1])

    # Above the handle.
    if kind == "scythe":
        # The snath alone (the blade is fitted from RW_Fold by fit_scythe):
        # everything above the hand grip is the blade mount.
        if hi_k > k1 + 1:
            zones["collar"] = part.capsule(z[k1 + 1], z[hi_k], "blade mount above the snath grip (RW_Weapon part)")
    elif kind in ("sword", "knife"):
        k = k1 + 1
        while k <= hi_k:
            run = [cuts[j] for j in range(k, min(hi_k, k + int(3 / STEP)) + 1)]
            if all(flat(c) for c in run):
                break
            k += 1
        blade_k = k
        # A hand guard stands well proud of the grip: 2x for swords, 1.5x for
        # the smaller knife guards.
        guard_at = (1.5 if kind == "knife" else 2.0) * w_h
        guards, ricasso, j = [], [], k1 + 1
        while j < blade_k:
            wide = bool(cuts[j] and cuts[j]["width"] > guard_at)
            e = j
            while e + 1 < blade_k and bool(cuts[e + 1] and cuts[e + 1]["width"] > guard_at) == wide:
                e += 1
            (guards if wide else ricasso).append((j, e))
            j = e + 1
        for n, (a, b) in enumerate(guards):
            pts = part.points_between(z[a], z[b])
            cap, _, _ = part.head_capsule([(p[0], p[1], p[2]) for p in pts])
            ext = [max(cuts[i]["width"] for i in range(a, b + 1) if cuts[i])]
            cap.update(axis_range=[round(z[a], 2), round(z[b], 2)], width=round(ext[0], 2))
            zones["guard" if n == 0 else f"guard{n + 1}"] = cap
        for a, b in ricasso:
            if not guards or a < guards[0][1] or (b - a + 1) * STEP < 2.0:
                continue
            between = any(g[0] > b for g in guards)
            name = "ricasso" if between else "collar"
            zones[name] = part.capsule(z[a], z[b], "narrow run between two guards" if between
                                       else "narrow run between the guard and the flat blade")
        if blade_k <= hi_k:
            blade = part.points_between(z[blade_k], z[hi_k] + STEP)
            if True:
                start = cuts[blade_k]["centroid"]
                tip = part.point((0.0, 0.0, 1.0), region=blade)
                end = tuple(tip["tip"])
                ks = [k for k in range(blade_k, hi_k + 1) if cuts[k]]
                radial = [max(seg_dist(q, start, end) for q in part.planes[k]) for k in ks]
                zones["head"] = dict(start=r(start), end=r(end), radius=round(pct(radial, 0.8), 2),
                                     length=round(norm(sub(end, start)), 2),
                                     axis_range=[round(z[blade_k], 2), round(z[hi_k], 2)],
                                     evidence="flat blade: thickness under half the handle's")
                segs = blade_segments(part, ks, start, end)
                if segs:
                    zones["head"]["segments"] = segs
                tip = part.point(unit(sub(end, start)), region=blade)
                # Stab along the blade; the tip's own taper leans toward the
                # spine on single-edged blades.
                tip["taper_axis"] = tip["axis"]
                tip["axis"] = r(unit(sub(end, start)), 3)
                zones["point"] = tip
        else:
            notes.append("no flat blade found above the handle")
    else:
        above = [k for k in range(k1 + 1, hi_k + 1) if cuts[k]]
        if above:
            kmax = max(above, key=lambda k: cuts[k]["width"])
            # An axe head tapers into its eye; a mace's sleeve is not head.
            thr = (0.3 if kind == "axe" else 0.5) * cuts[kmax]["width"]
            a = b = kmax
            while a - 1 > k1 and cuts[a - 1] and cuts[a - 1]["width"] >= thr:
                a -= 1
            while b + 1 <= hi_k and cuts[b + 1] and cuts[b + 1]["width"] >= thr:
                b += 1
            head = part.points_between(z[a], z[b])
            cap, c, axis = part.head_capsule(head, across=part.axis if kind == "axe" else None)
            cap["axis_range"] = [round(z[a], 2), round(z[b], 2)]
            cap["evidence"] = f"run around the widest cut ({cuts[kmax]['width']:.1f} uu) at >= half width"
            zones["head"] = cap
            if kind == "axe":
                zones.update(axe_bits(part, head, c, axis))
            if b < hi_k and (hi_k - b) * STEP >= 3.0:
                spike = part.points_between(z[b], z[hi_k] + STEP)
                p = part.point((0.0, 0.0, 1.0), region=spike)
                if kind == "axe" or p["radius_2uu_from_tip"] < 2.5:
                    p["evidence"] = "spike above the head"
                    zones["point"] = p
                else:
                    zones["top"] = part.capsule(z[b], z[hi_k], "part above the head")
            if a - 1 > k1 and (a - 1 - k1) * STEP >= 2.0:
                zones["collar"] = part.capsule(z[k1 + 1], z[a - 1], "between the handle and the head, wider than the handle")
    # Below the handle: pommel / butt.
    bottom = z[lo_k]
    pom_top = max(lower_bottom, bottom + 2.5)
    if pom_top > bottom:
        cap = part.capsule(bottom, min(pom_top, z[hi_k]), "butt end below the lower Idle fist")
        widest = max(cuts[k]["width"] for k in range(lo_k, part.k_of(pom_top) + 1) if cuts[k])
        cap["knob"] = widest > 1.15 * w_h
        cap["widest"] = round(widest, 2)
        zones["pommel"] = cap
    top_start = z[min(k1 + 1, hi_k)]
    if top_start - upper_top >= 3.0 and kind not in ("sword", "knife"):
        zones["shaft"] = part.capsule(upper_top, top_start, "handle above the upper Idle fist, up to the first wider part")
    grip = scale(add(fists[lower][0], fists[upper][0]), 0.5) if len(gripped) > 1 else fists[gripped[0]][0]
    far = max(part.local.values(), key=lambda p: norm(sub(p, fists["Right"][0])))
    zones["reach"] = dict(axis_min=round(z[lo_k], 2), axis_max=round(z[hi_k], 2),
                          length=round(z[hi_k] - z[lo_k], 2),
                          far_point_from_main_fist=r(far),
                          from_main_fist=round(norm(sub(far, fists["Right"][0])), 2),
                          tip_along_axis_from_main_fist=round(z[hi_k] - fists["Right"][0][2], 2))
    meta = dict(gripped_width=round(w_h, 2), gripped_thickness=round(th_h, 2),
                idle_fists={s: dict(centre=r(fists[s][0]), axis_span=[round(min(p[2] for p in fists[s][1]), 2),
                                                                       round(max(p[2] for p in fists[s][1]), 2)],
                                    on_weapon=on[s]) for s in fists},
                lower_hand=lower, upper_hand=upper, notes=notes)
    return zones, meta


def fit_scythe(rig, bone, pose):
    """The Scythe's blade hangs off RW_Fold, across or along the snath, so it
    is cut along its own principal axis, oriented from the fold pivot to the
    tip, and fitted as a curved capsule with segments."""
    pts = [v for v, _, _ in rig.weapon_points(bone, pose=pose, only={"RW_Fold"})]
    pivot = rig.to_local(bone, pose[0][rig.index["RW_Fold"]], *pose)
    c, axis = principal(pts)
    proj = [dot(sub(p, c), axis) for p in pts]
    lo = min(zip(proj, pts))[1]; hi = max(zip(proj, pts))[1]
    if norm(sub(lo, pivot)) > norm(sub(hi, pivot)):
        axis = scale(axis, -1)
    cap, c, _ = Part.head_capsule(None, pts, toward=axis)
    cap["evidence"] = "blade skinned to RW_Fold, along its own axis from the fold pivot"
    # The crescent is too wide for one capsule to follow, so its cutting
    # edge is traced: per 2 uu cut along the blade, the boundary point on the
    # concave side, which faces the snath grip, starting 5 uu past the fold
    # pivot (nearer in, the trace runs up the mount's heel, not an edge).
    blade = Part(rig, bone, "blade", pose, axis=axis, only={"RW_Fold"})
    _, normal = principal(pts)
    normal = unit(cross(axis, principal(pts, remove=(axis,))[1]))
    inward = unit(cross(normal, axis))
    grip = rig.to_local(bone, pose[0][rig.index["RightHand_1stP"]], *pose)
    if dot(sub(grip, c), inward) < 0:
        inward = scale(inward, -1)
    trace = []
    for k in range(0, len(blade.planes), 4):
        if blade.planes[k]:
            p = max(blade.planes[k], key=lambda p: dot(p, inward))
            if dot(sub(p, pivot), axis) >= 5.0:
                trace.append(p)
    line = simplify(trace, 1.0)
    edge = dict(polyline=[r(p) for p in line], radius=1.5, facing=r(inward, 3),
                evidence="concave boundary of the blade, toward the snath grip, simplified to 1 uu")
    tip = blade.point(axis)
    tip["evidence"] = "far end of the blade from the fold pivot"
    return dict(head=cap, edge=edge, point=tip, fold_pivot=dict(at=r(pivot)))


def simplify(points, tol):
    """Douglas-Peucker."""
    if len(points) < 3:
        return points
    a, b = points[0], points[-1]
    d = [seg_dist(p, a, b) for p in points[1:-1]]
    i = max(range(len(d)), key=d.__getitem__)
    if d[i] <= tol:
        return [a, b]
    return simplify(points[:i + 2], tol)[:-1] + simplify(points[i + 1:], tol)


def inset(zone):
    """Ends pulled in by the radius (at most half the length), so the capsule
    surface ends at the geometry instead of a radius past it."""
    if "start" not in zone or "radius" not in zone:
        return
    a, b = zone["start"], zone["end"]
    d = sub(b, a); L = norm(d)
    k = min(zone["radius"], L * 0.5)
    if L > 0:
        u = scale(d, 1.0 / L)
        zone["inset_start"] = r(add(a, scale(u, k)))
        zone["inset_end"] = r(sub(b, scale(u, k)))


def blade_segments(part, ks, start, end, tol=1.0):
    """Split a curved blade into capsules whose chord stays within tol of the
    centroid curve."""
    cents = [part.cuts[k]["centroid"] for k in ks]
    def dev(i, j):
        return max(seg_dist(cents[m], cents[i], cents[j]) for m in range(i, j + 1))
    if dev(0, len(cents) - 1) <= tol:
        return None
    cuts, i = [], 0
    while i < len(cents) - 1:
        j = len(cents) - 1
        while j > i + 1 and dev(i, j) > tol:
            j = (i + j) // 2 if dev(i, (i + j) // 2) > tol else j - max(1, (j - i) // 8)
        cuts.append((i, j)); i = j
    out = []
    for i, j in cuts:
        a, b = cents[i], cents[j] if j < len(cents) - 1 else end
        radial = [max(seg_dist(q, a, b) for q in part.planes[ks[m]]) for m in range(i, j + 1)]
        out.append(dict(start=r(a), end=r(b), radius=round(pct(radial, 0.8), 2)))
    return out


def axe_bits(part, head, c, axis):
    """Bits (cutting edges) and back picks at the ends of an axe head."""
    proj = [dot(sub(p, c), axis) for p in head]
    lo, hi = min(proj), max(proj)
    out = {}
    height = max(p[2] for p in head) - min(p[2] for p in head)
    for name, sign, ext in (("plus", 1, hi), ("minus", -1, lo)):
        band = max(3.0, 0.15 * (hi - lo))
        end = [p for p, t in zip(head, proj) if sign * (ext - t) <= band]
        if len(end) < 3:
            continue
        h = max(p[2] for p in end) - min(p[2] for p in end)
        d = scale(axis, sign)
        if h >= 0.5 * height:
            ec, ev = principal(end, remove=(axis,))
            ep = [dot(sub(p, ec), ev) for p in end]
            s, e = add(ec, scale(ev, min(ep))), add(ec, scale(ev, max(ep)))
            if e[2] < s[2]:
                s, e = e, s
            radial = [seg_dist(p, s, e) for p in end]
            out[f"edge_{name}"] = dict(start=r(s), end=r(e), radius=round(pct(radial, 0.8), 2),
                                       facing=r(d, 3), height=round(h, 2),
                                       evidence="bit: end of the head at least half the head's height")
        else:
            p = part.point(d, region=head)
            p["evidence"] = f"back pick: end of the head {h:.1f} uu tall"
            out[f"pick_{name}"] = p
    return out


def fit_gauntlet(part, fists, bone):
    side = "Right" if bone.startswith("RW") else "Left"
    pts = list(part.local.values())
    front = max(p[0] for p in pts)
    face = [p for p in pts if p[0] >= front - 6.0]
    cap, c, axis = part.head_capsule(face)
    cap["evidence"] = "knuckle face: the front 6 uu along +X"
    body, _, _ = part.head_capsule(pts, toward=(1.0, 0.0, 0.0))
    centre = fists[side][0]
    far = max(pts, key=lambda p: p[0])
    zones = dict(head=cap, body=body,
                 reach=dict(axis_min=round(min(p[0] for p in pts), 2), axis_max=round(front, 2),
                            length=round(front - min(p[0] for p in pts), 2),
                            far_point_from_main_fist=r(far),
                            front_ahead_of_fist=round(front - centre[0], 2)))
    meta = dict(idle_fists={side: dict(centre=r(centre))}, notes=[])
    return zones, meta


def fit_shield(part, fists):
    pts = list(part.local.values())
    c, a1 = principal(pts)
    _, a2 = principal(pts, remove=(a1,))
    normal = unit(cross(a1, a2))
    hand = fists["Left"][0]
    if dot(sub(hand, c), normal) > 0:
        normal = scale(normal, -1)
    inplane = [norm(sub(sub(p, c), scale(normal, dot(sub(p, c), normal)))) for p in pts]
    along = [dot(sub(p, c), normal) for p in pts]
    front = max(along)
    R = pct(inplane, 0.98)
    # The plate's outer surface, read on its outer half (the boss spikes
    # stand proud of it near the centre).
    rim = sorted(a for a, d in zip(along, inplane) if d >= 0.5 * R)
    plate = rim[int(0.9 * (len(rim) - 1))]
    zones = dict(face=dict(centre=r(add(c, scale(normal, plate))), normal=r(normal, 3), radius=round(R, 2),
                           thickness=round(plate - min(along), 2), body_centre=r(c),
                           spikes_front=r(add(c, scale(normal, front))),
                           spikes_proud_of_plate=round(front - plate, 2),
                           evidence="disc: plane of the two largest axes; normal away from the left fist; "
                                    "centre on the plate's outer surface (90th percentile over its outer half)"),
                 reach=dict(radius=round(max(inplane), 2)))
    meta = dict(idle_fists={"Left": dict(centre=r(hand), behind_face=round(front - dot(sub(hand, c), normal), 2))},
                notes=[])
    return zones, meta


def measure(slug):
    rig = Rig(slug)
    out = dict(slug=slug, psk=str(rig.psk.relative_to(BUILD.parent)).replace("\\", "/"),
               space="game convention (UModel PSK Y negated), weapon-bone local, Unreal units",
               parts=[])
    path, source = anim_path(slug)
    anim = Anim(path) if path else None
    for bone, kind, *mode in WEAPONS[slug]:
        # Skin the mesh into Idle frame 0 (or the named mode pose): moving
        # parts sit as the game shows them, not as authored in the bind pose.
        seq = mode[0] if mode else "Idle"
        pose = anim.pose(rig, seq, 0) if anim else None
        part = Part(rig, bone, kind, pose, skip={"RW_Fold"} if kind == "scythe" else ())
        fists, source = idle_fists(rig, bone)
        if kind == "gauntlet":
            zones, meta = fit_gauntlet(part, fists, bone)
        elif kind == "shield":
            zones, meta = fit_shield(part, fists)
        else:
            zones, meta = fit_long(part, fists, kind)
        if kind == "scythe":
            zones.update(fit_scythe(rig, bone, pose))
            # Reach over the whole scythe, blade included.
            every = [v for v, _, _ in rig.weapon_points(bone, pose=pose)]
            grip = tuple(meta["idle_fists"]["Right"]["centre"])
            far = max(every, key=lambda p: norm(sub(p, grip)))
            zones["reach"].update(far_point_from_main_fist=r(far), from_main_fist=round(norm(sub(far, grip)), 2),
                                  note="axis_min/max are the snath; far point includes the blade")
        for zone in zones.values():
            inset(zone)
        over = OVERRIDES.get((slug, bone), {})
        applied = []
        for name, value in over.items():
            if name == "reason":
                continue
            if value is None:
                zones.pop(name, None)
            else:
                zones[name] = value
            applied.append(name)
        entry = dict(bone=bone, kind=kind, mesh_pose=f"{seq} frame 0" if anim else "bind",
                     mode=(mode[0].replace("idle_", "") if mode else None), long_axis=list(part.axis), anim_source=source,
                     vertices=len(part.local), triangles=len(part.tris), zones=zones, **meta,
                     profile_columns=["axis", "width", "thickness", "cx", "cy", "cz"],
                     profile=part.profile())
        if applied:
            entry["overrides"] = dict(zones=applied, reason=over.get("reason", ""))
        out["parts"].append(entry)
    path = BUILD / f"{slug}-audit/melee_zones.json"
    path.write_text(json.dumps(out, indent=1) + "\n", encoding="utf-8")
    return out


def summary(out):
    for p in out["parts"]:
        line = [f"{out['slug']}:{p['bone']} ({p['kind']})"]
        for name, zone in p["zones"].items():
            if "start" in zone:
                line.append(f"  {name:<10} {zone['start']} -> {zone['end']} r={zone['radius']}")
            elif "tip" in zone:
                line.append(f"  {name:<10} tip={zone['tip']} axis={zone['axis']}")
            elif "normal" in zone:
                line.append(f"  {name:<10} centre={zone['centre']} n={zone['normal']} R={zone['radius']}")
            else:
                line.append(f"  {name:<10} {zone}")
        print("\n".join(line))


if __name__ == "__main__":
    for slug in (sys.argv[1:] or list(WEAPONS)):
        summary(measure(slug))
