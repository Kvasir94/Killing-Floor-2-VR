"""Sample a stock melee weapon's RW_Damage bone through its 1P attack animations.

Stock melee hit traces (KFMeleeHelperBase.HitboxChain) hang from the
HitboxBoneName bone, RW_Damage by default, along its Z axis. This reads the
offline UModel export (build/<slug>-audit/export, PSK + PSA) and, for every
attack sequence, poses the rig frame by frame and reports in rig-root space
(the 1P arms root, which sits at the player's view):

- where RW_Damage is and where its Z axis points;
- the blade tip (MeleeHeadEnd from build/<slug>-audit/melee_head.json, in
  RW_Weapon space) and both hands;
- how far along the damage axis the tip falls, how far the tip sits off that
  axis, and the angle between the damage axis and the weapon's own reach axis.

  python -I tools/re/sample_melee_damage_bone.py <slug> [sequence-substring=Atk]
writes build/<slug>-audit/damage_bone_samples.json and prints a summary.
"""
from pathlib import Path
import json
import math
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_flamethrower_assets import chunks, parse_bones, ctext, INFO, KEY  # noqa: E402
from audit_m14_assets import mul, conj, rotate  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def sub(a, b): return tuple(x - y for x, y in zip(a, b))
def add(a, b): return tuple(x + y for x, y in zip(a, b))
def dot(a, b): return sum(x * y for x, y in zip(a, b))
def norm(a): return math.sqrt(dot(a, a))
def unit(a):
    n = norm(a)
    return tuple(x / n for x in a) if n else a


def main(slug, needle="Atk"):
    audit = ROOT / "build" / f"{slug}-audit"
    psk = next((audit / "export").glob("*MESH*/SkeletalMesh3/*.psk"))
    psa = next((audit / "export").glob("*ANIM*/AnimSet/*.psa"))
    head = json.loads((audit / "melee_head.json").read_text())
    tip_local = tuple(head["MeleeHeadEnd"])
    bones = parse_bones(chunks(psk)["REFSKELT"])
    index = {b["name"]: i for i, b in enumerate(bones)}
    anim = chunks(psa)
    names = [b["name"] for b in parse_bones(anim["BONENAMES"])]
    size, count, raw = anim["ANIMINFO"]
    infos = [INFO.unpack_from(raw, i * size) for i in range(count)]
    keys = anim["ANIMKEYS"][2]

    def pose(info, frame):
        pos, rot = [], []
        for i, b in enumerate(bones):
            if b["name"] in names:
                k = KEY.unpack_from(keys, ((info[10] + frame) * info[2] + names.index(b["name"])) * KEY.size)
                q, p = k[3:7], k[:3]
            else:
                q, p = b["local_quaternion"], b["local_position"]
            if i:
                parent = b["parent_index"]
                p = add(pos[parent], rotate(rot[parent], p))
                q = mul(rot[parent], conj(q))
            pos.append(p); rot.append(q)
        return pos, rot

    hand_names = [n for n in ("RightHand_1stP", "LeftHand_1stP") if n in index]
    out = dict(slug=slug, psk=str(psk), psa=str(psa), tip_in_rw_weapon=tip_local,
               damage_parent=bones[index["RW_Damage"]]["parent"], sequences=[])
    for info in infos:
        name = ctext(info[0])
        if needle.lower() not in name.lower():
            continue
        frames = []
        for f in range(info[11]):
            pos, rot = pose(info, f)
            dmg, dq = pos[index["RW_Damage"]], rot[index["RW_Damage"]]
            axis = unit(rotate(dq, (0, 0, 1)))
            wpn, wq = pos[index["RW_Weapon"]], rot[index["RW_Weapon"]]
            tip = add(wpn, rotate(wq, tip_local))
            reach_axis = unit(sub(tip, wpn))
            along = dot(sub(tip, dmg), axis)
            off = norm(sub(sub(tip, dmg), tuple(a * along for a in axis)))
            frames.append(dict(
                frame=f,
                damage_origin=[round(x, 1) for x in dmg],
                damage_origin_from_view=round(norm(dmg), 1),
                damage_axis=[round(x, 3) for x in axis],
                tip=[round(x, 1) for x in tip],
                tip_from_view=round(norm(tip), 1),
                tip_along_damage_axis=round(along, 1),
                tip_off_damage_axis=round(off, 1),
                damage_axis_vs_weapon_deg=round(math.degrees(math.acos(max(-1, min(1, dot(axis, reach_axis))))), 1),
                damage_origin_to_right_hand=round(norm(sub(dmg, pos[index[hand_names[0]]])), 1) if hand_names else None,
            ))
        out["sequences"].append(dict(name=name, frames=info[11], rate=info[8], samples=frames))
    (audit / "damage_bone_samples.json").write_text(json.dumps(out, indent=1) + "\n")
    print(f"{slug}: RW_Damage parent={out['damage_parent']}  tip in RW_Weapon={tip_local}")
    for s in out["sequences"]:
        fr = s["samples"]
        mid = fr[len(fr) // 2]
        print(f"  {s['name']:<18} frames={s['frames']:>3}  mid-frame: damage origin {mid['damage_origin_from_view']:>6} from view,"
              f" {mid['damage_origin_to_right_hand']} from right hand; tip {mid['tip_from_view']:>6} from view,"
              f" {mid['tip_along_damage_axis']:>6} along axis, {mid['tip_off_damage_axis']:>5} off;"
              f" axis vs weapon {mid['damage_axis_vs_weapon_deg']:>5} deg")


if __name__ == "__main__":
    main(sys.argv[1], *(sys.argv[2:3]))
