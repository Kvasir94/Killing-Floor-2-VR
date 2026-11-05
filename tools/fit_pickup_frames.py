"""Fit each stock pickup mesh onto its first-person rig: the world gun mapping.

A dropped gun keeps its stock pickup body and art; the first-person rig frame
(the profile root at Idle frame 0, tools/author_world_gun_rigs.py) is placed
inside it by one fitted similarity per gun: pickup_local = Origin + s*R*rig.
The rig's catch grips and visual follow from that mapping.

Pickup meshes are separate, simplified models, so the fit is by surface, not
by shared vertices: both meshes are sampled evenly by area, aligned from every
axis-aligned orientation at the shared scale, then refined by trimmed rigid
point-to-point ICP. Most pickups share the first-person scale; a few are
modelled at another size (the FAL, MKB42 and Thompson 10 to 14 percent
smaller), so a scale search follows and keeps a scale only when it fits
decisively better than 1. Every fit is rendered for a visual check
(tools/render_pickup_fits.py) before it is used.

Writes build/world-gun-rigs/pickup-fits.json.
"""
import argparse
import itertools
import json
import struct
import sys
from pathlib import Path

import numpy as np

ROOT = next(p for p in Path(__file__).resolve().parents if (p / 'AGENTS.md').is_file())
sys.path[:0] = [str(ROOT / 'tools'), str(ROOT / 'tools/re')]
from audit_flamethrower_assets import chunks, parse_bones
from audit_source_assets import read_package
from inspect_grenade_grips import extract
import author_world_gun_rigs as rigs

SAMPLES = 2500

# Rig parts the pickup models in another state, left out of the fit: the
# Bastion's shield is deployed on the rig and folded on its pickup.
FIT_EXCLUDE = {'KFWeap_HRG_BarrierRifle': ('RW_Barrel2',)}


def sample_surface(vertices, triangles, count, seed=7):
    """Area-weighted points on the triangles (vertex density differs per mesh)."""
    v = np.asarray(vertices, dtype=float)
    t = np.asarray(triangles, dtype=int)
    a, b, c = v[t[:, 0]], v[t[:, 1]], v[t[:, 2]]
    area = np.linalg.norm(np.cross(b - a, c - a), axis=1) * 0.5
    keep = area > 1e-9
    a, b, c, area = a[keep], b[keep], c[keep], area[keep]
    rng = np.random.default_rng(seed)
    pick = rng.choice(len(area), count, p=area / area.sum())
    u, w = rng.random(count), rng.random(count)
    flip = u + w > 1
    u[flip], w[flip] = 1 - u[flip], 1 - w[flip]
    return a[pick] + (b[pick] - a[pick]) * u[:, None] + (c[pick] - a[pick]) * w[:, None]


def nearest(src, dst):
    """Index and distance of the nearest dst point for every src point."""
    d2 = (dst * dst).sum(1)
    best_i = np.empty(len(src), dtype=int)
    best_d = np.empty(len(src))
    for lo in range(0, len(src), 1024):
        s = src[lo:lo + 1024]
        d = d2[None] - 2 * s @ dst.T + (s * s).sum(1)[:, None]
        i = d.argmin(1)
        best_i[lo:lo + 1024] = i
        best_d[lo:lo + 1024] = np.sqrt(np.maximum(d[np.arange(len(s)), i], 0))
    return best_i, best_d


def umeyama(src, dst):
    """Similarity (s, R, t) minimising |s R src + t - dst| (proper rotation)."""
    ms, md = src.mean(0), dst.mean(0)
    xs, xd = src - ms, dst - md
    u, sig, vt = np.linalg.svd(xd.T @ xs / len(src))
    d = np.ones(3)
    if np.linalg.det(u @ vt) < 0:
        d[-1] = -1
    r = u @ np.diag(d) @ vt
    # Stock pickups share the first-person scale (the fifteen vertex-exact fits
    # measured 0.99 to 1.00); a free scale drifts on parts one model lacks.
    s = 1.0
    return s, r, md - s * r @ ms


