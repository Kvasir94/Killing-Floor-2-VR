"""Draw every physical melee weapon's hit zones, coloured by damage type, on one sheet.

For Kvasir94's review (#227): each weapon's own mesh (offline UModel export, game
space, posed at Idle frame 0) seen from its side, with the zones the game sweeps
drawn over it the way VRPhysicalMelee builds them:
- measured blades (VRMeleeBlades.uc): an edge rail per sample (radius 4, centred
  2 UU past the edge) and body rails along the blade, point rails at points;
- other weapons: the profile head capsule (VRHandsBridge WeaponProfiles), at
  least VRPhysicalMelee.MinimumEdgeRadius for its class;
- the shaft/hilt/pommel sweep (PommelPoints: 6 UU behind the grip to the head).
Colours: red slash, blue bludgeon, purple pierce, green stock stab (tip thrust),
orange the weapon's own stock slashing type (Crovel). Under each panel, the stock
damage types per part, read from the shipped script source.

  python tools/re/melee_zone_sheet.py [out.png]
"""
import math
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import melee_rig as mr  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SRC = Path(r"D:/SteamLibrary/steamapps/common/killingfloor2/Development/Src")
BRIDGE = ROOT / "script/KF2VR/Classes/VRHandsBridge.uc"
BLADES = ROOT / "script/KF2VR/Classes/VRMeleeBlades.uc"
TRAITS = ROOT / "script/KF2VR/Classes/VRMeleeTraits.uc"

WEAPONS = [  # (class, export slug, bone)
    ("KFWeap_Edged_Katana", "edged-katana", "RW_Weapon"),
    ("KFWeap_Edged_Zweihander", "edged-zweihander", "RW_Weapon"),
    ("KFWeap_Edged_IonThruster", "edged-ionthruster", "RW_Weapon"),
    ("KFWeap_Edged_Scythe", "edged-scythe", "RW_Weapon"),
    ("KFWeap_Edged_FireAxe", "edged-fireaxe", "RW_Weapon"),
    ("KFWeap_Edged_AbominationAxe", "edged-abominationaxe", "RW_Weapon"),
    ("KFWeap_Blunt_Crovel", "crovel", "RW_Weapon"),
    ("KFWeap_Blunt_Pulverizer", "pulverizer", "RW_Weapon"),
    ("KFWeap_Blunt_ChainBat", "blunt-chainbat", "RW_Weapon"),
    ("KFWeap_Blunt_MedicBat", "blunt-medicbat", "RW_Weapon"),
    ("KFWeap_Blunt_MaceAndShield", "blunt-maceandshield", "RW_Weapon"),
    ("KFWeap_Blunt_PowerGloves", "blunt-powergloves", "RW_Weapon"),
    ("KFWeap_HRG_BlastBrawlers", "blastbrawlers", "RW_Weapon"),
    ("KFWeap_Knife_Berserker", "knife-berserker", "RW_Weapon"),
    ("KFWeap_Knife_Commando", "knife-commando", "RW_Weapon"),
    ("KFWeap_Knife_Demolitionist", "knife-demolitionist", "RW_Weapon"),
    ("KFWeap_Knife_FieldMedic", "knife-fieldmedic", "RW_Weapon"),
    ("KFWeap_Knife_Firebug", "knife-firebug", "RW_Weapon"),
    ("KFWeap_Knife_Gunslinger", "knife-gunslinger", "RW_Weapon"),
    ("KFWeap_Knife_Sharpshooter", "knife-sharpshooter", "RW_Weapon"),
    ("KFWeap_Knife_Support", "knife-support", "RW_Weapon"),
    ("KFWeap_Knife_Survivalist", "knife-survivalist", "RW_Weapon"),
    ("KFWeap_Knife_SWAT", "knife-swat", "RW_Weapon"),
    ("KFWeap_Eviscerator", "eviscerator", "RW_Weapon"),
    ("KFWeap_Pistol_Bladed", "bladedpistol", "RW_Weapon"),
    ("KFWeap_Rifle_MosinNagant", "mosin", "RW_Weapon"),
    ("KFWeap_Rifle_FrostShotgunAxe", "frostfang", "RW_Weapon"),
]
# Melee guns swing with their stock bash (VRPhysicalMelee.Initialize).
BASH_ONLY = {"KFWeap_Eviscerator", "KFWeap_Pistol_Bladed", "KFWeap_Rifle_MosinNagant", "KFWeap_Rifle_FrostShotgunAxe"}
MIN_EDGE = {1: 6, 2: 7, 3: 9}  # VRPhysicalMelee.MinimumEdgeRadius by VRMeleeTraits class
COL = {"slash": (220, 40, 40), "blunt": (40, 110, 230), "pierce": (150, 60, 200), "stab": (30, 160, 70),
       "own": (240, 140, 20)}


