#!/usr/bin/env python3
"""Measure grab-region thickness of exported KF2 Zed PSK meshes relative to the Clot.

Offline prep for VRGrapplePose / VRBodyHold.SeatInPalm scaling. Stdlib only.

Region rules mirror VRGrapplePose.RegionForBone (substring, lower-cased):
  neck -> Neck; head/jaw -> Skull; shoulder/spine/hips/pelvis/chest -> Shoulder; else Limb.

For each mesh and each grab bone, vertices weighted > 0.5 to that bone are taken
and the mean perpendicular distance to the bone axis (bone origin -> child bone
origin) is reported in Unreal units, along with the bone length. For bones with no
usable child (head), the axis is the parent->bone direction.

Usage:
  python measure_zed_grab_sizes.py MESH_DIR_OR_PSK... --out OUTDIR [--clot PSK]
Each positional argument is "Label=path/to/mesh.psk" (Label is the Zed name).
"""
import argparse
import json
import math
import os
import struct
import sys

GRAB_BONES = [
    # (region hint name, bone-name regex-free candidates (lower-case), axis child hint)
    ("neck", ["neck"]),
    ("head", ["head"]),
    ("spine2", ["spine2", "spine_2", "chest"]),
    ("shoulder", ["rightshoulder", "leftshoulder", "clavicle_r", "clavicle_l"]),
    ("hips", ["hips", "pelvis"]),
    ("arm", ["rightarm", "leftarm"]),
    ("forearm", ["rightforearm", "leftforearm"]),
    ("upleg", ["rightupleg", "leftupleg"]),
    ("lowleg", ["rightleg", "leftleg"]),
]


def region_for_bone(name):
    s = name.lower()
    if "neck" in s:
        return "Neck"
    if "head" in s or "jaw" in s:
        return "Skull"
    for k in ("shoulder", "spine", "hips", "pelvis", "chest"):
        if k in s:
            return "Shoulder"
    return "Limb"


def read_psk(path):
    data = open(path, "rb").read()
    off = 0
    chunks = {}
    while off + 32 <= len(data):
        name = data[off:off + 20].split(b"\0")[0].decode("ascii", "replace")
        _flag, size, count = struct.unpack_from("<iii", data, off + 20)
        off += 32
        chunks[name] = (data[off:off + size * count], size, count)
        off += size * count
    pts_b, _, npts = chunks["PNTS0000"]
    pts = [struct.unpack_from("<3f", pts_b, i * 12) for i in range(npts)]
    bones = []
    b, sz, n = chunks["REFSKELT"]
    for i in range(n):
        base = i * sz
        nm = b[base:base + 64].split(b"\0")[0].decode("ascii", "replace")
        _f, nch, par = struct.unpack_from("<iii", b, base + 64)
        q = struct.unpack_from("<4f", b, base + 76)
        p = struct.unpack_from("<3f", b, base + 92)
        bones.append({"name": nm, "parent": par if i else -1, "children": nch, "q": q, "p": p})
    w_b, w_sz, nw = chunks["RAWWEIGHTS"]
    weights = {}  # bone -> list of (point, weight)
    for i in range(nw):
        wt, pi, bi = struct.unpack_from("<fii", w_b, i * w_sz)
        weights.setdefault(bi, []).append((pi, wt))
    return pts, bones, weights


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz)


def qrot(q, v):
    x, y, z, w = q
    # v' = q * v * q^-1
    t = (2 * (y * v[2] - z * v[1]), 2 * (z * v[0] - x * v[2]), 2 * (x * v[1] - y * v[0]))
    return (v[0] + w * t[0] + (y * t[2] - z * t[1]),
            v[1] + w * t[1] + (z * t[0] - x * t[2]),
            v[2] + w * t[2] + (x * t[1] - y * t[0]))


def conj(q):
    return (-q[0], -q[1], -q[2], q[3])


def world_positions(bones, conj_all):
    """PSK stores the root orientation conjugated; some exporters conjugate all. Try both."""
    rot = []
    pos = []
    for i, b in enumerate(bones):
        q = b["q"]
        if conj_all or i == 0:
            q = conj(q)
        if b["parent"] < 0 or i == 0:
            rot.append(q)
            pos.append(b["p"])
        else:
            pr, pp = rot[b["parent"]], pos[b["parent"]]
            r = qrot(pr, b["p"])
            pos.append((pp[0] + r[0], pp[1] + r[1], pp[2] + r[2]))
            rot.append(qmul(pr, q))
    return pos


