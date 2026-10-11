"""Generate the Deadbolt weathering decal atlas (4x4 cells, RGBA, sRGB colour + alpha).
Cells:  0-3 rust drips / rust ring, 4-5 oil, 6-7 soot, 8-11 paint chips, 12-13 grime, 14 scratches, 15 scuffs."""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

C = 512
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "weapons", "deadbolt", "decal_atlas.png")   # committed source asset
rng = np.random.default_rng(7)

def up(a, size):
    return np.asarray(Image.fromarray(a.astype(np.float32), mode='F').resize(size, Image.BICUBIC))

def fbm(h=C, w=C, base=4, octaves=6, gain=0.55, stretch=(1, 1)):
    acc = np.zeros((h, w), np.float32); amp = 1.0; tot = 0.0
    for o in range(octaves):
        f = base * 2**o
        g = rng.random((max(2, int(f*stretch[0])), max(2, int(f*stretch[1])))).astype(np.float32)
        acc += amp*up(g, (w, h)); tot += amp; amp *= gain
    acc /= tot
    return (acc - acc.min())/(acc.max() - acc.min() + 1e-6)

yy, xx = np.mgrid[0:C, 0:C].astype(np.float32)/C

def sstep(a, b, x):
    t = np.clip((x - a)/(b - a), 0, 1); return t*t*(3 - 2*t)

