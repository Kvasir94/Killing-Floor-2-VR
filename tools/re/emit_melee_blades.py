"""Emit script/KF2VR/Classes/VRMeleeBlades.uc from docs/re/melee-zones/<slug>-blade.json.

The blade JSON (tools/re/measure_melee_blades.py, game space, RW_Weapon) holds
each weapon's measured blade segments (centreline, edge direction, flat normal,
edge and spine reach, thickness, edge/spine kind) and its points. This writes
them as UnrealScript defaultproperties for VRPhysicalMelee's per-blade hit zones
(#227, Kvasir94 2026-11-09: "highly detailed hurtboxes, closely mapped to the
weapons, generous where they should be (blade side)").

Parts (VRMeleeScale): 0 the stock attack, 1 bludgeon, 2 pierce, 3 the weapon's
own stock slashing type (the Crovel's light attack), 4 the stock stab (thrust).

  python tools/re/emit_melee_blades.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "docs/re/melee-zones"
OUT = ROOT / "script/KF2VR/Classes/VRMeleeBlades.uc"

CLASSES = {
    "edged-katana": "KFWeap_Edged_Katana",
    "edged-zweihander": "KFWeap_Edged_Zweihander",
    "edged-ionthruster": "KFWeap_Edged_IonThruster",
    "edged-scythe": "KFWeap_Edged_Scythe",
    "edged-fireaxe": "KFWeap_Edged_FireAxe",
    "edged-abominationaxe": "KFWeap_Edged_AbominationAxe",
    "crovel": "KFWeap_Blunt_Crovel",
    "blunt-medicbat": "KFWeap_Blunt_MedicBat",
    "knife-berserker": "KFWeap_Knife_Berserker",
    "knife-commando": "KFWeap_Knife_Commando",
    "knife-demolitionist": "KFWeap_Knife_Demolitionist",
    "knife-fieldmedic": "KFWeap_Knife_FieldMedic",
    "knife-firebug": "KFWeap_Knife_Firebug",
    "knife-gunslinger": "KFWeap_Knife_Gunslinger",
    "knife-sharpshooter": "KFWeap_Knife_Sharpshooter",
    "knife-support": "KFWeap_Knife_Support",
    "knife-survivalist": "KFWeap_Knife_Survivalist",
    "knife-swat": "KFWeap_Knife_SWAT",
}
# What the back of a single-edged head does when it leads: the Fire Axe's
# back is its pick (pierce); a blade's spine, saw or thorns bludgeon.
BACK_PIERCE = {"edged-fireaxe"}
# The Crovel's edges use its own stock slashing type (its light attack).
EDGE_STOCK_SLASH = {"crovel"}
# Kvasir94 2026-11-09: the Ion Thruster's energy blade slices on every side, no flat.
NO_FLAT = {"edged-ionthruster"}


def v(x):
    return "(X=%s,Y=%s,Z=%s)" % tuple(f"{round(c, 3):g}" for c in x)


def main():
    segs, points = [], []
    for slug, cls in CLASSES.items():
        path = DATA / f"{slug}-blade.json"
        if not path.exists():
            raise SystemExit(f"missing {path}")
        d = json.loads(path.read_text(encoding="utf-8"))
        for e in d["entries"]:
            if e["type"] == "blade":
                for s in e["segments"]:
                    if s.get("spine") == "edge" or s.get("edges") == "both":
                        back = 0
                    elif slug in BACK_PIERCE:
                        back = 2
                    else:
                        back = 1
                    edge = 3 if slug in EDGE_STOCK_SLASH else 0
                    segs.append(
                        f"WeaponClassName={cls},Start={v(s['start'])},End={v(s['end'])},EdgeDir={v(s['edge_dir'])},"
                        f"FlatNormal={v((0, 0, 0) if slug in NO_FLAT else s['flat_normal'])},EdgeReach={round(max(s['edge_reach_start'], s['edge_reach_end']), 2):g},"
                        f"SpineReach={round(max(s['spine_reach_start'], s['spine_reach_end']), 2):g},"
                        f"HalfThick={round(s['half_thickness'], 2):g},EdgePart={edge},BackPart={back}")
            elif e["type"] == "edge_line":
                line = e["polyline"]
                for a, b in zip(line, line[1:]):
                    segs.append(
                        f"WeaponClassName={cls},Start={v(a)},End={v(b)},EdgeDir={v(e['outward'])},"
                        f"FlatNormal=(X=0,Y=0,Z=0),EdgeReach=0.5,SpineReach=0.5,"
                        f"HalfThick={round(e['half_thickness'], 2):g},EdgePart={3 if slug in EDGE_STOCK_SLASH else 0},BackPart=1")
            elif e["type"] == "plate":
                # The shovel's face: a segment down its length whose two
                # "edges" are its sides, so it is covered edge to edge; a flat
                # contact bludgeons, an edge-on one slices (its stock type).
                c, la, wa, n = e["centre"], e["length_axis"], e["width_axis"], e["normal"]
                lo, hi = e["length_range"]
                a0 = [c[i] + la[i] * lo for i in range(3)]
                a1 = [c[i] + la[i] * hi for i in range(3)]
                w = max(abs(e["width_range"][0]), abs(e["width_range"][1]))
                t = max(abs(e["thickness_range"][0]), abs(e["thickness_range"][1]))
                segs.append(
                    f"WeaponClassName={cls},Start={v(a0)},End={v(a1)},EdgeDir={v(wa)},FlatNormal={v(n)},"
                    f"EdgeReach={round(w, 2):g},SpineReach={round(w, 2):g},HalfThick={round(t, 2):g},EdgePart=3,BackPart=3")
            elif e["type"] == "point":
                # Sword and knife tips land the stock stab through the thrust
                # rule; the others (picks, spikes, claws, syringes) pierce.
                part = 4 if e["name"] == "tip" else 2
                points.append(f"WeaponClassName={cls},Tip={v(e['tip'])},Axis={v(e['axis'])},Part={part}")
    # Shaft centrelines, butt to head (measure_melee_shafts.py): one piece per
    # straight run, for the shaft hit lines.
    shafts = []
    for path in sorted(DATA.glob("*-shaft.json")):
        d = json.loads(path.read_text(encoding="utf-8"))
        for a, b in zip(d["points"], d["points"][1:]):
            shafts.append(f"WeaponClassName={d['weapon_class']},A={v(a)},B={v(b)}")
    lines = [
        "// GENERATED by tools/re/emit_melee_blades.py from docs/re/melee-zones/<slug>-blade.json.",
        "// Do not edit by hand. Each weapon's measured blade segments and points in",
        "// RW_Weapon game space (#227): VRPhysicalMelee sweeps an edge rail along each",
        "// segment's edge (generous: MinimumEdgeRadius) and a tight body rail along its",
        "// centreline, and point rails at each tip.",
        "class VRMeleeBlades extends Object;",
        "",
        "struct BladeSeg",
        "{",
        "    var name WeaponClassName;",
        "    var vector Start, End, EdgeDir, FlatNormal;",
        "    var float EdgeReach, SpineReach, HalfThick;",
        "    // VRMeleeScale part: the edge's (0 stock attack, 3 own stock slash) and",
        "    // the back's when it leads (0 a second edge, 1 bludgeon, 2 pierce).",
        "    var byte EdgePart, BackPart;",
        "};",
        "struct BladePoint",
        "{",
        "    var name WeaponClassName;",
        "    var vector Tip, Axis;",
        "    var byte Part;",
        "};",
        "// A straight piece of the shaft's centreline, butt to head (<slug>-shaft.json).",
        "struct BladeShaft",
        "{",
        "    var name WeaponClassName;",
        "    var vector A, B;",
        "};",
        "var array<BladeSeg> Segs;",
        "var array<BladePoint> Points;",
        "var array<BladeShaft> Shafts;",
        "",
        "defaultproperties",
        "{",
    ]
    for i, s in enumerate(segs):
        lines.append(f"    Segs({i})=({s})")
    for i, p in enumerate(points):
        lines.append(f"    Points({i})=({p})")
    for i, p in enumerate(shafts):
        lines.append(f"    Shafts({i})=({p})")
    lines.append("}")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(OUT, len(segs), "segments", len(points), "points", len(shafts), "shaft pieces")


if __name__ == "__main__":
    main()