def vec(text):
    return tuple(float(x) for x in re.findall(r"[XYZ]=(-?[\d.]+)", text))


def profiles():
    out = {}
    for line in BRIDGE.read_text(encoding="utf-8").splitlines():
        m = re.search(r"WeaponClassName=(\w+),.*bPhysicalMelee=true", line)
        if not m:
            continue
        h0 = re.search(r"MeleeHeadStart=\(([^)]*)\)", line)
        h1 = re.search(r"MeleeHeadEnd=\(([^)]*)\)", line)
        r = re.search(r"MeleeRadius=([\d.]+)", line)
        if h0 and h1 and r:
            out[m.group(1)] = (vec(h0.group(1)), vec(h1.group(1)), float(r.group(1)))
    return out


def blades():
    segs, points = {}, {}
    for line in BLADES.read_text(encoding="utf-8").splitlines():
        m = re.search(r"Segs\(\d+\)=\(WeaponClassName=(\w+),(.*)\)$", line)
        if m:
            d = {k: vec(v) for k, v in re.findall(r"(Start|End|EdgeDir|FlatNormal)=\(([^)]*)\)", m.group(2))}
            for k in ("EdgeReach", "SpineReach", "HalfThick", "EdgePart", "BackPart"):
                d[k] = float(re.search(k + r"=(-?[\d.]+)", m.group(2)).group(1))
            segs.setdefault(m.group(1), []).append(d)
        m = re.search(r"Points\(\d+\)=\(WeaponClassName=(\w+),(.*)\)$", line)
        if m:
            d = {k: vec(v) for k, v in re.findall(r"(Tip|Axis)=\(([^)]*)\)", m.group(2))}
            d["Part"] = int(re.search(r"Part=(\d+)", m.group(2)).group(1))
            points.setdefault(m.group(1), []).append(d)
    return segs, points


def traits():
    out = {}
    for line in TRAITS.read_text(encoding="utf-8").splitlines():
        m = re.search(r"WeaponClassName=(\w+),MeleeClass=(\d)", line)
        if m:
            out[m.group(1)] = int(m.group(2))
    return out


def stock(cls):
    """Damage type and amount per fire mode, following the class's parents."""
    modes = {}
    seen = 0
    while cls and seen < 8:
        seen += 1
        f = next(iter(SRC.glob(f"*/Classes/{cls}.uc")), None)
        if not f:
            break
        text = f.read_text(encoding="utf-8", errors="replace")
        for mode in ("DEFAULT_FIREMODE", "HEAVY_ATK_FIREMODE", "BASH_FIREMODE"):
            t = re.search(r"InstantHitDamageTypes\(" + mode + r"\)\s*=\s*class'(\w+)'", text)
            d = re.search(r"InstantHitDamage\(" + mode + r"\)\s*=\s*([\d.]+)", text)
            if t and (mode, "type") not in modes:
                modes[(mode, "type")] = t.group(1)
            if d and (mode, "dmg") not in modes:
                modes[(mode, "dmg")] = d.group(1)
        m = re.search(r"class\s+\w+\s+extends\s+(\w+)", text)
        cls = m.group(1) if m else None
    return modes


