"""Sample both hands on every melee weapon through its stock 1P animations.

Reads the CLI-only UModel PSK/PSA exports under build/<slug>-audit/export
(perk knives play the Commando knife's anim set, see melee_rig.SHARED_ANIM)
and build/<slug>-audit/melee_zones.json from measure_melee_zones.py; no game,
SDK, editor or tests. Everything is game space (UModel's Y mirror undone).

For Idle, every Atk_*, Combo_*, Bash, Stab, HardFire_*, Super_Attack,
Brace_in/loop/out and Block_Hit_* sequence the set has, the rig is posed
frame by frame and, for each hand:

- fist: the mean of the index..pinky first and second joints (the closed
  fist's centre, where a handle passes) and the knuckle span, in the weapon
  bone's space. `along` is the fist centre on the weapon's long axis (+Z, or
  +X for gauntlets): the grip point. min/max over a sequence is the slide
  range that sequence uses.
- gap: the fist centre's distance from the weapon's cross-section centreline
  at that point minus the section radius (beyond the ends: distance to the
  end). Under 3.5 uu the hand is on the weapon (a closed fist centre sits up to ~3 uu off a thin haft).
- lead hand: of the hands on the weapon, the one nearer the head (larger
  `along`), per frame.
- the weapon against the main (right) hand: RW_Weapon's rotation and offset
  relative to RightHand_1stP, compared with Idle frame 0. A non-zero angle is
  the weapon pivoting in the fist during a swing.

Brace_loop also yields the guard pose: the weapon's long axis and the centre
of its length in rig Root space, and in view terms. The 1P Root sits at the
player's view; the Idle pose shows Root +Y forward, -X right and +Z up in
game space (the hands and shoulders lie ahead of the root along +Y, the right
shoulder at -X), so view = (forward, right, up) = (Y, -X, Z).

  python -I tools/re/sample_melee_grips.py [slug ...]   (default: all)
writes build/<slug>-audit/melee_grips.json.
"""
from pathlib import Path
import json
import math
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from melee_rig import BUILD, Rig, Anim, anim_path, game, dot, sub, add, scale, norm, unit, r, mul, conj, rotate  # noqa: E402
from measure_melee_zones import WEAPONS, FINGERS  # noqa: E402

WANTED = ("Idle", "Atk_", "Combo_", "Bash", "Stab", "HardFire_", "Super_Attack", "Brace_", "Block_Hit_")
REQUIRED = ("Idle", "Atk_F", "Atk_B", "Atk_L", "Atk_R", "Atk_H_F", "Atk_H_B", "Atk_H_L", "Atk_H_R",
            "Brace_in", "Brace_loop", "Block_Hit_V1")
ON_GAP = 3.5
SAMPLE_COLUMNS = ["frame", "right_along", "right_gap", "left_along", "left_gap", "weapon_turn_deg",
                  "axis_root_x", "axis_root_y", "axis_root_z", "centre_root_x", "centre_root_y", "centre_root_z"]
COL = {name: i for i, name in enumerate(SAMPLE_COLUMNS)}


def view(v):
    """Rig Root game space to (forward, right, up)."""
    return (v[1], -v[0], v[2])


def quat_angle(a, b):
    d = abs(sum(x * y for x, y in zip(a, b)))
    return math.degrees(2 * math.acos(min(1.0, d)))


class Surface:
    """The weapon's centreline and section radius along its long axis, from
    the zone profile (every 1 uu)."""

    def __init__(self, part):
        self.axis = tuple(part["long_axis"])
        rows = part["profile"]
        self.rows = [(row[0], (row[3], row[4], row[5]), row[1] * 0.5) for row in rows]
        self.lo, self.hi = rows[0][0], rows[-1][0]

    def gap(self, p):
        t = dot(p, self.axis)
        tc = min(self.hi, max(self.lo, t))
        row = min(self.rows, key=lambda row: abs(row[0] - tc))
        c = row[1]
        off = sub(sub(p, c), scale(self.axis, dot(sub(p, c), self.axis)))
        radial = norm(off) - row[2]
        if self.lo <= t <= self.hi:
            return max(radial, 0.0) if radial > 0 else radial
        return math.hypot(max(radial, 0.0), abs(t - tc))


