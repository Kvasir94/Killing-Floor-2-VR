"""Measure the stock belt links (the retired joint-chain belt, VRBeltChain, was built from them).

Run with Blender (headless):
  & 'C:\\Program Files\\Blender Foundation\\Blender 5.2\\blender.exe' --background \
      --factory-startup --python tools/measure_belt_links.py [-- --assets <checkout>]

For each belt-fed rig, for the leading round (RW_Bullets1) and the round in the
box mouth (RW_Bullets<outside>), in that bone's own frame:
  hinge   the round axis the belt bends about (from the bind belt's curvature)
  tangent the belt direction toward the leading round
  centre  the centre of the cartridge cross-section (the link's pivot)
  play    for the round in the box mouth (the loose belt's link): how far a link
          turns on its neighbour sideways (about the belt's normal) and about
          the belt (twist) before the two links' meshes touch more than they
          already interlock at rest. The child sits one pitch along its own
          belt direction from the parent's centre and turns about that centre,
          as in VRBeltChain; contact is a vertex of one mesh inside the other
          (ray parity against a BVH of the stock faces).
  axial   the cartridge's extent along the hinge from the centre (its length)
  radius  the cartridge's radius about that axis (median vertex distance)
  limits  how far one link turns on its neighbour about the hinge before the
          cross-sections either side collide: the middle link B is fixed, its
          parent A straight behind it, its child C turned by theta about C's
          own centre; the limit is the first theta where A and C, or B and C,
          overlap (convex hulls, separating-axis test) more than they already
          do straight, since neighbouring links interlock at rest.
Also the box body's extent in the box bone frame (the belt's box collider).
Stock PSK exports are read under --assets (default: this checkout).
Prints JSON; VRMG3BeltPath.BeltLink holds the values (docs/re/belt-link-geometry.md).
"""
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'tools'), str(ROOT/'tools/re')]
import inspect_stock_grip_fit as G  # noqa: E402
from mathutils import Quaternion, Vector  # noqa: E402
from mathutils.bvhtree import BVHTree  # noqa: E402

# Rig, belt bones, rounds outside the box at bind.
RIGS = {
    'MG3': ('build/mg3-audit/export/WEP_1P_MG3_MESH/SkeletalMesh3/WEP_1stP_MG3_Rig.psk', 12, 5, 'RW_Magazine'),
    'Stoner': ('build/stoner63a-audit/export/WEP_1P_Stoner63A_MESH/SkeletalMesh3/Wep_1stP_Stoner63A_Rig.psk', 14, 10, 'RW_Magazine1'),
    'Bastion': ('build/bastion-audit/export/WEP_1P_HRG_BarrierRifle_MESH/SkeletalMesh3/WEP_1stP_HRG_BarrielRifle_Rig.psk', 14, 10, 'RW_Magazine1'),
}


def hull(pts):
    pts = sorted(set((round(x, 4), round(y, 4)) for x, y in pts))
    def cross(o, a, b):
        return (a[0]-o[0])*(b[1]-o[1]) - (a[1]-o[1])*(b[0]-o[0])
    lo, hi = [], []
    for p in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    for p in reversed(pts):
        while len(hi) >= 2 and cross(hi[-2], hi[-1], p) <= 0:
            hi.pop()
        hi.append(p)
    return lo[:-1] + hi[:-1]


def penetration(a, b):
    """Smallest overlap along any edge normal of two convex polygons (<= 0: apart)."""
    best = 1e9
    for poly in (a, b):
        for i in range(len(poly)):
            x0, y0 = poly[i]
            x1, y1 = poly[(i+1) % len(poly)]
            nx, ny = y1-y0, x0-x1
            length = math.hypot(nx, ny)
            if length < 1e-9:
                continue
            nx /= length
            ny /= length
            pa = [x*nx+y*ny for x, y in a]
            pb = [x*nx+y*ny for x, y in b]
            best = min(best, min(max(pa), max(pb)) - max(min(pa), min(pb)))
    return best


def place(poly, ox, oy, th):
    c, s = math.cos(th), math.sin(th)
    return [(ox + x*c - y*s, oy + x*s + y*c) for x, y in poly]


def inside(tree, point, direction=Vector((0.577, 0.577, 0.577))):
    hits, origin = 0, point.copy()
    for _ in range(64):
        loc, _, _, _ = tree.ray_cast(origin, direction)
        if loc is None:
            break
        hits += 1
        origin = loc + direction*1e-4
    return hits % 2 == 1


def contacts(tree_a, verts_a, tree_b, verts_b):
    return sum(inside(tree_a, v) for v in verts_b) + sum(inside(tree_b, v) for v in verts_a)


