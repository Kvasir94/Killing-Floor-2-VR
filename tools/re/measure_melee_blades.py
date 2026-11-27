"""Measure every cutting/striking head of the stock melee weapons in cross-section.

Phase 1 of the VR melee plan (#227): runtime-ready hurtbox segments that follow
each blade's curve and taper, with the cutting edge, the spine and the flats
told apart, plus the stabbing points (Kvasir94, 2026-11-09: the edge slices,
flats/spines/hilts bludgeon, points pierce). Offline: reads the CLI-only
UModel exports under build/<slug>-audit/export (no game, SDK or editor) and the
zone fits in docs/re/melee-zones/<slug>-zones.json (measure_melee_zones.py) for
the blade starts, tips and haft axes.

Space: RW_Weapon bone space, game convention (UModel's PSK mirrors Y;
melee_rig.game), Unreal units. The mesh is skinned into Idle frame 0, as
measure_melee_zones.py does; the Scythe is measured FOLDED (idle_folded), the
mode VR holds it in.

Method (docs/re/MELEE_WEAPON_ZONES_AND_GRIPS.md, "Blade edges", has the
results and limits).
1. Region per weapon: a sword or knife blade from where measure_melee_zones
   found it flat to the tip; an axe bit is the head beyond its cheeks (haft
   radius + 1.5 uu); the Scythe's blade is the largest connected piece of
   RW_Fold (the crescent, without the bolted back plate) outside 8 uu of the
   fold pivot; the Crovel's shovel is everything above its head start.
2. Cuts every 0.5 uu, intersecting the triangles (true cross-sections). A
   first pass cuts normal to the blade chord (the Scythe: planes radiating from
   a point inside its crescent); then the blade is re-cut twice normal to its
   own centre curve (the width midpoints, smoothed over 5 uu), each plane
   keeping only the points near its station. Per cut a rotating caliper finds
   the thinnest direction (flat normal) and the width across it (axe heads and
   the Scythe lie in the XZ plane: their flat normal is fixed to Y). Axe bits
   keep straight cuts along the haft, with the centreline on the cheek line.
3. Edge side: the thickness of the outer 20% of the width at each end; a
   cutting edge closes to a few tenths of a uu, a spine stays near full
   thickness. The blade's edge side is the thinner end by the median over all
   cuts; per segment both ends under 45% of the thickness = double edged, and
   ends within 25% of each other = `ambiguous` (geometry alone cannot tell).
   Axes, the Scythe and the Crovel take the side from their layout. Every
   blade is then checked against the stock attacks (swing_check): the motion
   of the blade's middle in weapon space over the fastest quarter of each
   Atk_/Combo_ sequence leads with the edge.
4. Teeth: each segment is re-cut every 0.1 uu and the extent toward the edge
   and the spine compared with a +-1 uu running mean; three or more teeth
   deeper than 0.08 uu = a serrated edge or a saw-backed spine.
5. Segments: the cuts are split at the cut of largest error (centre off the
   chord + edge direction turned, as uu at the edge + reach off a linear
   taper) until it is under max(0.3 uu, 1% of the length), 2 to 6 segments,
   none shorter than max(1.5 uu, 8% of the length). The centreline is a
   continuous polyline through the smoothed width midpoints at the segment
   boundaries, ending at the blade tip.
6. Per segment, from the segment line to the section points: edge_reach (max
   over the segment) and edge_reach_start/end (at its ends, for a tapered
   slab), spine_reach likewise, half_thickness (max). Measured geometry; any
   extra generosity is the runtime's choice.
7. OVERRIDES: corrections from the Blender review, each with its reason,
   copied into the JSON.

  python -I tools/re/measure_melee_blades.py [slug ...]   (default: all)
writes docs/re/melee-zones/<slug>-blade.json and
build/melee-zone-review/blade-data/<slug>.json (mesh, UVs, texture and
segments for melee_zone_review.render_blades / blade_sheet).
"""
from pathlib import Path
import json
import math
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from melee_rig import (ROOT, BUILD, Rig, Anim, anim_path, dot, sub, add, scale, norm, unit,  # noqa: E402
                       cross, r, principal, slice_mesh, game, rotate, conj)

ZONES = ROOT / "docs/re/melee-zones"
REVIEW = BUILD / "melee-zone-review/blade-data"
STEP = 0.5
SCHEMA_VERSION = 1

KNIVES = ("knife-berserker", "knife-commando", "knife-demolitionist", "knife-fieldmedic",
          "knife-firebug", "knife-gunslinger", "knife-sharpshooter", "knife-support",
          "knife-survivalist", "knife-swat")

# slug -> (mode pose or None, kind). Kinds: sword/knife (blade above the
# guard, edge side from geometry), scythe (folded crescent), axe (bits and
# back), crovel (shovel + claw), points (point entries only).
SPECS = {
    "edged-katana": (None, "sword"),
    "edged-zweihander": (None, "sword"),
    "edged-ionthruster": (None, "sword"),
    "edged-scythe": ("idle_folded", "scythe"),
    "edged-fireaxe": (None, "axe"),
    "edged-abominationaxe": (None, "axe"),
    "crovel": (None, "crovel"),
    "blunt-medicbat": (None, "points"),
    **{k: (None, "knife") for k in KNIVES},
}

