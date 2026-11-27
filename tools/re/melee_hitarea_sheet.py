"""Offline sheet of every melee weapon's VR hit area, as the runtime builds it.

For an audit by eye (Kvasir94, 2026-11-10): each weapon's damaging volumes drawn
on its stock mesh, every part labelled with the damage types it can deal and
the numbers behind it. Nothing here is measured again: the volumes are rebuilt
from the shipped script data exactly as VRPhysicalMelee builds them, so the
sheet shows what the game sweeps.

Sources (all read, never written):
  script/KF2VR/Classes/VRMeleeBlades.uc     measured segments and points
  script/KF2VR/Classes/VRPhysicalMelee.uc   rail sizes and rules (defaults)
  script/KF2VR/Classes/VRHandsBridge.uc     profile heads (MeleeHeadStart/End/Radius)
  script/KF2VR/Classes/VRMeleeTraits.uc     class, point, spike
  script/KF2VR/Classes/VRScytheFold.uc      the Scythe's shown fold (M26)
  stock Development/Src KFWeap_*            light/heavy/bash damage types and amounts
  build/melee-zone-review/blade-data, data  weapon meshes (melee_zone_review.py export,
                                            measure_melee_blades.py)

Three steps, offline:
  python -I tools/re/melee_hitarea_sheet.py data
      build/melee-hitarea/data/<slug>.json (volumes, damage table, mesh)
  "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b --factory-startup \
      --python tools/re/melee_hitarea_sheet.py -- render [slug ...]
      build/melee-hitarea/renders/<slug>[_<variant>]_<view>.png
  python tools/re/melee_hitarea_sheet.py page     (needs Pillow)
      build/melee-hitarea/index.html (one artifact page, renders inlined as WebP)

Space: RW_Weapon bone space, game convention (left-handed; renders are
mirrored back so they read the right way round), Unreal units (1 uu = 1 cm in the headset: tracking maps 100 uu to a metre).
"""
from pathlib import Path
import json
import math
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
CLS = ROOT / "script/KF2VR/Classes"
OUT = ROOT / "build/melee-hitarea"
REVIEW = ROOT / "build/melee-zone-review"
STOCK = [Path(r"D:/SteamLibrary/steamapps/common/killingfloor2/Development/Src/KFGameContent/Classes"),
         Path(r"D:/SteamLibrary/steamapps/common/killingfloor2/Development/Src/KFGame/Classes")]

# slug -> (weapon class, display name). Order is the sheet's order.
WEAPONS = [
    ("edged-katana", "KFWeap_Edged_Katana", "Katana"),
    ("edged-zweihander", "KFWeap_Edged_Zweihander", "Zweihander"),
    ("edged-ionthruster", "KFWeap_Edged_IonThruster", "Ion Thruster"),
    ("edged-scythe", "KFWeap_Edged_Scythe", "Blood Sickle (Scythe)"),
    ("edged-fireaxe", "KFWeap_Edged_FireAxe", "Fire Axe"),
    ("edged-abominationaxe", "KFWeap_Edged_AbominationAxe", "Abomination Axe"),
    ("crovel", "KFWeap_Blunt_Crovel", "Crovel"),
    ("pulverizer", "KFWeap_Blunt_Pulverizer", "Pulverizer"),
    ("blunt-chainbat", "KFWeap_Blunt_ChainBat", "Chain Bat"),
    ("blunt-medicbat", "KFWeap_Blunt_MedicBat", "Hemoclobber (Medic Bat)"),
    ("blunt-maceandshield", "KFWeap_Blunt_MaceAndShield", "Bone Crusher (Mace and Shield)"),
    ("blunt-powergloves", "KFWeap_Blunt_PowerGloves", "Battery Gloves (Power Gloves)"),
    ("blastbrawlers", "KFWeap_HRG_BlastBrawlers", "HRG Blast Brawlers"),
    ("knife-berserker", "KFWeap_Knife_Berserker", "Berserker knife"),
    ("knife-commando", "KFWeap_Knife_Commando", "Commando knife"),
    ("knife-demolitionist", "KFWeap_Knife_Demolitionist", "Demolitionist knife"),
    ("knife-fieldmedic", "KFWeap_Knife_FieldMedic", "Field Medic knife"),
    ("knife-firebug", "KFWeap_Knife_Firebug", "Firebug knife"),
    ("knife-gunslinger", "KFWeap_Knife_Gunslinger", "Gunslinger knife"),
    ("knife-sharpshooter", "KFWeap_Knife_Sharpshooter", "Sharpshooter knife"),
    ("knife-support", "KFWeap_Knife_Support", "Support knife"),
    ("knife-survivalist", "KFWeap_Knife_Survivalist", "Survivalist knife"),
    ("knife-swat", "KFWeap_Knife_SWAT", "SWAT knife"),
]
# Extra behaviour that is not a volume (VRPhysicalMelee.ResolveContacts).
NOTES = {
    "blunt-medicbat": "Trigger held makes the swing heavy and arms the stock healing blast on the first enemy hit "
                      "(VRMedicBatImpact: KFDT_Toxic_MedicBatGas 225, radius 500, heals 15). Touching an ally heals "
                      "instead of hitting (melee spec M20).",
    "pulverizer": "Trigger held makes the swing heavy; with a shell loaded the first enemy contact detonates the "
                  "stock directional blast (VRPulverizerImpact, the Wep_Pulverizer_Explosion archetype).",
    "blastbrawlers": "A trigger-loaded punch fires the stock shotgun blast (KFDT_Ballistic_BlastBrawlersShotgun 39 x 5 "
                     "pellets) at its first contact, or from the muzzle at full extension (VRBrawlerBlast).",
    "blunt-maceandshield": "The shield (left hand, LW_Weapon) is drawn 45 uu to the side of the mace so both read; its "
                           "lines are moved with it. The shield is traced as chords of its measured face, 8 uu apart "
                           "both ways (it was a capsule across the middle); the two through the centre also meet walls.",
    "blunt-powergloves": "Each fist is its own head capsule; no shaft or pommel.",
    "edged-scythe": "The blade's lines turn with the fold (melee spec M26, VRScytheFold): folded is the anim tree's "
                    "25 deg 'Empty' pose, unfolded 95 deg. The snath's shaft lines do not turn.",
}

# Melee-capable guns and the VR Tomahawk: profile head only, no exported mesh.
NOT_DRAWN = ["VRWeap_Tomahawk", "KFWeap_Pistol_Bladed", "KFWeap_Eviscerator", "KFWeap_Rifle_FrostShotgunAxe",
             "KFWeap_Rifle_MosinNagant"]

# Shaft centreline pieces (VRMeleeBlades.Shafts), filled by blades().
SHAFTS = []
# Per-segment covered areas, filled by build_lines() for the drawing.
AREAS = []

MODES = {"DEFAULT_FIREMODE": 0, "ALTFIRE_FIREMODE": 1, "RELOAD_FIREMODE": 2, "BASH_FIREMODE": 3,
         "GRENADE_FIREMODE": 4, "HEAVY_ATK_FIREMODE": 5, "CUSTOM_FIREMODE": 6}
LIGHT, HEAVY, BASH = 0, 5, 3


# ---------------------------------------------------------------- parsing

def defaults_block(text):
    i = text.find("defaultproperties")
    return text[i:] if i >= 0 else ""


def num(s):
    return float(s.strip().rstrip("f"))


def vec(s):
    m = dict(re.findall(r"([XYZ])=(-?[\d.]+)", s))
    return [float(m.get("X", 0)), float(m.get("Y", 0)), float(m.get("Z", 0))]


def struct_fields(s):
    """(A=1,B=(X=..),C=name) -> {A: '1', B: '(X=..)', C: 'name'} (one level)."""
    s = s.strip()
    if s.startswith("("):
        s = s[1:-1]
    out, depth, key, cur = {}, 0, None, ""
    for ch in s + ",":
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "=" and depth == 0 and key is None:
            key, cur = cur.strip(), ""
            continue
        if ch == "," and depth == 0:
            if key is not None:
                out[key] = cur.strip()
            key, cur = None, ""
            continue
        cur += ch
    return out


def uc_defaults(path):
    out = {}
    for line in defaults_block(path.read_text(encoding="utf-8", errors="replace")).splitlines():
        line = line.split("//")[0].strip()
        m = re.match(r"(\w+)(?:\((\w+)\))?\s*=\s*(.+)$", line)
        if m:
            k = m.group(1) + (f"({m.group(2)})" if m.group(2) else "")
            out[k] = m.group(3).strip()
    return out