def blur(a, r):
    return np.asarray(Image.fromarray((np.clip(a, 0, 1)*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(r))).astype(np.float32)/255

def colorize(mask_noise, c0, c1):
    m = mask_noise[..., None]
    return (np.array(c0)[None, None]*(1 - m) + np.array(c1)[None, None]*m)

def rust_drip(n_drips=1, length=0.95, width=0.11, src_r=0.11):
    a = np.zeros((C, C), np.float32)
    cols = np.linspace(0.5 - 0.12*(n_drips - 1), 0.5 + 0.12*(n_drips - 1), n_drips)
    for x0 in cols:
        wob = up(rng.random((8, 2)).astype(np.float32), (C, C))[:, 0] if False else None
        path = x0 + 0.035*(fbm(C, 1, 3, 4)[:, 0] - 0.5)
        L = length*(0.75 + 0.25*rng.random())
        w = width*(1 - 0.65*yy/L)*(0.75 + 0.5*fbm(base=3, octaves=3))
        streak = np.exp(-((xx - path[:, None])/np.maximum(w, 1e-3))**2) * np.clip(1 - yy/L, 0, 1)**1.3
        riv = fbm(base=6, octaves=5, stretch=(0.25, 3.0))
        streak *= 0.45 + 0.75*riv
        src = sstep(src_r, src_r*0.4, np.hypot(xx - x0, (yy - 0.06)*1.3) + 0.04*(fbm(base=8) - 0.5))
        a = np.maximum(a, np.maximum(streak, src))
    a *= 0.35 + 0.75*fbm(base=10, octaves=5)
    a = np.clip(a*2.2, 0, 1)
    tone = fbm(base=8, octaves=6)
    rgb = colorize(tone, (0.30, 0.10, 0.025), (0.12, 0.045, 0.015))
    return rgb, a

def rust_ring():
    r = np.hypot(xx - 0.5, yy - 0.5)
    n = fbm(base=8)
    a = sstep(0.42, 0.18, r + 0.12*(n - 0.5)) * (0.5 + 0.6*fbm(base=12)) * sstep(0.02, 0.10, r)
    rgb = colorize(fbm(base=10), (0.45, 0.18, 0.05), (0.18, 0.07, 0.02))
    return rgb, np.clip(a, 0, 1)

def oil(drip):
    n = fbm(base=5)
    r = np.hypot(xx - 0.5, (yy - (0.25 if drip else 0.5))*1.2)
    blob = sstep(0.30, 0.18, r + 0.15*(n - 0.5))
    a = blob
    if drip:
        path = 0.5 + 0.02*(fbm(C, 1, 3, 4)[:, 0] - 0.5)
        w = 0.035*(0.6 + 0.6*fbm(base=3, octaves=3))
        d = np.exp(-((xx - path[:, None])/w)**2) * sstep(0.25, 0.35, yy) * np.clip(1 - (yy - 0.3)/0.65, 0, 1)
        a = np.maximum(a, d)
    a = a*(0.55 + 0.45*fbm(base=14, octaves=4))
    rgb = colorize(fbm(base=6), (0.03, 0.025, 0.02), (0.09, 0.06, 0.03))
    return rgb, np.clip(a, 0, 1)

def soot(directional):
    n = fbm(base=4)
    if directional:          # strongest at the top edge, fading downward
        a = np.clip(1 - yy*1.15, 0, 1)**1.6 * sstep(0.5, 0.15, np.abs(xx - 0.5) + 0.12*(n - 0.5))
    else:
        r = np.hypot(xx - 0.5, yy - 0.5)
        a = sstep(0.48, 0.12, r + 0.18*(n - 0.5))
    a *= 0.5 + 0.6*fbm(base=16, octaves=4)
    rgb = colorize(fbm(base=8), (0.015, 0.012, 0.010), (0.06, 0.04, 0.025))
    return rgb, np.clip(a, 0, 1)

def chips(mode):
    n = fbm(base=10, octaves=6, gain=0.6)
    if mode == "edge":
        th = 0.36 + 0.62*yy**0.9
    elif mode == "corner":
        th = 0.40 + 0.85*np.clip(np.hypot(xx, yy)/1.1, 0, 1)
    else:
        th = 0.60 + 0.25*np.hypot(xx - 0.5, yy - 0.5)
    m = (n > th).astype(np.float32)
    m = blur(m, 1.2); m = (m > 0.5).astype(np.float32)
    rim = (blur(m, 4) > 0.12).astype(np.float32)          # exposed primer/dirt rim around each chip
    # fade the decal out at its borders so it never shows a square edge
    border = sstep(0.0, 0.06, xx)*sstep(1.0, 0.94, xx)*sstep(1.0, 0.94, yy)*(sstep(0.0, 0.04, yy) if mode != "edge" else 1)
    metal = colorize(fbm(base=20, octaves=4), (0.09, 0.088, 0.085), (0.17, 0.165, 0.16))
    primer = np.array((0.11, 0.045, 0.015))[None, None]
    rgb = metal*m[..., None] + primer*(rim - m)[..., None].clip(0, 1)
    a = np.clip(rim, 0, 1)*border
    # metal mask in the blue... keep metal-ness: return as separate mask via alpha weighting
    return rgb, a, m*border

def grime(mode):
    if mode == "smudge":
        r = np.hypot(xx - 0.5, yy - 0.5)
        a = sstep(0.5, 0.15, r + 0.2*(fbm(base=3) - 0.5))*(0.35 + 0.65*fbm(base=7))
    else:  # vertical wash streaks, heaviest at the bottom
        a = fbm(base=6, octaves=5, stretch=(0.2, 3.0))*sstep(0.1, 0.9, yy)*sstep(0.0, 0.12, xx)*sstep(1.0, 0.88, xx)
        a = np.clip(a*1.4 - 0.2, 0, 1)
    rgb = colorize(fbm(base=9), (0.05, 0.035, 0.02), (0.12, 0.08, 0.045))
    return rgb, np.clip(a*0.85, 0, 1)

def scratches(scuff):
    img = Image.new('L', (C, C), 0); d = ImageDraw.Draw(img)
    for _ in range(60 if not scuff else 160):
        x0, y0 = rng.random()*C, rng.random()*C
        ang = rng.normal(0.15, 0.25) if not scuff else rng.random()*np.pi
        L = (rng.random()*0.5 + 0.1)*C*(0.35 if scuff else 1)
        x1, y1 = x0 + np.cos(ang)*L, y0 + np.sin(ang)*L
        d.line((x0, y0, x1, y1), fill=int(120 + rng.random()*135), width=1 if rng.random() < 0.8 else 2)
    a = np.asarray(img.filter(ImageFilter.GaussianBlur(0.6))).astype(np.float32)/255
    r = np.hypot(xx - 0.5, yy - 0.5)
    a *= sstep(0.5, 0.3, r)*(0.4 + 0.6*fbm(base=5))
    rgb = colorize(fbm(base=12), (0.55, 0.53, 0.5), (0.75, 0.73, 0.70))
    return rgb, np.clip(a*1.3, 0, 1)

cells = [rust_drip(1), rust_drip(1, 0.6, 0.11), rust_drip(2), rust_ring(),
         oil(True), oil(False), soot(False), soot(True),
         chips("edge"), chips("edge"), chips("scatter"), chips("corner"),
         grime("smudge"), grime("wash"), scratches(False), scratches(True)]
atlas = np.zeros((4*C, 4*C, 4), np.float32)
metal = np.zeros((4*C, 4*C), np.float32)
for i, cell in enumerate(cells):
    r, c = divmod(i, 4)
    rgb, a = cell[0], cell[1]
    atlas[r*C:(r+1)*C, c*C:(c+1)*C, :3] = rgb
    atlas[r*C:(r+1)*C, c*C:(c+1)*C, 3] = a
    if len(cell) > 2:
        metal[r*C:(r+1)*C, c*C:(c+1)*C] = cell[2]
# store colours as sRGB 8-bit
srgb = np.where(atlas[..., :3] <= 0.0031308, atlas[..., :3]*12.92, 1.055*np.power(atlas[..., :3], 1/2.4) - 0.055)
out = np.concatenate([srgb, atlas[..., 3:4]], axis=2)
Image.fromarray((np.clip(out, 0, 1)*255).astype(np.uint8), 'RGBA').save(OUT)
Image.fromarray((np.clip(metal, 0, 1)*255).astype(np.uint8), 'L').save(OUT.replace("decal_atlas", "decal_metal"))
prev = Image.new('RGB', (4*C, 4*C), (150, 120, 40)); prev.paste(Image.open(OUT), (0, 0), Image.open(OUT))
prev.thumbnail((1024, 1024))
os.makedirs(os.path.join(ROOT, "build", "deadbolt-concept"), exist_ok=True)
prev.save(os.path.join(ROOT, "build", "deadbolt-concept", "decal_preview.png"))
print("ok", OUT)