def choose_variant(bones, pts):
    """Pick the quaternion convention whose skeleton lies closest to the mesh."""
    best = None
    for conj_all in (False, True):
        pos = world_positions(bones, conj_all)
        # mean distance from each point to the nearest bone origin (sampled)
        step = max(1, len(pts) // 400)
        tot = 0.0
        cnt = 0
        for p in pts[::step]:
            tot += min(math.dist(p, bp) for bp in pos)
            cnt += 1
        score = tot / max(cnt, 1)
        if best is None or score < best[0]:
            best = (score, conj_all, pos)
    return best


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def norm(a):
    return math.sqrt(dot(a, a))


def descendants(bones, idx):
    kids = [i for i, b in enumerate(bones) if b["parent"] == idx and i != idx]
    n = 0
    for k in kids:
        n += 1 + descendants(bones, k)
    return n


def pick_axis(bones, pos, idx):
    """Return (axis_unit, length, axis_note). Axis = bone -> principal child."""
    kids = [i for i, b in enumerate(bones) if b["parent"] == idx and i != idx]
    if bones[idx]["name"].lower() == "head" and bones[idx]["parent"] >= 0:
        # The head has only face/gore/hair helper children; use the neck->head direction
        # (the skull sits above the head joint) so every Zed is measured the same way.
        par = bones[idx]["parent"]
        d = sub(pos[idx], pos[par])
        L = norm(d)
        if L > 0.5:
            return tuple(c / L for c in d), L, "parent->bone (neck->head; length = neck bone length)"
    # Prefer a child that is a skeleton continuation (most descendants, not twist/gore/face helpers).
    def helper(i):
        n = bones[i]["name"].lower()
        return any(k in n for k in ("twist", "gore", "face_", "eye", "lip", "jaw", "tongue", "hair", "jiggle", "weapon", "claw"))
    cand = [k for k in kids if not helper(k)] or kids
    cand.sort(key=lambda k: (-descendants(bones, k), -norm(sub(pos[k], pos[idx]))))
    for k in cand:
        d = sub(pos[k], pos[idx])
        L = norm(d)
        if L > 0.5:
            return tuple(c / L for c in d), L, "to child " + bones[k]["name"]
    par = bones[idx]["parent"]
    if par >= 0:
        d = sub(pos[idx], pos[par])
        L = norm(d)
        if L > 0.5:
            return tuple(c / L for c in d), L, "parent->bone (no child; length = parent bone length)"
    return None, 0.0, "no axis"


def measure_bone(pts, weights, bones, pos, idx):
    axis, length, note = pick_axis(bones, pos, idx)
    verts = [pi for pi, w in weights.get(idx, []) if w > 0.5]
    if axis is None or not verts:
        return None
    o = pos[idx]
    rs = []
    ts = []
    for pi in verts:
        v = sub(pts[pi], o)
        t = dot(v, axis)
        perp = sub(v, tuple(a * t for a in axis))
        rs.append(norm(perp))
        ts.append(t)
    n = len(rs)
    mean_r = sum(rs) / n
    # Centered: remove the lateral offset of the cloud centroid so an asymmetric
    # cloud (skull ahead of the head joint) is measured as a thickness, not an offset.
    cm = [0.0, 0.0, 0.0]
    perps = []
    for pi in verts:
        v = sub(pts[pi], o)
        t = dot(v, axis)
        perps.append(sub(v, tuple(a * t for a in axis)))
    for p in perps:
        for k in range(3):
            cm[k] += p[k] / n
    mean_rc = sum(norm(sub(p, cm)) for p in perps) / n
    rs_sorted = sorted(rs)
    return {
        "bone_length_uu": round(length, 2),
        "verts": n,
        "radius_uu": round(mean_r, 2),
        "radius_centered_uu": round(mean_rc, 2),
        "radius_p90_uu": round(rs_sorted[int(0.9 * (n - 1))], 2),
        "axial_extent_uu": round(max(ts) - min(ts), 2),
        "axis": note,
    }


def match_bone(bones, cands, prefer_side=None):
    out = []
    for i, b in enumerate(bones):
        n = b["name"].lower().replace(" ", "")
        if n in cands:
            out.append(i)
    return out


def analyse(label, path):
    pts, bones, weights = read_psk(path)
    score, conj_all, pos = choose_variant(bones, pts)
    res = {"zed": label, "mesh": os.path.basename(path), "bone_count": len(bones),
           "quat_conj_all": conj_all, "skeleton_fit_uu": round(score, 2), "measurements": [],
           "unmatched_hint_bones": [], "region_rule_notes": []}
    for hint, cands in GRAB_BONES:
        idxs = match_bone(bones, cands)
        if not idxs:
            res["unmatched_hint_bones"].append(hint)
            continue
        # Average left/right if both present; report each.
        for idx in idxs:
            m = measure_bone(pts, weights, bones, pos, idx)
            if not m:
                res["unmatched_hint_bones"].append(bones[idx]["name"] + " (no >0.5 verts or axis)")
                continue
            m.update({"hint": hint, "bone": bones[idx]["name"], "region": region_for_bone(bones[idx]["name"])})
            res["measurements"].append(m)
    # Bones the rules would misclassify (non-arm/leg bones falling to Limb).
    odd = [b["name"] for b in bones
           if region_for_bone(b["name"]) == "Limb"
           and not any(k in b["name"].lower() for k in
                       ("arm", "leg", "hand", "foot", "toe", "thigh", "calf", "finger", "thumb",
                        "index", "middle", "ring", "pinky", "root", "twist", "gore", "face", "eye", "lip", "brow", "lid"))]
    res["region_rule_notes"] = odd
    res["bone_names"] = [b["name"] for b in bones]
    return res


def merged(measurements, hint):
    ms = [m for m in measurements if m["hint"] == hint]
    if not ms:
        return None
    n = len(ms)
    return {k: round(sum(m[k] for m in ms) / n, 2)
            for k in ("bone_length_uu", "radius_uu", "radius_centered_uu", "radius_p90_uu", "axial_extent_uu")} | {
        "bones": "/".join(m["bone"] for m in ms), "region": ms[0]["region"], "verts": sum(m["verts"] for m in ms),
        "axis": ms[0]["axis"]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("meshes", nargs="+", help="Label=path.psk (first entry is the Clot reference)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    results = []
    for spec in a.meshes:
        label, path = spec.split("=", 1)
        results.append(analyse(label, path))
    ref = {h: merged(results[0]["measurements"], h) for h, _ in GRAB_BONES}
    rows = []
    for r in results:
        for hint, _ in GRAB_BONES:
            m = merged(r["measurements"], hint)
            if not m:
                continue
            base = ref.get(hint)
            row = {"zed": r["zed"], "mesh": r["mesh"], "region": m["region"], "hint": hint,
                   "bone": m["bones"], "bone_length_uu": m["bone_length_uu"],
                   "radius_uu": m["radius_uu"], "radius_centered_uu": m["radius_centered_uu"],
                   "verts": m["verts"], "axis": m["axis"]}
            if base:
                row["ratio_to_clot"] = round(m["radius_uu"] / base["radius_uu"], 3) if base["radius_uu"] else None
                row["ratio_centered_to_clot"] = (round(m["radius_centered_uu"] / base["radius_centered_uu"], 3)
                                                 if base["radius_centered_uu"] else None)
            rows.append(row)
    with open(os.path.join(a.out, "zed_grab_sizes.json"), "w", encoding="utf-8") as f:
        json.dump({"rows": rows, "meshes": results}, f, indent=1)
    lines = ["| Zed | mesh | region | hint | bone | bone len uu | radius uu | ratio | centered r | ratio c | verts | axis |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append("| {zed} | {mesh} | {region} | {hint} | {bone} | {bone_length_uu} | {radius_uu} | {ratio_to_clot} | "
                     "{radius_centered_uu} | {ratio_centered_to_clot} | {verts} | {axis} |".format(**r))
    notes = ["", "## Notes", ""]
    for r in results:
        un = r["unmatched_hint_bones"]
        notes.append("- **%s** (%s, %d bones, quat_conj_all=%s, fit %.2f uu)%s%s" % (
            r["zed"], r["mesh"], r["bone_count"], r["quat_conj_all"], r["skeleton_fit_uu"],
            ("; no bones for hints: " + ", ".join(un)) if un else "",
            ("; non-limb bones the rules send to Limb: " + ", ".join(r["region_rule_notes"][:12])) if r["region_rule_notes"] else ""))
    with open(os.path.join(a.out, "zed_grab_sizes.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines + notes) + "\n")
    print("\n".join(lines + notes))


if __name__ == "__main__":
    sys.exit(main())
