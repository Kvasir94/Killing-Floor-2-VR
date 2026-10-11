"""Judge sheet: only the mutually consistent concept panels (side profile, top-down, 3/4 iso) beside matching renders.
The concept side profile is flipped horizontally so its orientation matches the render (its text reads backwards)."""
import os, sys
from PIL import Image, ImageOps
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
R = os.path.join(ROOT, "build", "deadbolt-concept", "renders") + os.sep
pre = sys.argv[1]
con = Image.open(os.path.join(ROOT, "assets", "weapons", "deadbolt", "concept", "deadbolt-concept-sheet.webp")).convert("RGB")
panels = [("side_in", (20, 75, 540, 215), True), ("top", (545, 75, 860, 215), False), ("iso", (0, 255, 520, 572), False)]
rows = []
for v, box, flip in panels:
    c = con.crop(box)
    if flip:
        c = ImageOps.mirror(c)
    c.resize((c.width*2, c.height*2), Image.LANCZOS).save(R + f"concept_{v}.png")
    r = Image.open(R + f"{pre}_{v}.png").convert("RGB")
    h = 520
    c = c.resize((int(c.width*h/c.height), h), Image.LANCZOS)
    r = r.resize((int(r.width*h/r.height), h), Image.LANCZOS)
    row = Image.new("RGB", (c.width + r.width + 20, h), (40, 40, 40))
    row.paste(c, (0, 0)); row.paste(r, (c.width + 20, 0))
    rows.append(row)
sheet = Image.new("RGB", (max(r.width for r in rows), sum(r.height for r in rows) + 20), (40, 40, 40))
y = 0
for r in rows:
    sheet.paste(r, (0, y)); y += r.height + 10
sheet.save(R + f"{pre}_judge.png")
print("ok")
