"""Contact sheets of the Ripcord take frames from render_ripcord_anim.py (needs Pillow):

    python tools/ripcord/make_anim_sheets.py

Reads build/ripcord-concept/review/frames.json and writes review/sheet_<take>.png: every frame
labelled with its time, frame number and beat, and a bar showing where it falls in the take; and
burns the same label into every full-size beat frame (full/*_labelled.png). Same layout as the
Deadbolt's sheets (tools/deadbolt/make_anim_sheets.py).
"""
import json, os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REV = os.path.join(ROOT, "build", "ripcord-concept", "review")

def font(size, bold=True):
    for f in (("arialbd.ttf" if bold else "arial.ttf"), "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            pass
    return ImageFont.load_default()

def sheet(take, info, frames, cols, cell_w=720):
    seconds, beats = info["seconds"], info["beats"]
    ims = [Image.open(os.path.join(REV, f["file"])).convert("RGB") for f in frames]
    cell_h = int(ims[0].height*cell_w/ims[0].width)
    head, pad = 70, 6
    rows = (len(ims) + cols - 1)//cols
    out = Image.new("RGB", (cols*(cell_w + pad) + pad, head + rows*(cell_h + pad) + pad), (24, 24, 26))
    d = ImageDraw.Draw(out)
    beat_txt = "   ".join(f"{k} {v:.3f}s" for k, v in sorted(beats.items(), key=lambda kv: kv[1]))
    d.text((pad + 4, 8), f"{take.upper()}  take  {seconds:.2f} s  @ {fps} fps  ({round(seconds*fps)} frames)", fill=(255, 210, 120), font=font(28))
    d.text((pad + 4, 42), "beats: " + beat_txt + "      blue marks: rest-pose fairlead socket and drum centre", fill=(200, 200, 200), font=font(17, False))
    f_lab, f_beat = font(26), font(22)
    for i, (im, f) in enumerate(zip(ims, frames)):
        x = pad + (i % cols)*(cell_w + pad); y = head + (i//cols)*(cell_h + pad)
        out.paste(im.resize((cell_w, cell_h), Image.LANCZOS), (x, y))
        d.rectangle((x, y, x + 250, y + 36), fill=(0, 0, 0))
        d.text((x + 8, y + 4), f"t={f['time']:.3f}s  f{f['frame']:03d}", fill=(255, 255, 255), font=f_lab)
        if f["beat"]:
            w = d.textlength(f["beat"].upper(), font=f_beat)
            d.rectangle((x + cell_w - w - 18, y, x + cell_w, y + 34), fill=(200, 60, 20))
            d.text((x + cell_w - w - 9, y + 5), f["beat"].upper(), fill=(255, 255, 255), font=f_beat)
        # rest-pose guides (fixed camera): fairlead socket and drum centre
        for (u, v) in guides.values():
            gx, gy = x + int(u*cell_w), y + int((1 - v)*cell_h)
            for k in range(x, x + cell_w, 14): d.line((k, gy, k + 6, gy), fill=(90, 200, 255), width=1)
            d.line((gx, gy - 14, gx, gy + 14), fill=(90, 200, 255), width=2)
        # take timeline with beat ticks and this frame's position
        by = y + cell_h - 12
        d.rectangle((x, by, x + cell_w, y + cell_h), fill=(0, 0, 0))
        for v in beats.values():
            bx = x + int(cell_w*v/seconds); d.line((bx, by, bx, y + cell_h), fill=(200, 60, 20), width=2)
        px = x + int(cell_w*f["time"]/seconds)
        d.rectangle((x, by + 3, px, y + cell_h - 3), fill=(255, 190, 80))
    path = os.path.join(REV, f"sheet_{take.lower()}.png")
    out.save(path)
    return path

def label_full(f):
    """Burn the time, frame and beat into a full-size frame (written beside it as *_labelled.png)."""
    im = Image.open(os.path.join(REV, f["file"])).convert("RGB")
    d = ImageDraw.Draw(im)
    txt = f"{f['take'].upper()}  t={f['time']:.3f}s  f{f['frame']:03d}" + (f"  {f['beat'].upper()}" if f["beat"] else "")
    d.rectangle((0, 0, d.textlength(txt, font=font(34)) + 24, 50), fill=(0, 0, 0))
    d.text((12, 6), txt, fill=(255, 255, 255), font=font(34))
    for (u, v) in guides.values():
        gx, gy = int(u*im.width), int((1 - v)*im.height)
        for k in range(0, im.width, 20): d.line((k, gy, k + 9, gy), fill=(90, 200, 255), width=2)
        d.line((gx, gy - 24, gx, gy + 24), fill=(90, 200, 255), width=3)
    out = os.path.join(REV, f["file"].replace(".png", "_labelled.png"))
    im.save(out)
    return out

data = json.load(open(os.path.join(REV, "frames.json"), encoding="utf-8"))
fps = data["fps"]
guides = data.get("guides", {})
for take, cols in (("Fire", 4), ("Reel", 4), ("Yank", 4), ("Reload", 4)):
    frames = [f for f in data["frames"] if f["take"] == take]
    if frames:
        print(sheet(take, data["takes"][take], frames, cols))
for f in data.get("full", []):
    print(label_full(f))

# the re-imported game rig at its beats (preview_ripcord_export.py), one labelled grid
import glob
shots = sorted(glob.glob(os.path.join(REV, "game_rig_*_rig.png")))
if shots:
    ims = [Image.open(p).convert("RGB") for p in shots]
    w, h = ims[0].width//2, ims[0].height//2
    cols = 4
    grid = Image.new("RGB", (cols*w, ((len(ims) + cols - 1)//cols)*h), (24, 24, 26))
    d = ImageDraw.Draw(grid)
    for i, (p, im) in enumerate(zip(shots, ims)):
        x, y = (i % cols)*w, (i//cols)*h
        grid.paste(im.resize((w, h), Image.LANCZOS), (x, y))
        take, frame = os.path.basename(p).split("_")[2:4]
        d.rectangle((x, y, x + 230, y + 30), fill=(0, 0, 0))
        d.text((x + 6, y + 4), f"{take} f{frame}  (game FBX)", fill=(255, 255, 255), font=font(20))
    grid.save(os.path.join(REV, "game_rig_check.png"))
    print(os.path.join(REV, "game_rig_check.png"))