def melee_defaults():
    d = uc_defaults(CLS / "VRPhysicalMelee.uc")
    g = lambda k: num(d[k])
    return dict(edge_r=g("EdgeRailRadius"), edge_out=g("EdgeRailOut"), point_r=g("PointRailRadius"),
                body_r=g("BodyRailRadius"), max_rails=int(g("MaximumRails")),
                line_tip=g("LineTipPad"), line_flat=g("LineFlatPad"),
                knife_edge=g("KnifeEdgePad"), knife_flat=g("KnifeFlatPad"), knife_tip=g("KnifeTipPad"), line_step=g("LineSubstep"), line_steps=int(g("MaximumLineSubsteps")),
                line_sweep=d.get("bLineSweep", "true").lower() == "true",
                shield_centre=vec(d["ShieldCentre"]), shield_r=g("ShieldRadius"), shield_step=g("ShieldChordSpacing"),
                min_edge={int(i): num(v) for i, v in ((k[18:-1], v) for k, v in d.items()
                                                       if k.startswith("MinimumEdgeRadius("))},
                pommel_back=g("PommelBack"), pommel_r=g("PommelRadius"), spike_r=g("SpikeRadius"),
                spike_len=g("SpikeLength"), spike_reach=g("SpikeContactReach"), stab_angle=g("StabMaxAngle"),
                point_lead_dot=g("PointLeadDot"), shaft_lo=g("ShaftScaleLow"), shaft_hi=g("ShaftScaleHigh"),
                pommel_anchor=g("PommelAnchorDamage"), pommel_min=g("PommelMinSpeed"),
                curve_top=g("CurveTopSpeed"), start_speed=g("StartSpeed"), heavy_speed=g("HeavySpeed"))


def blades():
    segs, points = [], []
    SHAFTS.clear()
    for line in (CLS / "VRMeleeBlades.uc").read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*(Segs|Points|Shafts)\((\d+)\)=(\(.*\))\s*$", line)
        if not m:
            continue
        if m.group(1) == "Shafts":
            f = struct_fields(m.group(3))
            SHAFTS.append(dict(cls=f["WeaponClassName"], a=vec(f["A"]), b=vec(f["B"])))
            continue
        f = struct_fields(m.group(3))
        if m.group(1) == "Segs":
            segs.append(dict(index=int(m.group(2)), cls=f["WeaponClassName"], start=vec(f["Start"]),
                             end=vec(f["End"]), edge_dir=vec(f["EdgeDir"]), flat=vec(f["FlatNormal"]),
                             flat_src=vec(f["FlatNormal"]),
                             edge_reach=num(f["EdgeReach"]), spine_reach=num(f["SpineReach"]),
                             half_thick=num(f["HalfThick"]), edge_part=int(f["EdgePart"]),
                             back_part=int(f["BackPart"])))
        else:
            points.append(dict(cls=f["WeaponClassName"], tip=vec(f["Tip"]), axis=vec(f["Axis"]),
                               part=int(f["Part"])))
    return segs, points


def profiles():
    out = {}
    for line in (CLS / "VRHandsBridge.uc").read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*WeaponProfiles\((\d+)\)=(\(.*\))\s*$", line)
        if not m or "MeleeHeadStart" not in line:
            continue
        f = struct_fields(m.group(2))
        out.setdefault(f["WeaponClassName"], dict(head_start=vec(f["MeleeHeadStart"]), head_end=vec(f["MeleeHeadEnd"]),
                                                  radius=num(f.get("MeleeRadius", "0")), root=f.get("RootBone")))
    return out


def traits():
    out = {}
    for line in (CLS / "VRMeleeTraits.uc").read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*Traits\((\d+)\)=(\(.*\))\s*$", line)
        if not m:
            continue
        f = struct_fields(m.group(2))
        out[f["WeaponClassName"]] = dict(melee_class=int(f.get("MeleeClass", 0)), point=f.get("bPoint") == "true",
                                         stab_tip=vec(f["StabTip"]) if "StabTip" in f else None,
                                         stab_axis=vec(f["StabAxis"]) if "StabAxis" in f else None,
                                         edge=vec(f["Edge"]) if "Edge" in f else None,
                                         double=f.get("bDoubleEdge") == "true")
    return out


def scythe_fold():
    d = uc_defaults(CLS / "VRScytheFold.uc")
    return dict(pivot=vec(d["Pivot"]), folded_pivot=vec(d["FoldedPivot"]), folded=num(d["FoldedDegrees"]),
                unfolded=num(d["UnfoldDegrees"]))


def stock_class_file(cls):
    for base in STOCK:
        p = base / f"{cls}.uc"
        if p.exists():
            return p
    return None


def stock_weapon(cls):
    """Merged defaults through the stock class chain (child wins)."""
    chain = []
    c = cls
    while c:
        p = stock_class_file(c)
        if p is None:
            break
        text = p.read_text(encoding="utf-8", errors="replace")
        chain.append(uc_defaults(p))
        m = re.search(r"class\s+\w+\s+extends\s+(\w+)", text)
        c = m.group(1) if m else None
        if c in ("KFWeapon", "Weapon"):
            break
    merged = {}
    for d in reversed(chain):
        merged.update(d)
    types, dmg = {}, {}
    for k, v in merged.items():
        m = re.match(r"InstantHitDamage(Types)?\((\w+)\)$", k)
        if not m:
            continue
        idx = MODES.get(m.group(2), None) if not m.group(2).isdigit() else int(m.group(2))
        if idx is None:
            continue
        if m.group(1):
            mm = re.search(r"class'(\w+)'", v)
            types[idx] = mm.group(1) if mm else v
        else:
            dmg[idx] = num(v)
    extra = {k: re.search(r"class'(\w+)'", v).group(1) for k, v in merged.items()
             if re.search(r"class'(\w+)'", v) and k.endswith("DamageType") or k in ("FoldedDT", "FoldedDTAlt",
                                                                                    "UnfoldedDT", "UnfoldedDTAlt")}
    nums = {k: num(v) for k, v in merged.items() if k in ("FoldedDamage", "FoldedDamageAlt", "UnfoldedDamage",
                                                         "UnfoldedDamageAlt")}
    return dict(types=types, damage=dmg, extra=extra, nums=nums)


def dt_family(name):
    if not name:
        return "none"
    for fam in ("Slashing", "Bludgeon", "Piercing", "Ballistic", "Explosive", "Toxic", "EMP", "Fire"):
        if f"_{fam}" in name or name.startswith(f"KFDT_{fam}"):
            return fam.lower()
    if name == "VRDT_MeleePommel":
        return "bludgeon"
    if name == "VRDT_MeleePierce":
        return "piercing"
    return "other"


def twin_exists(name):
    return (CLS / f"VRDTX_{name}.uc").exists()


# ---------------------------------------------------------------- geometry

def add(a, b): return [x + y for x, y in zip(a, b)]
def sub(a, b): return [x - y for x, y in zip(a, b)]
def mul(a, s): return [x * s for x in a]
def dot(a, b): return sum(x * y for x, y in zip(a, b))
def length(a): return math.sqrt(dot(a, a))
def norm(a):
    n = length(a)
    return [x / n for x in a] if n > 1e-9 else [0.0, 0.0, 0.0]
def lerp(a, b, t): return [x + (y - x) * t for x, y in zip(a, b)]
def r3(a, n=2): return [round(x, n) for x in a]
def cross3(a, b): return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def fold_dir(d, u, F):
    a = math.radians(F["folded"] + (F["unfolded"] - F["folded"]) * u)
    c, s = math.cos(a), math.sin(a)
    return [d[0] * c - d[2] * s, d[1], d[0] * s + d[2] * c]


def fold_point(p, u, F):
    return add(lerp(F["folded_pivot"], F["pivot"], u), fold_dir(sub(p, F["pivot"]), u, F))


def build_rails(cls, segs, points, contact_start, contact_end, contact_radius, M):
    """VRPhysicalMelee.BuildBladeRails, verbatim: [(pos, radius, seg, kind, part, axis)]."""
    rails = []

    def add_rail(p, radius, seg, kind, part, axis=(0.0, 0.0, 0.0)):
        if len(rails) >= M["max_rails"]:
            return
        rails.append(dict(p=list(p), r=radius, seg=seg, kind=kind, part=part, axis=list(axis)))

    mine = [s for s in segs if s["cls"] == cls]
    for s in mine:
        i = s["index"]
        ln = length(sub(s["end"], s["start"]))
        step = M["edge_r"] * 1.2
        n = max(1, int(ln / step + 0.999))
        for j in range(n + 1):
            if j == 0 and rails and rails[-1]["seg"] == i - 1 and any(t["index"] == i - 1 for t in mine):
                continue
            a = lerp(s["start"], s["end"], j / n)
            ed = norm(s["edge_dir"])
            add_rail(add(a, mul(ed, s["edge_reach"] + M["edge_out"])), M["edge_r"], i, 0, 0)
            k = max(1, int((s["edge_reach"] + s["spine_reach"]) / (M["body_r"] * 2) + 0.999))
            for l_ in range(k):
                body = add(a, mul(ed, -s["spine_reach"] + (s["edge_reach"] + s["spine_reach"]) * (l_ + 0.5) / k))
                add_rail(body, max((s["edge_reach"] + s["spine_reach"]) * 0.5 / k, s["half_thick"]) + 0.5, i, 1, 0)
    if not rails:
        ln = length(sub(contact_end, contact_start))
        n = max(1, int(ln / (contact_radius * 1.5) + 0.999))
        for j in range(n + 1):
            add_rail(lerp(contact_start, contact_end, j / n), contact_radius, -1, 0, 0)
    for t in points:
        if t["cls"] != cls:
            continue
        ax = norm(t["axis"])
        add_rail(sub(t["tip"], mul(ax, 1.5)), M["point_r"], -1, 2, t["part"], ax)
    return rails


