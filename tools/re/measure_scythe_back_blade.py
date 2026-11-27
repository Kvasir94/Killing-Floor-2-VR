"""Measure the Scythe's bolted back blade and add it to its blade data.

measure_melee_blades.py fits only the Scythe's main crescent (the largest
connected piece of RW_Fold); the hooked plate bolted to its back had no hit
area (hit-area audit, 2026-11-10; Kvasir94: "add the extra hit areas"). This
takes the second largest connected piece of RW_Fold from the same review mesh
(idle_folded, RW_Weapon game space), fits its centreline in the blade's XZ
plane in 4 uu slices along its principal axis and writes it as a second blade
entry, `back_blade`, in docs/re/melee-zones/edged-scythe-blade.json.

Edge side: the side facing away from the crescent (it is the outer rim of the
weapon); the inner side, bolted against the crescent's spine, bludgeons. That
is a reading of the model, not a measured bevel.

Run after measure_melee_blades.py (which rewrites the file without this
entry), then tools/re/emit_melee_blades.py.

  python -I tools/re/measure_scythe_back_blade.py
"""
from pathlib import Path
import json
import math
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import melee_hitarea_sheet as sheet  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REVIEW = ROOT / "build/melee-zone-review"
OUT = ROOT / "docs/re/melee-zones/edged-scythe-blade.json"
SLICE = 4.0
TOLERANCE = 2.5


def islands(verts, tris, keep):
    parent = {i: i for i in keep}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    seen = {}
    for i in keep:
        k = tuple(round(c, 1) for c in verts[i])
        if k in seen:
            parent[find(i)] = find(seen[k])
        else:
            seen[k] = i
    for t in tris:
        if all(i in parent for i in t):
            a = find(t[0])
            for j in t[1:]:
                parent[find(j)] = a
    groups = {}
    for i in keep:
        groups.setdefault(find(i), []).append(i)
    return sorted(groups.values(), key=len, reverse=True)


def simplify(points, tol):
    if len(points) < 3:
        return list(range(len(points)))
    a, b = points[0], points[-1]
    ab = sheet.sub(b, a)
    n = sheet.length(ab)
    worst, at = 0.0, 0
    for i in range(1, len(points) - 1):
        ap = sheet.sub(points[i], a)
        t = max(0.0, min(1.0, sheet.dot(ap, ab) / (n * n)))
        d = sheet.length(sheet.sub(points[i], sheet.add(a, sheet.mul(ab, t))))
        if d > worst:
            worst, at = d, i
    if worst <= tol:
        return [0, len(points) - 1]
    left = simplify(points[:at + 1], tol)
    right = simplify(points[at:], tol)
    return left[:-1] + [i + at for i in right]


def main():
    base = json.loads((REVIEW / "blade-data/edged-scythe.json").read_text(encoding="utf-8"))
    unf = json.loads((REVIEW / "data/edged-scythe.json").read_text(encoding="utf-8"))["parts"][0]["verts"]
    F = sheet.scythe_fold()
    V = base["verts"]
    fold = {i for i, (a, b) in enumerate(zip(V, unf))
            if sheet.length(sheet.sub(a, b)) > 0.05 and sheet.length(sheet.sub(sheet.fold_point(a, 1.0, F), b)) < 0.5}
    groups = islands(V, base["tris"], fold)
    crescent, plate = [V[i] for i in groups[0]], [V[i] for i in groups[1]]
    # Principal axis in the XZ plane.
    cx = sum(v[0] for v in plate) / len(plate)
    cz = sum(v[2] for v in plate) / len(plate)
    sxx = sum((v[0] - cx) ** 2 for v in plate)
    szz = sum((v[2] - cz) ** 2 for v in plate)
    sxz = sum((v[0] - cx) * (v[2] - cz) for v in plate)
    ang = 0.5 * math.atan2(2 * sxz, sxx - szz)
    axis = [math.cos(ang), 0.0, math.sin(ang)]
    side = [-axis[2], 0.0, axis[0]]
    # The edge faces away from the crescent.
    ccx = sum(v[0] for v in crescent) / len(crescent)
    ccz = sum(v[2] for v in crescent) / len(crescent)
    if sheet.dot([cx - ccx, 0.0, cz - ccz], side) < 0:
        side = sheet.mul(side, -1)
    centre = [cx, 0.0, cz]
    along = [sheet.dot(sheet.sub(v, centre), axis) for v in plate]
    lo, hi = min(along), max(along)
    cuts = []
    t = lo
    while t < hi - 1e-6:
        t1 = min(t + SLICE, hi)
        band = [v for v, a in zip(plate, along) if t <= a <= t1]
        if band:
            off = [sheet.dot(sheet.sub(v, centre), side) for v in band]
            mid = (min(off) + max(off)) / 2
            cuts.append(dict(t=(t + t1) / 2, mid=mid, half=(max(off) - min(off)) / 2,
                             thick=max(abs(v[1]) for v in band)))
        t = t1
    cuts[0]["t"], cuts[-1]["t"] = lo, hi
    pts = [sheet.add(centre, sheet.add(sheet.mul(axis, c["t"]), sheet.mul(side, c["mid"]))) for c in cuts]
    keep = simplify(pts, TOLERANCE)
    segs = []
    for n, (i, j) in enumerate(zip(keep, keep[1:])):
        run = cuts[i:j + 1]
        d = sheet.norm(sheet.sub(pts[j], pts[i]))
        e = sheet.norm([-d[2], 0.0, d[0]])
        if sheet.dot(e, side) < 0:
            e = sheet.mul(e, -1)
        half = max(c["half"] for c in run)
        segs.append(dict(index=n, start=sheet.r3(pts[i]), end=sheet.r3(pts[j]), axis=sheet.r3(d, 4),
                         length=round(sheet.length(sheet.sub(pts[j], pts[i])), 2), edge_dir=sheet.r3(e, 4),
                         flat_normal=[0.0, -1.0, 0.0], edge_reach=round(half, 2),
                         edge_reach_start=round(run[0]["half"], 2), edge_reach_end=round(run[-1]["half"], 2),
                         spine_reach=round(half, 2), spine_reach_start=round(run[0]["half"], 2),
                         spine_reach_end=round(run[-1]["half"], 2),
                         half_thickness=round(max(c["thick"] for c in run), 2), edges="one", spine="plain",
                         edge_damage="slash", spine_damage="blunt", flat_damage="blunt"))
    entry = dict(type="blade", name="back_blade", damage="slash",
                 length=round(sum(s["length"] for s in segs), 2), segments=segs,
                 note="the plate bolted to the crescent's back (second largest connected piece of RW_Fold); edge "
                      "side taken as the side facing away from the crescent, not from a measured bevel "
                      "(tools/re/measure_scythe_back_blade.py)")
    data = json.loads(OUT.read_text(encoding="utf-8"))
    data["entries"] = [e for e in data["entries"] if e.get("name") != "back_blade"]
    # Keep the tip point last, as emit_melee_blades.py lists segments in entry order.
    at = next((k for k, e in enumerate(data["entries"]) if e["type"] != "blade"), len(data["entries"]))
    data["entries"].insert(at, entry)
    OUT.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    print(f"back_blade: {len(plate)} vertices, {len(segs)} segments, length {entry['length']}")
    for s in segs:
        print("  ", s["start"], "->", s["end"], "edge", s["edge_dir"], "half width", s["edge_reach"])


if __name__ == "__main__":
    main()