def hand_sample(rig, side, bone, pos, rot, axis, surface):
    joints = [rig.to_local(bone, pos[rig.index[f"{side}Hand{f}{j}_1stP"]], pos, rot)
              for f in FINGERS for j in (1, 2)]
    centre = scale(tuple(map(sum, zip(*joints))), 1.0 / len(joints))
    knuckles = [dot(p, axis) for p in joints[0::2]]
    wrist = rig.to_local(bone, pos[rig.index[f"{side}Hand_1stP"]], pos, rot)
    return dict(along=round(dot(centre, axis), 2), gap=round(surface.gap(centre), 2),
                centre=r(centre), wrist=r(wrist),
                knuckle_span=[round(min(knuckles), 2), round(max(knuckles), 2)])


def sample(slug):
    rig = Rig(slug)
    zones = json.loads((BUILD / f"{slug}-audit/melee_zones.json").read_text(encoding="utf-8"))
    path, source = anim_path(slug)
    out = dict(slug=slug, psk=zones["psk"], anim_source=source,
               space="game convention (UModel PSK Y negated); weapon-bone local unless named Root/view",
               parts=[])
    if not path:
        out["missing"] = "no 1P anim set exported"
        (BUILD / f"{slug}-audit/melee_grips.json").write_text(json.dumps(out, separators=(",", ":")) + "\n", encoding="utf-8")
        return out
    anim = Anim(path)
    out["psa"] = str(path.relative_to(BUILD.parent)).replace("\\", "/")
    names = [n for n in anim.sequences if any(n.startswith(w) for w in WANTED) and n != "Brace_out"] + \
        [n for n in ("Brace_out",) if n in anim.sequences]
    out["missing_sequences"] = [n for n in REQUIRED if n not in anim.sequences]
    out["sampled_sequences"] = names
    hand_bone = rig.index["RightHand_1stP"]
    done = set()
    for part in zones["parts"]:
        bone = part["bone"]
        if bone in done:     # the folded Scythe: same bone, same hands
            continue
        done.add(bone)
        axis = tuple(part["long_axis"])
        surface = Surface(part)
        widx = rig.index[bone]
        host = rig.index["LeftHand_1stP" if bone.startswith("LW") else "RightHand_1stP"]
        pos0, rot0 = anim.pose(rig, "Idle", 0)
        rel0 = mul(conj(rot0[host]), rot0[widx])
        off0 = rotate(conj(rot0[host]), sub(pos0[widx], pos0[host]))
        seqs = {}
        for name in names:
            frames = []
            for f in range(anim.frames(name)):
                pos, rot = anim.pose(rig, name, f)
                hands = {s: hand_sample(rig, s, bone, pos, rot, axis, surface) for s in ("Right", "Left")}
                rel = mul(conj(rot[host]), rot[widx])
                off = rotate(conj(rot[host]), sub(pos[widx], pos[host]))
                turn = mul(conj(rel0), rel)
                ang = quat_angle(rel0, rel)
                s = math.sqrt(max(0.0, 1 - turn[3] ** 2))
                # A rotation axis is a pseudovector: undoing the mirror also
                # flips its sign.
                turn_axis = scale(game(scale(turn[:3], 1 / s)), -1) if s > 1e-6 else (0.0, 0.0, 0.0)
                wp, wq = pos[widx], rot[widx]
                mid = (part["zones"]["reach"].get("axis_min", 0) + part["zones"]["reach"].get("axis_max", 0)) * 0.5 \
                    if "axis_min" in part["zones"]["reach"] else 0.0
                centre_root = game(add(wp, rotate(wq, game(scale(axis, mid)))))
                axis_root = game(rotate(wq, game(axis)))
                frames.append(dict(frame=f, hands=hands, weapon_turn_deg=round(ang, 2),
                                   weapon_turn_axis=r(turn_axis, 3),
                                   weapon_shift=round(norm(sub(off, off0)), 2),
                                   axis_root=r(axis_root, 3), centre_root=r(centre_root)))
            seqs[name] = summarise(name, frames, anim.rate(name))
        entry = dict(bone=bone, kind=part["kind"], long_axis=list(axis), sequences=seqs)
        entry["summary"] = overall(seqs, part)
        if "Brace_loop" in seqs:
            entry["guard_pose"] = guard_pose(seqs["Brace_loop"], seqs.get("Idle"))
        out["parts"].append(entry)
    (BUILD / f"{slug}-audit/melee_grips.json").write_text(json.dumps(out, separators=(",", ":")) + "\n", encoding="utf-8")
    return out


