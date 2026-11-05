"""Find a melee weapon's stabbing point for VRPhysicalMelee stab-and-stick.

Reads the same CLI-only UModel PSK export as measure_melee_head.py
(build/<slug>-audit/export) and works in RW_Weapon space on bind-pose
vertices skinned to RW_* bones. The point is the vertex farthest along a
direction (default: from the grip toward the fitted head centre in
build/<slug>-audit/melee_head.json, i.e. the top spike of an axe), averaged
over the vertices within 0.5 uu of it. The stab axis runs from the centroid
of the last `length` uu (default 6) of the weapon in that direction to the
point.

  python tools/re/measure_melee_point.py <slug> [length=6] [dx dy dz]
writes build/<slug>-audit/melee_point.json and prints StabTip / StabAxis.
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
def unit(a): return scale(a, 1.0/(norm(a) or 1.0))


def weapon_points(slug):
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
    return out, psk, [rotate(conj(rotations[root]), sub(points[p], positions[root]))
                      for p, (w, b) in owner.items() if b in weapon_bone]


def main(slug, length=6.0, direction=None):
    out, psk, local = weapon_points(slug)
    if direction is None:
        head = json.loads((out / 'melee_head.json').read_text(encoding='utf-8'))
        direction = scale(add(head['MeleeHeadStart'], head['MeleeHeadEnd']), 0.5)
    d = unit(direction)
    far = max(dot(p, d) for p in local)
    tip_points = [p for p in local if dot(p, d) >= far - 0.5]
    tip = scale(tuple(map(sum, zip(*tip_points))), 1.0/len(tip_points))
    base_points = [p for p in local if dot(p, d) >= far - length]
    base = scale(tuple(map(sum, zip(*base_points))), 1.0/len(base_points))
    axis = unit(sub(tip, base))
    r3 = lambda v: [round(x, 3) for x in v]
    report = dict(scope='Offline PSK bind-pose stab point; check against the model in Blender and the headset.',
                  psk=str(psk.relative_to(ROOT)), direction=r3(d), length=length,
                  StabTip=[round(x, 1) for x in tip], StabAxis=r3(axis), tip_points=len(tip_points))
    (out / 'melee_point.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    f = lambda v, n: "(" + ",".join(f"{k}={round(x, n):g}" for k, x in zip("XYZ", v)) + ")"
    print(f"StabTip={f(tip, 1)},StabAxis={f(axis, 3)}")


if __name__ == '__main__':
    args = sys.argv[1:]
    main(args[0], float(args[1]) if len(args) > 1 else 6.0,
         tuple(float(a) for a in args[2:5]) if len(args) >= 5 else None)