def shield_lines(M):
    """VRPhysicalMelee.BuildShieldLines, verbatim: chords of the shield's face (LW_Weapon space)."""
    out, c, r, step = [], M["shield_centre"], M["shield_r"], M["shield_step"]
    for n in range(-int(r / step), int(r / step) + 1):
        o = n * step
        half = max(r * r - o * o, 0) ** 0.5
        if half < 2:
            continue
        kind = 0 if n == 0 else 1
        out.append(dict(a=[c[0], c[1] + o, c[2] - half], b=[c[0], c[1] + o, c[2] + half], kind=kind))
        out.append(dict(a=[c[0], c[1] - half, c[2] + o], b=[c[0], c[1] + half, c[2] + o], kind=kind))
    return out


def build_lines(cls, segs, points, M):
    """VRPhysicalMelee.BuildBladeLines, verbatim (melee spec M27):
    [(a, b, seg, kind, part, axis)], kind 0 edge, 1 body, 2 point, 3 shaft."""
    lines = []

    def add_line(a, b, seg, kind, part, axis=(0.0, 0.0, 0.0)):
        if length(sub(b, a)) < 0.01:
            return
        lines.append(dict(a=list(a), b=list(b), seg=seg, kind=kind, part=part, axis=list(axis)))

    pad, flat_pad, tip_pad = M["edge_out"] + M["edge_r"], M["line_flat"], M["line_tip"]
    if cls.startswith("KFWeap_Knife_"):   # KFWeap_Edged_Knife subclasses
        pad, flat_pad, tip_pad = M["knife_edge"], M["knife_flat"], M["knife_tip"]
    for n, s in enumerate(segs):
        if s["cls"] != cls:
            continue
        prev = segs[n - 1] if n > 0 else None
        nxt = segs[n + 1] if n + 1 < len(segs) else None
        first = prev is None or prev["cls"] != cls or length(sub(prev["end"], s["start"])) > 0.1
        last = nxt is None or nxt["cls"] != cls or length(sub(nxt["start"], s["end"])) > 0.1
        d = norm(sub(s["end"], s["start"]))
        ln, width = length(sub(s["end"], s["start"])), s["edge_reach"] + s["spine_reach"]
        # The joint at each end, shared with the neighbouring segment.
        ea = eb = norm(s["edge_dir"])
        edge_a = edge_b = s["edge_reach"]
        spine_a = spine_b = s["spine_reach"]
        if not first:
            ea = norm(add(ea, norm(prev["edge_dir"])))
            edge_a, spine_a = max(edge_a, prev["edge_reach"]), max(spine_a, prev["spine_reach"])
        if not last:
            eb = norm(add(eb, norm(nxt["edge_dir"])))
            edge_b, spine_b = max(edge_b, nxt["edge_reach"]), max(spine_b, nxt["spine_reach"])
        a, b = s["start"], s["end"]
        if last:
            b = add(b, mul(d, tip_pad))
        i = s["index"]
        add_line(add(a, mul(ea, edge_a + pad)), add(b, mul(eb, edge_b + pad)), i, 0, 0)
        fn = norm(s["flat_src"]) if length(s["flat_src"]) > 0.5 else norm(cross3(d, ea))
        add_line(add(add(a, mul(ea, edge_a)), mul(fn, flat_pad)), add(add(b, mul(eb, edge_b)), mul(fn, flat_pad)), i, 1, 0)
        add_line(sub(add(a, mul(ea, edge_a)), mul(fn, flat_pad)), sub(add(b, mul(eb, edge_b)), mul(fn, flat_pad)), i, 1, 0)
        # For the drawing only: the area this segment's lines cover.
        back = pad if (s["back_part"] == 0 or s["back_part"] == s["edge_part"]) else 0.0
        AREAS.append(dict(cls=cls, quad=[sub(a, mul(ea, spine_a + back)), sub(b, mul(eb, spine_b + back)),
                                         add(b, mul(eb, edge_b + pad)), add(a, mul(ea, edge_a + pad))]))
        if s["back_part"] == 0 or s["back_part"] == s["edge_part"]:
            add_line(sub(a, mul(ea, spine_a + pad)), sub(b, mul(eb, spine_b + pad)), i, 0, 0)
        if width <= ln * 1.5 or width <= M["body_r"] * 2:
            k = max(1, int(width / (M["body_r"] * 2) + 0.999))
            for l_ in range(k):
                f = (l_ + 0.5) / k
                add_line(add(a, mul(ea, -spine_a + (edge_a + spine_a) * f)),
                         add(b, mul(eb, -spine_b + (edge_b + spine_b) * f)), i, 1, 0)
        else:
            m = max(1, int(ln / (M["body_r"] * 2.6) + 0.999))
            for j in range(0 if first else 1, m + 1):
                f = j / m
                q = lerp(s["start"], s["end"], f)
                e = norm(lerp(ea, eb, f))
                add_line(sub(q, mul(e, spine_a + (spine_b - spine_a) * f)),
                         add(q, mul(e, edge_a + (edge_b - edge_a) * f + pad)), i, 1, 0)
    # A head whose back is a pick: lines from the bit's joints to the pick's tip.
    for n, s in enumerate(segs):
        if s["cls"] != cls or s["back_part"] != 2:
            continue
        prev = segs[n - 1] if n > 0 else None
        first = prev is None or prev["cls"] != cls or length(sub(prev["end"], s["start"])) > 0.1
        for t in points:
            if t["cls"] != cls or t["part"] != 2 or dot(sub(t["tip"], s["start"]), norm(s["edge_dir"])) > -1:
                continue
            if first:
                add_line(s["start"], t["tip"], s["index"], 1, 0)
            add_line(s["end"], t["tip"], s["index"], 1, 0)
            AREAS.append(dict(cls=cls, quad=[s["start"], s["end"], t["tip"], t["tip"]]))
    for t in points:
        if t["cls"] != cls:
            continue
        ax = norm(t["axis"])
        add_line(sub(t["tip"], mul(ax, 1.5 + M["point_r"])), add(t["tip"], mul(ax, M["point_r"])), -1, 2, t["part"], ax)
    for h in SHAFTS:
        if h["cls"] == cls:
            add_line(h["a"], h["b"], -1, 3, 0)
    return lines


# ---------------------------------------------------------------- damage table

def describe(t, d):
    return dict(type=t, family=dt_family(t), damage=d)


def seg_list(ids, mine):
    if len(ids) == len(mine):
        return "all segments"
    base = min(t["index"] for t in mine)
    return "segments " + ", ".join(str(i - base) for i in ids)


