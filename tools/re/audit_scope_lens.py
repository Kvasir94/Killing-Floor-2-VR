"""Measure a stock scoped rig's lens center for VRM14Scope.LensOffset.

Reads an existing CLI-only UModel PSK export (see audit_stock_gun_assets.py);
no game, SDK, editor or tests. The lens is the geometry of material slot
ScopeMICIndex (KFWeap_ScopedBase default 2, unless the class overrides it).
UModel may split a mesh element into two slots, so check the printed
material list against the stock lens MIC before trusting a slot.

  python tools/re/audit_scope_lens.py <slug> <lens-slot> [sight-bone]
writes build/<slug>-audit/lens.json and prints the offset in the sight bone.
"""
from pathlib import Path
import json
import struct
import sys
from audit_flamethrower_assets import chunks, parse_bones
from audit_m14_assets import mul, conj, rotate

ROOT = Path(__file__).resolve().parents[2]


def main(slug, slot, sight_name="RW_Sight"):
    out = ROOT / f"build/{slug}-audit"
    psk = next(out.glob("export/*/SkeletalMesh3/*.psk"))
    mesh = chunks(psk); bones = parse_bones(mesh["REFSKELT"])
    positions, rotations = [], []
    for i, b in enumerate(bones):
        p, q = b["local_position"], b["local_quaternion"]
        if i:
            parent = b["parent_index"]
            p = tuple(a+c for a, c in zip(positions[parent], rotate(rotations[parent], p)))
            q = mul(rotations[parent], conj(q))
        positions.append(p); rotations.append(q)
    materials = [m[0].split(b'\0')[0].decode() for m in struct.iter_unpack('<64s6i', mesh['MATT0000'][2])]
    points = list(struct.iter_unpack('<3f', mesh['PNTS0000'][2]))
    wedges = list(struct.iter_unpack('<IffBBH', mesh['VTXW0000'][2]))
    faces = list(struct.iter_unpack('<3HBBI', mesh['FACE0000'][2]))
    lens = sorted({wedges[w][0] for f in faces if f[3] == slot for w in f[:3]})
    assert lens, f"material slot {slot} has no geometry; slots: {materials}"
    index = {b['name']: i for i, b in enumerate(bones)}
    sight = index[sight_name]
    local = [rotate(conj(rotations[sight]), tuple(a-c for a, c in zip(points[i], positions[sight]))) for i in lens]
    bounds = [[min(p[i] for p in local), max(p[i] for p in local)] for i in range(3)]
    center = [(lo+hi)/2 for lo, hi in bounds]
    weights = list(struct.iter_unpack('<fii', mesh['RAWWEIGHTS'][2]))
    report = dict(scope='Offline PSK inspection only; optical alignment needs headset validation.',
        psk=str(psk.relative_to(ROOT)), materials=materials, lens_slot=slot, sight_bone=sight_name,
        lens_point_count=len(lens), lens_bones=sorted({bones[b]['name'] for w, p, b in weights if p in lens}),
        lens_bounds_in_sight=bounds, lens_center_in_sight=center)
    (out / 'lens.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({k: report[k] for k in ('materials', 'lens_point_count', 'lens_bones', 'lens_center_in_sight')}, indent=2))


if __name__ == '__main__':
    main(sys.argv[1], int(sys.argv[2]), *sys.argv[3:4])