def icp(src, dst, s, r, t, iterations=60, trim=0.8, mode='both'):
    """Trimmed ICP. 'both' pairs each model's points with the other's nearest;
    'rig' pairs only src points onto dst (dst may carry extra parts)."""
    for _ in range(iterations):
        moved = s * src @ r.T + t
        i, d = nearest(moved, dst)
        keep_a = d <= np.quantile(d, trim)
        a, b = src[keep_a], dst[i[keep_a]]
        if mode == 'both':
            j, e = nearest(dst, moved)
            keep_b = e <= np.quantile(e, trim)
            a = np.concatenate([a, src[j[keep_b]]])
            b = np.concatenate([b, dst[keep_b]])
        s2, r2, t2 = umeyama(a, b)
        if np.abs(r2 - r).max() < 1e-6 and np.abs(t2 - t).max() < 1e-4:
            s, r, t = s2, r2, t2
            break
        s, r, t = s2, r2, t2
    return s, r, t


def score(src, dst, s, r, t):
    moved = s * src @ r.T + t
    _, a = nearest(moved, dst)
    _, b = nearest(dst, moved)
    return float(np.quantile(np.concatenate([a, b]), 0.9)), float(np.mean(np.concatenate([a, b])))


def rotations():
    """The 24 proper axis-aligned rotations."""
    out = []
    for perm in itertools.permutations(range(3)):
        for signs in itertools.product((1, -1), repeat=3):
            m = np.zeros((3, 3))
            for row, (col, sign) in enumerate(zip(perm, signs)):
                m[row, col] = sign
            if np.linalg.det(m) > 0:
                out.append(m)
    return out


def lateral_axis(bore_rotation):
    """The root axis across the bore (VRWorldDropGun.HandGrips' Side: the
    profile BoreRotation applied to Y), as an index."""
    pitch, yaw, roll = (np.radians(a * 360.0 / 65536) for a in bore_rotation)
    sp, cp, sy, cy, sr, cr = np.sin(pitch), np.cos(pitch), np.sin(yaw), np.cos(yaw), np.sin(roll), np.cos(roll)
    side = np.array([sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp])
    return int(np.abs(side).argmax())


def fit(rig_pts, pickup_pts, receiver_pts=None, lateral=1):
    """rig -> pickup rigid transform: pickup = R rig + t.

    The receiver (root-bone geometry) is rigid in both models while moving
    parts sit anywhere on their travel, so a receiver-only fit is tried beside
    the whole-rig fit and the better one on the whole rig wins. Either model may
    carry parts the other lacks (a riot shield on the pickup, rails on the
    rig), so each candidate is judged by its better direction: how well the
    rig lies on the pickup, or the pickup on the rig.

    Some pickups are a mirror image of their first-person art (the
    flamethrower's tank hangs on the other side), so a bad fit is retried
    against the rig mirrored across its bore plane (normal to the root axis
    lateral); a decisively better result
    keeps that proper rotation, which lays the gun's symmetric body on the
    pickup and leaves only the mirrored parts on opposite sides."""
    def length(points):
        axis = np.linalg.svd(points - points.mean(0), full_matrices=False)[2][0]
        return float(np.ptp(points @ axis))

    # A pickup modelled at another size can lock onto a reversed orientation
    # at scale 1 (the double-barrel's stock on its muzzle), so the orientation
    # search also runs at the scale the two lengths suggest.
    guess = float(np.clip(length(pickup_pts) / length(rig_pts), 0.75, 1.3))
    starts = [1.0] if abs(guess - 1.0) < 0.05 else [1.0, guess]

    def candidate(flip):
        best = None
        for k0 in starts:
            row = fit_proper(k0 * rig_pts * flip, pickup_pts, None if receiver_pts is None else k0 * receiver_pts * flip)
            s, r, t, metric = fit_scale(rig_pts * flip, pickup_pts, np.array(row['rotation']), row)
            if best is None or metric < best[0]:
                row.update(start_scale=k0)
                best = (metric, s, r, t, row)
        return best

    best = candidate(np.ones(3))
    if best[0] > 1.0:
        mirror = np.ones(3)
        mirror[lateral] = -1.0
        mirrored = candidate(mirror)
        if mirrored[0] < 0.7 * best[0]:
            mirrored[4].update(mirrored_art=True, proper_symmetric=best[0])
            best = mirrored
    metric, s, r, t, row = best
    if metric > 3.0:
        # One model carries a large part the other lacks (the G18's riot
        # shield on its pickup, the Bastion's shield on its rig): no
        # two-sided distance can be small, so judge by the better one-sided
        # fit (fit_proper's quality) at the shared scale.
        row = fit_proper(rig_pts, pickup_pts, receiver_pts)
        row.update(extra_part=True)
        s, r, t, metric = 1.0, np.array(row['rotation']), np.array(row['origin']), row['quality']
    p90, mean = score(rig_pts, pickup_pts, s, r, t)
    row.update(scale=s, rotation=r.tolist(), origin=t.tolist(), p90=p90, mean=mean, symmetric=metric)
    return row


