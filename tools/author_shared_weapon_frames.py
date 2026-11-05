"""Author cosmetic pickup-to-first-person frames from shared mesh vertices.

Offline asset authoring only. Reads existing ActorX exports and cooked pickup
geometry; does not run the game or change pickup/grab authority. Only rigid fits
supported by a distributed set of original receiver vertices are admitted.
"""
import argparse
import json
import re
import struct
import sys
from collections import Counter
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'tools'), str(ROOT / 'tools/re')]
from inspect_grenade_grips import extract
from audit_source_assets import read_package
from audit_flamethrower_assets import chunks, parse_bones, INFO, KEY, ctext
from audit_stock_gun_assets import global_pose
from audit_m14_assets import rotate, conj


def source_mesh(path):
    c = chunks(path)
    bones = parse_bones(c['REFSKELT'])
    root = next(i for i, b in enumerate(bones) if b['name'] == 'RW_Weapon')
    pos, rot = global_pose(bones, [(b['local_position'], b['local_quaternion']) for b in bones])
    points = np.array([rotate(conj(rot[root]), np.array(p) - pos[root])
                       for p in struct.iter_unpack('<3f', c['PNTS0000'][2])])
    wedges = list(struct.iter_unpack('<IffBBH', c['VTXW0000'][2]))
    faces = np.array([[wedges[j][0] for j in f[:3]] for f in struct.iter_unpack('<3HBBI', c['FACE0000'][2])])
    receiver = np.zeros(len(points), dtype=bool)
    for weight, vertex, bone in struct.iter_unpack('<fii', c['RAWWEIGHTS'][2]):
        if bone == root and weight > .99:
            receiver[vertex] = True
    return points, faces, receiver


def triangle_keys(vertices, faces, normalized=False):
    t = vertices[faces]
    lengths = np.linalg.norm(np.roll(t, -1, axis=1) - np.roll(t, 1, axis=1), axis=2)
    order = np.argsort(lengths, axis=1)
    lengths = np.take_along_axis(lengths, order, axis=1)
    keys = np.round(lengths / np.maximum(lengths[:, -1:], 1e-9), 4) if normalized else np.round(lengths, 3)
    return [(tuple(k), o, e) for k, o, e in zip(keys, order, lengths)]


def fit(a, b):
    ac, bc = a.mean(0), b.mean(0)
    u, _, vt = np.linalg.svd((a - ac).T @ (b - bc))
    r = vt.T @ u.T
    if np.linalg.det(r) < 0:
        vt[-1] *= -1
        r = vt.T @ u.T
    return r, bc - r @ ac