def damage_rows(cls, slug, stock, trait, rails, segs, M, has_blades, pommel, spike, fold_state=None):
    """Every part with the damage type(s) it deals on a light and a heavy
    swing, following VRPhysicalMelee.ResolveContacts / BladePart and
    VRMeleeScale.PartSwapType / PartBaseDamage."""
    T, D = dict(stock["types"]), dict(stock["damage"])
    if slug == "edged-scythe":
        x, n = stock["extra"], stock["nums"]
        if fold_state == "folded":
            T[LIGHT], T[HEAVY], T[BASH] = x["FoldedDT"], x["FoldedDTAlt"], "KFDT_Piercing_ScytheStabFolded"
            D[LIGHT], D[HEAVY], D[BASH] = n["FoldedDamage"], n["FoldedDamageAlt"], 40
        else:
            T[LIGHT], T[HEAVY], T[BASH] = x["UnfoldedDT"], x["UnfoldedDTAlt"], "KFDT_Piercing_ScytheStab"
            D[LIGHT], D[HEAVY], D[BASH] = n["UnfoldedDamage"], n["UnfoldedDamageAlt"], 60
    mclass = trait["melee_class"] if trait else 0
    is_blunt = mclass == 3
    bash_t = T.get(BASH)
    stab_allowed = bool(trait and trait["point"] and dt_family(bash_t) == "piercing")

    def part_base(part):
        # VRMeleeScale.PartBaseDamage
        if slug == "edged-scythe" and part == "bludgeon":
            return D.get(BASH, 25) if fold_state == "folded" else 25.0
        if part == "pierce" and dt_family(bash_t) == "piercing":
            return D.get(BASH, 25)
        if dt_family(bash_t) == "bludgeon" and cls not in ("KFWeap_Blunt_MaceAndShield", "KFWeap_Pistol_Bladed"):
            return D.get(BASH, 25)
        return 25.0

    lo, hi = M["shaft_lo"], M["shaft_hi"]

    def part_hit(kind):
        t = "VRDT_MeleePommel" if kind == "bludgeon" else "VRDT_MeleePierce"
        b = part_base(kind)
        same = dict(type=t, family=dt_family(t), damage=f"{b * lo:g}-{b * hi:g}",
                    note=f"base {b:g} x {lo:g}-{hi:g} by speed; never takes a limb")
        return same, same

    def mode_hit(mode_type_light, mode_type_heavy, note=""):
        lt = dict(type=mode_type_light, family=dt_family(mode_type_light), damage=D.get(LIGHT))
        ht = dict(type=mode_type_heavy, family=dt_family(mode_type_heavy), damage=D.get(HEAVY))
        if note:
            lt["note"] = ht["note"] = note
        return lt, ht

    def own(note=""):
        return mode_hit(T.get(LIGHT), T.get(HEAVY), note)

    def edge_note():
        # Melee spec M31: edge hits take limbs as stock does; no speed gate.
        return ""

    def blunt_face():
        if is_blunt:
            # PART_STOCK_BLUNT: the heavy's bludgeon type when the mode's own is not one
            lt = T.get(LIGHT) if dt_family(T.get(LIGHT)) == "bludgeon" or dt_family(T.get(HEAVY)) != "bludgeon" \
                else T.get(HEAVY)
            return mode_hit(lt, T.get(HEAVY), "the swing's own amount (melee spec M19)")
        return part_hit("bludgeon")

    rows = []
    mine = [s for s in segs if s["cls"] == cls]
    if has_blades and mine:
        edge_parts = sorted({s["edge_part"] for s in mine})
        back_parts = sorted({s["back_part"] for s in mine})
        has_flat = any(length(s["flat"]) > 0.5 for s in mine)
        for ep in edge_parts:
            if ep == 3:
                l, h = mode_hit(T.get(LIGHT), T.get(LIGHT), "its light attack's slash at the swing's own amount")
                h["damage"] = D.get(HEAVY)
            else:
                l, h = own(edge_note())
            ids = [s["index"] for s in mine if s["edge_part"] == ep]
            rows.append(dict(part="edge", label="Edge leading (red edge lines)", light=l, heavy=h,
                             how="contact moving into the edge side, not along the flat normal; "
                                 + seg_list(ids, mine)))
        if has_flat:
            l, h = blunt_face()
            ids = [s["index"] for s in mine if length(s["flat"]) > 0.5]
            rows.append(dict(part="flat", label="Flat leading (blue body lines)", light=l, heavy=h,
                             how="contact moving within ~32 deg of the flat's normal (|v.n| > 0.85); "
                                 + seg_list(ids, mine)))
        for bp in back_parts:
            if bp == 3:
                l, h = mode_hit(T.get(LIGHT), T.get(LIGHT), "its light attack's slash at the swing's own amount")
                h["damage"] = D.get(HEAVY)
                lab = "Other side leading (slices like the edge)"
            elif bp == 0:
                l, h = own(edge_note())
                lab = "Second edge / back leading (double-edged)"
            elif bp == 1:
                l, h = blunt_face()
                lab = "Spine / back leading"
            else:
                l, h = part_hit("pierce")
                lab = "Back pick leading"
            ids = [s["index"] for s in mine if s["back_part"] == bp]
            rows.append(dict(part="back", label=lab, light=l, heavy=h,
                             how="contact moving against the edge direction (v.e < -0.5); " + seg_list(ids, mine)))
    elif rails:
        if cls == "KFWeap_Blunt_MaceAndShield":
            x = stock["extra"]
            l, h = mode_hit(x["MaceLightDamageType"], x["MaceHeavyDamageType"])
            rows.append(dict(part="head", label="Mace head (orange capsule)", light=l, heavy=h,
                             how="any contact"))
            l, h = mode_hit(x["ShieldLightDamageType"], x["ShieldHeavyDamageType"])
            rows.append(dict(part="shield", label="Shield face (chord lines, left hand)", light=l, heavy=h,
                             how="any contact; chords of the measured face disc (radius 31) on LW_Weapon"))
        else:
            l, h = own()
            rows.append(dict(part="head", label="Head (orange capsule)", light=l, heavy=h, how="any contact"))
    for kind_part in sorted({r_["part"] for r_ in rails if r_["kind"] == 2}):
        if kind_part == 4:
            l, h = own()
            rows.append(dict(part="tip", label="Tip (magenta point line), not thrusting", light=l, heavy=h,
                             how="the swing's own hit"))
        else:
            l, h = part_hit("pierce")
            rows.append(dict(part="point", label="Pick / spike / claw leading (magenta point line)", light=l,
                             heavy=h, how=f"contact travelling along the point's axis (within "
                                          f"{math.degrees(math.acos(M['point_lead_dot'])):.0f} deg)"))
            hz = [r_ for r_ in rails if r_["kind"] == 2 and r_["part"] == kind_part]
            if any(r_["p"][2] < 0 for r_ in hz):
                l, h = part_hit("bludgeon")
                rows.append(dict(part="point_side", label="Butt point not leading (below the grip)", light=l,
                                 heavy=h, how="a point line below the grip that is not leading bludgeons"))
            if any(r_["p"][2] >= 0 for r_ in hz):
                l, h = own()
                rows.append(dict(part="point_side", label="Head point not leading", light=l, heavy=h,
                                 how="a head point line that is not leading lands the swing's own hit"))
    if stab_allowed:
        l = dict(type=bash_t, family=dt_family(bash_t), damage=D.get(LIGHT), note="stock stab type, light amount")
        h = dict(type=bash_t, family=dt_family(bash_t), damage=D.get(HEAVY), note="stock stab type, heavy amount")
        rows.append(dict(part="thrust", label="Tip-first thrust (any contact near the tip)", light=l, heavy=h,
                         how=f"travelling within {M['stab_angle']:g} deg of the blade axis, hit within "
                             f"2 x radius + {M['spike_reach']:g} uu of the tip; a deep stick lands it once "
                             f"(melee spec M9, M22)"))
    if spike:
        l, h = own()
        rows.append(dict(part="spike", label="Spike (yellow), swung", light=l, heavy=h,
                         how="the spike capsule's own sweep; tip-first it is the thrust above"))
    if pommel:
        b = part_base("bludgeon")
        same = dict(type="VRDT_MeleePommel", family="bludgeon",
                    damage=f"{b * lo:g}-{b * hi:g}",
                    note=f"stock bash base {b:g} x {lo:g}-{hi:g} by speed (from {M['pommel_min']:g} uu/s)")
        rows.append(dict(part="shaft", label="Shaft / grip / pommel (green shaft lines)", light=same, heavy=same,
                         how="butt to head along the real shaft; lands only when the head did not hit that Zed "
                             "this stroke; never takes a limb"))
    return rows


# ---------------------------------------------------------------- data step

def mesh_for(slug):
    bd = REVIEW / "blade-data" / f"{slug}.json"
    if bd.exists():
        d = json.loads(bd.read_text(encoding="utf-8"))
        return [dict(bone="RW_Weapon", verts=d["verts"], tris=d["tris"], uvs=d.get("uvs"), texture=d.get("texture"))]
    d = json.loads((REVIEW / "data" / f"{slug}.json").read_text(encoding="utf-8"))
    return [dict(bone=p["bone"], verts=p["verts"], tris=p["tris"], uvs=None, texture=None) for p in d["parts"]]