def summarise(name, frames, rate):
    hands = {}
    for s in ("Right", "Left"):
        a = [fr["hands"][s]["along"] for fr in frames]
        g = [fr["hands"][s]["gap"] for fr in frames]
        on = [fr["hands"][s]["along"] for fr in frames if fr["hands"][s]["gap"] <= ON_GAP]
        hands[s] = dict(along_min=round(min(a), 2), along_max=round(max(a), 2),
                        along_on_min=round(min(on), 2) if on else None,
                        along_on_max=round(max(on), 2) if on else None,
                        gap_min=round(min(g), 2), gap_max=round(max(g), 2),
                        on_weapon_fraction=round(len(on) / len(frames), 2))
    lead = {"Right": 0, "Left": 0}
    spacing = []
    for fr in frames:
        on = [s for s in ("Right", "Left") if fr["hands"][s]["gap"] <= ON_GAP]
        if len(on) == 2:
            hi = max(on, key=lambda s: fr["hands"][s]["along"])
            lead[hi] += 1
            spacing.append(abs(fr["hands"]["Right"]["along"] - fr["hands"]["Left"]["along"]))
    both = sum(lead.values())
    return dict(frames=len(frames), rate=round(rate, 2), hands=hands,
                both_on_fraction=round(both / len(frames), 2),
                lead_hand=(max(lead, key=lead.get) if both else None),
                lead_frames=lead,
                spacing_min=round(min(spacing), 2) if spacing else None,
                spacing_max=round(max(spacing), 2) if spacing else None,
                weapon_turn_max_deg=max(fr["weapon_turn_deg"] for fr in frames),
                weapon_turn_axis_at_max=max(frames, key=lambda fr: fr["weapon_turn_deg"])["weapon_turn_axis"],
                weapon_shift_max=max(fr["weapon_shift"] for fr in frames),
                frame0={s: frames[0]["hands"][s] for s in ("Right", "Left")},
                sample_columns=SAMPLE_COLUMNS,
                samples=[[fr["frame"], fr["hands"]["Right"]["along"], fr["hands"]["Right"]["gap"],
                          fr["hands"]["Left"]["along"], fr["hands"]["Left"]["gap"], fr["weapon_turn_deg"],
                          *fr["axis_root"], *fr["centre_root"]] for fr in frames])


