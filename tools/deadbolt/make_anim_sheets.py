"""Contact sheets of the Deadbolt take frames from render_deadbolt_anim.py (needs Pillow):

    python tools/deadbolt/make_anim_sheets.py

Reads build/deadbolt-concept/review/frames.json and writes review/sheet_<take>.png: every frame
labelled with its time, frame number and beat, and a bar showing where it falls in the take.
"""
import json, os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REV = os.path.join(ROOT, "build", "deadbolt-concept", "review")

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
    d.text((pad + 4, 42), "beats: " + beat_txt + "      blue dashes: rest-pose muzzle and ram height", fill=(200, 200, 200), font=font(17, False))
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
        # rest-pose guides (fixed camera): muzzle height/position and the ram's front edge
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
for take, cols in (("Fire", 4), ("Reload", 4)):
    frames = [f for f in data["frames"] if f["take"] == take]
    if frames:
        print(sheet(take, data["takes"][take], frames, cols))
for f in data.get("full", []):
    print(label_full(f))
