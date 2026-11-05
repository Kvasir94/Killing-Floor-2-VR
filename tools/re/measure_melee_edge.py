"""Find a melee weapon's cutting-edge direction for VRMeleeTraits.Edge.

Reads the same offline UModel PSK export as measure_melee_head.py (bind-pose
vertices skinned to RW_* weapon bones, in RW_Weapon space). Over the striking
region it takes the blade's long axis, then the widest direction across it.
The edge is the end of that width with the thinner cross-section; a spine is
thick. A blade whose two width ends are nearly equally thin is double-edged.

Limits found by checking every result against the models in Blender: the
long axis and blade plane are reliable, but the side choice is not. Saw-backed
spines read thin and win (Support, SWAT knives), and curved or spiked heads can
fool it (scythe, Survivalist). Confirm the side visually before trusting it.

  python tools/re/measure_melee_edge.py <slug> [head-fraction=0.55] [axe]

An axe's head runs across the shaft, so with "axe" the edge is instead the
thinner end of the head's long axis.
writes build/<slug>-audit/melee_edge.json and prints the trait fields.
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
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])


def principal(points, remove=()):
    c = scale(tuple(map(sum, zip(*points))), 1.0/len(points))
    m = [[0.0]*3 for _ in range(3)]
    for p in points:
        d = sub(p, c)
        for r in remove: d = sub(d, scale(r, dot(d, r)))
        for i in range(3):
            for j in range(3):
                m[i][j] += d[i]*d[j]
    v = (0.3, 1.0, 0.2) if remove else (1.0, 0.3, 0.2)
    for _ in range(200):
        for r in remove: v = sub(v, scale(r, dot(v, r)))
        v = tuple(sum(m[i][j]*v[j] for j in range(3)) for i in range(3))
        v = unit(v)
    return c, v


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
    root = {b['name']: i for i, b in enumerate(bones)}['RW_Weapon']
    points = list(struct.iter_unpack('<3f', mesh['PNTS0000'][2]))
    weights = list(struct.iter_unpack('<fii', mesh['RAWWEIGHTS'][2]))
    weapon_bone = {i for i, b in enumerate(bones) if b['name'].startswith('RW_')}
    owner = {}
    for w, p, b in weights:
        if w > owner.get(p, (0, -1))[0]: owner[p] = (w, b)
    local = [rotate(conj(rotations[root]), sub(points[p], positions[root]))
             for p, (w, b) in owner.items() if b in weapon_bone]
    assert local, "no vertices skinned to RW_ bones"
    return out, psk, local


def thickness(points, c, normal):
    t = sorted(dot(sub(p, c), normal) for p in points)
    if len(t) < 4: return float('inf')
    return t[int(0.9*(len(t)-1))] - t[int(0.1*(len(t)-1))]


def main(slug, fraction=0.55, mode=''):
    out, psk, local = weapon_points(slug)
    reach_dir = max(local, key=norm)
    axis0 = unit(reach_dir)
    reach = dot(reach_dir, axis0)
    head = [p for p in local if dot(p, axis0) >= fraction*reach]
    c, length = principal(head)
    _, width = principal(head, remove=(length,))
    normal = unit(cross(length, width))
    w = sorted(dot(sub(p, c), width) for p in head)
    lo, hi = w[int(0.15*(len(w)-1))], w[int(0.85*(len(w)-1))]
    side_hi = [p for p in head if dot(sub(p, c), width) >= hi]
    side_lo = [p for p in head if dot(sub(p, c), width) <= lo]
    t_hi, t_lo = thickness(side_hi, c, normal), thickness(side_lo, c, normal)
    edge = width if t_hi <= t_lo else scale(width, -1)
    if mode == 'axe':
        l = sorted(dot(sub(p, c), length) for p in head)
        a, b = l[int(0.15*(len(l)-1))], l[int(0.85*(len(l)-1))]
        t_hi = thickness([p for p in head if dot(sub(p, c), length) >= b], c, normal)
        t_lo = thickness([p for p in head if dot(sub(p, c), length) <= a], c, normal)
        edge = length if t_hi <= t_lo else scale(length, -1)
    ratio = min(t_hi, t_lo) / max(t_hi, t_lo, 1e-6)
    double = ratio > 0.7
    r3 = lambda v: [round(x, 3) for x in v]
    report = dict(scope='Offline PSK bind-pose estimate; confirm edge-on cuts in the headset.',
        psk=str(psk.relative_to(ROOT)), head_fraction=fraction, head_points=len(head),
        Edge=r3(edge), bDoubleEdge=double, thin_side=round(min(t_hi, t_lo), 2),
        thick_side=round(max(t_hi, t_lo), 2), blade_axis=r3(length))
    (out / 'melee_edge.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    e = r3(edge)
    print(f"{slug}: Edge=(X={e[0]:g},Y={e[1]:g},Z={e[2]:g}){',bDoubleEdge=true' if double else ''}"
          f"  thin/thick={min(t_hi, t_lo):.2f}/{max(t_hi, t_lo):.2f}")


if __name__ == '__main__':
    main(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 0.55,
         sys.argv[3] if len(sys.argv) > 3 else '')
