"""Inspect installed AF2011 cooked assets offline; never launch the game/SDK.

Writes only build/af2011-audit/evidence.json. No build or test suite is run.
"""
from pathlib import Path
import hashlib
import json
from audit_flamethrower_assets import package, value, Reader

ROOT = Path(__file__).resolve().parents[2]
BASE = Path("D:/SteamLibrary/steamapps/common/killingfloor2/KFGame/BrewedPC/Packages/Weapons/AF2001")


def main():
    paths = [BASE / name for name in (
        "WEP_1P_AF2001_MESH.upk", "WEP_1P_AF2001_ANIM.upk", "WEP_AF2001_ARCH.upk")]
    report = dict(scope="Offline cooked asset inspection only; no build, test, game/SDK launch or deployment.",
                  weapon="KFWeap_Pistol_AF2011",
                  packages=[dict(path=str(p), sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths])
    names, objects, fields = package(paths[0])
    mesh = next(o for o in objects if o["cls"] == "SkeletalMesh" and o["name"] == "Wep_1stP_AF2001_Rig")
    report["mesh"] = mesh["name"]
    report["sockets"] = [{k: value(f, names) for k, f in fields(o).items()}
                         for o in objects if o["cls"] == "SkeletalMeshSocket" and o["outer"] == objects.index(mesh) + 1]
    names, objects, fields = package(paths[1])
    anim = next(o for o in objects if o["cls"] == "AnimSet" and o["name"] == "Wep_1stP_AF2001_Anim")
    report["animset"] = anim["name"]
    reader = Reader(fields(anim)["TrackBoneNames"]["value"])
    report["animation_bones"] = [reader.fname(names) for _ in range(reader.i32())]
    report["sequences"] = []
    for obj in objects:
        if obj["cls"] != "AnimSequence":
            continue
        f = fields(obj)
        report["sequences"].append({k: value(f[k], names) for k in ("SequenceName", "NumFrames", "SequenceLength", "RateScale") if k in f})
    report["animation_notifies"] = [dict(name=o["name"], cls=o["cls"], properties={k: value(f, names) for k, f in fields(o).items()})
                                   for o in objects if "AnimNotify" in o["cls"]]
    names, objects, fields = package(paths[2])
    report["muzzle_effects"] = [dict(name=o["name"], cls=o["cls"], properties={k: value(f, names) for k, f in fields(o).items()})
                               for o in objects if "MuzzleFlash" in o["cls"] or "MuzzleFlash" in o["name"]]
    out = ROOT / "build/af2011-audit"
    out.mkdir(parents=True, exist_ok=True)
    (out / "evidence.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in ("sockets", "animation_bones", "sequences", "muzzle_effects")}, indent=2))


if __name__ == "__main__":
    main()