def symmetric(src, dst, s, r, t):
    """Scale-neutral surface distance: the mean of both directions' 80th
    percentile (one direction alone rewards shrinking into the other model)."""
    moved = s * src @ r.T + t
    _, a = nearest(moved, dst)
    _, b = nearest(dst, moved)
    return float((np.quantile(a, 0.8) + np.quantile(b, 0.8)) / 2)


def fit_scale(src, dst, r, row):
    """Search a uniform scale and keep it only when it is decisively better
    than 1 (12 percent; the AK12 muzzle alone buys 9 at 0.955) and not at the
    edge of the search. Returns the scale, pose and its symmetric distance."""
    def at(k, src, dst, iterations):
        c = k * src.mean(0)
        _, r2, t2 = icp(k * src, dst, 1.0, r, dst.mean(0) - r @ c, iterations=iterations, trim=0.9, mode='both')
        return symmetric(k * src, dst, 1.0, r2, t2), k, r2, t2
    coarse = [at(k, src[::2], dst[::2], 40) for k in np.arange(0.75, 1.301, 0.025)]
    best = min(coarse, key=lambda x: x[0])
    fine = [at(k, src, dst, 60) for k in np.arange(best[1] - 0.02, best[1] + 0.021, 0.005)]
    best = min(fine, key=lambda x: x[0])
    unit = at(1.0, src, dst, 60)
    row.update(scale_search=round(float(best[1]), 3), symmetric_at_scale=best[0], symmetric_at_1=unit[0])
    if best[0] < 0.88 * unit[0] and 0.76 < best[1] < 1.29:
        return float(best[1]), best[2], best[3], best[0]
    return 1.0, unit[2], unit[3], unit[0]


def fit_proper(rig_pts, pickup_pts, receiver_pts=None):
    results = []
    sources = [rig_pts]
    if receiver_pts is not None:
        sources.append(receiver_pts)
    for src in sources:
        best = None
        rc, pc = src.mean(0), pickup_pts.mean(0)
        coarse_src, coarse_pickup = src[::4], pickup_pts[::4]
        for r0 in rotations():
            t0 = pc - r0 @ rc
            for mode in ('both', 'rig'):
                _, r, t = icp(coarse_src, coarse_pickup, 1.0, r0, t0, iterations=25, mode=mode)
                q = quality(coarse_src, coarse_pickup, r, t)
                if best is None or q < best[0]:
                    best = (q, r, t, mode)
        _, r, t, mode = best
        _, r, t = icp(src, pickup_pts, 1.0, r, t, iterations=80, trim=0.9, mode=mode)
        # Every candidate is judged on the whole rig, its moving parts included.
        results.append((quality(rig_pts, pickup_pts, r, t), r, t, mode, src is not rig_pts))
    q, r, t, mode, receiver = min(results, key=lambda x: x[0])
    p90, mean = score(rig_pts, pickup_pts, 1.0, r, t)
    return dict(scale=1.0, rotation=r.tolist(), origin=t.tolist(), p90=p90, mean=mean, mode=mode,
                receiver=receiver, quality=q)


def quality(src, dst, r, t):
    moved = src @ r.T + t
    _, a = nearest(moved, dst)
    _, b = nearest(dst, moved)
    return float(min(np.quantile(a, 0.8), np.quantile(b, 0.8)))


