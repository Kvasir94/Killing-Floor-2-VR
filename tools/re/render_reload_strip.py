"""Frame strip of a stock 1P reload clip (gun + stock arms), software-drawn
from the UModel PSK/PSA exports. No game, GPU or Blender.

    python tools/re/render_reload_strip.py OUT.png Class Clip "t:caption" "t:caption" ...
        [--hi Bone=amber,Bone=blue,Prefix*=green] [--view 1p|side|top] [--w 300] [--h 240] [--title T]

Times are raw clip seconds (as the AnimSet notifies give them; see
stock_reload_timeline.py). Views: 1p is the gun in profile, top looks down on
it (bows and crossbows read best), side looks along the bore. The frame is
fitted to the gun over all frames; arms are clipped. Needs the stock arms PSK
at build/melee-zone-review/arms (see melee_flip_candidates.py).
"""
import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools' / 're'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import melee_rig as mr  # noqa: E402
import stock_reload_timeline as st  # noqa: E402

ARMS_PSK = ROOT / 'build/melee-zone-review/arms/Wep_1stP_Naked_Hands_Rig.psk'
SKIN, WEAPON, BG = (196, 150, 122), (150, 154, 162), (22, 23, 26)
COLOURS = {'amber': (255, 170, 50), 'blue': (90, 190, 255), 'red': (235, 90, 80), 'green': (120, 220, 130)}


def rig_at(path):
    real = mr.mesh_path
    mr.mesh_path = lambda slug: path
    try:
        return mr.Rig('x')
    finally:
        mr.mesh_path = real


def tris_of(rig, pose, rigid, colour_of):
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
        col = colour_of(rig.bones[b]['name'])
        if col is None:
            continue
        out.append(([pt(i) for i in tri], col))
    return out


VIEWS = {
    # (screen x, screen y, depth: larger = farther) from game space (X fwd, Y right, Z up)
    '1p': lambda v: (v[1], -v[2], v[0]),
    'side': lambda v: (v[0], -v[2], v[1]),      # from the gun's left, muzzle to the right
    'top': lambda v: (v[1], -v[0], -v[2]),
}


def draw(tris, box, view, W, H):
    x0, y0, x1, y1 = box
    s = min((W - 12) / (x1 - x0), (H - 12) / (y1 - y0))
    ox = (W - (x1 - x0) * s) / 2
    oy = (H - (y1 - y0) * s) / 2
    im = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(im)
    proj = [([view(p) for p in t], col, t) for t, col in tris]
    for pv, col, t in sorted(proj, key=lambda e: -sum(p[2] for p in e[0])):
        a, b, c = t
        n = mr.cross(mr.sub(b, a), mr.sub(c, a))
        ln = mr.norm(n) or 1
        k = 0.42 + 0.58 * abs(n[0] * 0.55 + n[1] * 0.35 + n[2] * 0.76) / ln
        d.polygon([(ox + (p[0] - x0) * s, oy + (p[1] - y0) * s) for p in pv],
                  fill=tuple(min(255, int(ch * k)) for ch in col))
    return im


def strip(out, cls, clip, marks, hi, view_name='1p', W=300, H=240, title=None, pad=6.0, arms_on=True):
    pkg, set_name, psk, psa = st.inputs(cls)
    rig = rig_at(psk)
    arms = rig_at(ARMS_PSK)
    anim = mr.Anim(psa)
    clips = st.rsm.read_clips(pkg, set_name)
    length = clips[clip]['length']
    nframes = anim.frames(clip)
    view = VIEWS[view_name]

    def wcol(name):
        if any(w in name for w in mr.HAND_WORDS) or name.endswith('_1stP'):
            return None
        for bone, col in hi.items():
            if name == bone or (bone.endswith('*') and name.startswith(bone[:-1])):
                return COLOURS[col]
        return WEAPON

    frames = []
    for t, cap in marks:
        f = max(0, min(nframes - 1, round(t / length * (nframes - 1))))
        tr = tris_of(rig, anim.pose(rig, clip, f), True, wcol)
        if arms_on:
            tr += tris_of(arms, anim.pose(arms, clip, f), False, lambda n: SKIN)
        frames.append(tr)
    # Frame on the gun (all frames), arms clipped.
    pts = [view(v) for fr in frames for t, col in fr if col == WEAPON for v in t]
    box = (min(p[0] for p in pts) - pad, min(p[1] for p in pts) - pad,
           max(p[0] for p in pts) + pad, max(p[1] for p in pts) + pad)
    try:
        font = ImageFont.truetype('arial.ttf', 13)
        bold = ImageFont.truetype('arialbd.ttf', 14)
    except OSError:
        font = bold = ImageFont.load_default()
    head = 24 if title else 0
    sheet = Image.new('RGB', (W * len(frames), H + 34 + head), BG)
    d = ImageDraw.Draw(sheet)
    if title:
        d.text((8, 5), title, fill=(240, 240, 240), font=bold)
    for i, (tr, (t, cap)) in enumerate(zip(frames, marks)):
        sheet.paste(draw(tr, box, view, W, H), (i * W, head))
        d.text((i * W + 6, head + H + 2), f'{t:.2f}s', fill=(150, 155, 165), font=font)
        d.text((i * W + 6, head + H + 16), cap, fill=(235, 235, 235), font=font)
        if i:
            d.line([(i * W, head), (i * W, head + H + 34)], fill=(50, 52, 58))
    sheet.save(out)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out'); ap.add_argument('cls'); ap.add_argument('clip')
    ap.add_argument('marks', nargs='+')
    ap.add_argument('--hi', default='')
    ap.add_argument('--view', default='1p')
    ap.add_argument('--w', type=int, default=300)
    ap.add_argument('--h', type=int, default=240)
    ap.add_argument('--title', default=None)
    ap.add_argument('--noarms', action='store_true')
    a = ap.parse_args()
    marks = [(float(m.split(':', 1)[0]), m.split(':', 1)[1] if ':' in m else '') for m in a.marks]
    hi = dict(x.split('=') for x in a.hi.split(',') if x)
    print(strip(a.out, a.cls, a.clip, marks, hi, a.view, a.w, a.h, a.title, arms_on=not a.noarms))


if __name__ == '__main__':
    main()