# (slug, entry name) -> {field: value, "reason": why}. Applied after the
# measurement, every entry copied into the JSON under "overrides". Filled from
# the Blender review (side, edge-on and end-on renders).
OVERRIDES = {
    ("knife-support", "blade"): dict(
        flip_edge=True,
        reason="the blade is modelled as a flat 0.23 uu slab, so the thickness test cannot see the bevel; the "
               "edge is the curved belly (+X): the stock knife attacks (shared Commando anim set) lead with +X "
               "(swing check 1/15 before the flip), the -X side carries saw teeth along its length (side and "
               "close-up renders), and +X thins slightly toward the tip"),
    ("edged-ionthruster", "blade"): dict(
        double=True, flip_edge=True,
        reason="the mesh blade is a symmetric 2.3 x 0.8 uu bar with no bevel on either side (end thickness ratios "
               "0.54/0.55); it is an energy blade, so both sides cut. edge_dir is turned to +X, the side the stock "
               "attacks lead with (13 of 16)"),
    ("knife-firebug", "blade"): {
        "segments.0,1.edge_texture": "serrated",
        "reason": "teeth on the concave (cutting) side next to the finger ring, seen in the side close-up; they sit "
                  "where the ring's geometry hides them from the silhouette tooth count"},
    ("knife-demolitionist", "blade"): {
        "segments.3.edge_texture": "serrated",
        "reason": "stepped teeth on the straight +X edge 22-27 uu up, seen in the side close-up (too shallow for "
                  "the silhouette tooth count). +X is the edge although the -X side angles to the tip like a "
                  "tanto: +X carries the modelled bevel (outer tenth 0.00-0.06 uu thick against 0.15) and the "
                  "stock knife attacks lead with +X"},
    ("edged-scythe", "blade"): {
        "segments.0.edge_texture": None, "segments.*.spine": "spiked",
        "reason": "the four 'teeth' on segment 0 are the fold gear's rim beside the blade's heel, not "
                  "serrations; the crescent's convex back carries thorns along its whole length (about z 32, 10, "
                  "-5 and -24 in the folded side render), so its spine is 'spiked' rather than plain"},
    ("crovel", "shovel_sides"): {
        "segments.1,2,3.edge_texture": "serrated", "segments.1,2,3.spine_texture": "serrated",
        "reason": "both long sides of the shovel are saw-toothed from about z 25 to 40 (side render); the short "
                  "segment 1 falls under the tooth count's window"},
}


def pct(values, q):
    v = sorted(values)
    return v[int(q * (len(v) - 1))] if v else 0.0


def median(values):
    return pct(values, 0.5)


def mean(points):
    return scale(tuple(map(sum, zip(*points))), 1.0 / len(points))


def perp(v, axis):
    return sub(v, scale(axis, dot(v, axis)))


def seg_closest(p, a, b):
    ab = sub(b, a); L = dot(ab, ab)
    t = 0.0 if L == 0 else max(0.0, min(1.0, dot(sub(p, a), ab) / L))
    return add(a, scale(ab, t)), t


def angle(u, v):
    return math.degrees(math.acos(max(-1.0, min(1.0, dot(unit(u), unit(v))))))


def load_zones(slug, mode=None):
    data = json.loads((ZONES / f"{slug}-zones.json").read_text(encoding="utf-8"))
    for p in data["parts"]:
        if p["bone"] == "RW_Weapon" and (mode is None or p.get("mode") == mode.replace("idle_", "")):
            return p
    raise KeyError(slug)


class Mesh:
    """Weapon vertices skinned into the measuring pose, RW_Weapon game space."""

    def __init__(self, slug, mode=None):
        self.rig = Rig(slug)
        path, _ = anim_path(slug)
        anim = Anim(path)
        self.seq = mode or "Idle"
        self.pose = anim.pose(self.rig, self.seq, 0)
        pts = self.rig.weapon_points("RW_Weapon", pose=self.pose)
        self.local = {p: v for v, p, _ in pts}
        self.bone_of = {p: self.rig.bones[self.rig.owner[p]]["name"] for _, p, _ in pts}

    def region(self, keep, any_vertex=False):
        """Vertices passing keep(point id, position) and the triangles wholly
        inside; with any_vertex, every weapon triangle touching one (long
        blade triangles often start below the blade's first cut), with its
        other vertices added."""
        ids = {p for p, v in self.local.items() if keep(p, v)}
        if any_vertex:
            tris = [t for t, _ in self.rig.weapon_triangles(set(self.local)) if any(p in ids for p in t)]
            ids |= {p for t in tris for p in t}
        else:
            tris = [t for t, _ in self.rig.weapon_triangles(ids)]
        return {p: self.local[p] for p in ids}, tris

    def islands(self, ids):
        """Connected pieces (welded positions) of the triangles among ids,
        largest first, as sets of point ids."""
        par = {}
        def find(x):
            while par.setdefault(x, x) != x:
                par[x] = par[par[x]]
                x = par[x]
            return x
        key = {p: tuple(round(c, 2) for c in self.local[p]) for p in ids}
        for t, _ in self.rig.weapon_triangles(set(ids)):
            a = find(key[t[0]])
            for q in t[1:]:
                b = find(key[q])
                par[b] = a
                a = find(a)
        out = {}
        for p in ids:
            out.setdefault(find(key[p]), set()).add(p)
        return sorted(out.values(), key=len, reverse=True)

    def bone_origin(self, bone):
        return self.rig.to_local("RW_Weapon", self.pose[0][self.rig.index[bone]], *self.pose)


# ---------------------------------------------------------------- sections

def caliper(points, axis, ref_n=None):
    """Thinnest direction in the cut plane (flat normal n), the width
    direction w across it, both unit and perpendicular to axis. n keeps the
    sign of ref_n when given."""
    a = (1.0, 0.0, 0.0) if abs(axis[0]) < 0.9 else (0.0, 1.0, 0.0)
    e1 = unit(perp(a, axis)); e2 = cross(axis, e1)
    xy = [(dot(p, e1), dot(p, e2)) for p in points]
    best = None
    for k in range(180):
        t = math.radians(k)
        c, s = math.cos(t), math.sin(t)
        proj = [x * c + y * s for x, y in xy]
        ext = max(proj) - min(proj)
        if best is None or ext < best[0]:
            best = (ext, t)
    t = best[1]
    n = add(scale(e1, math.cos(t)), scale(e2, math.sin(t)))
    if ref_n is not None and dot(n, ref_n) < 0:
        n = scale(n, -1)
    w = unit(cross(n, axis))
    return n, w