def export():
    M = melee_defaults()
    segs, points = blades()
    P, TR, F = profiles(), traits(), scythe_fold()
    (OUT / "data").mkdir(parents=True, exist_ok=True)
    index = []
    for slug, cls, title in WEAPONS:
        prof, trait = P[cls], TR.get(cls)
        stock = stock_weapon(cls)
        mclass = trait["melee_class"] if trait else 0
        dual = cls in ("KFWeap_Blunt_PowerGloves", "KFWeap_HRG_BlastBrawlers")
        radius = prof["radius"]
        if not dual and mclass < 5:
            radius = max(radius, M["min_edge"].get(mclass, 0))
        cs, ce = prof["head_start"], prof["head_end"]
        rails = [] if dual else build_rails(cls, segs, points, cs, ce, radius, M)
        if dual:
            # Dual gauntlets keep the profile head: three samples, swept as one capsule.
            rails = [dict(p=lerp(cs, ce, t), r=radius, seg=-1, kind=0, part=0, axis=[0, 0, 0]) for t in (0, .5, 1)]
        has_blades = any(s["cls"] == cls for s in segs)
        # The sphere rails this replaced, for the before/after count.
        capped = len(rails)
        uncapped = len(build_rails(cls, segs, points, cs, ce, radius, dict(M, max_rails=10 ** 6))) if not dual else capped
        seg_base = min([s["index"] for s in segs if s["cls"] == cls] or [0])
        AREAS.clear()
        lines = build_lines(cls, segs, points, M)
        areas = [a_["quad"] for a_ in AREAS]
        if dual:
            lines = []
        # The damage table reads the points as rails did: one entry per point.
        if lines:
            rails = [dict(p=l_["b"], r=0.0, seg=-1, kind=2, part=l_["part"], axis=l_["axis"])
                     for l_ in lines if l_["kind"] == 2]
            if not has_blades:
                # No measured blade: the profile head capsule stays (swept as spheres).
                ln_ = length(sub(ce, cs))
                n_ = 3
                while n_ < 16 and (n_ - 1) * radius * 1.5 < ln_:
                    n_ += 1
                rails += [dict(p=lerp(cs, ce, t / (n_ - 1)), r=radius, seg=-1, kind=0, part=0, axis=[0, 0, 0])
                          for t in range(n_)]
        # PommelPoints (from the measured head, before any fold).
        pommel = None
        hc = mul(add(cs, ce), 0.5)
        if any(l_["kind"] == 3 for l_ in lines):
            pommel = dict(lines=True)
        elif not dual and length(hc) >= 1:
            ax = norm(hc)
            far = min(dot(cs, ax), dot(ce, ax)) - radius
            if far >= 4:
                pommel = dict(a=r3(mul(ax, -M["pommel_back"])), b=r3(mul(ax, far)), r=M["pommel_r"])
        spike = None
        if trait and trait.get("stab_axis") and length(trait["stab_axis"]) > 0.5:
            tip = trait["stab_tip"]
            spike = dict(a=r3(sub(tip, mul(norm(trait["stab_axis"]), M["spike_len"]))), b=r3(tip), r=M["spike_r"])
        variants = [("", None)]
        if slug == "edged-scythe":
            variants = [("folded", 0.0), ("unfolded", 1.0)]
        meshes = mesh_for(slug)
        for vname, u in variants:
            vr = [dict(r_) for r_ in rails]
            vl = [dict(l_) for l_ in lines]
            va = [[list(q) for q in a_] for a_ in areas]
            if u is not None:
                va = [[fold_point(q, u, F) for q in a_] for a_ in va]
            head = [cs, ce]
            vmeshes = meshes
            seg_view = [s for s in segs if s["cls"] == cls]
            if u is not None:
                for r_ in vr:
                    r_["p"] = fold_point(r_["p"], u, F)
                    r_["axis"] = fold_dir(r_["axis"], u, F)
                for l_ in vl:
                    if l_["kind"] == 3:
                        continue
                    l_["a"] = fold_point(l_["a"], u, F)
                    l_["b"] = fold_point(l_["b"], u, F)
                    l_["axis"] = fold_dir(l_["axis"], u, F)
                head = [fold_point(cs, u, F), fold_point(ce, u, F)]
                # The measured mesh is idle_folded (RW_Fold 140 deg): the zone
                # review's idle_unfolded export tells which vertices are RW_Fold.
                unf = json.loads((REVIEW / "data" / "edged-scythe.json").read_text(encoding="utf-8"))["parts"][0]["verts"]
                base = meshes[0]["verts"]
                # RW_Fold vertices are the moving ones that the fold turn
                # carries onto idle_unfolded (4039 to 0.01 uu); ~200 others
                # (the latch linkage) follow another bone: idle_unfolded's
                # own positions unfolded, idle_folded's folded.
                fold = [length(sub(a, b)) > 0.05 and length(sub(fold_point(a, 1.0, F), b)) < 0.5
                        for a, b in zip(base, unf)]
                verts = [r3(fold_point(v, u, F)) if f else (w if u == 1.0 else v)
                         for v, w, f in zip(base, unf, fold)]
                if u == 1.0:
                    err = [length(sub(a, b)) for a, b in zip(verts, unf)]
                    print(f"  scythe unfold check: RW_Fold verts {sum(fold)}, max error vs idle_unfolded "
                          f"{max(err):.3f} uu")
                vmeshes = [dict(meshes[0], verts=verts)]
                seg_view = [dict(s, start=fold_point(s["start"], u, F), end=fold_point(s["end"], u, F),
                                 edge_dir=fold_dir(s["edge_dir"], u, F), flat=fold_dir(s["flat"], u, F))
                            for s in seg_view]
            rows = damage_rows(cls, slug, stock, trait, vr, segs, M, has_blades, pommel, spike,
                               fold_state=vname or None)
            key = slug + (f"_{vname}" if vname else "")
            data = dict(slug=slug, key=key, cls=cls, title=title + (f", {vname}" if vname else ""),
                        variant=vname, melee_class=mclass, dual=dual,
                        profile=dict(head_start=r3(head[0]), head_end=r3(head[1]), radius=radius,
                                     profile_radius=prof["radius"], used=not has_blades),
                        old_rails=capped, old_rails_uncapped=uncapped, seg_base=seg_base,
                        rails=[dict(r_, p=r3(r_["p"]), axis=r3(r_["axis"], 3)) for r_ in vr],
                        lines=[dict(l_, a=r3(l_["a"]), b=r3(l_["b"]), axis=r3(l_["axis"], 3)) for l_ in vl],
                        areas=[[r3(q) for q in a_] for a_ in va],
                        segments=[dict(index=s["index"] - min(t["index"] for t in seg_view), start=r3(s["start"]), end=r3(s["end"]),
                                       edge_dir=r3(s["edge_dir"], 3), flat=r3(s["flat"], 3),
                                       edge_reach=s["edge_reach"], spine_reach=s["spine_reach"],
                                       half_thick=s["half_thick"], edge_part=s["edge_part"],
                                       back_part=s["back_part"]) for s in seg_view],
                        pommel=pommel, spike=spike, stock=stock, rows=rows, meshes=vmeshes,
                        shield_lines=shield_lines(M) if cls == "KFWeap_Blunt_MaceAndShield" else None,
                        shield=None)
            (OUT / "data" / f"{key}.json").write_text(json.dumps(data), encoding="utf-8")
            counts = {k: sum(1 for l_ in vl if l_["kind"] == k) for k in (0, 1, 2, 3)}
            index.append(dict(key=key, slug=slug, title=data["title"], rails=counts))
            print(key, "lines", counts, "capsule" if not has_blades else "", "spike" if spike else "")
    extra = []
    for cls in NOT_DRAWN:
        p = P.get(cls)
        if p:
            extra.append(dict(cls=cls, head_start=p["head_start"], head_end=p["head_end"], radius=p["radius"],
                              melee_class=TR.get(cls, {}).get("melee_class")))
    (OUT / "index.json").write_text(json.dumps(dict(weapons=index, not_drawn=extra, constants=M)), encoding="utf-8")


# ---------------------------------------------------------------- render step (Blender)

COL = dict(edge=(0.95, 0.12, 0.10), body=(0.15, 0.45, 1.0), point=(1.0, 0.1, 0.9), head=(1.0, 0.55, 0.05),
           pommel=(0.1, 0.85, 0.3), spike=(1.0, 0.9, 0.1), shield=(1.0, 0.55, 0.05))


def views_for(d):
    """[(name, view dir, up)] game space: the flat side, the edge side, the back side and end-on."""
    segs = d["segments"]
    if segs:
        main = max(segs, key=lambda s: length(sub(s["end"], s["start"])))
        flat = main["flat"] if length(main["flat"]) > 0.5 else norm([main["edge_dir"][1], -main["edge_dir"][0], 0]) \
            if abs(main["edge_dir"][2]) < 0.9 else [0, 1, 0]
        edge = main["edge_dir"]
        chord = norm(sub(segs[-1]["end"], segs[0]["start"]))
    else:
        hs, he = d["profile"]["head_start"], d["profile"]["head_end"]
        chord = norm(sub(he, hs)) if length(sub(he, hs)) > 1 else [0, 0, 1]
        flat = [0, 1, 0] if abs(chord[1]) < 0.8 else [1, 0, 0]
        edge = norm([chord[1] * flat[2] - chord[2] * flat[1], chord[2] * flat[0] - chord[0] * flat[2],
                     chord[0] * flat[1] - chord[1] * flat[0]])
    flat, edge = norm(flat), norm(edge)
    up = edge
    return [("side", mul(flat, -1), up), ("other side", flat, up),
            ("edge on", mul(edge, -1), [-x for x in flat]),
            ("three-quarter", norm(add(add(mul(flat, -0.75), mul(edge, -0.45)), mul(chord, -0.45))), up)]


