"""Concept comparison sheet: for the main Ripcord and the fixed-spool alternative, the 2D concept image,
its Pixal3D blockout and the procedural model, then both on the same forearm.

    python tools/ripcord/make_compare_sheet.py

Reads assets/weapons/ripcord/concept/concept-*.webp and build/ripcord-concept/review/ (written by
render_ripcord.py and render_ripcord_compare.py); writes build/ripcord-concept/review/compare_concepts.png.
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CON = os.path.join(ROOT, "assets", "weapons", "ripcord", "concept")
REV = os.path.join(ROOT, "build", "ripcord-concept", "review")
H = 420
ROWS = [
    ("A  main: drum beside the forearm", ["concept-a-s101.webp", "pixal_concept_a_s101_pix_a.png", "review_iso.png", "review_hero_out.png"]),
    ("B  alternative: fixed-spool reel along the forearm", ["concept-b-s303.webp", "pixal_concept_b_s303_pix_a.png", "alt_iso.png", "alt_hero_out.png"]),
]

def font(size):
    for f in ("C:/Windows/Fonts/arialbd.ttf", "C:/Windows/Fonts/arial.ttf"):
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            pass
    return ImageFont.load_default()

def load(name):
    for d in (CON, REV):
        p = os.path.join(d, name)
        if os.path.exists(p):
            im = Image.open(p).convert("RGB")
            return im.resize((int(im.width*H/im.height), H), Image.LANCZOS)
    im = Image.new("RGB", (int(H*4/3), H), (60, 60, 60))
    ImageDraw.Draw(im).text((20, H//2), "not generated: " + name, fill=(220, 220, 220), font=font(20))
    return im

rows = []
for title, names in ROWS:
    ims = [load(n) for n in names]
    row = Image.new("RGB", (sum(i.width for i in ims) + 10*(len(ims) - 1), H + 44), (34, 34, 36))
    ImageDraw.Draw(row).text((8, 6), title + "   (2D concept | Pixal3D blockout | procedural | procedural hero)", fill=(235, 225, 200), font=font(26))
    x = 0
    for im in ims:
        row.paste(im, (x, 44)); x += im.width + 10
    rows.append(row)
side = load("compare_side_out.png")
side = side.resize((int(side.width*1.6), int(side.height*1.6)), Image.LANCZOS)
W = max(max(r.width for r in rows), side.width)
sheet = Image.new("RGB", (W, sum(r.height for r in rows) + side.height + 20*len(rows)), (34, 34, 36))
y = 0
for r in rows:
    sheet.paste(r, (0, y)); y += r.height + 20
sheet.paste(side, ((W - side.width)//2, y))
out = os.path.join(REV, "compare_concepts.png")
sheet.save(out)
print(out, sheet.size)
