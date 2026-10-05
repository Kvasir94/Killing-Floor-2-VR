"""Offline cooked-package and UModel PSK/PSA evidence for the stock Flamethrower.

Requires prior CLI-only UModel exports under build/flamethrower-audit/export.
Reads installed assets; writes only build/flamethrower-audit/evidence.json.

Reproduce the extraction in PowerShell (explicit -export never opens a viewer):
  New-Item -ItemType Directory -Path D:/KF2-VR/build/flamethrower-audit/export -Force
  & D:/KF1-VR/scratch/umodel/umodel.exe -export -notex -out=D:/KF2-VR/build/flamethrower-audit/export -path=D:/SteamLibrary/steamapps/common/killingfloor2/KFGame/BrewedPC WEP_1P_Flamethrower_MESH Wep_1stP_Flamethrower_Rig
  & D:/KF1-VR/scratch/umodel/umodel.exe -export -notex -out=D:/KF2-VR/build/flamethrower-audit/export -path=D:/SteamLibrary/steamapps/common/killingfloor2/KFGame/BrewedPC WEP_1P_Flamethrower_ANIM Wep_1stP_Flamethrower_anim
  python D:/KF2-VR/tools/re/audit_flamethrower_assets.py
"""
from pathlib import Path
import hashlib
import json
import math
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from audit_source_assets import read_package, properties
from ue3.upkg import Reader

GAME = Path("D:/SteamLibrary/steamapps/common/killingfloor2")
OUT = ROOT / "build/flamethrower-audit"
BONE = struct.Struct("<64s3i11f")
INFO = struct.Struct("<64s64s4i3f3i")
KEY = struct.Struct("<8f")


def ctext(raw):
    return raw.rstrip(b"\0").decode()


def chunks(path):
    data, offset, result = path.read_bytes(), 0, {}
    while offset + 32 <= len(data):
        name, flag, size, count = struct.unpack_from("<20s3i", data, offset)
        offset += 32
        result[ctext(name)] = (size, count, data[offset:offset + size * count])
        offset += size * count
    assert offset == len(data), (path, offset, len(data))
    return result


def parse_bones(chunk):
    size, count, raw = chunk
    assert size == BONE.size
    rows = [BONE.unpack_from(raw, i * size) for i in range(count)]
    names = [ctext(row[0]) for row in rows]
    return [dict(name=names[i], parent=names[row[3]], parent_index=row[3],
                 local_quaternion=row[4:8], local_position=row[8:11])
            for i, row in enumerate(rows)]


def value(field, names):
    kind, data = field["kind"], field["value"]
    if kind == "NameProperty": return Reader(data).fname(names)
    if kind == "StrProperty": return Reader(data).fstring()
    if kind == "IntProperty": return struct.unpack("<i", data)[0]
    if kind == "FloatProperty": return struct.unpack("<f", data)[0]
    if kind == "BoolProperty": return field["extra"]
    if kind == "StructProperty" and field["extra"] == "Vector": return struct.unpack("<3f", data)
    if kind == "StructProperty" and field["extra"] == "Vector2D": return struct.unpack("<2f", data)
    if kind == "StructProperty" and field["extra"] == "Rotator": return struct.unpack("<3i", data)
    if kind == "ObjectProperty": return struct.unpack("<i", data)[0]
    return data.hex()


def package(path):
    data, names, imports, objects = read_package(path)
    def fields(obj):
        return properties(data[obj["offset"] + 4:obj["offset"] + obj["size"]], names)[0]
    return names, objects, fields