def section(points, axis, ref_n=None, flat=None):
    """Width, thickness, the width midpoint and the end thicknesses of one cut."""
    if len(points) < 4:
        return None
    if flat is not None:   # the layout fixes the flats (axe heads, the scythe)
        n = unit(perp(flat, axis))
        w = unit(cross(n, axis))
    else:
        n, w = caliper(points, axis, ref_n)
    pw = [dot(p, w) for p in points]
    pn = [dot(p, n) for p in points]
    lo, hi = min(pw), max(pw)
    width = hi - lo
    thick = max(pn) - min(pn)
    if width < 1e-3:
        return None
    band = 0.2 * width
    def end_thickness(sel):
        v = [b for a, b in zip(pw, pn) if sel(a)]
        return (max(v) - min(v)) if len(v) > 1 else 0.0
    t_hi = end_thickness(lambda a: a >= hi - band)
    t_lo = end_thickness(lambda a: a <= lo + band)
    centre_axis = mean(points)
    mid = add(add(scale(w, (lo + hi) / 2), scale(n, (max(pn) + min(pn)) / 2)),
              scale(axis, dot(centre_axis, axis)))
    return dict(n=n, w=w, lo=lo, hi=hi, width=width, thickness=thick, t_hi=t_hi, t_lo=t_lo,
                mid=mid, points=points)


def cut_blade(local, tris, axis, origin=(0.0, 0.0, 0.0), keep=None, flat=None):
    """Cuts along axis; keep(cut points) -> points filters each cut (the
    region's own bounds when the triangles reach past it)."""
    t0, planes = slice_mesh(local, tris, axis, origin=origin, step=STEP)
    cuts, ref = [], None
    for k, pts in enumerate(planes):
        if keep:
            pts = keep(pts)
        s = section(pts, axis, ref, flat)
        if s:
            ref = s["n"]
            s["t"] = t0 + k * STEP + dot(origin, axis)
            s["o"] = scale(axis, s["t"])
            cuts.append(s)
    return cuts


def plane_cut(tris, o, t, near):
    """Section points of triangles (lists of three positions, with their
    bounding centre and radius) with the plane through o normal to t,
    keeping only triangles whose bound comes within `near` of o."""
    out = []
    for (c, rad, tri) in tris:
        if norm(sub(c, o)) > near + rad:
            continue
        d = [dot(sub(v, o), t) for v in tri]
        for i in range(3):
            j = (i + 1) % 3
            if d[i] * d[j] <= 0 and d[i] != d[j]:
                f = d[i] / (d[i] - d[j])
                out.append(add(tri[i], scale(sub(tri[j], tri[i]), f)))
    return out


