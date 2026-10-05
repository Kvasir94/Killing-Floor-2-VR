"""Inspect saved CLI-only Pulverizer exports and cooked packages; no runtime/tests.

Recreate PSK/PSA with D:/KF1-VR/scratch/umodel/umodel.exe -export -notex,
-out=D:/KF2-VR/build/pulverizer-audit/export and
-path=D:/SteamLibrary/steamapps/common/killingfloor2/KFGame/BrewedPC, then:
  WEP_1P_Pulverizer_MESH Wep_1stP_Pulverizer_Rig_New
  WEP_1P_Pulverizer_ANIM Wep_1stP_Pulverizer_Anim
"""
from pathlib import Path
import hashlib
import json
import struct
from audit_flamethrower_assets import chunks, parse_bones, package, value, INFO, ctext, read_package
from audit_m14_assets import mul, conj, rotate

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/pulverizer-audit"
GAME = Path("D:/SteamLibrary/steamapps/common/killingfloor2")


def main():
    psk = OUT / "export/WEP_1P_Pulverizer_MESH/SkeletalMesh3/Wep_1stP_Pulverizer_Rig_New.psk"
    psa = OUT / "export/WEP_1P_Pulverizer_ANIM/AnimSet/Wep_1stP_Pulverizer_Anim.psa"
    mesh = chunks(psk); bones = parse_bones(mesh["REFSKELT"])
    positions, rotations = [], []
    for i, bone in enumerate(bones):
        p, q = bone["local_position"], bone["local_quaternion"]
        if i:
            parent = bone["parent_index"]
            p = tuple(a + b for a, b in zip(positions[parent], rotate(rotations[parent], p)))
            q = mul(rotations[parent], conj(q))
        positions.append(p); rotations.append(q)
    root = next(i for i, b in enumerate(bones) if b["name"] == "RW_Weapon")
    points = list(struct.iter_unpack("<3f", mesh["PNTS0000"][2]))
    local = [rotate(conj(rotations[root]), tuple(a-b for a, b in zip(p, positions[root]))) for p in points]
    weights = list(struct.iter_unpack("<fii", mesh["RAWWEIGHTS"][2]))
    groups = {}
    for i, bone in enumerate(bones):
        indices = sorted({p for w, p, b in weights if b == i and w >= 0.5})
        if indices:
            groups[bone["name"]] = dict(points=len(indices), bounds_in_weapon=[
                [min(local[p][axis] for p in indices), max(local[p][axis] for p in indices)] for axis in range(3)])
    base = GAME / "KFGame/BrewedPC/Packages/Weapons/Pulverizer"
    paths = [base / "WEP_1P_Pulverizer_MESH.upk", base / "WEP_1P_Pulverizer_ANIM.upk"]
    names, objects, fields = package(paths[0])
    sockets = [{k: value(v, names) for k, v in fields(o).items()} for o in objects if o["cls"] == "SkeletalMeshSocket"]
    infos = list(INFO.iter_unpack(chunks(psa)["ANIMINFO"][2]))
    _, _, imports, _ = read_package(paths[1])
    def imported_path(index):
        obj = imports[-index-1]
        return (imported_path(obj["outer"]) + "." if obj["outer"] < 0 else "") + obj["name"]
    sounds = sorted({imported_path(-i-1) for i, obj in enumerate(imports) if obj["cls"] == "AkEvent"})
    report = dict(scope="Offline asset inspection; no build or tests.", weapon="KFWeap_Blunt_Pulverizer",
        bone_count=len(bones), bones=bones, vertex_groups=groups, sockets=sockets, sound_imports=sounds,
        sequences=[dict(name=ctext(i[0]), frames=i[11], rate=i[8]) for i in infos],
        packages=[dict(path=str(p), sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths])
    (OUT / "evidence.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(dict(bone_count=len(bones), sound_imports=sounds), indent=2))


if __name__ == "__main__":
    main()
