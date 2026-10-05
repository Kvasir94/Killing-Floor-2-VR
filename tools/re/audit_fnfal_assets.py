"""Read the CLI-only FN FAL PSK export and cooked package; no game/tests.

Exports live in build/fnfal-audit/export. To recreate them, use the existing
UModel executable with -export -notex -out=<that folder> and
-path=D:/SteamLibrary/steamapps/common/killingfloor2/KFGame/BrewedPC, followed
by WEP_1P_FNFAL_MESH WEP_1stP_FNFAL_Rig.
"""
from pathlib import Path
import hashlib
import json
import struct
from audit_flamethrower_assets import chunks, parse_bones, package, value
from audit_m14_assets import mul, conj, rotate

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/fnfal-audit"
GAME = Path("D:/SteamLibrary/steamapps/common/killingfloor2")
LENS_MATERIAL = 2  # KFWeap_ScopedBase.ScopeMICIndex; the FAL does not override it.


def main():
    psk = OUT / "export/WEP_1P_FNFAL_MESH/SkeletalMesh3/WEP_1stP_FNFAL_Rig.psk"
    mesh = chunks(psk); bones = parse_bones(mesh["REFSKELT"])
    positions, rotations = [], []
    for i, b in enumerate(bones):
        p, q = b["local_position"], b["local_quaternion"]
        if i:
            parent = b["parent_index"]
            p = tuple(a+b for a,b in zip(positions[parent], rotate(rotations[parent], p)))
            q = mul(rotations[parent], conj(q))
        positions.append(p); rotations.append(q)
    materials = [m[0].split(b'\0')[0].decode() for m in struct.iter_unpack('<64s6i', mesh['MATT0000'][2])]
    points = list(struct.iter_unpack('<3f', mesh['PNTS0000'][2]))
    wedges = list(struct.iter_unpack('<IffBBH', mesh['VTXW0000'][2]))
    faces = list(struct.iter_unpack('<3HBBI', mesh['FACE0000'][2]))
    lens_points = sorted({wedges[w][0] for f in faces if f[3] == LENS_MATERIAL for w in f[:3]})
    root = next(i for i,b in enumerate(bones) if b['name'] == 'RW_Weapon')
    local = [rotate(conj(rotations[root]), tuple(a-b for a,b in zip(points[i], positions[root]))) for i in lens_points]
    bounds = [[min(p[i] for p in local), max(p[i] for p in local)] for i in range(3)]
    center = [(lo+hi)/2 for lo,hi in bounds]
    sight = next(i for i,b in enumerate(bones) if b['name'] == 'RW_Sight')
    center_world = tuple(a+b for a,b in zip(positions[root], rotate(rotations[root], center)))
    sight_center = rotate(conj(rotations[sight]), tuple(a-b for a,b in zip(center_world,positions[sight])))
    sight_forward = rotate(conj(rotations[sight]), rotate(rotations[root], (1,0,0)))
    weights = list(struct.iter_unpack('<fii', mesh['RAWWEIGHTS'][2]))
    lens_bones = sorted({bones[b]['name'] for w,p,b in weights if p in lens_points})
    path = GAME / 'KFGame/BrewedPC/Packages/Weapons/FNFAL/WEP_1P_FNFAL_MESH.upk'
    names, objects, fields = package(path)
    sockets = [{k:value(v,names) for k,v in fields(o).items()} for o in objects if o['cls']=='SkeletalMeshSocket']
    report = dict(scope='Offline asset/source inspection only; no build or test execution.',
        weapon='KFWeap_AssaultRifle_FNFal', bone_count=len(bones), bones=bones, materials=materials,
        sockets=sockets, lens_material_index=LENS_MATERIAL, lens_point_count=len(local),
        lens_bones=lens_bones, lens_bounds_in_weapon=bounds, lens_center_in_weapon=center,
        lens_center_in_sight=sight_center, optical_forward_in_sight=sight_forward,
        packages=[dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())],
        profile=dict(RootBone='RW_Weapon', SupportBone='RW_Weapon', IdleAnimation='Idle', MuzzleSocket='MuzzleFlash'),
        limitations=['Lens center uses lens-material geometry in the ActorX bind pose; physical eye relief and optical alignment require later headset validation.'])
    (OUT / 'evidence.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({k:report[k] for k in ('materials','lens_point_count','lens_bones','lens_center_in_sight','optical_forward_in_sight')},indent=2))


if __name__ == '__main__':
    main()
