"""Render the stock in-hand flips and twirls of the knives and the Katana.

For the reverse-grip plan (#227 follow-up): every stock 1P animation segment
where the weapon turns more than 60 degrees in the right hand (found by
scanning RW_Weapon against RightHand_1stP, relative to Idle), rendered from
the first-person camera as an animated GIF at the animation's own rate plus
a frame strip. All ten class knives share WEP_1P_CommandoKnife_ANIM (stock
KFWeap_Knife_* AnimSets), so the knife moves are drawn on each knife mesh.

  python tools/re/melee_flip_candidates.py [out_dir]
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import melee_rig as mr  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
KNIVES = ["knife-commando", "knife-berserker", "knife-demolitionist", "knife-fieldmedic", "knife-firebug",
          "knife-gunslinger", "knife-sharpshooter", "knife-support", "knife-survivalist", "knife-swat"]
# (slug, sequence, first frame, last frame, label) from the >60 degree scan,
# padded a few frames each side so the move reads from rest to rest.
MOVES = [
    ("knife", "Guncheck_v3", 30, 48, "Inspect 3: full twirl through the fingers"),
    ("knife", "Guncheck_v3", 10, 28, "Inspect 3: roll and back"),
    ("knife", "Equip", 14, 30, "Draw: flip into the hand"),
    ("knife", "PutAway", 0, 32, "Holster: turn down to sheathe"),
    ("knife", "Clean_NoBlood", 10, 30, "Wipe: turn the blade over"),
    ("edged-katana", "Guncheck_v2", 14, 70, "Katana inspect 2: turn and regrip"),
    ("edged-katana", "Clean_NoBlood", 2, 15, "Katana wipe: turn the blade over"),
]
W, H = 240, 200
SKIN, WEAPON, BG = (196, 150, 122), (205, 208, 214), (22, 23, 26)


ARMS_PSK = ROOT / "build/melee-zone-review/arms/Wep_1stP_Naked_Hands_Rig.psk"  # stock CHR_1P_Arms_MESH


def frame_tris(rig, pose, rigid, colour):
    """Right arm/hand or weapon triangles in game space. The weapon moves
    rigidly with each vertex's owning bone (its RW_Damage helper is not keyed);
    the arms are blend-skinned."""
    pos, rot = pose
    cache = {}

    def pt(i):
        if i not in cache:
            if rigid:
                b = rig.owner[i]
                local = mr.rotate(mr.conj(rig.bind_rot[b]), mr.sub(rig.points[i], rig.bind_pos[b]))
                cache[i] = mr.game(mr.add(pos[b], mr.rotate(rot[b], local)))
            else:
                cache[i] = mr.game(rig.skin(i, pos, rot))
        return cache[i]
    out = []
    for tri, _ in rig.faces:
        b = rig.owner.get(tri[0])
        if b is None:
            continue
        name = rig.bones[b]["name"]
        if not (name.startswith("Right") or name.startswith("RW_")):
            continue
        out.append(([pt(i) for i in tri], colour))
    return out


def project(v):
    # Seen from the 1P camera along +X (game space: Y right, Z up), drawn
    # orthographic: stock 1P weapons sit so close to the camera that a true
    # perspective bends a blade that crosses near the eye.
    return (v[1], -v[2])


def render(frames, box):
    (x0, y0, x1, y1) = box
    s = min((W - 20) / (x1 - x0), (H - 20) / (y1 - y0))
    imgs = []
    for tris in frames:
        im = Image.new("RGB", (W, H), BG)
        d = ImageDraw.Draw(im)
        for t, col in sorted(tris, key=lambda t: -sum(v[0] for v in t[0])):
            a, b, c = t
            n = mr.cross(mr.sub(b, a), mr.sub(c, a))
            ln = mr.norm(n) or 1
            view = mr.unit(a)
            k = 0.45 + 0.55 * abs(mr.dot(n, view)) / ln
            d.polygon([(10 + (p[0] - x0) * s, 10 + (p[1] - y0) * s) for p in map(project, t)],
                      fill=tuple(int(ch * k) for ch in col))
        imgs.append(im)
    return imgs


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build/melee-zone-review/flips"
    out.mkdir(parents=True, exist_ok=True)
    try:
        font = ImageFont.truetype("arial.ttf", 14)
    except OSError:
        font = ImageFont.load_default()
    index = []
    real_mesh_path = mr.mesh_path
    mr.mesh_path = lambda slug: ARMS_PSK if slug == "arms" else real_mesh_path(slug)
    arms = mr.Rig("arms")
    for m, (who, seq, f0, f1, label) in enumerate(MOVES):
        slugs = KNIVES if who == "knife" else [who]
        for slug in slugs:
            rig = mr.Rig(slug)
            anim = mr.Anim(mr.anim_path(slug)[0])
            f1c = min(f1, anim.frames(seq) - 1)
            frames = [frame_tris(rig, anim.pose(rig, seq, f), True, WEAPON)
                      + frame_tris(arms, anim.pose(arms, seq, f), False, SKIN) for f in range(f0, f1c + 1)]
            pts = [project(v) for fr in frames for t, _ in fr for v in t]
            box = (min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts))
            imgs = render(frames, box)
            ms = int(1000 / anim.rate(seq))
            gif = out / f"move{m}-{slug}.gif"
            # Hold the last frame so each loop reads as one move.
            imgs[0].save(gif, save_all=True, append_images=imgs[1:] + [imgs[-1]] * 12, duration=ms, loop=0)
            step = max(1, len(imgs) // 8)
            strip_imgs = imgs[::step][:8]
            strip = Image.new("RGB", (W * len(strip_imgs), H + 22), BG)
            for i, im in enumerate(strip_imgs):
                strip.paste(im, (i * W, 22))
            ImageDraw.Draw(strip).text((8, 4), f"{label}  ({seq} frames {f0}-{f1c}, {len(imgs) / anim.rate(seq):.2f} s)  {slug}",
                                       fill=(230, 230, 230), font=font)
            strip.save(out / f"move{m}-{slug}-strip.png")
            index.append((m, slug, seq, f0, f1c, label, round(len(imgs) / anim.rate(seq), 2), gif.name))
            print(gif)
    (out / "index.txt").write_text("\n".join("\t".join(map(str, r)) for r in index) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