def play(local, faces, centre, axes, pitch):
    """Largest turn (degrees, each way) about each axis through the parent's
    centre before the child link touches the parent more than at rest."""
    tl = axes['tangent']
    parent = BVHTree.FromPolygons(local, faces)
    result = {}
    for name in ('play', 'twist'):
        axis = axes['normal'] if name == 'play' else tl
        limits = []
        for sign in (1, -1):
            last = 0.0
            rest = None
            for step in range(0, 361 if name == 'twist' else 121):
                q = Quaternion(axis, math.radians(step*0.25*sign))
                child = [centre + q @ (v - centre + tl*pitch) for v in local]
                tree = BVHTree.FromPolygons(child, faces)
                c = contacts(parent, local, tree, child)
                if rest is None:
                    rest = c
                elif c > rest + 2:
                    break
                last = step*0.25*sign
            limits.append(round(last, 2))
        result[name + '_deg'] = sorted(limits)
    return result


def measure(psk, n, outside, box, assets=ROOT):
    w = G.geometry(Path(assets)/psk)
    names = w['names']
    p0, q0 = G.pose(w['bones'])
    bones = [names.index(f'RW_Bullets{k}') for k in range(1, n+1)]
    refp = [p0[b] for b in bones]
    hinge = Vector()
    for i in range(1, n-1):
        k = (refp[i-1]-refp[i]).normalized().cross((refp[i]-refp[i+1]).normalized())
        hinge += -k if hinge.dot(k) < 0 else k
    pitch = sum((refp[i]-refp[i+1]).length for i in range(n-1))/(n-1)
    result = {'pitch': round(pitch, 4)}
    bi = names.index(box)
    owner = lambda i: names[max(w['weights'][i], key=w['weights'][i].get)]
    body = [q0[bi].inverted() @ (Vector(w['points'][i]) - p0[bi]) for i in range(len(w['points'])) if owner(i) == box]
    result['box_min'] = [round(min(v[k] for v in body), 3) for k in range(3)]
    result['box_max'] = [round(max(v[k] for v in body), 3) for k in range(3)]
    for which in (0, outside-1):
        inv = q0[bones[which]].inverted()
        hl = (inv @ hinge).normalized()
        toward = (refp[which-1]-refp[which]) if which > 0 else (refp[0]-refp[1])
        tl = (inv @ toward).normalized()
        tl = (tl - hl*tl.dot(hl)).normalized()
        nl = hl.cross(tl)
        bone = f'RW_Bullets{which+1}'
        owned = [i for i in range(len(w['points']))
                 if names[max(w['weights'][i], key=w['weights'][i].get)] == bone]
        local = [inv @ (Vector(w['points'][i]) - p0[bones[which]]) for i in owned]
        sil = hull([(v.dot(tl), v.dot(nl)) for v in local])
        cx = (min(x for x, _ in sil) + max(x for x, _ in sil))/2
        cy = (min(y for _, y in sil) + max(y for _, y in sil))/2
        sil = [(x-cx, y-cy) for x, y in sil]
        a = place(sil, -pitch, 0, 0)
        b = place(sil, 0, 0, 0)
        base_ac = penetration(a, place(sil, pitch, 0, 0))
        base_bc = penetration(b, place(sil, pitch, 0, 0))
        limits = []
        for sign in (1, -1):
            last = 0
            for d in range(1, 181):
                th = math.radians(d*sign)
                c = place(sil, pitch*math.cos(th), pitch*math.sin(th), th)
                if penetration(a, c) > max(base_ac, 0) + 0.02 or penetration(b, c) > base_bc + 0.02:
                    break
                last = d
            limits.append(last*sign)
        centre = tl*cx + nl*cy
        axial = [v.dot(hl) for v in local]
        radial = sorted(((v-centre) - hl*(v-centre).dot(hl)).length for v in local)
        result[bone] = {'hinge': [round(x, 4) for x in hl], 'tangent': [round(x, 4) for x in tl],
                        'centre': [round(x, 4) for x in centre], 'bend_deg': sorted(limits),
                        'axial': [round(min(axial), 3), round(max(axial), 3)],
                        'radius': round(radial[len(radial)//2], 3)}
        if which == outside-1:
            index = {v: k for k, v in enumerate(owned)}
            faces = [[index[i] for i in f] for f in G.selected_faces(w, lambda b, bone=bone: b == bone)]
            result[bone].update(play(local, faces, centre, {'tangent': tl, 'normal': nl}, pitch))
    return result


def main():
    args = sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
    assets = args[args.index('--assets')+1] if '--assets' in args else ROOT
    print(json.dumps({key: measure(*rig, assets=assets) for key, rig in RIGS.items()}, indent=1))
    return 0


if __name__ == '__main__':
    main()
