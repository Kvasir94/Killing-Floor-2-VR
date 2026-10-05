"""Fit a melee weapon's striking-head capsule for VRPhysicalMelee.

Reads an existing CLI-only UModel PSK export (build/<slug>-audit/export, see
audit_stock_gun_assets.py); no game, SDK, editor or tests. Uses the bind-pose
vertices skinned to weapon bones (RW_*, excluding the arms and hands), in
RW_Weapon space. The far part of the weapon from the grip (projection >= the
head fraction of its reach) is fitted with a capsule along that region's own
principal axis, so a blade runs along its edge and a hammer or axe head
across the shaft. Radius is the 80th percentile distance from that axis.

  python tools/re/measure_melee_head.py <slug> [head-fraction=0.55]
writes build/<slug>-audit/melee_head.json and prints the profile fields.
"""
from pathlib import Path
import json
import math
import struct
import sys
from audit_flamethrower_assets import chunks, parse_bones
from audit_m14_assets import mul, conj, rotate

ROOT = Path(__file__).resolve().parents[2]


def dot(a, b): return sum(x*y for x, y in zip(a, b))
def sub(a, b): return tuple(x-y for x, y in zip(a, b))
def add(a, b): return tuple(x+y for x, y in zip(a, b))
def scale(a, s): return tuple(x*s for x in a)
def norm(a): return math.sqrt(dot(a, a))


def principal_axis(points):
    c = scale(tuple(map(sum, zip(*points))), 1.0/len(points))
    m = [[0.0]*3 for _ in range(3)]
    for p in points:
        d = sub(p, c)
        for i in range(3):
            for j in range(3):
                m[i][j] += d[i]*d[j]
    v = (1.0, 0.3, 0.2)
    for _ in range(100):
        v = tuple(sum(m[i][j]*v[j] for j in range(3)) for i in range(3))
        n = norm(v) or 1.0
        v = scale(v, 1.0/n)
    return c, v


def main(slug, fraction=0.55):
    out = ROOT / f"build/{slug}-audit"
    psk = next(out.glob("export/*/SkeletalMesh3/*.psk"))
    mesh = chunks(psk); bones = parse_bones(mesh["REFSKELT"])
    positions, rotations = [], []
    for i, b in enumerate(bones):
        p, q = b["local_position"], b["local_quaternion"]
        if i:
            parent = b["parent_index"]
            p = add(positions[parent], rotate(rotations[parent], p))
            q = mul(rotations[parent], conj(q))
        positions.append(p); rotations.append(q)
    index = {b['name']: i for i, b in enumerate(bones)}
    root = index['RW_Weapon']
    points = list(struct.iter_unpack('<3f', mesh['PNTS0000'][2]))
    weights = list(struct.iter_unpack('<fii', mesh['RAWWEIGHTS'][2]))
    weapon_bone = {i for i, b in enumerate(bones) if b['name'].startswith('RW_')}
    owner = {}
    for w, p, b in weights:
        if w > owner.get(p, (0, -1))[0]: owner[p] = (w, b)
    local = [rotate(conj(rotations[root]), sub(points[p], positions[root]))
             for p, (w, b) in owner.items() if b in weapon_bone]
    assert local, "no vertices skinned to RW_ bones"
    reach_dir = max(local, key=norm)
    axis0 = scale(reach_dir, 1.0/norm(reach_dir))
    reach = dot(reach_dir, axis0)
    head = [p for p in local if dot(p, axis0) >= fraction*reach]
    c, axis = principal_axis(head)
    proj = [dot(sub(p, c), axis) for p in head]
    start, end = add(c, scale(axis, min(proj))), add(c, scale(axis, max(proj)))
    radial = sorted(norm(sub(sub(p, c), scale(axis, dot(sub(p, c), axis)))) for p in head)
    radius = max(3.0, min(14.0, radial[int(0.8*(len(radial)-1))]))
    if dot(end, axis0) < dot(start, axis0): start, end = end, start
    r3 = lambda v: [round(x, 1) for x in v]
    report = dict(scope='Offline PSK bind-pose fit; contact feel needs headset validation.',
        psk=str(psk.relative_to(ROOT)), head_fraction=fraction, reach=round(reach, 1),
        head_points=len(head), MeleeHeadStart=r3(start), MeleeHeadEnd=r3(end), MeleeRadius=round(radius, 1))
    (out / 'melee_head.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    f = lambda v: f"(X={v[0]:g},Y={v[1]:g},Z={v[2]:g})"
    print(f"MeleeHeadStart={f(r3(start))},MeleeHeadEnd={f(r3(end))},MeleeRadius={round(radius,1):g}  reach={reach:.1f}")


if __name__ == '__main__':
    main(sys.argv[1], *(float(a) for a in sys.argv[2:3]))