def overall(seqs, part):
    """Grip ranges over all attack-type sequences, plus Idle."""
    attack = [n for n in seqs if not n.startswith(("Idle", "Brace_out"))]
    out = {}
    for s in ("Right", "Left"):
        a, g = COL[f"{s.lower()}_along"], COL[f"{s.lower()}_gap"]
        on = [(n, x[0], x[a]) for n in attack for x in seqs[n]["samples"] if x[g] <= ON_GAP]
        total = sum(seqs[n]["frames"] for n in attack)
        idle = (seqs["Idle"]["samples"][0][a], seqs["Idle"]["samples"][0][g]) if "Idle" in seqs else None
        out[s] = dict(idle_along=idle[0] if idle else None, idle_gap=idle[1] if idle else None,
                      on_weapon_fraction=round(len(on) / total, 2) if total else 0.0,
                      along_min=round(min(v for *_, v in on), 2) if on else None,
                      along_max=round(max(v for *_, v in on), 2) if on else None,
                      along_p10=round(sorted(v for *_, v in on)[len(on) // 10], 2) if on else None,
                      along_p90=round(sorted(v for *_, v in on)[(9 * len(on)) // 10], 2) if on else None,
                      at_min=(on and list(min(on, key=lambda t: t[2])[:2])) or None,
                      at_max=(on and list(max(on, key=lambda t: t[2])[:2])) or None,
                      sequences_off_weapon=[n for n in attack if seqs[n]["hands"][s]["on_weapon_fraction"] < 0.5])
    lead = {"Right": 0, "Left": 0}
    for n in attack:
        for k, v in seqs[n]["lead_frames"].items():
            lead[k] += v
    out["lead_hand"] = max(lead, key=lead.get) if sum(lead.values()) else None
    out["lead_frames"] = lead
    out["lead_by_sequence"] = {n: seqs[n]["lead_hand"] for n in attack}
    out["weapon_turn_max_deg"] = max(seqs[n]["weapon_turn_max_deg"] for n in seqs)
    out["weapon_turn_by_sequence"] = {n: seqs[n]["weapon_turn_max_deg"] for n in seqs}
    out["weapon_shift_max"] = max(seqs[n]["weapon_shift_max"] for n in seqs)
    return out


def guard_pose(brace, idle):
    xs = brace["samples"]
    def mean(key):
        i = COL[key + "_x"]
        return scale(tuple(map(sum, zip(*[x[i:i + 3] for x in xs]))), 1.0 / len(xs))
    axis = unit(mean("axis_root")); centre = mean("centre_root")
    out = dict(axis_root=r(axis, 3), centre_root=r(centre),
               axis_view=r(view(axis), 3), centre_view=r(view(centre)),
               axis_spread_deg=round(max(math.degrees(math.acos(max(-1, min(1, dot(unit(x[6:9]), axis)))))
                                         for x in xs), 2),
               hands=brace["frame0"],
               elevation_deg=round(math.degrees(math.asin(max(-1, min(1, axis[2])))), 1),
               heading_deg_right_of_forward=round(math.degrees(math.atan2(view(axis)[1], view(axis)[0])), 1))
    if idle:
        x0 = idle["samples"][0]
        out["idle_axis_view"] = r(view(x0[6:9]), 3)
        out["idle_centre_view"] = r(view(x0[9:12]))
    return out


def axes_check(slug):
    """Idle-pose evidence for the rig Root axes (game space)."""
    rig = Rig(slug)
    path, _ = anim_path(slug)
    pos, rot = Anim(path).pose(rig, "Idle", 0)
    names = ("RightArm_1stP", "LeftArm_1stP", "RightHand_1stP", "LeftHand_1stP")
    return {n: r(game(pos[rig.index[n]]), 1) for n in names}


def report(out):
    for p in out["parts"]:
        s = p["summary"]
        print(f"{out['slug']}:{p['bone']} anim={out.get('anim_source')} missing={out.get('missing_sequences')}")
        for h in ("Right", "Left"):
            x = s[h]
            print(f"  {h:<5} idle={x['idle_along']} gap={x['idle_gap']} on={x['on_weapon_fraction']}"
                  f" range=[{x['along_min']}, {x['along_max']}] p10-90=[{x['along_p10']}, {x['along_p90']}]"
                  f" off-in={x['sequences_off_weapon'][:6]}")
        print(f"  lead={s['lead_hand']} {s['lead_frames']} turn_max={s['weapon_turn_max_deg']} shift_max={s['weapon_shift_max']}")
        if "guard_pose" in p:
            g = p["guard_pose"]
            print(f"  guard axis_view={g['axis_view']} centre_view={g['centre_view']} elev={g['elevation_deg']}"
                  f" heading={g['heading_deg_right_of_forward']}")


if __name__ == "__main__":
    slugs = sys.argv[1:] or list(WEAPONS)
    for slug in slugs:
        report(sample(slug))