def kind_of(dt):
    dt = (dt or "").lower()
    if "slash" in dt:
        return "slash"
    if "pierc" in dt:
        return "stab"
    return "blunt"


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build/melee-zone-review/melee-zone-damage-sheet.png"
    prof, (segs, pts), tr = profiles(), blades(), traits()
    try:
        font = ImageFont.truetype("arial.ttf", 15)
        small = ImageFont.truetype("arial.ttf", 13)
        big = ImageFont.truetype("arialbd.ttf", 17)
    except OSError:
        font = small = big = ImageFont.load_default()
    W, H, T = 560, 330, 120
    cols = 4
    rows = math.ceil(len(WEAPONS) / cols)
    legend_h = 70
    sheet = Image.new("RGB", (cols * W, legend_h + rows * (H + T)), (24, 24, 26))
    dr = ImageDraw.Draw(sheet)
    x = 12
    for name, key in (("slash (edge)", "slash"), ("bludgeon (flat, spine, hilt, shaft, blunt head)", "blunt"),
                      ("pierce (pick, spike, claw, syringe)", "pierce"), ("stock stab (tip-first thrust)", "stab"),
                      ("weapon's own stock slash (Crovel)", "own")):
        dr.rectangle((x, 20, x + 22, 42), fill=COL[key])
        dr.text((x + 28, 22), name, fill=(235, 235, 235), font=font)
        x += 28 + int(dr.textlength(name, font=font)) + 30
    dr.text((12, 48), "Light grey: the weapon itself, side view as held at Idle; coloured circles: its hit zones. Flat sides of every blade bludgeon except the Ion Thruster; "
            "body rails take the part the contact leads with.", fill=(170, 170, 170), font=small)
    for i, (cls, slug, bone) in enumerate(WEAPONS):
        ox, oy = (i % cols) * W, legend_h + (i // cols) * (H + T)
        dr.rectangle((ox + 2, oy + 2, ox + W - 2, oy + H + T - 2), outline=(60, 60, 64))
        dr.text((ox + 10, oy + 6), cls.replace("KFWeap_", ""), fill=(255, 255, 255), font=big)
        try:
            rig = mr.Rig(slug)
            anim, _ = mr.anim_path(slug)
            pose = None
            if anim:
                a = mr.Anim(anim)
                name = "idle_folded" if slug == "edged-scythe" and "idle_folded" in a.sequences else "Idle"
                if name in a.sequences:
                    pose = a.pose(rig, name, 0)
            wp = rig.weapon_points(bone, pose=pose)
            mesh = [v for v, _, _ in wp]
            local = {i: v for v, i, _ in wp}
            tris = [tuple(local[i] for i in tri) for tri, _ in rig.weapon_triangles(set(local))]
        except Exception as e:  # noqa: BLE001
            mesh, tris = [], []
            dr.text((ox + 10, oy + 30), f"mesh not exported ({type(e).__name__})", fill=(200, 120, 120), font=small)
        zone = []  # (centre, radius, colour key)
        p = prof.get(cls)
        mclass = tr.get(cls, 0)
        stk = stock(cls)
        if cls in segs:
            for s in segs[cls]:
                e = mr.unit(s["EdgeDir"])
                n = max(1, math.ceil(mr.norm(mr.sub(s["End"], s["Start"])) / 4.8))
                for j in range(n + 1):
                    a = tuple(s["Start"][k] + (s["End"][k] - s["Start"][k]) * j / n for k in range(3))
                    zone.append((mr.add(a, mr.scale(e, s["EdgeReach"] + 2)), 4, "own" if s["EdgePart"] == 3 else "slash"))
                    back = {0: "slash", 1: "blunt", 2: "pierce", 3: "own"}[int(s["BackPart"])]
                    wid = s["EdgeReach"] + s["SpineReach"]
                    k = max(1, math.ceil(wid / 6))
                    for m in range(k):
                        b = mr.add(a, mr.scale(e, -s["SpineReach"] + wid * (m + 0.5) / k))
                        rad = max(wid * 0.5 / k, s["HalfThick"]) + 0.5
                        # The spine half takes the back part; the edge half the edge.
                        side = "own" if s["EdgePart"] == 3 else ("slash" if (m + 0.5) / k > 0.5 else back)
                        zone.append((b, rad, side))
        elif p:
            r = max(p[2], MIN_EDGE.get(mclass, 0)) if mclass in MIN_EDGE else p[2]
            head = kind_of(stk.get(("BASH_FIREMODE" if cls in BASH_ONLY else "DEFAULT_FIREMODE", "type")))
            n = max(1, math.ceil(mr.norm(mr.sub(p[1], p[0])) / (r * 1.2)))
            for j in range(n + 1):
                zone.append((tuple(p[0][k] + (p[1][k] - p[0][k]) * j / n for k in range(3)), r, head))
        for q in pts.get(cls, []):
            zone.append((mr.sub(q["Tip"], mr.scale(mr.unit(q["Axis"]), 1.5)), 3, "stab" if q["Part"] == 4 else "pierce"))
        if p and cls not in ("KFWeap_Blunt_PowerGloves", "KFWeap_HRG_BlastBrawlers"):
            hc = mr.scale(mr.add(p[0], p[1]), 0.5)
            ax = mr.unit(hc)
            rr = max(p[2], MIN_EDGE.get(mclass, 0)) if mclass in MIN_EDGE else p[2]
            far = min(mr.dot(p[0], ax), mr.dot(p[1], ax)) - rr
            if far >= 4:
                n = max(1, math.ceil((far + 6) / 5))
                for j in range(n + 1):
                    zone.append((mr.scale(ax, -6 + (far + 6) * j / n), 4.5, "blunt"))
        allp = mesh + [c for c, _, _ in zone]
        if not allp:
            continue
        ext = [max(v[k] for v in allp) - min(v[k] for v in allp) for k in range(3)]
        a1, a2 = sorted(range(3), key=lambda k: -ext[k])[:2]
        lo1, hi1 = min(v[a1] for v in allp) - 8, max(v[a1] for v in allp) + 8
        lo2, hi2 = min(v[a2] for v in allp) - 8, max(v[a2] for v in allp) + 8
        sc = min((W - 30) / (hi1 - lo1), (H - 50) / (hi2 - lo2))

        def to(v):
            return (ox + 15 + (v[a1] - lo1) * sc, oy + 40 + (hi2 - v[a2]) * sc)
        # The weapon as a solid shaded silhouette, far faces first.
        a3 = 3 - a1 - a2
        for t in sorted(tris, key=lambda t: sum(v[a3] for v in t)):
            n = mr.cross(mr.sub(t[1], t[0]), mr.sub(t[2], t[0]))
            ln = mr.norm(n)
            shade = 0.55 + 0.45 * (abs(n[a3]) / ln if ln else 0)
            g = int(120 + 110 * shade)
            dr.polygon([to(v) for v in t], fill=(g, g, int(g * 0.97)))
        # Zones on a translucent layer so the weapon shows through.
        layer = Image.new("RGBA", sheet.size, (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        for c, rad, key in zone:
            px, py = to(c)
            rr = rad * sc
            ld.ellipse((px - rr, py - rr, px + rr, py + rr), fill=COL[key] + (38,), outline=COL[key] + (230,), width=2)
        sheet.paste(Image.alpha_composite(sheet.convert("RGBA"), layer).convert("RGB"))
        dr = ImageDraw.Draw(sheet)
        light = stk.get(("DEFAULT_FIREMODE", "type"), "?")
        heavy = stk.get(("HEAVY_ATK_FIREMODE", "type"), "?")
        bash = stk.get(("BASH_FIREMODE", "type"), "?")
        lines = []
        if cls in BASH_ONLY:
            lines.append(f"Swings use its stock bash: {bash} ({stk.get(('BASH_FIREMODE', 'dmg'), '?')})")
        else:
            lines.append(f"Edge/head light: {light} ({stk.get(('DEFAULT_FIREMODE', 'dmg'), '?')})")
            lines.append(f"Edge/head heavy: {heavy} ({stk.get(('HEAVY_ATK_FIREMODE', 'dmg'), '?')})")
            if cls in segs or mclass in (1, 2):
                lines.append(f"Flat, spine, hilt, shaft: bludgeon at bash amount ({stk.get(('BASH_FIREMODE', 'dmg'), '?')}) x0.35-0.8")
            if any(q["Part"] == 4 for q in pts.get(cls, [])):
                lines.append(f"Tip-first thrust: stock stab {bash}")
            if any(q["Part"] == 2 for q in pts.get(cls, [])):
                lines.append("Pick/spike/claw/syringe: pierce at bash amount x0.35-0.8")
        lines.append(f"Hit zones: {len(zone)} rails" + (" from measured blade" if cls in segs else " from profile head"))
        for j, t in enumerate(lines):
            dr.text((ox + 10, oy + H + 4 + j * 18), t, fill=(220, 220, 220), font=small)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    print(out)


if __name__ == "__main__":
    main()
