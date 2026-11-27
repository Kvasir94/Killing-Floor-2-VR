"""Measure each melee weapon's shaft centreline, butt to head, for the VR shaft hit lines.

The handle, hilt and pommel bludgeon (melee spec M12, M27). The runtime used a
straight capsule from 6 uu behind the grip to the head, which left the butt end
of every long weapon and the handle of most knives without a hit area (hit-area
audit, 2026-11-10). This follows the mesh instead: the middle of the weapon's
RW_Weapon vertices in 3 uu slices along the long axis (+Z in every melee rig),
from the fitted handle zone's lowest point to just below the head, simplified
to a few straight pieces.

Offline. Reads the review meshes written by melee_zone_review.py export and
measure_melee_blades.py (build/melee-zone-review), the zone fits in
docs/re/melee-zones/<slug>-zones.json and the shipped profile heads.

  python -I tools/re/measure_melee_shafts.py
writes docs/re/melee-zones/<slug>-shaft.json (RW_Weapon game space, uu).
"""
from pathlib import Path
import json
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import melee_hitarea_sheet as sheet  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ZONES = ROOT / "docs/re/melee-zones"
REVIEW = ROOT / "build/melee-zone-review"
SLICE = 3.0
TOLERANCE = 1.0
MAX_PIECES = 5
# Gauntlets have no shaft; the shield is not held by one.
SKIP = {"blunt-powergloves", "blastbrawlers"}


def simplify(points, tol):
    """Ramer-Douglas-Peucker."""
    if len(points) < 3:
        return points
    a, b = points[0], points[-1]
    ab = sheet.sub(b, a)
    n = sheet.length(ab)
    worst, at = 0.0, 0
    for i in range(1, len(points) - 1):
        ap = sheet.sub(points[i], a)
        t = max(0.0, min(1.0, sheet.dot(ap, ab) / (n * n))) if n > 1e-6 else 0.0
        d = sheet.length(sheet.sub(points[i], sheet.add(a, sheet.mul(ab, t))))
        if d > worst:
            worst, at = d, i
    if worst <= tol:
        return [a, b]
    return simplify(points[:at + 1], tol)[:-1] + simplify(points[at:], tol)


def main():
    M = sheet.melee_defaults()
    segs, _ = sheet.blades()
    P, TR, F = sheet.profiles(), sheet.traits(), sheet.scythe_fold()
    for slug, cls, title in sheet.WEAPONS:
        if slug in SKIP:
            continue
        zones = json.loads((ZONES / f"{slug}-zones.json").read_text(encoding="utf-8"))["parts"][0]["zones"]
        mesh = sheet.mesh_for(slug)[0]["verts"]
        if slug == "edged-scythe":
            # Leave the folding blade out: it crosses the snath's Z range.
            unf = json.loads((REVIEW / "data" / "edged-scythe.json").read_text(encoding="utf-8"))["parts"][0]["verts"]
            mesh = [v for v, w in zip(mesh, unf) if sheet.length(sheet.sub(v, w)) <= 0.05]
        butt = zones["handle"]["axis_range"][0]
        if "pommel" in zones and zones["pommel"].get("axis_range"):
            butt = min(butt, zones["pommel"]["axis_range"][0])
        mine = [s for s in segs if s["cls"] == cls]
        prof = P[cls]
        if slug == "edged-scythe":
            top, why = F["pivot"][2] - 3.0, "3 uu below the fold pivot"
        elif mine:
            top, why = min(min(s["start"][2], s["end"][2]) for s in mine) - 0.5, "0.5 uu below the measured blade"
        else:
            mclass = TR[cls]["melee_class"] if cls in TR else 0
            radius = max(prof["radius"], M["min_edge"].get(mclass, 0))
            top = min(prof["head_start"][2], prof["head_end"][2]) - radius
            why = f"the head capsule's lower end (radius {radius:g})"
        # Follow the shaft itself: each slice keeps the vertices within the
        # handle's own radius (plus 2 uu) of the previous slice's centre, so a
        # collar, pump or head beside the shaft does not pull the line off it.
        reach = max(zones["handle"].get("radius") or 3.0, 2.0) + 2.0
        pts, centre = [], None
        z = butt
        while z < top - 1e-6:
            hi = min(z + SLICE, top)
            band = [v for v in mesh if z <= v[2] <= hi]
            if centre is None:
                near = [v for v in band if (v[0] ** 2 + v[1] ** 2) ** 0.5 <= reach + 6]
            else:
                near = [v for v in band if ((v[0] - centre[0]) ** 2 + (v[1] - centre[1]) ** 2) ** 0.5 <= reach]
            if near:
                # The middle of the slice's extent, not the vertex mean: detail
                # on one side of a grip would pull a mean toward it.
                centre = [(min(v[0] for v in near) + max(v[0] for v in near)) / 2,
                          (min(v[1] for v in near) + max(v[1] for v in near)) / 2]
                pts.append([centre[0], centre[1], (z + hi) / 2])
            z = hi
        # Three-slice running mean: wraps and bolts make single slices jump.
        pts = [[sum(q[i] for q in pts[max(0, k - 1):k + 2]) / len(pts[max(0, k - 1):k + 2]) for i in (0, 1)] + [p[2]]
               for k, p in enumerate(pts)]
        if len(pts) < 2:
            print(slug, "no shaft found")
            continue
        # Run the ends out to the measured limits.
        pts[0] = [pts[0][0], pts[0][1], butt]
        pts[-1] = [pts[-1][0], pts[-1][1], top]
        tol = TOLERANCE
        line = simplify(pts, tol)
        while len(line) - 1 > MAX_PIECES:
            tol += 0.25
            line = simplify(pts, tol)
        line = [sheet.r3(p) for p in line]
        out = dict(slug=slug, weapon_class=cls, space="RW_Weapon game space, uu", butt_z=round(butt, 2),
                   top_z=round(top, 2), top_rule=why, slice=SLICE, tolerance=round(tol, 2), points=line)
        (ZONES / f"{slug}-shaft.json").write_text(json.dumps(out, indent=1) + "\n", encoding="utf-8")
        print(f"{slug:24s} butt {butt:7.2f} top {top:6.2f} pieces {len(line) - 1}  {line}")


if __name__ == "__main__":
    main()