def rig_surface(name, profile, assets, exports, animations):
    """Area-weighted samples of the rig's weapon-only Idle surface in its root
    frame, as author_world_gun_rigs sees it, and of its receiver alone.
    Vertex samples would crowd onto detailed parts and leave broad faces (a
    stock) bare, which reads as a gap wherever the pickup covers them."""
    mesh_name, anims = assets(name)
    psk = exports[mesh_name.split('.')[-1].lower()]
    psas = [animations[a.split('.')[-1].lower()] for a in anims if a.split('.')[-1].lower() in animations]
    bones = parse_bones(chunks(psk)['REFSKELT'])
    root = [b['name'] for b in bones].index(profile['root'])
    pose = rigs.idle_pose(bones, psas, profile['idle'])
    points, _, ids = rigs.weapon_points(psk, bones, pose, root, with_ids=True)
    _, receiver_ids = rigs.weapon_points(psk, bones, pose, root, with_ids=True, receiver_only=True)
    c = chunks(psk)
    wedges = [w[0] for w in rigs.WEDGE.iter_unpack(c['VTXW0000'][2])]
    where = {v: i for i, v in enumerate(ids)}
    excluded = {i for i, b in enumerate(bones) if b['name'] in FIT_EXCLUDE.get(name, ())}
    if excluded:
        weights = {}
        for weight, vertex, bone in rigs.WEIGHT.iter_unpack(c['RAWWEIGHTS'][2]):
            weights.setdefault(vertex, []).append((weight, bone))
        where = {v: i for v, i in where.items() if max(weights[v])[1] not in excluded}
    receiver_ids = set(receiver_ids)
    faces, receiver_faces = [], []
    for f in struct.iter_unpack('<3HBBI', c['FACE0000'][2]):
        corners = [wedges[f[k]] for k in range(3)]
        if all(v in where for v in corners):
            faces.append([where[v] for v in corners])
            if all(v in receiver_ids for v in corners):
                receiver_faces.append(faces[-1])
    def area(tris):
        t = np.asarray(tris, dtype=int).reshape(-1, 3)
        return float(np.linalg.norm(np.cross(points[t[:, 1]] - points[t[:, 0]], points[t[:, 2]] - points[t[:, 0]]), axis=1).sum())
    rig_pts = sample_surface(points, faces, SAMPLES, seed=3)
    # The receiver alone is a candidate only when it is a substantial part.
    substantial = len(receiver_faces) >= 20 and area(receiver_faces) >= 0.3 * area(faces)
    return rig_pts, sample_surface(points, receiver_faces, SAMPLES, seed=5) if substantial else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--exports', type=Path, default=ROOT / 'build/shared-weapon-frames/held-export')
    parser.add_argument('--game-root', type=Path, default=Path('D:/SteamLibrary/steamapps/common/killingfloor2'))
    parser.add_argument('--assets', type=Path, default=ROOT / 'build/shared-weapon-frames/assets.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/world-gun-rigs/pickup-fits.json')
    parser.add_argument('--weapon', action='append')
    args = parser.parse_args()
    exports = {p.stem.lower(): p for p in args.exports.rglob('*.psk')}
    animations = {p.stem.lower(): p for p in args.exports.rglob('*.psa')}
    pickups = {row['weapon']: row['pickup'] for row in json.loads(args.assets.read_text())}
    packages = {p.stem.lower(): p for p in (args.game_root / 'KFGame/BrewedPC/Packages/Weapons').rglob('*.upk')}
    assets = rigs.class_assets(args.game_root)
    result = json.loads(args.output.read_text()) if args.output.exists() and args.weapon else {}
    for name, profile in sorted(rigs.profiles().items()):
        if args.weapon and name not in args.weapon:
            continue
        try:
            if name not in pickups:
                raise ValueError('no stock pickup mesh')
            package_name, mesh = pickups[name].split('.')
            package = packages[package_name.lower()]
            objects = read_package(package)[3]
            mesh = next(o['name'] for o in objects if o['cls'] == 'StaticMesh' and o['name'].lower() == mesh.lower())
            pickup = extract(package, mesh)
            rig_pts, receiver_pts = rig_surface(name, profile, assets, exports, animations)
            pickup_pts = sample_surface(pickup['vertices'], pickup['triangles'], SAMPLES)
            row = fit(rig_pts, pickup_pts, receiver_pts, lateral=lateral_axis(profile['bore_rotation']))
            row.update(weapon=name, pickup=f'{package_name}.{mesh}', pickup_mesh=mesh,
                       size=float(np.ptp(pickup_pts, axis=0).max()))
            result[name] = row
            print(f"{name:42s} s={row['scale']:.3f} p90={row['p90']:.2f} mean={row['mean']:.2f} size={row['size']:.0f}", flush=True)
        except (ValueError, KeyError, StopIteration) as ex:
            result[name] = dict(weapon=name, unavailable=str(ex))
            print(name, 'unavailable:', ex, flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