def render(keys=None, size=(1400, 720)):
    import bpy
    import bmesh
    from mathutils import Vector, Matrix
    rend = OUT / "renders"
    rend.mkdir(parents=True, exist_ok=True)
    idx = json.loads((OUT / "index.json").read_text(encoding="utf-8"))
    scene = bpy.context.scene
    for o in list(scene.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    scene.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in \
        [e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items] else "BLENDER_EEVEE"
    scene.render.resolution_x, scene.render.resolution_y = size
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("hit")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.055, 0.058, 0.066, 1)
    bg.inputs[1].default_value = 1.0
    scene.world = world

    def emit_mat(name, col, alpha):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        nt = m.node_tree
        for n in list(nt.nodes):
            nt.nodes.remove(n)
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        em = nt.nodes.new("ShaderNodeEmission")
        em.inputs[0].default_value = (*col, 1)
        em.inputs[1].default_value = 1.0
        tr = nt.nodes.new("ShaderNodeBsdfTransparent")
        mix = nt.nodes.new("ShaderNodeMixShader")
        mix.inputs[0].default_value = alpha
        nt.links.new(tr.outputs[0], mix.inputs[1])
        nt.links.new(em.outputs[0], mix.inputs[2])
        nt.links.new(mix.outputs[0], out.inputs[0])
        if hasattr(m, "surface_render_method"):
            m.surface_render_method = "BLENDED"
        else:
            m.blend_method = "BLEND"
        m.use_backface_culling = name != "ribbon"
        return m

    def weapon_mat(texture):
        m = bpy.data.materials.new("weapon")
        m.use_nodes = True
        nt = m.node_tree
        for n in list(nt.nodes):
            nt.nodes.remove(n)
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        bsdf = nt.nodes.new("ShaderNodeBsdfDiffuse")
        if texture and Path(texture).exists():
            img = bpy.data.images.load(texture)
            img.alpha_mode = "NONE"
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = img
            nt.links.new(tex.outputs["Color"], bsdf.inputs["Color"])
        else:
            bsdf.inputs["Color"].default_value = (0.55, 0.55, 0.53, 1)
        nt.links.new(bsdf.outputs[0], out.inputs[0])
        return m

    def union_mesh(name, spheres, capsules, mat, parent, voxel):
        bm = bmesh.new()
        for p, r in spheres:
            geom = bmesh.ops.create_uvsphere(bm, u_segments=20, v_segments=12, radius=r)
            bmesh.ops.translate(bm, verts=geom["verts"], vec=Vector(p))
        for a, b, r in capsules:
            a, b = Vector(a), Vector(b)
            dvec = b - a
            n = max(2, int(dvec.length / (r * 0.5)) + 1)
            for i in range(n + 1):
                geom = bmesh.ops.create_uvsphere(bm, u_segments=20, v_segments=12, radius=r)
                bmesh.ops.translate(bm, verts=geom["verts"], vec=a + dvec * (i / n))
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        o = bpy.data.objects.new(name, me)
        scene.collection.objects.link(o)
        mod = o.modifiers.new("remesh", "REMESH")
        mod.mode = "VOXEL"
        mod.voxel_size = voxel
        mod.use_smooth_shade = True
        o.data.materials.append(mat)
        o.parent = parent
        return o

    def line(name, a, b, radius, mat, parent):
        a, b = Vector(a), Vector(b)
        dvec = b - a
        if dvec.length < 1e-4:
            return
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=True, segments=8, radius1=radius, radius2=radius, depth=dvec.length)
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        o = bpy.data.objects.new(name, me)
        scene.collection.objects.link(o)
        o.matrix_basis = Matrix.Translation((a + b) / 2) @ dvec.normalized().to_track_quat("Z", "Y").to_matrix().to_4x4()
        o.data.materials.append(mat)
        o.parent = parent

    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 2.5
    scene.collection.objects.link(sun)

    for w in idx["weapons"]:
        key = w["key"]
        if keys and key not in keys and w["slug"] not in keys:
            continue
        d = json.loads((OUT / "data" / f"{key}.json").read_text(encoding="utf-8"))
        made = [o for o in scene.objects if o.type != "LIGHT"]
        for o in made:
            bpy.data.objects.remove(o, do_unlink=True)
        root = bpy.data.objects.new("mirror_root", None)
        scene.collection.objects.link(root)
        root.scale = (1, -1, 1)
        mesh_parts = [m for m in d["meshes"] if m["bone"] == "RW_Weapon"]
        shield_parts = [m for m in d["meshes"] if m["bone"] == "LW_Weapon" and d.get("shield_lines")]
        allpts = []
        span_ref = []
        for mp in mesh_parts + shield_parts:
            me = bpy.data.meshes.new("weapon")
            verts = [tuple(v) for v in mp["verts"]]
            if mp in shield_parts:
                # Shown beside the mace, offset along -X so both read.
                verts = [(v[0] - 45, v[1], v[2]) for v in verts]
            me.from_pydata(verts, [], [tuple(t) for t in mp["tris"]])
            if mp.get("uvs"):
                uv = me.uv_layers.new(name="UV")
                for poly, corners in zip(me.polygons, mp["uvs"]):
                    for li, c in zip(poly.loop_indices, corners):
                        uv.data[li].uv = (c[0], 1.0 - c[1])
            me.materials.append(weapon_mat(mp.get("texture")))
            o = bpy.data.objects.new("weapon", me)
            scene.collection.objects.link(o)
            o.parent = root
            allpts += verts
        size_ref = max(max(v[i] for v in allpts) - min(v[i] for v in allpts) for i in range(3))
        voxel = max(0.12, min(0.6, size_ref / 260))
        rails = d["rails"]
        mats = {k: emit_mat(k, c, 0.30 if k != "body" else 0.24) for k, c in COL.items()}
        # A weapon with no measured blade keeps its head capsule (orange).
        head = [(r_["p"], r_["r"]) for r_ in rails if r_["kind"] == 0 and r_["r"] > 0]
        if head:
            union_mesh("head", head, [], mats["head"], root, voxel)
        # The hit lines themselves (melee spec M27), drawn as thin solid tubes:
        # edge red, body blue, point magenta, shaft green.
        solid = dict(edge=emit_mat("l_edge", COL["edge"], 1.0), body=emit_mat("l_body", COL["body"], 1.0),
                     point=emit_mat("l_point", COL["point"], 1.0), pommel=emit_mat("l_shaft", COL["pommel"], 1.0))
        lr = max(0.16, min(0.75, size_ref / 230))
        # The area each segment's lines cover, as a faint ribbon from its back
        # to its generous edge line.
        ribbon = emit_mat("ribbon", (0.95, 0.25, 0.2), 0.16)
        for quad in d.get("areas", []):
            me = bpy.data.meshes.new("ribbon")
            me.from_pydata([tuple(q) for q in quad], [], [(0, 1, 2, 3)])
            me.materials.append(ribbon)
            o = bpy.data.objects.new("ribbon", me)
            scene.collection.objects.link(o)
            o.parent = root
        for l_ in d.get("lines", []):
            kind_name = ("edge", "body", "point", "pommel")[l_["kind"]]
            line("hit", l_["a"], l_["b"], lr * (1.0 if l_["kind"] != 1 else 0.7), solid[kind_name], root)
        for l_ in d.get("shield_lines") or []:
            # Drawn with the shield, 45 uu to the side of the mace.
            a_, b_ = [l_["a"][0] - 45, l_["a"][1], l_["a"][2]], [l_["b"][0] - 45, l_["b"][1], l_["b"][2]]
            line("hit", a_, b_, lr * (1.0 if l_["kind"] == 0 else 0.7), solid["edge" if l_["kind"] == 0 else "body"], root)
        if d.get("pommel") and not d["pommel"].get("lines"):
            p = d["pommel"]
            union_mesh("pommel", [], [(p["a"], p["b"], p["r"])], mats["pommel"], root, voxel)
        if d.get("spike"):
            p = d["spike"]
            union_mesh("spike", [], [(p["a"], p["b"], p["r"])], mats["spike"], root, voxel)
        if d.get("shield"):
            s = d["shield"]
            union_mesh("shield", [], [([s["a"][0] - 45, s["a"][1], s["a"][2]], [s["b"][0] - 45, s["b"][1], s["b"][2]],
                                       s["r"])], mats["shield"], root, voxel * 1.5)
        # Flat normal (cyan) tick per segment: a contact moving along it is a flat hit.
        tickn = emit_mat("tick_n", (0.0, 0.9, 0.9), 1.0)
        tr = max(0.08, size_ref / 900)
        for s in d["segments"]:
            mid = lerp(s["start"], s["end"], 0.5)
            if length(s["flat"]) > 0.5:
                h = s["half_thick"] + 2.5
                line("flat", sub(mid, mul(s["flat"], h)), add(mid, mul(s["flat"], h)), tr, tickn, root)
        bpy.context.view_layer.update()
        focus = [Vector((v[0], -v[1], v[2])) for v in allpts]
        for r_ in rails:
            p = r_["p"]
            for sgn in (-1, 1):
                focus.append(Vector((p[0] + sgn * r_["r"], -p[1] + sgn * r_["r"], p[2] + sgn * r_["r"])))
        for l_ in d.get("lines", []):
            for q in (l_["a"], l_["b"]):
                focus.append(Vector((q[0], -q[1], q[2])))
        for l_ in d.get("shield_lines") or []:
            for q in (l_["a"], l_["b"]):
                focus.append(Vector((q[0] - 45, -q[1], q[2])))
        for vname, view, up in views_for(d):
            dv = Vector((view[0], -view[1], view[2])).normalized()
            upv = Vector((up[0], -up[1], up[2]))
            upv = (upv - dv * upv.dot(dv)).normalized()
            right = dv.cross(upv)
            # Long axis across the frame: swap so the larger extent is horizontal.
            xs = [p.dot(right) for p in focus]
            ys = [p.dot(upv) for p in focus]
            if (max(ys) - min(ys)) > (max(xs) - min(xs)):
                right, upv = upv, -right
                xs, ys = [p.dot(right) for p in focus], [p.dot(upv) for p in focus]
            cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
            scene.collection.objects.link(cam)
            cam.data.type = "ORTHO"
            cam.data.clip_start, cam.data.clip_end = 0.1, 2000
            aspect = size[0] / size[1]
            # Frame to the weapon: a long blade gets a wide, short image.
            ext_x, ext_y = max(xs) - min(xs), max(ys) - min(ys)
            scene.render.resolution_x = size[0]
            scene.render.resolution_y = int(max(300, min(size[0] * 0.8, size[0] * (ext_y * 1.15 + 2) / (ext_x * 1.06 + 2))))
            aspect = scene.render.resolution_x / scene.render.resolution_y
            cam.data.ortho_scale = max(ext_x * 1.06, (ext_y * 1.15) * aspect) + 2
            centre = right * (max(xs) + min(xs)) / 2 + upv * (max(ys) + min(ys)) / 2
            depth = sum((p.dot(dv) for p in focus)) / len(focus)
            cam.matrix_basis = Matrix.Translation(centre + dv * depth - dv * 600) @ \
                Matrix((right, upv, -dv)).transposed().to_4x4()
            sun.matrix_basis = Matrix.Translation((0, 0, 0)) @ Matrix((right, upv, -dv)).transposed().to_4x4() @ \
                Matrix.Rotation(math.radians(-25), 4, "X")
            scene.camera = cam
            # Two passes, joined in the page step: the weapon alone, then the
            # hit lines alone on a clear background, so a line inside the mesh
            # (a shaft's centreline, a blade's body line) still shows.
            stem = f"{key}_{vname.replace(' ', '-')}"
            for o in scene.objects:
                if o.type == "MESH":
                    o.hide_render = o.name.split(".")[0] != "weapon"
            scene.render.film_transparent = False
            scene.render.filepath = str(rend / f"{stem}.png")
            bpy.ops.render.render(write_still=True)
            for o in scene.objects:
                if o.type == "MESH":
                    o.hide_render = o.name.split(".")[0] == "weapon"
            scene.render.film_transparent = True
            scene.render.image_settings.color_mode = "RGBA"
            scene.render.filepath = str(rend / "overlay" / f"{stem}.png")
            bpy.ops.render.render(write_still=True)
            scene.render.image_settings.color_mode = "RGB"
            bpy.data.objects.remove(cam, do_unlink=True)
        print("rendered", key)