def cut_curved(local, tris, cuts, keep=None, passes=2, smooth=10, flat=None):
    """Re-cut a blade normal to its own centre curve: the width midpoints of
    the previous cuts, smoothed over `smooth` cuts (5 uu), resampled every
    STEP of arc length; each plane keeps only the section points within the
    local width of the station (a curved blade's plane can meet it twice).
    The cut's t is the arc length from the first station."""
    bound = []
    for tri in tris:
        vs = [local[p] for p in tri]
        c = mean(vs)
        bound.append((c, max(norm(sub(v, c)) for v in vs), vs))
    for _ in range(passes):
        mids = [c["mid"] for c in cuts]
        sm = []
        for i in range(len(mids)):
            a, b = max(0, i - smooth // 2), min(len(mids), i + smooth // 2 + 1)
            sm.append(mean(mids[a:b]))
        sm[0], sm[-1] = mids[0], mids[-1]
        widths = [c["width"] for c in cuts]
        # Resample by arc length.
        arc = [0.0]
        for p, q in zip(sm, sm[1:]):
            arc.append(arc[-1] + norm(sub(q, p)))
        stations, k = [], 0
        s_val = 0.0
        while s_val <= arc[-1] + 1e-6:
            while k < len(arc) - 2 and arc[k + 1] < s_val:
                k += 1
            seg = max(arc[k + 1] - arc[k], 1e-9)
            f = min(1.0, max(0.0, (s_val - arc[k]) / seg))
            o = add(sm[k], scale(sub(sm[k + 1], sm[k]), f))
            a, b = max(0, k - 2), min(len(sm) - 1, k + 3)
            tan = unit(sub(sm[b], sm[a]))
            stations.append((s_val, o, tan, max(widths[a:b + 1])))
            s_val += STEP
        new, ref = [], cuts[0]["n"]
        for s_val, o, tan, wmax in stations:
            near = 0.75 * wmax + 1.0
            pts = [p for p in plane_cut(bound, o, tan, near) if norm(sub(p, o)) <= near]
            if keep:
                pts = keep(pts)
            s = section(pts, tan, ref, flat)
            if s:
                ref = s["n"]
                s["t"], s["o"] = s_val, o
                new.append(s)
        cuts = new
    return cuts


def orient_edge(cuts, edge_hint=None):
    """Point every cut's w toward the edge side. With edge_hint (a direction,
    or a callable(cut) -> direction) the layout decides; otherwise the side
    whose outer 20% is thinner, by the median over all cuts after aligning
    w between neighbours. Returns per-cut ratios for the evidence."""
    for i in range(1, len(cuts)):
        if dot(cuts[i]["w"], cuts[i - 1]["w"]) < 0:
            flip(cuts[i])
    if edge_hint is not None:
        for s in cuts:
            h = edge_hint(s) if callable(edge_hint) else edge_hint
            if dot(s["w"], h) < 0:
                flip(s)
        return
    hi = median([s["t_hi"] / max(s["thickness"], 1e-3) for s in cuts])
    lo = median([s["t_lo"] / max(s["thickness"], 1e-3) for s in cuts])
    if lo < hi:
        for s in cuts:
            flip(s)


def flip(s):
    s["w"] = scale(s["w"], -1)
    s["lo"], s["hi"] = -s["hi"], -s["lo"]
    s["t_lo"], s["t_hi"] = s["t_hi"], s["t_lo"]


def edge_off(c):
    """Edge-side extent of a cut from its station on the centre path."""
    return c["hi"] - dot(c["o"], c["w"])


def spine_off(c):
    return dot(c["o"], c["w"]) - c["lo"]


def texture(values, window=6, depth=0.25):
    """Teeth along a side: local maxima of the residual from a running mean
    deeper than `depth` uu (alternating with minima). Returns the count."""
    if len(values) < 2 * window + 3:
        return 0
    res = []
    for i in range(len(values)):
        a, b = max(0, i - window), min(len(values), i + window + 1)
        res.append(values[i] - sum(values[a:b]) / (b - a))
    teeth, state = 0, 0
    for v in res:
        if v > depth and state <= 0:
            teeth += 1; state = 1
        elif v < -depth and state >= 0:
            state = -1
    return teeth


# ---------------------------------------------------------------- segments

def split(cuts, length, min_segs=2, max_segs=6):
    """Boundary cut indices: recursive split at the cut of largest error."""
    tol = max(0.3, 0.01 * length)
    min_len = max(1.5, 0.08 * length)
    def err(i, j):
        a, b = cuts[i]["mid"], cuts[j]["mid"]
        worst, at = 0.0, None
        for m in range(i + 1, j):
            if cuts[m]["t"] - cuts[i]["t"] < min_len or cuts[j]["t"] - cuts[m]["t"] < min_len:
                continue
            f = (m - i) / (j - i)
            c, _ = seg_closest(cuts[m]["mid"], a, b)
            e = norm(sub(cuts[m]["mid"], c))
            # Edge direction turned, as uu at the edge.
            wi = add(scale(cuts[i]["w"], 1 - f), scale(cuts[j]["w"], f))
            e += math.radians(angle(cuts[m]["w"], wi)) * edge_off(cuts[m]) if norm(wi) > 0 else 0
            # Reach off a linear taper.
            rh = cuts[i]["width"] * (1 - f) + cuts[j]["width"] * f
            e += abs(cuts[m]["width"] - rh) * 0.5
            if e > worst:
                worst, at = e, m
        return worst, at
    bounds = [0, len(cuts) - 1]
    while len(bounds) - 1 < max_segs:
        best = None
        for i, j in zip(bounds, bounds[1:]):
            if cuts[j]["t"] - cuts[i]["t"] < 2 * min_len:
                continue
            e, m = err(i, j)
            if m is not None and (best is None or e > best[0]):
                best = (e, m)
        if best is None and len(bounds) - 1 < min_segs:
            best = (0.0, None)
        if best is None or (best[0] <= tol and len(bounds) - 1 >= min_segs):
            break
        if best[0] <= tol or best[1] is None:   # straight: halve the longest for the minimum count
            i, j = max(zip(bounds, bounds[1:]), key=lambda ij: ij[1] - ij[0])
            best = (0, (i + j) // 2)
        bounds = sorted(set(bounds + [best[1]]))
    return bounds


def smooth_mid(cuts, k, span=2):
    a, b = max(0, k - span), min(len(cuts), k + span + 1)
    return mean([c["mid"] for c in cuts[a:b]])


def build_segments(cuts, tip=None, double=None, spine_label=None):
    length = cuts[-1]["t"] - cuts[0]["t"]
    bounds = split(cuts, length)
    nodes = [smooth_mid(cuts, k) for k in bounds]
    nodes[0] = smooth_mid(cuts, 1, span=1)   # the first three cuts: a guard remnant can skew the very first
    if tip is not None:
        nodes[-1] = tuple(tip)
    segs = []
    for n, (i, j) in enumerate(zip(bounds, bounds[1:])):
        a, b = nodes[n], nodes[n + 1]
        ax = unit(sub(b, a))
        group = cuts[i:j + 1]
        w = unit(perp(mean([c["w"] for c in group]), ax))
        fn = unit(cross(ax, w))   # always axis x edge_dir (component-wise cross product)
        per_cut = []
        for c in group:
            ev, sv, th = 0.0, 0.0, 0.0
            for p in c["points"]:
                q, _ = seg_closest(p, a, b)
                d = sub(p, q)
                ev = max(ev, dot(d, w)); sv = max(sv, -dot(d, w)); th = max(th, abs(dot(d, fn)))
            per_cut.append((ev, sv, th))
        mid_cut = group[len(group) // 2]
        def proj(p):
            q, _ = seg_closest(p, a, b)
            return [round(dot(sub(p, q), w), 3), round(dot(sub(p, q), fn), 3)]
        section_2d = dict(t=round(mid_cut["t"], 2), points=[proj(p) for p in mid_cut["points"]])
        ratio_e = median([c["t_hi"] / max(c["thickness"], 1e-3) for c in group])
        ratio_s = median([c["t_lo"] / max(c["thickness"], 1e-3) for c in group])
        dbl = double if double is not None else (ratio_e < 0.45 and ratio_s < 0.45)
        ambiguous = (not dbl and double is None and ratio_s - ratio_e < 0.25 * max(ratio_s, 1e-3))
        head = per_cut[:max(1, len(per_cut) // 5)]
        tail = per_cut[-max(1, len(per_cut) // 5):]
        seg = dict(
            index=n, start=r(a), end=r(b), axis=r(ax, 4), length=round(norm(sub(b, a)), 2),
            arc_range=[round(group[0]["t"], 2), round(group[-1]["t"], 2)],
            edge_dir=r(w, 4), flat_normal=r(fn, 4),
            edge_reach=round(max(e for e, _, _ in per_cut), 2),
            edge_reach_start=round(max(e for e, _, _ in head), 2),
            edge_reach_end=round(max(e for e, _, _ in tail), 2),
            spine_reach=round(max(s for _, s, _ in per_cut), 2),
            spine_reach_start=round(max(s for _, s, _ in head), 2),
            spine_reach_end=round(max(s for _, s, _ in tail), 2),
            half_thickness=round(max(t for _, _, t in per_cut), 2),
            edges="both" if dbl else "one",
            spine="edge" if dbl else (spine_label or "plain"),
            edge_end_thickness_ratio=round(ratio_e, 2), spine_end_thickness_ratio=round(ratio_s, 2),
            ambiguous=bool(ambiguous), _section=section_2d)
        segs.append(seg)
    return segs


def teeth(local, tris, seg, step=0.1, window=1.0, depth=0.08):
    """Teeth along each side of one segment: the mesh is cut every `step` uu
    across the segment, the extent toward the edge and toward the spine
    taken per cut, and each compared with its running mean over +-window uu;
    a tooth is a rise of more than `depth` uu above it followed by a fall
    below. (The 0.5 uu measuring cuts alias saw teeth about 1 uu apart.)
    Returns (edge teeth, spine teeth)."""
    a, b = tuple(seg["start"]), tuple(seg["end"])
    ax, w = unit(sub(b, a)), tuple(seg["edge_dir"])
    L = norm(sub(b, a))
    reach = max(seg["edge_reach"], seg["spine_reach"]) + 1.0
    bound = []
    for tri in tris:
        vs = [local[p] for p in tri]
        c = mean(vs)
        bound.append((c, max(norm(sub(v, c)) for v in vs), vs))
    ev, sv = [], []
    t = step / 2
    while t < L:
        o = add(a, scale(ax, t))
        pts = [q for q in plane_cut(bound, o, ax, reach * 1.5) if norm(perp(sub(q, o), ax)) <= reach * 1.5]
        if pts:
            ev.append(max(dot(sub(q, o), w) for q in pts))
            sv.append(max(-dot(sub(q, o), w) for q in pts))
        t += step
    win = max(2, int(window / step))
    return texture(ev, win, depth), texture(sv, win, depth)


def blade_entry(name, cuts, tip=None, double=None, damage="slash", note="", spine_label=None, region=None):
    segs = build_segments(cuts, tip, double, spine_label)
    for s in segs:
        if region is None:
            continue
        et, st = teeth(*region, s)
        s["edge_teeth"], s["spine_teeth"] = et, st
        if et >= 3:
            s["edge_texture"] = "serrated"
        if st >= 3:
            if s["spine"] == "plain":
                s["spine"] = "saw"
            elif s["spine"] == "edge":
                s["spine_texture"] = "serrated"
    return dict(name=name, type="blade", damage=damage,
                edges="both" if all(s["edges"] == "both" for s in segs) else
                      ("one" if all(s["edges"] == "one" for s in segs) else "mixed"),
                spine=sorted({s["spine"] for s in segs}),
                length=round(cuts[-1]["t"] - cuts[0]["t"], 2), cuts=len(cuts),
                ambiguous=any(s["ambiguous"] for s in segs),
                evidence=note, segments=segs)


def point_entry(name, pts, direction, length=6.0, note="", damage="pierce"):
    far = max(dot(p, direction) for p in pts)
    tipv = [p for p in pts if dot(p, direction) >= far - 0.5]
    tip = mean(tipv)
    back = [p for p in pts if far - length <= dot(p, direction) <= far - 0.5]
    base = mean(back) if back else sub(tip, direction)
    axis = unit(sub(tip, base))
    near = [norm(perp(sub(p, tip), axis)) for p in pts if -2.0 <= dot(sub(p, tip), axis) <= 0]
    return dict(name=name, type="point", damage=damage, tip=r(tip), axis=r(axis, 4), base=r(base),
                radius_2uu_from_tip=round(max(near), 2) if near else 0.0, evidence=note)


# ---------------------------------------------------------------- weapons

def pre(slug, name, key, default=None):
    """A measuring-time override (flip_edge, double) from OVERRIDES."""
    return OVERRIDES.get((slug, name), {}).get(key, default)


def measure_sword(mesh, zones, kind):
    head, tip = zones["zones"]["head"], zones["zones"]["point"]
    z0 = head["axis_range"][0]
    axis = unit(sub(tuple(head["end"]), tuple(head["start"])))
    local, tris = mesh.region(lambda p, v: v[2] >= z0 + 0.25, any_vertex=True)
    cuts = cut_blade(local, tris, axis, keep=lambda pts: [q for q in pts if q[2] >= z0 - 0.01])
    # Drop leading cuts that are not yet blade-like (a guard or collar
    # remnant: under 2.5x as wide as thick), at most the first 3 uu.
    while len(cuts) > 8 and cuts[0]["t"] - z0 < 3.0 and cuts[0]["width"] < 2.5 * cuts[0]["thickness"]:
        cuts.pop(0)
    cuts = cut_curved(local, tris, cuts, keep=lambda pts: [q for q in pts if q[2] >= z0 - 0.01])
    while len(cuts) > 8 and cuts[0]["t"] < 3.0 and cuts[0]["width"] < 2.5 * cuts[0]["thickness"]:
        cuts.pop(0)
    orient_edge(cuts)
    if pre(mesh.rig.slug, "blade", "flip_edge"):
        for c in cuts:
            flip(c)
    blade = blade_entry("blade", cuts, tip=tip["tip"], region=(local, tris),
                        double=pre(mesh.rig.slug, "blade", "double"),
                        note=f"blade from z {z0} (measure_melee_zones flat-blade start) to the tip, first cut along "
                             f"the blade chord {r(axis, 3)}, then along its own centre curve")
    last = tuple(blade["segments"][-1]["axis"])
    hooked = angle(last, tuple(tip["axis"])) > 25.0
    pt = dict(name="tip", type="point", damage="pierce", tip=tip["tip"],
              axis=tip["taper_axis"] if hooked else tip["axis"], chord_axis=tip["axis"],
              taper_axis=tip["taper_axis"], last_segment_axis=list(last),
              evidence="blade tip (measure_melee_zones point); axis = the base-to-tip chord, or for a hooked "
                       "tip (last segment more than 25 deg off the chord: the Firebug karambit) the taper of the last 6 uu")
    return [blade, pt], dict(blade_axis=r(axis, 4)), local, tris


# The folded Scythe's crescent wraps around the gap in front of the snath,
# so it is first cut by planes radiating from a point inside that gap
# (SCYTHE_CENTRE, x/z game space, read off the folded side render), from the
# fold gear round to the tip, then re-cut along its own centre curve.
SCYTHE_CENTRE = (-10.0, 0.0, 12.0)
SCYTHE_GEAR_RADIUS = 8.0


def cut_radial(local, tris, centre, a0, a1, step_deg=1.0, keep=None, flat=None):
    bound = []
    for tri in tris:
        vs = [local[p] for p in tri]
        c = mean(vs)
        bound.append((c, max(norm(sub(v, c)) for v in vs), vs))
    cuts, ref = [], None
    a = a0
    while a <= a1:
        rad = math.radians(a)
        ray = (math.cos(rad), 0.0, math.sin(rad))
        tan = (-math.sin(rad), 0.0, math.cos(rad))
        pts = [q for q in plane_cut(bound, centre, tan, 200.0) if dot(sub(q, centre), ray) > 0]
        if keep:
            pts = keep(pts)
        sec = section(pts, tan, ref, flat)
        if sec:
            ref = sec["n"]
            sec["t"], sec["o"] = a, sec["mid"]
            cuts.append(sec)
        a += step_deg
    return cuts


def measure_scythe(mesh, zones):
    zn = zones["zones"]
    pivot = tuple(zn["fold_pivot"]["at"])
    tip = tuple(zn["point"]["tip"])
    C = SCYTHE_CENTRE
    def ang(v):
        d = math.degrees(math.atan2(v[2] - C[2], v[0] - C[0]))
        return d if d > 0 else d + 360.0
    # The crescent is the largest connected piece of RW_Fold; the bolted
    # back plate and its straps are separate pieces.
    fold = {p for p in mesh.local if mesh.bone_of[p] == "RW_Fold"}
    crescent = mesh.islands(fold)[0]
    def blade_vertex(p, v):
        return p in crescent and norm(sub(v, pivot)) >= SCYTHE_GEAR_RADIUS
    local, tris = mesh.region(blade_vertex)
    keep = lambda pts: [q for q in pts if norm(sub(q, pivot)) >= SCYTHE_GEAR_RADIUS]
    a0 = min(ang(v) for v in local.values() if ang(v) < 180)
    cuts = cut_radial(local, tris, C, a0, ang(tip), keep=keep, flat=(0.0, 1.0, 0.0))
    cuts = cut_curved(local, tris, cuts, keep=keep, flat=(0.0, 1.0, 0.0))
    orient_edge(cuts, lambda c: sub(C, c["mid"]))
    blade = blade_entry("blade", cuts, tip=list(tip), double=False, region=(local, tris),
                        note="RW_Fold crescent, folded (idle_folded), from the fold gear (outside "
                             f"{SCYTHE_GEAR_RADIUS} uu of the pivot) to the tip; first cut radially about "
                             f"{list(SCYTHE_CENTRE)} (inside the crescent's gap), then along its own centre curve; "
                             "edge = the concave inner side, toward the snath")
    pt = dict(name="tip", type="point", damage="pierce", tip=zn["point"]["tip"], axis=zn["point"]["axis"],
              evidence="far end of the folded blade")
    return [blade, pt], dict(fold_pivot=r(pivot)), local, tris


def haft_axis(zones):
    h = zones["zones"]["handle"]
    return dict(start=h["start"], end=h["end"], axis=r(unit(sub(tuple(h["end"]), tuple(h["start"]))), 4))


def measure_axe(mesh, zones, slug):
    zn = zones["zones"]
    za, zb = zn["head"]["axis_range"]
    # The cheeks: the head beyond the haft's radius plus 1 uu.
    cheek = zn["handle"]["radius"] + 1.5
    entries, keep = [], {}
    for side, sign in (("plus", 1), ("minus", -1)):
        sel = lambda p, v, s=sign: za - 0.01 <= v[2] <= zb + 0.5 and s * v[0] >= cheek
        if f"edge_{side}" in zn:
            local, tris = mesh.region(sel, any_vertex=True)
            # Straight cuts along the haft: each is the bit's wedge from the
            # cheek out to the edge. The centreline is the cheek line itself
            # (x = +-cheek, parallel to the haft), so every segment is a slab
            # from the haft out to the edge, edge_dir +-X, and the segments
            # follow the edge's profile through edge_reach_start/end.
            ycentre = (zn["handle"]["start"][1] + zn["handle"]["end"][1]) / 2
            cuts = cut_blade(local, tris, (0.0, 0.0, 1.0), flat=(0.0, 1.0, 0.0),
                             keep=lambda pts, s=sign: [q for q in pts if s * q[0] >= cheek - 0.01
                                                       and za - 0.01 <= q[2] <= zb + 0.5])
            orient_edge(cuts, (float(sign), 0.0, 0.0))
            for c in cuts:
                c["mid"] = c["o"] = (sign * cheek, ycentre, c["t"])
            e = blade_entry(f"bit_{side}", cuts, double=False, spine_label="haft", region=(local, tris),
                            note=f"axe bit: head beyond x {sign * cheek:+.1f} (haft radius + 1.5), cut along +Z; "
                                 f"centreline on the cheek line; edge = the end away from the haft "
                                 f"({'+' if sign > 0 else '-'}X)")
            entries.append(e); keep.update(local)
        elif f"pick_{side}" in zn:
            local, tris = mesh.region(sel)
            pt = point_entry(f"back_pick", list(local.values()), (float(sign), 0.0, 0.0),
                             note="back pick: the head's short end, farthest along "
                                  f"{'+' if sign > 0 else '-'}X; axis = taper of its last 6 uu")
            pt["region_extent"] = dict(z=[round(min(v[2] for v in local.values()), 2),
                                          round(max(v[2] for v in local.values()), 2)])
            entries.append(pt); keep.update(local)
    if "point" in zn:
        local, _ = mesh.region(lambda p, v: v[2] >= zb - 0.5 and abs(v[0]) < cheek + 3)
        pt = point_entry("top_spike", list(local.values()), (0.0, 0.0, 1.0),
                         note="spike above the head, farthest along +Z")
        entries.append(pt); keep.update(local)
    _, tris = mesh.region(lambda p, v: p in keep)
    return entries, dict(haft=haft_axis(zones)), keep, tris


def measure_crovel(mesh, zones):
    zn = zones["zones"]
    za, zb = zn["head"]["axis_range"]
    local, tris = mesh.region(lambda p, v: v[2] >= za - 0.01)
    pts = list(local.values())
    c, a1 = principal(pts)
    _, a2 = principal(pts, remove=(a1,))
    normal = unit(cross(a1, a2))
    if normal[1] < 0:
        normal = scale(normal, -1)
    length_axis = unit(perp((0.0, 0.0, 1.0), normal))
    width_axis = unit(cross(normal, length_axis))
    pl = [dot(sub(p, c), length_axis) for p in pts]
    pw = [dot(sub(p, c), width_axis) for p in pts]
    pn = [dot(sub(p, c), normal) for p in pts]
    plate = dict(name="shovel_plate", type="plate", centre=r(c), normal=r(normal, 4),
                 length_axis=r(length_axis, 4), width_axis=r(width_axis, 4),
                 length_range=[round(min(pl), 2), round(max(pl), 2)],
                 width_range=[round(min(pw), 2), round(max(pw), 2)],
                 thickness_range=[round(min(pn), 2), round(max(pn), 2)], damage="blunt",
                 evidence="shovel region (z >= measure_melee_zones head start); normal = least principal axis; "
                          "the plate faces bludgeon")
    cuts = cut_blade(local, tris, length_axis)
    orient_edge(cuts, width_axis)
    sides = blade_entry("shovel_sides", cuts, double=True, region=(local, tris),
                        note="shovel cut along its length: both long sides are edges (stock light attack "
                             "KFDT_Slashing_Crovel)")
    # The far edge: the boundary at the top of the shovel, per 1 uu strip
    # across the width, the point farthest along the length axis.
    strips = {}
    for p, l, w in zip(pts, pl, pw):
        k = int(math.floor(w))
        if k not in strips or l > strips[k][0]:
            strips[k] = (l, p)
    rim = [strips[k][1] for k in sorted(strips)]
    tip_l = max(pl)
    far = [p for p in rim if dot(sub(p, c), length_axis) >= tip_l - 6.0]
    poly = simplify(far, 0.5)
    far_edge = dict(name="far_edge", type="edge_line", damage="slash", polyline=[r(p) for p in poly],
                    outward=r(length_axis, 4), half_thickness=round((max(pn) - min(pn)) / 2, 2),
                    evidence="top boundary of the shovel (farthest along its length per 1 uu strip across, "
                             "within 6 uu of the top), simplified to 0.5 uu")
    # Crowbar claw at the butt.
    claw_region, _ = mesh.region(lambda p, v: v[2] <= zn["pommel"]["axis_range"][1])
    claw_pts = list(claw_region.values())
    entries = [plate, sides, far_edge]
    keep = dict(local); keep.update(claw_region)
    _, alltris = mesh.region(lambda p, v: p in keep)
    return entries, dict(haft=haft_axis(zones)), keep, alltris, claw_pts


def simplify(points, tol):
    if len(points) < 3:
        return points
    a, b = points[0], points[-1]
    d = [norm(sub(p, seg_closest(p, a, b)[0])) for p in points[1:-1]]
    i = max(range(len(d)), key=d.__getitem__)
    if d[i] <= tol:
        return [a, b]
    return simplify(points[:i + 2], tol)[:-1] + simplify(points[i + 1:], tol)


def claw_point(pts, zones):
    """The crowbar claw: the butt hooks out to +X and back, ending in a
    forked claw that points along -X (read off the side render). Tip = the
    vertices within 0.5 uu of the farthest along -X; axis = taper of the last
    4 uu; the fork's two prongs are recorded across Y."""
    e = point_entry("claw", pts, (-1.0, 0.0, 0.0), length=4.0,
                    note="crowbar claw at the butt: the hook's end, farthest along -X; axis = taper of its last "
                         "4 uu; forked across Y (prongs)")
    far = min(p[0] for p in pts)
    tipv = [p for p in pts if p[0] <= far + 0.5]
    for name, sel in (("prong_plus_y", lambda p: p[1] > 0.3), ("prong_minus_y", lambda p: p[1] < -0.3)):
        side = [p for p in tipv if sel(p)]
        if side:
            e.setdefault("prongs", []).append(dict(name=name, tip=r(mean(side))))
    e["width_across"] = round(max(p[1] for p in tipv) - min(p[1] for p in tipv), 2)
    return e


def measure(slug):
    mode, kind = SPECS[slug]
    zones = load_zones(slug, mode)
    mesh = Mesh(slug, mode)
    extra = {}
    claw = None
    if kind in ("sword", "knife"):
        entries, extra, local, tris = measure_sword(mesh, zones, kind)
    elif kind == "scythe":
        entries, extra, local, tris = measure_scythe(mesh, zones)
    elif kind == "axe":
        entries, extra, local, tris = measure_axe(mesh, zones, slug)
    elif kind == "crovel":
        entries, extra, local, tris, claw = measure_crovel(mesh, zones)
        entries.append(claw_point(claw, zones))
    else:   # Medic Bat: the front syringe
        zb = zones["zones"]["head"]["axis_range"][1]
        local, tris = mesh.region(lambda p, v: v[2] >= zb)
        entries = [point_entry("syringe_tip", list(local.values()), (0.0, 0.0, 1.0),
                               note="front syringe above the bat head, farthest along +Z; axis = taper of its "
                                    "last 6 uu")]
    swing_check(slug, mode, entries)
    applied = []
    for e in entries:
        over = OVERRIDES.get((slug, e["name"]))
        if not over:
            continue
        for key, value in over.items():
            if key in ("reason", "flip_edge", "double"):   # applied while measuring
                continue
            if key.startswith("segments."):
                _, idx, field = key.split(".")
                for sg in e["segments"]:
                    if idx == "*" or str(sg["index"]) in idx.split(","):
                        if value is None:
                            sg.pop(field, None)
                        else:
                            sg[field] = value
            else:
                e[key] = value
        e.setdefault("overrides", []).append(dict({k: v for k, v in over.items() if k != "reason"},
                                                  reason=over["reason"]))
        applied.append(e["name"])
    for e in entries:
        if e["type"] != "blade":
            continue
        segs = e["segments"]
        e["edges"] = ("both" if all(sg["edges"] == "both" for sg in segs) else
                      "one" if all(sg["edges"] == "one" for sg in segs) else "mixed")
        e["spine"] = sorted({sg["spine"] for sg in segs})
        e["ambiguous"] = any(sg["ambiguous"] for sg in segs)
        # Kvasir94's ruling (2026-11-09): the edge slices; flats, spines and
        # the haft side bludgeon; a spine that is a second edge slices.
        e.pop("damage", None)
        for sg in segs:
            sg["edge_damage"] = "slash"
            sg["spine_damage"] = "slash" if sg["spine"] == "edge" else "blunt"
            sg["flat_damage"] = "blunt"
        sc = e.get("swing_check")
        if any("flip_edge" in o or "double" in o for o in e.get("overrides", [])):
            src = "override (visual review)"
        elif kind == "axe":
            src = "layout (the bit's end away from the haft)"
        elif kind == "scythe":
            src = "layout (the crescent's concave side, toward the snath)"
        elif kind == "crovel":
            src = "layout (both long sides of the shovel)"
        elif sc and sc["on_edge_side"] >= 0.75 * sc["attacks"]:
            src = "geometry (thinner side), confirmed by the stock swing check"
        else:
            src = "geometry (thinner side)"
        e["edge_side_source"] = src
    out = dict(slug=slug, schema_version=SCHEMA_VERSION, bone="RW_Weapon",
               space="RW_Weapon bone space, game convention (UModel PSK Y negated), Unreal units",
               mesh_pose=f"{mesh.seq} frame 0", mode=(mode.replace("idle_", "") if mode else None),
               kind=kind, **extra, entries=entries)
    def public(o):
        if isinstance(o, dict):
            return {k: public(v) for k, v in o.items() if not k.startswith("_")}
        if isinstance(o, list):
            return [public(v) for v in o]
        return o
    (ZONES / f"{slug}-blade.json").write_text(json.dumps(public(out), indent=1) + "\n", encoding="utf-8")
    REVIEW.mkdir(parents=True, exist_ok=True)
    every, _ = mesh.region(lambda p, v: True)
    ids = {p: i for i, p in enumerate(every)}
    tris, uvs = review_uvs(mesh.rig, ids)
    texdir = BUILD / f"melee-blade-tex/{slug}"
    tex = sorted(texdir.rglob("*_D.png")) if texdir.exists() else []
    review = dict(slug=slug, kind=kind, verts=[r(v) for v in every.values()], tris=tris, uvs=uvs,
                  texture=str(tex[0]) if tex else None, entries=entries)
    (REVIEW / f"{slug}.json").write_text(json.dumps(review), encoding="utf-8")
    return out


def review_uvs(rig, ids):
    """Weapon triangles (indices into the review vertex list) with their
    per-corner UVs from the PSK wedges, so the review can show the diffuse
    texture (edge bevels and saw teeth are often painted, not modelled)."""
    from audit_flamethrower_assets import chunks
    import struct
    mesh = chunks(rig.psk)
    wedges = list(struct.iter_unpack("<IffBBH", mesh["VTXW0000"][2]))
    faces = list(struct.iter_unpack("<3HBBI", mesh["FACE0000"][2]))
    tris, uvs = [], []
    for f in faces:
        pts = [wedges[f[i]][0] for i in range(3)]
        if all(p in ids for p in pts):
            tris.append([ids[p] for p in pts])
            uvs.append([[round(wedges[f[i]][1], 4), round(wedges[f[i]][2], 4)] for i in range(3)])
    return tris, uvs


ATTACKS = ("Atk_", "Combo_")


def swing_check(slug, mode, entries):
    """Independent check of the edge side: through every stock Atk_/Combo_
    sequence, the motion of the blade's middle (velocity in Root space,
    rotated into RW_Weapon space) over the fastest quarter of the frames.
    A cutting attack leads with the edge, so its motion should lie on the
    edge side. Per blade entry: the number of attacks whose motion has a
    positive component along the middle segment's edge_dir, and the mean
    component (unit motion). On a double-edged blade it names the side the
    attacks lead with."""
    rig = Rig(slug)
    path, _ = anim_path(slug)
    anim = Anim(path)
    if mode:   # the Scythe's folded attacks are not separate sequences
        return
    i = rig.index["RW_Weapon"]
    seqs = [n for n in sorted(anim.sequences) if n.startswith(ATTACKS)]
    for e in entries:
        if e["type"] != "blade":
            continue
        seg = max(e["segments"], key=lambda s: s["length"])
        probe = scale(add(tuple(seg["start"]), tuple(seg["end"])), 0.5)
        ed = tuple(seg["edge_dir"])
        hits, comps = 0, []
        for name in seqs:
            pts, rots = [], []
            for f in range(anim.frames(name)):
                pos, rot = anim.pose(rig, name, f)
                pts.append(add(pos[i], rotate(rot[i], game(probe))))
                rots.append(rot[i])
            vel = sorted(((norm(sub(pts[f], pts[f - 1])), game(rotate(conj(rots[f]), sub(pts[f], pts[f - 1]))))
                          for f in range(1, len(pts))), key=lambda x: -x[0])
            top = vel[:max(1, len(vel) // 4)]
            m = unit(tuple(sum(v[k] for _, v in top) for k in range(3)))
            c = dot(m, ed)
            comps.append(c)
            hits += c > 0
        e["swing_check"] = dict(attacks=len(seqs), on_edge_side=hits, mean_component=round(sum(comps) / len(comps), 2),
                                probe=r(probe), evidence="stock attack motion at the blade's middle, in weapon space")


def summary(out):
    print(out["slug"])
    for e in out["entries"]:
        if e["type"] == "blade":
            print(f"  {e['name']}: {len(e['segments'])} segs, edges={e['edges']} spine={e['spine']} "
                  f"teeth e/s={[(x.get('edge_teeth'), x.get('spine_teeth')) for x in e['segments']]} "
                  f"ambiguous={e['ambiguous']}")
            for s in e["segments"]:
                print(f"    {s['start']} -> {s['end']} edge {s['edge_dir']} er {s['edge_reach_start']}/"
                      f"{s['edge_reach_end']} sr {s['spine_reach']} ht {s['half_thickness']} "
                      f"ratios e/s {s['edge_end_thickness_ratio']}/{s['spine_end_thickness_ratio']} "
                      f"{s['edges']} {s['spine']}{' AMBIG' if s['ambiguous'] else ''}")
        elif e["type"] == "point":
            print(f"  {e['name']}: tip {e['tip']} axis {e['axis']}")
        else:
            print(f"  {e['name']}: {e['type']}")


if __name__ == "__main__":
    for slug in (sys.argv[1:] or list(SPECS)):
        summary(measure(slug))