def nearest(p, s):
    """For each point of s, the distance to and index of its nearest point in p
    (exact; squared distances as |a|^2 + |b|^2 - 2 a.b, one matmul per batch)."""
    p2 = (p * p).sum(1)
    errors, matches = [], []
    for batch in np.array_split(s, max(1, len(s) // 512)):
        d = p2[None] - 2.0 * (batch @ p.T) + (batch * batch).sum(1)[:, None]
        index = d.argmin(1)
        # Recompute the chosen pair directly: the expansion loses precision
        # at the 0.0002 UU thresholds the fit uses.
        matches.extend(index); errors.extend(np.linalg.norm(batch - p[index], axis=1))
    return np.array(errors), np.array(matches)


def alignment(p, f, receiver, s, sf):
    shapes = {}
    for k, _, e in triangle_keys(p, f, True):
        if e[0] > .2:
            shapes.setdefault(k, []).append(e)
    ratios = [float(np.median(e / shapes[k][0])) for k, _, e in triangle_keys(s, sf, True)
              if e[0] > .2 and len(shapes.get(k, [])) == 1]
    if not ratios:
        raise ValueError('no shared triangle scale')
    mode, count = Counter(round(x, 4) for x in ratios).most_common(1)[0]
    if count < 12:
        raise ValueError('ambiguous triangle scale')
    scale = float(np.median([x for x in ratios if abs(x - mode) < .0001]))
    if not .5 < scale < 2:
        raise ValueError('unsupported scale')
    p = p * scale
    shapes = {}
    for i, (k, order, e) in enumerate(triangle_keys(p, f)):
        if e[0] > .2 and e[0] + e[1] > e[2] + .02:
            shapes.setdefault(k, []).append((i, order))
    seeds = []
    sample = s[np.linspace(0, len(s) - 1, min(48, len(s)), dtype=int)]
    candidates = [(j, order, shapes[k][0]) for j, (k, order, _) in enumerate(triangle_keys(s, sf))
                  if len(shapes.get(k, [])) == 1]
    for j, order, (i, other) in candidates[::max(1, len(candidates) // 48)]:
        r, t = fit(p[f[i]][other], s[sf[j]][order])
        err, _ = nearest(p @ r.T + t, sample)
        seeds.append((float(np.median(err)), r, t))
    best = None
    for _, r, t in sorted(seeds, key=lambda x: x[0])[:6]:
        for threshold in (.01, .001, .0002):
            err, match = nearest(p @ r.T + t, s)
            valid = (err < threshold) & receiver[match]
            if valid.sum() < 30:
                break
            r, t = fit(p[match[valid]], s[valid])
        err, match = nearest(p @ r.T + t, s)
        valid = (err < .0002) & receiver[match]
        unique = np.unique(match[valid])
        if len(unique) < 50:
            continue
        spread = np.linalg.svd(p[unique] - p[unique].mean(0), compute_uv=False) / np.sqrt(len(unique))
        if spread[1] < 2 or spread[2] < .3:
            continue
        if best is None or len(unique) > best['receiver_points']:
            best = dict(origin=t.tolist(), axes=(r.T * scale).tolist(), receiver_points=len(unique),
                        receiver_rms=float(np.sqrt(np.mean(err[valid] ** 2))), spread=spread.tolist())
    if best is None:
        raise ValueError('no distributed exact receiver fit')
    return best


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--assets', type=Path, required=True)
    parser.add_argument('--exports', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--world-exports', type=Path, required=True)
    parser.add_argument('--game-root', type=Path, default=Path('D:/SteamLibrary/steamapps/common/killingfloor2'))
    parser.add_argument('--weapon', action='append')
    args = parser.parse_args()
    packages = {p.stem.lower(): p for p in (args.game_root / 'KFGame/BrewedPC/Packages/Weapons').rglob('*.upk')}
    exports = {p.stem.lower(): p for p in args.exports.rglob('*.psk')}
    animations = {p.stem.lower(): p for p in args.exports.rglob('*.psa')}
    world = list(args.world_exports.rglob('*.psk'))
    result = json.loads(args.output.read_text()) if args.output.exists() else {}
    for row in json.loads(args.assets.read_text()):
        if args.weapon and row['weapon'] not in args.weapon:
            continue
        try:
            pickup_package, pickup = row['pickup'].split('.')
            p, f, receiver = source_mesh(exports[row['held'].split('.')[-1].lower()])
            package = packages[pickup_package.lower()]
            objects = read_package(package)[3]
            pickup = next(o['name'] for o in objects if o['cls'] == 'StaticMesh' and o['name'].lower() == pickup.lower())
            mesh = extract(package, pickup)
            try:
                frame = alignment(p, f, receiver, np.array(mesh['vertices']), np.array(mesh['triangles']))
                frame['basis'] = 'first-person receiver'
            except ValueError:
                # Stock pickup LODs often share only the third-person receiver.
                # Admit its root only when its canonical receiver also agrees
                # with the first-person receiver; never infer axes from bounds.
                candidates = []
                for path in world:
                    if path.parent.parent.name.lower() != pickup_package.lower():
                        continue
                    try:
                        wp, wf, wr = source_mesh(path)
                        check, _ = nearest(p[receiver], wp[wr])
                        if len(check) < 50 or np.median(check) > 1.5 or np.quantile(check, .9) > 4:
                            continue
                        candidate = alignment(wp, wf, wr, np.array(mesh['vertices']), np.array(mesh['triangles']))
                        candidate['basis'] = str(path)
                        candidate['held_receiver_median'] = float(np.median(check))
                        candidates.append(candidate)
                    except (ValueError, StopIteration):
                        continue
                if not candidates:
                    raise ValueError('no verified shared receiver frame')
                frame = max(candidates, key=lambda x: x['receiver_points'])
            hc = chunks(exports[row['held'].split('.')[-1].lower()])
            hb = parse_bones(hc['REFSKELT']); hi = {b['name']: i for i, b in enumerate(hb)}
            for anim in row['anims']:
                ac = chunks(animations[anim.split('.')[-1].lower()])
                idle = next((x for x in INFO.iter_unpack(ac['ANIMINFO'][2]) if ctext(x[0]).lower() == row['idle'].lower()), None)
                if idle is not None:
                    break
            if idle is None:
                raise ValueError('no authored idle grip')
            tracks = {b['name']: i for i, b in enumerate(parse_bones(ac['BONENAMES']))}
            local = []
            for bone in hb:
                if bone['name'] in tracks:
                    k = KEY.unpack_from(ac['ANIMKEYS'][2], (idle[10] * idle[2] + tracks[bone['name']]) * KEY.size)
                    local.append((k[:3], k[3:7]))
                else:
                    local.append((bone['local_position'], bone['local_quaternion']))
            hp, hq = global_pose(hb, local)
            frame['primary'] = list(rotate(conj(hq[hi['RW_Weapon']]), np.array(hp[hi['RightHand_1stP']]) - hp[hi['RW_Weapon']]))
            frame['support'] = list(rotate(conj(hq[hi['RW_Weapon']]), np.array(hp[hi['LeftHand_1stP']]) - hp[hi['RW_Weapon']]))
            result[row['weapon']] = dict(**row, **frame)
            print(row['weapon'], frame['receiver_points'], flush=True)
        except (ValueError, KeyError, StopIteration) as ex:
            result[row['weapon']] = dict(**row, unavailable=str(ex))
            print(row['weapon'], str(ex), flush=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
