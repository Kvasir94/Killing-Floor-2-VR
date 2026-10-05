"""Offline cooked-package and UModel PSK/PSA evidence for one stock KF2 gun.

Reads installed assets and existing CLI-only UModel exports; never launches the
game, SDK, editor or Blender. Writes only build/<slug>-audit/evidence.json.
Asset inspection is not gameplay, fit or headset acceptance.

Reproduce (PowerShell), e.g. for the SA80 L85A2 Bullpup:
  $u = 'D:/KF1-VR/scratch/umodel/umodel.exe'
  $p = 'D:/SteamLibrary/steamapps/common/killingfloor2/KFGame/BrewedPC'
  & $u -export -notex -out=D:/KF2-VR/build/sa80-audit/export -path=$p WEP_1P_L85A2_MESH Wep_1stP_L85A2_Rig
  & $u -export -notex -out=D:/KF2-VR/build/sa80-audit/export -path=$p WEP_1P_L85A2_ANIM Wep_1st_L85A2_Anim
  python tools/re/audit_stock_gun_assets.py sa80 KFWeap_AssaultRifle_Bullpup
The class's FirstPersonMeshName/FirstPersonAnimSetNames select the packages.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import re
import struct

from audit_flamethrower_assets import chunks, parse_bones, package, value, INFO, KEY, ctext
from audit_m14_assets import mul, conj, rotate

ROOT = Path(__file__).resolve().parents[2]
GAME = Path("D:/SteamLibrary/steamapps/common/killingfloor2")
SRC = GAME / "Development/Src"
WEAPONS = GAME / "KFGame/BrewedPC/Packages/Weapons"
# Sequences whose hand placement must hold on the gun while the player keeps
# both grips. Reloads, equips and bashes intentionally move hands off the gun.
HELD_PREFIXES = ("idle", "shoot")


def class_source(name):
    path = next(SRC.glob(f"*/Classes/{name}.uc"))
    return path, path.read_text(encoding="utf-8", errors="replace")


def class_facts(name):
    path, text = class_source(name)
    code = re.sub(r"//[^\n]*", "", text)
    def props(key):
        return {m.group(1) or "": m.group(2).strip() for m in re.finditer(key + r"(?:\[|\()?(\w*)(?:\]|\))?\s*=\s*([^\n]+)", code)}
    subclasses = sorted(p.stem for p in SRC.glob("*/Classes/*.uc")
                        if re.search(r"\bclass\s+\w+\s+extends\s+" + name + r"\b", p.read_text(encoding="utf-8", errors="replace")))
    return dict(
        path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        parent=re.search(r"\bclass\s+\w+\s+extends\s+(\w+)", code).group(1),
        subclasses_matching_IsA=subclasses,
        first_person_mesh=props("FirstPersonMeshName").get("", "").strip('"'),
        first_person_animsets=[v.strip('"') for v in props("FirstPersonAnimSetNames").values()],
        firing_states=props("FiringStatesArray"), fire_types=props("WeaponFireTypes"),
        fire_intervals=props("FireInterval"), damage_types=props("InstantHitDamageTypes"),
        burst_amount=props("BurstAmount").get("", None),
        magazine_capacity=props("MagazineCapacity"), inventory_size=props("InventorySize").get("", None),
        has_flashlight=props("bHasFlashlight").get("", None), has_iron_sights=props("bHasIronSights").get("", None),
        has_laser_sight=props("LaserSightTemplate").get("", None),
    )


def global_pose(bones, local):
    """ActorX convention: non-root local rotations are stored conjugated."""
    positions, rotations = [], []
    for i, b in enumerate(bones):
        p, q = local[i]
        if i:
            parent = b["parent_index"]
            p = tuple(a + c for a, c in zip(positions[parent], rotate(rotations[parent], p)))
            q = mul(rotations[parent], conj(q))
        positions.append(tuple(p)); rotations.append(tuple(q))
    return positions, rotations


def relative(pose, bone, frame_bone):
    positions, rotations = pose
    q = rotations[frame_bone]
    return (rotate(conj(q), tuple(a - c for a, c in zip(positions[bone], positions[frame_bone]))),
            mul(conj(q), rotations[bone]))


def angle(a, b):
    dot = abs(sum(x * y for x, y in zip(a, b))) / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(x * x for x in b)))
    return math.degrees(2 * math.acos(min(1.0, dot)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("slug"); parser.add_argument("weapon_class")
    args = parser.parse_args()
    out = ROOT / "build" / f"{args.slug}-audit"
    facts = class_facts(args.weapon_class)
    mesh_pkg, mesh_name = facts["first_person_mesh"].split(".")
    anim_pkg, anim_name = facts["first_person_animsets"][0].split(".")
    key = mesh_pkg.removeprefix("WEP_1P_").removesuffix("_MESH")
    paths = dict(MESH=next(WEAPONS.glob(f"*/{mesh_pkg}.upk")), ANIM=next(WEAPONS.glob(f"*/{anim_pkg}.upk")))
    report = dict(
        scope="Read-only cooked UPK parse and CLI-only UModel PSK/PSA decoding; no game/SDK/editor/Blender/XR launch. Profile fit remains untested in game.",
        weapon=args.weapon_class, package_key=key, mesh=f"{mesh_pkg}.{mesh_name}", animset=f"{anim_pkg}.{anim_name}",
        stock_class=facts,
        packages={k: dict(path=str(p), sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for k, p in paths.items()})

    names, objects, fields = package(paths["MESH"])
    mesh_obj = next(o for o in objects if o["name"].lower() == mesh_name.lower() and o["cls"] == "SkeletalMesh")
    mesh_index = objects.index(mesh_obj) + 1
    report["sockets"] = [{k: value(f, names) for k, f in fields(o).items()}
                         for o in objects if o["cls"] == "SkeletalMeshSocket" and o["outer"] == mesh_index]

    psk_path = out / "export" / mesh_pkg / "SkeletalMesh3" / f"{mesh_name}.psk"
    psa_path = out / "export" / anim_pkg / "AnimSet" / f"{anim_name}.psa"
    mesh = chunks(psk_path)
    bones = parse_bones(mesh["REFSKELT"])
    index = {b["name"]: i for i, b in enumerate(bones)}
    report["exports"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in (psk_path, psa_path)}
    report["bone_count"] = len(bones)
    report["bones"] = [dict(name=b["name"], parent=b["parent"]) for b in bones]
    report["wrist_bones_present"] = [b for b in ("RightHand_1stP", "LeftHand_1stP") if b in index]

    materials = [ctext(row[:64]) for row in (mesh["MATT0000"][2][i:i + mesh["MATT0000"][0]]
                                             for i in range(0, len(mesh["MATT0000"][2]), mesh["MATT0000"][0]))]
    wedges = list(struct.iter_unpack("<IffBBH", mesh["VTXW0000"][2]))
    faces = list(struct.iter_unpack("<3HBBI", mesh["FACE0000"][2]))
    weights = list(struct.iter_unpack("<fii", mesh["RAWWEIGHTS"][2]))
    slots = []
    for slot, material in enumerate(materials):
        points = {wedges[w][0] for f in faces if f[3] == slot for w in f[:3]}
        slots.append(dict(slot=slot, material=material, faces=sum(1 for f in faces if f[3] == slot),
                          bones=sorted({bones[b]["name"] for w, p, b in weights if p in points and w > 0})))
    report["material_slots"] = slots

    names, objects, fields = package(paths["ANIM"])
    anim_obj = next(o for o in objects if o["name"].lower() == anim_name.lower() and o["cls"] == "AnimSet")
    report["bAnimRotationOnly"] = value(fields(anim_obj)["bAnimRotationOnly"], names) if "bAnimRotationOnly" in fields(anim_obj) else None

    psa = chunks(psa_path)
    # UModel's PSA track order differs from the PSK skeleton and its BONENAMES
    # parents all point at Root, so keys are looked up by name and evaluated
    # on the PSK hierarchy.
    pbones = parse_bones(psa["BONENAMES"])
    # Locator bones (BarrelCenter, SightLocator...) may carry no track; the
    # engine then holds them at their reference pose, and so does the audit.
    # Tracks for bones the mesh lacks (an animation shared with a variant rig)
    # cannot move this mesh; they are recorded and skipped.
    report["tracks_without_mesh_bone"] = sorted(set(b["name"] for b in pbones) - set(index))
    pindex = {b["name"]: i for i, b in enumerate(pbones)}
    report["untracked_bones_at_reference_pose"] = sorted(set(index) - set(pindex))
    infos = list(INFO.iter_unpack(psa["ANIMINFO"][2]))
    keys = psa["ANIMKEYS"][2]

    def frame_pose(info, frame):
        base = (info[10] + frame) * info[2]
        local = []
        for b in bones:
            if b["name"] not in pindex:
                local.append((b["local_position"], b["local_quaternion"]))
                continue
            k = KEY.unpack_from(keys, (base + pindex[b["name"]]) * KEY.size)
            local.append((k[0:3], k[3:7]))
        return global_pose(bones, local)

    report["sequences"] = [dict(name=ctext(i[0]), frames=i[11], rate=i[8], seconds=i[7]) for i in infos]
    idle = next(i for i in infos if ctext(i[0]) == "Idle")
    idle_pose = frame_pose(idle, 0)
    root = index["RW_Weapon"]

    # Self-check of the quaternion convention: a rigid child such as the
    # muzzle must sit at its reference-pose offset from RW_Weapon in Idle.
    ref_pose = global_pose(bones, [(b["local_position"], b["local_quaternion"]) for b in bones])
    # Use the bone that carries the stock muzzle socket (RW_Muzzle, RW_Barrel...).
    muzzle_bone = next((s.get("BoneName") for s in report["sockets"] if s.get("SocketName") == "MuzzleFlash"), None)
    muzzle = index.get(muzzle_bone)
    if muzzle is not None and muzzle != root:
        ref_rel = relative(ref_pose, muzzle, root)[0]
        idle_rel = relative(idle_pose, muzzle, root)[0]
        report["fk_convention_check"] = dict(bone=muzzle_bone, reference_in_weapon=ref_rel, idle_in_weapon=idle_rel,
                                             distance=math.dist(ref_rel, idle_rel))

    weapon_bones = [b["name"] for b in bones if b["name"].startswith("RW_") and b["name"] != "RW_Weapon"]
    motion = []
    hands = {h: index[h] for h in ("RightHand_1stP", "LeftHand_1stP") if h in index}
    idle_rel = {name: relative(idle_pose, i, root) for name, i in list(hands.items()) + [(n, index[n]) for n in weapon_bones]}
    support = {n: dict(max_translation=0.0, max_rotation_deg=0.0) for n in ["RW_Weapon"] + weapon_bones}
    left = hands.get("LeftHand_1stP")
    left_idle = {n: relative(idle_pose, left, index[n]) for n in support} if left is not None else {}
    for info in infos:
        name = ctext(info[0])
        row = dict(animation=name, frames=info[11], bones={})
        held = name.lower().startswith(HELD_PREFIXES)
        for frame in range(info[11]):
            pose = frame_pose(info, frame)
            for bone_name, (ref_p, ref_q) in idle_rel.items():
                p, q = relative(pose, index[bone_name], root)
                entry = row["bones"].setdefault(bone_name, dict(max_translation=0.0, max_rotation_deg=0.0))
                entry["max_translation"] = max(entry["max_translation"], math.dist(p, ref_p))
                entry["max_rotation_deg"] = max(entry["max_rotation_deg"], angle(q, ref_q))
            if held and left is not None:
                for anchor, (ref_p, ref_q) in left_idle.items():
                    p, q = relative(pose, left, index[anchor])
                    s = support[anchor]
                    s["max_translation"] = max(s["max_translation"], math.dist(p, ref_p))
                    s["max_rotation_deg"] = max(s["max_rotation_deg"], angle(q, ref_q))
        row["bones"] = {k: v for k, v in row["bones"].items() if v["max_translation"] > 0.01 or v["max_rotation_deg"] > 0.05}
        motion.append(row)
    report["motion_relative_to_RW_Weapon_from_idle"] = motion
    report["left_hand_drift_by_anchor_in_held_sequences"] = dict(
        sequences=[r["animation"] for r in motion if r["animation"].lower().startswith(HELD_PREFIXES)],
        anchors=dict(sorted(support.items(), key=lambda kv: (round(kv[1]["max_translation"], 3), kv[0] != "RW_Weapon"))))
    report["idle_hands_in_RW_Weapon"] = {h: dict(position=idle_rel[h][0], quaternion=idle_rel[h][1]) for h in hands}
    socket_names = {s.get("SocketName") for s in report["sockets"]}
    report["socket_checks"] = dict(MuzzleFlash="MuzzleFlash" in socket_names, LaserSight="LaserSight" in socket_names,
                                   FlashLight="FlashLight" in socket_names, ShellEject="ShellEject" in socket_names)
    assert any(s["name"] == "Idle" and s["frames"] > 0 for s in report["sequences"])
    out.joinpath("evidence.json").write_text(json.dumps(report, indent=2) + "\n")

    print(json.dumps(dict(
        weapon=args.weapon_class, parent=facts["parent"], subclasses=facts["subclasses_matching_IsA"],
        bones=len(bones), sequences=[s["name"] for s in report["sequences"]], sockets=report["sockets"],
        materials=[(s["slot"], s["material"], s["faces"], s["bones"]) for s in slots],
        fk_check=report.get("fk_convention_check", {}).get("distance"),
        left_hand_anchor_ranking=list(report["left_hand_drift_by_anchor_in_held_sequences"]["anchors"].items())[:6],
        firing=facts["firing_states"], burst=facts["burst_amount"], flashlight=facts["has_flashlight"]), indent=1, default=str))


if __name__ == "__main__":
    main()