def main():
    base = GAME / "KFGame/BrewedPC/Packages/Weapons/Flamethrower"
    paths = {kind: base / f"WEP_1P_Flamethrower_{kind}.upk" for kind in ("MESH", "ANIM")}
    report = dict(
        scope="Offline cooked UPK parsing and existing command-line UModel PSK/PSA decoding; no game/editor/Blender/XR launch, build, test, deployment or settings change.",
        weapon="KFWeap_Flame_Flamethrower",
        mesh="WEP_1P_Flamethrower_MESH.Wep_1stP_Flamethrower_Rig",
        animset="WEP_1P_Flamethrower_ANIM.Wep_1stP_Flamethrower_anim",
        packages={kind: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for kind, path in paths.items()},
    )
    names, objects, fields = package(paths["MESH"])
    mesh = next(o for o in objects if o["name"] == "Wep_1stP_Flamethrower_Rig" and o["cls"] == "SkeletalMesh")
    mesh_index = objects.index(mesh) + 1
    report["sockets"] = [{k: value(f, names) for k, f in fields(o).items()}
                         for o in objects if o["cls"] == "SkeletalMeshSocket" and o["outer"] == mesh_index]
    psk = OUT / "export/WEP_1P_Flamethrower_MESH/SkeletalMesh3/Wep_1stP_Flamethrower_Rig.psk"
    bones = parse_bones(chunks(psk)["REFSKELT"])
    report["bones"] = bones
    report["bone_count"] = len(bones)
    names, objects, fields = package(paths["ANIM"])
    anim = next(o for o in objects if o["name"] == "Wep_1stP_Flamethrower_anim" and o["cls"] == "AnimSet")
    ap = fields(anim)
    reader = Reader(ap["TrackBoneNames"]["value"])
    tracks = [reader.fname(names) for _ in range(reader.i32())]
    assert set(tracks) == {b["name"] for b in bones}
    report["animation_track_count"] = len(tracks)
    report["bAnimRotationOnly"] = value(ap["bAnimRotationOnly"], names)
    report["sequences"] = []
    for obj in objects:
        if obj["cls"] != "AnimSequence": continue
        f = fields(obj)
        report["sequences"].append({k: value(f[k], names) for k in ("SequenceName", "NumFrames", "SequenceLength", "RateScale") if k in f})
    report["animation_notifies"] = [dict(name=o["name"], cls=o["cls"], properties={k: value(f, names) for k, f in fields(o).items()})
                                   for o in objects if "AnimNotify" in o["cls"]]
    psa = OUT / "export/WEP_1P_Flamethrower_ANIM/AnimSet/Wep_1stP_Flamethrower_anim.psa"
    pc = chunks(psa)
    psa_names = [b["name"] for b in parse_bones(pc["BONENAMES"])]
    size, count, raw = pc["ANIMINFO"]
    assert size == INFO.size
    infos = [INFO.unpack_from(raw, i * size) for i in range(count)]
    size, count, keys = pc["ANIMKEYS"]
    assert size == KEY.size
    idle = next(info for info in infos if ctext(info[0]) == "Idle")

    def sample(info, frame, bone):
        return KEY.unpack_from(keys, ((info[10] + frame) * info[2] + psa_names.index(bone)) * size)

    selected = [name for name in psa_names if name.startswith("RW_") or name in ("RightHand_1stP", "LeftHand_1stP")]
    report["idle_frame_zero"] = {bone: dict(position=sample(idle, 0, bone)[:3], quaternion=sample(idle, 0, bone)[3:7]) for bone in selected}
    report["local_animation_motion"] = []
    for info in infos:
        name = ctext(info[0])
        if name != "Idle" and not any(token in name.lower() for token in ("reload", "shoot", "putdown", "equip", "idle", "bash")): continue
        row = dict(animation=name, frames=info[11], rate=info[8], bones={})
        for bone in selected:
            ref = sample(idle, 0, bone)
            max_translation, max_rotation = 0, 0
            for frame in range(info[11]):
                key = sample(info, frame, bone)
                max_translation = max(max_translation, math.dist(key[:3], ref[:3]))
                norm = math.sqrt(sum(x*x for x in key[3:7])) * math.sqrt(sum(x*x for x in ref[3:7]))
                dot = abs(sum(x*y for x, y in zip(key[3:7], ref[3:7]))) / norm if norm else 1
                max_rotation = max(max_rotation, math.degrees(2 * math.acos(min(1, dot))))
            row["bones"][bone] = dict(max_local_translation_from_idle=max_translation, max_local_rotation_from_idle_deg=max_rotation)
        report["local_animation_motion"].append(row)
    report["profile_recommendation"] = dict(RootBone="RW_Weapon", IdleAnimation="Idle", SupportBone="RW_Weapon", MuzzleSocket="MuzzleFlash", bFirearm=True, bOneHanded=False, bGripAltFire=False)
    arch_path = base / "WEP_Flamethrower_ARCH.upk"
    names, objects, fields = package(arch_path)
    spray = next(o for o in objects if o["name"] == "WEP_Flamethrower_Flame" and o["cls"] == "SprayActor_Flame")
    spray_fields = fields(spray)
    spray_source = GAME / "Development/Src/KFGameContent/Classes/SprayActor_Flame.uc"
    socket_default = next(line.strip() for line in spray_source.read_text().splitlines() if "SpraySocketName=" in line)
    report["stock_spray_archetype"] = dict(
        package_path=str(arch_path), sha256=hashlib.sha256(arch_path.read_bytes()).hexdigest(),
        object=spray["name"], cls=spray["cls"],
        overrides={key: value(spray_fields[key], names) for key in ("SpraySocketName", "SprayDamage", "SplashDamageRadius", "SplashDamageInstigatorDamageScale") if key in spray_fields},
        socket_override_present="SpraySocketName" in spray_fields,
        inherited_socket_source=str(spray_source), inherited_socket_default=socket_default,
        damage_interval_source="KFWeap_FlameBase.TurnOnPilot assigns both pool actors the weapon default fire interval; KFWeap_Flame_Flamethrower default is 0.07 seconds.",
    )
    # Resolve the cooked override instead of assuming the generic spray base's
    # KFDT_Fire default. This is the class the typed gameplay replay requires.
    _, _, arch_imports, _ = read_package(arch_path)
    damage_ref = value(spray_fields["MyDamageType"], names)
    assert damage_ref < 0, "Expected an imported stock damage class"
    damage_import = arch_imports[-damage_ref - 1]
    assert damage_import["outer"] < 0, "Expected the damage class's package import"
    damage_package = arch_imports[-damage_import["outer"] - 1]
    report["stock_spray_archetype"]["my_damage_type"] = dict(
        object_reference=damage_ref, class_name=damage_import["name"],
        package=damage_package["name"],
        class_path=damage_package["name"] + "." + damage_import["name"],
        source="Cooked MyDamageType ObjectProperty override, resolved through the import table",
    )
    report["source_receipts"] = {}
    for relative in (
        "Development/Src/KFGameContent/Classes/KFWeap_Flame_Flamethrower.uc",
        "Development/Src/KFGameContent/Classes/SprayActor_Flame.uc",
        "Development/Src/KFGame/Classes/KFWeap_FlameBase.uc",
        "Development/Src/KFGame/Classes/KFSprayActor.uc",
    ):
        source = GAME / relative
        report["source_receipts"][relative] = dict(path=str(source), sha256=hashlib.sha256(source.read_bytes()).hexdigest())
    executable = "D:/KF1-VR/scratch/umodel/umodel.exe"
    common_args = ["-export", "-notex", f"-out={OUT.as_posix()}/export", f"-path={GAME.as_posix()}/KFGame/BrewedPC"]
    report["reproduction"] = dict(
        output_directory=str(OUT),
        extraction_argv=[[executable] + common_args + ["WEP_1P_Flamethrower_MESH", "Wep_1stP_Flamethrower_Rig"],
                         [executable] + common_args + ["WEP_1P_Flamethrower_ANIM", "Wep_1stP_Flamethrower_anim"]],
        audit_argv=["python", str(Path(__file__).resolve())],
    )
    report["limitations"] = ["Bone, socket and animation availability are verified offline; fitted visual alignment, damage and headset acceptance remain untested.", "Motion metrics are local-to-parent, measured against Idle frame 0; they are not a world-space animation acceptance test."]
    (OUT / "evidence.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("bone_count", "sockets", "profile_recommendation")}, indent=2))
    print("WEAPON BONES", [b["name"] for b in bones if b["name"].startswith("RW_")])
    print("SEQUENCES", [seq["SequenceName"] for seq in report["sequences"]])


if __name__ == "__main__":
    main()
