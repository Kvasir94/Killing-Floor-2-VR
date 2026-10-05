"""Read existing CLI-only M14 PSK/PSA exports and cooked packages; no game/tests.

Exports live in build/m14-audit/export. To recreate them, use the existing
UModel executable with -export -notex -out=<that folder> and
-path=D:/SteamLibrary/steamapps/common/killingfloor2/KFGame/BrewedPC, followed
by WEP_1P_M14EBR_MESH WEP_1stP_M14_EBR or
WEP_1P_M14EBR_ANIM Wep_1stP_M14_EBR_Anim.
"""
from pathlib import Path
import hashlib
import json
import struct
from audit_flamethrower_assets import chunks, parse_bones, package, value, INFO, KEY, ctext

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/m14-audit"
GAME = Path("D:/SteamLibrary/steamapps/common/killingfloor2")


def mul(a, b):
    x,y,z,w = a; X,Y,Z,W = b
    return (w*X+x*W+y*Z-z*Y, w*Y-x*Z+y*W+z*X, w*Z+x*Y-y*X+z*W, w*W-x*X-y*Y-z*Z)


def conj(q):
    return (-q[0], -q[1], -q[2], q[3])


def rotate(q, p):
    return mul(mul(q, (*p, 0)), conj(q))[:3]


def main():
    psk = OUT / "export/WEP_1P_M14EBR_MESH/SkeletalMesh3/WEP_1stP_M14_EBR.psk"
    psa = OUT / "export/WEP_1P_M14EBR_ANIM/AnimSet/Wep_1stP_M14_EBR_Anim.psa"
    mesh = chunks(psk); bones = parse_bones(mesh["REFSKELT"])
    positions, rotations = [], []
    for i, b in enumerate(bones):
        p, q = b["local_position"], b["local_quaternion"]
        if i:
            parent = b["parent_index"]
            p = tuple(a+b for a,b in zip(positions[parent], rotate(rotations[parent], p)))
            q = mul(rotations[parent], conj(q))
        positions.append(p); rotations.append(q)
    points = list(struct.iter_unpack('<3f', mesh['PNTS0000'][2]))
    wedges = list(struct.iter_unpack('<IffBBH', mesh['VTXW0000'][2]))
    faces = list(struct.iter_unpack('<3HBBI', mesh['FACE0000'][2]))
    lens_points = sorted({wedges[w][0] for f in faces if f[3] == 2 for w in f[:3]})
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
    base = GAME / 'KFGame/BrewedPC/Packages/Weapons/M14EBR'
    paths = [base / 'WEP_1P_M14EBR_MESH.upk', base / 'WEP_1P_M14EBR_ANIM.upk']
    names, objects, fields = package(paths[0])
    sockets = [{k:value(v,names) for k,v in fields(o).items()} for o in objects if o['cls']=='SkeletalMeshSocket']
    anim = chunks(psa)
    infos = list(INFO.iter_unpack(anim['ANIMINFO'][2]))
    report = dict(scope='Offline asset/source inspection only; no build or test execution.',
        weapon='KFWeap_Rifle_M14EBR', bone_count=len(bones), bones=bones,
        sequences=[dict(name=ctext(i[0]), frames=i[11], rate=i[8]) for i in infos],
        sockets=sockets, lens_material_index=2, lens_point_count=len(local),
        lens_bones=lens_bones, lens_bounds_in_weapon=bounds, lens_center_in_weapon=center,
        lens_center_in_sight=sight_center, optical_forward_in_sight=sight_forward,
        packages=[dict(path=str(p), sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths],
        profile=dict(RootBone='RW_Weapon', SupportBone='RW_Weapon', IdleAnimation='Idle', MuzzleSocket='MuzzleFlash', LaserSocket='LaserSight'),
        damage_type='KFDT_Ballistic_M14EBR',
        limitations=['Lens center uses material 2 geometry in the ActorX bind pose; physical eye relief and optical alignment require later headset validation.'])
    (OUT / 'evidence.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ('bone_count','lens_point_count','lens_bones','lens_center_in_weapon','lens_center_in_sight','optical_forward_in_sight')},indent=2))


if __name__ == '__main__':
    main()