# ---------------------------------------------------------------- page step

def sub_len(l_):
    return length(sub(l_["b"], l_["a"]))


def page():
    import base64
    import html
    import io
    from PIL import Image
    idx = json.loads((OUT / "index.json").read_text(encoding="utf-8"))
    M = idx["constants"]
    esc = html.escape
    fam_class = dict(slashing="slash", bludgeon="blunt", piercing="pierce")

    def img_uri(path):
        im = Image.open(path).convert("RGBA")
        over = path.parent / "overlay" / path.name
        if over.exists():
            # The weapon slightly dimmed, the hit lines on top at full strength.
            im = Image.blend(im, Image.new("RGBA", im.size, (20, 21, 24, 255)), 0.18)
            im = Image.alpha_composite(im, Image.open(over).convert("RGBA").resize(im.size))
        im = im.convert("RGB")
        im.thumbnail((900, 650))
        buf = io.BytesIO()
        im.save(buf, "WEBP", quality=82)
        return "data:image/webp;base64," + base64.b64encode(buf.getvalue()).decode()

    def dtcell(x):
        fam = x.get("family", "")
        dmg = x.get("damage")
        dm = f"{dmg:g}" if isinstance(dmg, (int, float)) else (dmg or "")
        note = f'<div class="note">{esc(x["note"])}</div>' if x.get("note") else ""
        return (f'<span class="dt {fam_class.get(fam, "other")}">{esc(fam)}</span> '
                f'<code>{esc(x.get("type") or "none")}</code> <b>{esc(dm)}</b>{note}')

    cards, toc = [], []
    for w in idx["weapons"]:
        d = json.loads((OUT / "data" / f"{w['key']}.json").read_text(encoding="utf-8"))
        anchor = w["key"]
        toc.append(f'<a href="#{anchor}">{esc(d["title"])}</a>')
        shots = sorted((OUT / "renders").glob(f"{w['key']}_*.png"))
        order = ["side", "other-side", "edge-on", "three-quarter"]
        shots.sort(key=lambda p: order.index(p.stem[len(w["key"]) + 1:]) if p.stem[len(w["key"]) + 1:] in order else 9)
        figs = "".join(f'<figure><img loading="lazy" src="{img_uri(p)}" alt="{esc(d["title"])} {esc(p.stem)}">'
                       f'<figcaption>{esc(p.stem[len(w["key"]) + 1:].replace("-", " "))}</figcaption></figure>'
                       for p in shots)
        rows = "".join(f'<tr><th>{esc(r["label"])}<div class="note">{esc(r["how"])}</div></th>'
                       f'<td>{dtcell(r["light"])}</td><td>{dtcell(r["heavy"])}</td></tr>' for r in d["rows"])
        st = d["stock"]
        stock_line = ", ".join(f"{n} <code>{esc(str(st['types'].get(str(i), st['types'].get(i, '-'))))}</code> "
                               f"{st['damage'].get(str(i), st['damage'].get(i, '-'))}"
                               for n, i in (("light", 0), ("heavy", 5), ("bash", 3)))
        rails = d["rails"]
        hl = d.get("lines", [])
        kinds = {k: [l_ for l_ in hl if l_["kind"] == k] for k in (0, 1, 2, 3)}
        heads = [r_ for r_ in rails if r_["kind"] == 0 and r_["r"] > 0]
        pad = M["edge_out"] + M["edge_r"]
        geo = []
        if d["segments"]:
            geo.append(f"<li><b>{len(hl)} hit lines</b> from {len(d['segments'])} measured segments: "
                       f"{len(kinds[0])} edge lines {pad:g} uu outside the real edge, {len(kinds[1])} body lines, "
                       f"{len(kinds[2])} point, {len(kinds[3])} shaft. Was {d['old_rails']} swept spheres"
                       + (f" (capped from {d['old_rails_uncapped']})" if d['old_rails_uncapped'] > d['old_rails'] else "")
                       + ".</li>")
        else:
            p = d["profile"]
            geo.append(f"<li><b>Head capsule</b> {p['head_start']} to {p['head_end']}, radius {p['radius']:g}"
                       + (f" (profile {p['profile_radius']:g}, raised to the class minimum)"
                          if p["radius"] != p["profile_radius"] else "") + f", swept as {len(heads)} spheres"
                       + (f"; {len(kinds[2])} point line, {len(kinds[3])} shaft line" if hl else "") + ".</li>")
        if kinds[3]:
            za = min(min(l_["a"][2], l_["b"][2]) for l_ in kinds[3])
            zb = max(max(l_["a"][2], l_["b"][2]) for l_ in kinds[3])
            geo.append(f"<li><b>Shaft line</b> along the real centreline from the butt (Z {za:g}) to the head "
                       f"(Z {zb:g}), {len(kinds[3])} straight piece{'s' if len(kinds[3]) != 1 else ''}. "
                       f"The old capsule started 6 uu behind the grip.</li>")
        elif d.get("pommel"):
            geo.append(f"<li><b>Shaft capsule</b> {d['pommel']['a']} to {d['pommel']['b']}, radius {d['pommel']['r']:g}.</li>")
        if d.get("spike"):
            geo.append(f"<li><b>Spike</b> {d['spike']['a']} to {d['spike']['b']}, radius {d['spike']['r']:g}.</li>")
        if d["dual"]:
            geo.append("<li>Dual gauntlets: the right fist is drawn; the left is the same capsule mirrored in Y "
                       "on LW_Weapon. No shaft.</li>")
        segrows = "".join(
            f"<tr><td>{s['index']}</td><td>{s['start']}</td><td>{s['end']}</td><td>{s['edge_dir']}</td>"
            f"<td>{s['flat'] if length(s['flat']) > 0.5 else 'none'}</td><td>{s['edge_reach']:g}</td>"
            f"<td>{s['spine_reach']:g}</td><td>{s['half_thick']:g}</td>"
            f"<td>{['own', 'bludgeon', 'pierce', 'own slash'][s['edge_part']] if s['edge_part'] < 4 else s['edge_part']}</td>"
            f"<td>{['second edge', 'bludgeon', 'pierce', 'own slash'][s['back_part']] if s['back_part'] < 4 else s['back_part']}</td></tr>"
            for s in d["segments"])
        seg_table = (f'<details><summary>Segment numbers ({len(d["segments"])})</summary><div class="scroll"><table class="num">'
                     f"<tr><th>#</th><th>start</th><th>end</th><th>edge dir</th><th>flat normal</th><th>edge reach</th>"
                     f"<th>spine reach</th><th>half thick</th><th>edge part</th><th>back part</th></tr>{segrows}</table>"
                     f"</div></details>") if d["segments"] else ""
        names = ("edge", "body", "point", "shaft")
        pt = "".join(f"<tr><td>{n_}</td><td>{names[l_['kind']]}</td><td>{l_['a']}</td><td>{l_['b']}</td>"
                     f"<td>{sub_len(l_):.1f}</td><td>{l_['seg'] - d['seg_base'] if l_['seg'] >= 0 else ''}</td></tr>"
                     for n_, l_ in enumerate(hl))
        pt_table = (f'<details><summary>Hit lines ({len(hl)})</summary><div class="scroll"><table class="num">'
                    f"<tr><th>#</th><th>kind</th><th>from</th><th>to</th><th>length</th><th>segment</th></tr>{pt}"
                    f"</table></div></details>" if hl else "")
        note = f'<p class="wnote">{esc(NOTES[d["slug"]])}</p>' if d["slug"] in NOTES else ""
        cards.append(f"""
<section class="weapon" id="{anchor}">
  <h2>{esc(d['title'])} <span class="cls">{esc(d['cls'])}</span></h2>
  <div class="shots">{figs}</div>
  <table class="dmg"><tr><th>Part</th><th>Light swing</th><th>Heavy swing</th></tr>{rows}</table>
  <ul class="geo">{''.join(geo)}<li>Stock modes: {stock_line}.</li></ul>
  {note}{seg_table}{pt_table}
</section>""")
    nd = "".join(f"<tr><td><code>{esc(x['cls'])}</code></td><td>{x['head_start']}</td><td>{x['head_end']}</td>"
                 f"<td>{x['radius']:g}</td></tr>" for x in idx["not_drawn"])
    css = """
:root{--bg:#f6f6f4;--fg:#1d1d1f;--muted:#6b6b70;--card:#fff;--line:#e2e2e0;--code:#f0efec;
--slash:#c62828;--blunt:#1e5bd6;--pierce:#b0129f;--other:#666}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#121214;--fg:#ececee;--muted:#9a9aa2;
--card:#1b1b1f;--line:#2c2c32;--code:#26262c;--slash:#ff6b60;--blunt:#7aa7ff;--pierce:#f07ae6;--other:#aaa;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#121214;--fg:#ececee;--muted:#9a9aa2;--card:#1b1b1f;--line:#2c2c32;--code:#26262c;
--slash:#ff6b60;--blunt:#7aa7ff;--pierce:#f07ae6;--other:#aaa;color-scheme:dark}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}
main{max-width:1180px;margin:0 auto;padding-block:24px 80px;padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px))}h1{font-size:26px;margin:0 0 6px}
.lede{color:var(--muted);max-width:900px}.legend{display:flex;flex-wrap:wrap;gap:8px 18px;margin:14px 0;padding:12px 14px;
background:var(--card);border:1px solid var(--line);border-radius:10px;font-size:14px}
.sw{display:inline-block;width:14px;height:14px;border-radius:3px;vertical-align:-2px;margin-right:6px}
nav{display:flex;flex-wrap:wrap;gap:6px;margin:12px 0 22px}nav a{font-size:13px;padding:3px 9px;border:1px solid var(--line);
border-radius:999px;color:var(--fg);text-decoration:none;background:var(--card)}
.weapon{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin:0 0 22px}
h2{font-size:20px;margin:0 0 10px}.cls{font:12px ui-monospace,monospace;color:var(--muted);font-weight:400;margin-left:6px}
.shots{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}figure{margin:0}
figure img{width:100%;display:block;border-radius:8px;background:#0e0f11}
figcaption{font-size:12px;color:var(--muted);text-align:center;margin-top:2px}
table{border-collapse:collapse;width:100%;margin-top:12px;font-size:14px}th,td{border-top:1px solid var(--line);padding:7px 8px;
text-align:left;vertical-align:top}table.dmg th:first-child{width:30%}code{font:12.5px ui-monospace,monospace;background:var(--code);
padding:1px 4px;border-radius:4px;word-break:break-all}.note{font-size:12px;color:var(--muted);font-weight:400}
.dt{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;padding:1px 6px;border-radius:4px;color:#fff}
.dt.slash{background:var(--slash)}.dt.blunt{background:var(--blunt)}.dt.pierce{background:var(--pierce)}.dt.other{background:var(--other)}
.review{border-left:4px solid var(--slash)}
.wnote{font-size:13.5px;margin:10px 0 0;padding:8px 10px;border-left:3px solid var(--pierce);background:var(--code);border-radius:4px}
ul.geo{font-size:13.5px;margin:10px 0 0;padding-left:18px}details{margin-top:8px;font-size:13px}summary{cursor:pointer;color:var(--muted)}
.scroll{overflow-x:auto}table.num{font:12px ui-monospace,monospace;white-space:nowrap}
@media (max-width:700px){.shots{grid-template-columns:1fr}table.dmg th:first-child{width:auto}}
"""
    # Artifact page: the host adds the document skeleton.
    body = f"""<title>VR melee hit areas</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>{css}</style>
<main>
<h1>Melee hit areas</h1>
<p class="lede">Every melee weapon's VR hit detection as the game builds it, drawn on the stock mesh in the weapon's
own space (RW_Weapon, 1 uu = 1 cm in the headset), with every damage type each part can deal. Hits are found by <b>lines along the
weapon</b> (melee spec M27): each line is traced against a Zed's own body shapes at up to {M['line_steps']} stepped
poses per frame (one every {M['line_step']:g} uu of travel), so a fast swing cannot skip a limb. A line touching a Zed
only decides <i>that</i> it is hit; which part's damage lands depends on the direction the weapon was moving at
contact, as each row says. Rebuilt from the shipped script data (VRMeleeBlades, VRPhysicalMelee, VRHandsBridge
profiles, VRMeleeTraits, VRScytheFold) and stock weapon defaults.</p>
<div class="legend">
<span><span class="sw" style="background:#f21f1a"></span>Edge lines ({M['edge_out'] + M['edge_r']:g} uu outside the real edge)</span>
<span><span class="sw" style="background:#2673ff"></span>Body lines</span>
<span><span class="sw" style="background:#ff1ae6"></span>Point lines</span>
<span><span class="sw" style="background:#ff8c0d"></span>Head capsule (no measured blade)</span>
<span><span class="sw" style="background:#1ad94d"></span>Shaft lines, butt to head</span>
<span><span class="sw" style="background:#ffe61a"></span>Spike</span>
<span><span class="sw" style="background:#00e6e6"></span>Flat normal</span>
</div>
<p class="note">Light or heavy: heavy when the blade's sweet spot peaks at {M['heavy_speed']:g} uu/s or more through a
real arc (Q2). Amounts are the stock numbers, which a swing can reach but not exceed (melee spec M30); a slow hit
lands below them, perk modifiers apply on top, and live balance tweaks can differ. Edge hits take limbs as stock does
(M31). Flat, spine, pick and shaft hits never take a limb.</p>
<section class="weapon review"><h2>Open points from the review</h2>
<ul class="geo">
<li><b>Edge reach:</b> {M['edge_out'] + M['edge_r']:g} cm outside the real edge on swords, axes and the Scythe (melee plan
Q1, "generous on the blade side"); {M['knife_edge']:g} cm on knives, with a {M['knife_flat']:g} cm margin off each flat.</li>
<li><b>Scythe back blade:</b> its outer side is taken as the cutting edge and the side bolted to the crescent as a
bludgeon. That is read from the model's shape, not from a measured bevel.</li>
<li><b>Karambit (Firebug knife):</b> its handle curves away from the weapon's long axis, so the straight shaft line
leaves the grip near the ring.</li>
<li><b>Gunslinger, Support and Survivalist knives:</b> the segment next to the guard has a twisted edge direction in the
measured data, which shows as a small hook in the edge line there.</li>
</ul></section>
<nav>{''.join(toc)}</nav>
{''.join(cards)}
<section class="weapon"><h2>Not drawn: profile head only</h2>
<p class="note">These melee-capable guns and the VR Tomahawk have no exported mesh in the melee review set; they hit with
their profile head capsule and the weapon's own melee type.</p>
<table class="num"><tr><th>class</th><th>head start</th><th>head end</th><th>radius</th></tr>{nd}</table></section>
</main>"""
    (OUT / "index.html").write_text(body, encoding="utf-8")
    print(OUT / "index.html", f"{len(body) / 1e6:.1f} MB")


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    step = argv[0] if argv else "data"
    if step == "data":
        export()
    elif step == "render":
        render(argv[1:] or None)
    elif step == "page":
        page()
    else:
        raise SystemExit(__doc__)
