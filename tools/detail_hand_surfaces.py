"""Restrained surface detail for the hands: worn leather and livelier finger skin.

Kvasir94 picked "worn leather" and "repaint the finger skin", and asked for it to
stay tasteful. Everything here is driven by the hands' own normal map, so the
paint follows the sculpted form instead of inventing new shapes:

- Leather: creases and seam recesses darken a little; raised edges and pads
  are rubbed slightly lighter and smoother; a slow blotch varies the sheen so
  the grain is not one even finish.
- Skin: brought about a quarter of the way up to the stock bare arms' tone
  (it was half as bright), knuckle and palm creases deepen, raised knuckles
  redden a touch, and creases lose their shine.
- A small debossed HORZINE wordmark on the underside of the left bracer,
  between the straps, taken from the wordmark on the watch's badge.

It edits `_D`, `_S` (specular with gloss in alpha) and `_N` of a hand revision
made by `rebalance_hand_materials.py`; no mesh, UV or weight changes.

    python tools/detail_hand_surfaces.py <revision> --base <revision>
    python tools/rebalance_hand_materials.py --stage <revision>   # same staging
"""
import argparse, collections, hashlib, json, runpy, shutil, struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'build/watch-detail-20260924'
SIZE = 4096
MAPS = ('VRHorzineHands_D.tga', 'VRHorzineHands_S.tga', 'VRHorzineHands_N.tga')
# Amounts, all small on purpose.
SKIN_GAIN = (1.27, 1.23, 1.19)
SKIN_CREASE, SKIN_GRIME, SKIN_FLUSH = 0.20, 0.07, 5.0
LEATHER_CREASE, LEATHER_RUB, LEATHER_BLOTCH = 0.15, 6.0, 0.10
RUB_SPEC, RUB_GLOSS = 0.28, 14.0
FINE_SPAN, BROAD_SPAN = 0.055, 0.013          # normal-map divergence that counts as a full crease or edge
# The wordmark on the watch badge in VRHorzineWatch_D (x, y, w, h), stored turned half round.
WORDMARK = (1440, 3676, 505, 84)
# Where it goes on the left bracer, hand frame in cm (fingers +X, thumb -Y, back of hand +Z).
MARK_CENTRE, MARK_WIDTH = (-3.9, 2.6, -1.9), 4.0
MARK_DEPTH, MARK_DARKEN, MARK_FLATTEN = 3.0, 0.45, 0.85


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def box(np, a, r):
    for ax in (0, 1):
        pad = [(r + 1, r) if i == ax else (0, 0) for i in range(2)]
        c = np.cumsum(np.pad(a, pad, mode='edge'), axis=ax, dtype=np.float64)
        n = a.shape[ax]
        a = ((np.take(c, np.arange(2 * r + 1, 2 * r + 1 + n), axis=ax) - np.take(c, np.arange(0, n), axis=ax)) / (2 * r + 1)).astype(np.float32)
    return a


def smooth(np, a, r):
    return box(np, box(np, box(np, a, r), r), r)


def left_hand_frame(np, chunks):
    """Origin and rows (fingers, away from thumb, back of hand) of the left hand, from the bind pose."""
    bones = [struct.unpack('<64s3i11f', row) for row in chunks['REFSKELT'].rows]
    names = [b[0].rstrip(b'\0').decode('ascii') for b in bones]

    def rotate(q, v):
        w, x, y, z = q
        u = np.array([x, y, z])
        return v + 2 * np.cross(u, np.cross(u, v) + w * v)

    def multiply(a, b):
        aw, ax, ay, az = a
        bw, bx, by, bz = b
        return np.array([aw * bw - ax * bx - ay * by - az * bz, aw * bx + ax * bw + ay * bz - az * by,
                         aw * by - ax * bz + ay * bw + az * bx, aw * bz + ax * by - ay * bx + az * bw])
    positions, rotations = [], []
    for i, bone in enumerate(bones):
        x, y, z, w = bone[4:8]
        q = np.array([w, x, y, z], float)
        p = np.array(bone[8:11], float)
        if i:
            parent = bone[3]
            p = positions[parent] + rotate(rotations[parent], p)
            q = multiply(rotations[parent], q * np.array([1, -1, -1, -1]))
        positions.append(p)
        rotations.append(q)
    at = {n: positions[i] for i, n in enumerate(names)}
    origin = at['LeftHand_1stP']
    f = at['LeftHandMiddle1_1stP'] - origin
    f /= np.linalg.norm(f)
    t = at['LeftHandIndex1_1stP'] - at['LeftHandPinky1_1stP']
    t -= f * (t @ f)
    t /= np.linalg.norm(t)
    d = -np.cross(f, t)
    return origin, np.array([f, -t, d / np.linalg.norm(d)])


def wordmark_pressed(np, Image, ImageFilter, runtime, chunks, P, wedge_point, uv, F, leather, centre=MARK_CENTRE, width=MARK_WIDTH):
    """Where the HORZINE mark lands in the atlas (0 to 1 per texel) when pressed at `centre`, and on how many faces."""
    # The wordmark: pressed into the leather under the left forearm.
    wx, wy, ww, wh = WORDMARK
    badge = np.asarray(Image.open(runtime / 'VRHorzineWatch_D.tga').convert('RGB').crop((wx, wy, wx + ww, wy + wh)).rotate(180)).astype(np.float32)
    letters = ((badge.max(-1) > 105)).astype(np.float32)
    letters = np.asarray(Image.fromarray((letters * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))).astype(np.float32) / 255
    origin, frame = left_hand_frame(np, chunks)
    local = (P - origin) @ frame.T
    face_points = local[wedge_point[F]]
    centre = np.array(centre)
    near = np.linalg.norm(face_points.mean(1) - centre, axis=1) < width
    normals = np.cross(face_points[:, 1] - face_points[:, 0], face_points[:, 2] - face_points[:, 0])
    lengths = np.linalg.norm(normals, axis=1, keepdims=True)
    normals = normals / np.maximum(lengths, 1e-9)
    patch = near & (np.abs(normals @ (centre * [0, 1, 1] / np.linalg.norm(centre[1:]))) > 0.6)
    patch &= leather[uv[F].mean(1).astype(int).clip(0, SIZE - 1)[:, 1], uv[F].mean(1).astype(int).clip(0, SIZE - 1)[:, 0]]
    if patch.sum() < 6:
        raise RuntimeError('No bracer leather found where the wordmark goes')
    n0 = normals[patch].mean(0)
    n0 /= np.linalg.norm(n0)
    if n0 @ (centre * [0, 1, 1]) < 0:
        n0 = -n0                                  # ActorX winding: face outward from the arm's axis
    along = np.array([1.0, 0, 0]) - n0 * n0[0]
    along /= np.linalg.norm(along)
    across = np.cross(n0, along)                  # runs up toward the back of the hand
    if across[2] < 0:
        across = -across
    height = width * wh / ww
    # One layer only: the bracer's UVs have a second, hidden sheet here. Keep
    # the UV-connected group of faces that takes most of the mark.
    group = {int(fi): int(fi) for fi in np.nonzero(patch)[0]}

    def find(a):
        while group[a] != a:
            group[a] = group[group[a]]
            a = group[a]
        return a
    edge_owner = {}
    for fi in group:
        f = F[fi]
        for a, b in ((0, 1), (1, 2), (2, 0)):
            key = tuple(sorted((round(float(uv[w][0]), 2), round(float(uv[w][1]), 2)) for w in (f[a], f[b])))
            if key in edge_owner:
                group[find(fi)] = find(edge_owner[key])
            else:
                edge_owner[key] = fi
    sheets = collections.defaultdict(lambda: np.zeros((SIZE, SIZE), np.float32))
    for fi in np.nonzero(patch)[0]:
        pressed = sheets[find(int(fi))]
        tri = uv[F[fi]]
        x0, y0 = np.floor(tri.min(0)).astype(int)
        x1, y1 = np.ceil(tri.max(0)).astype(int) + 1
        ys, xs = np.mgrid[y0:y1, x0:x1]
        (ax, ay), (bx, by), (cx, cy) = tri
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-6:
            continue
        wa = ((by - cy) * (xs + .5 - cx) + (cx - bx) * (ys + .5 - cy)) / den
        wb = ((cy - ay) * (xs + .5 - cx) + (ax - cx) * (ys + .5 - cy)) / den
        wc = 1 - wa - wb
        ok = (wa >= -0.02) & (wb >= -0.02) & (wc >= -0.02)
        pos = wa[..., None] * face_points[fi][0] + wb[..., None] * face_points[fi][1] + wc[..., None] * face_points[fi][2]
        rel = pos - centre
        u = (rel @ along) / width + 0.5
        v = 0.5 - (rel @ across) / height
        hit = ok & (u >= 0) & (u < 1) & (v >= 0) & (v < 1)
        if hit.any():
            value = letters[(v[hit] * wh).astype(int).clip(0, wh - 1), (u[hit] * ww).astype(int).clip(0, ww - 1)]
            pressed[ys[hit], xs[hit]] = np.maximum(pressed[ys[hit], xs[hit]], value)
    pressed = max(sheets.values(), key=lambda sheet: float(sheet.sum()))
    pressed = smooth(np, pressed, 1)
    if pressed.max() < 0.3:
        raise RuntimeError('The wordmark did not land on the bracer')
    return pressed, int(patch.sum())


def press(np, D, spec, gloss, N, pressed):
    """Apply a pressed mark to the colour, specular, gloss and normal arrays."""
    # A heat-pressed mark: the letters are darker, flattened and a little
    # burnished, and the normal tilts along their edges.
    D *= (1 - MARK_DARKEN * pressed)[..., None]
    spec *= 1 + 0.35 * pressed
    gloss += 45 * pressed
    gx, gy = np.gradient(pressed, axis=1), np.gradient(pressed, axis=0)
    flat = np.array([128, 128, 255], np.float32)
    N = N * (1 - MARK_FLATTEN * pressed[..., None]) + flat * (MARK_FLATTEN * pressed[..., None])
    N[..., 0] = (N[..., 0] + 127 * MARK_DEPTH * gx).clip(0, 255)
    N[..., 1] = (N[..., 1] + 127 * MARK_DEPTH * gy).clip(0, 255)

    return D, spec, gloss, N


def main(revision, base):
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
    source, runtime = ART / base / 'runtime', ART / revision / 'runtime'
    report_path = runtime / 'hand-surface-detail.json'
    if report_path.exists():
        raise RuntimeError('This candidate already has its surface detail; preserve it and start a new revision.')
    runtime.mkdir(parents=True, exist_ok=True)
    for p in source.iterdir():
        if p.is_file() and (p.suffix.lower() in {'.fbx', '.psk', '.tga', '.png'} or p.name == 'hand-material-rebalance.json'):
            shutil.copy2(p, runtime / p.name)
    report = {'base_revision': base, 'base_sha256': {n: digest(source / n) for n in MAPS}}

    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    chunks = g['read_psk'](runtime / 'VRFloatingHands.psk')
    points, wedges, faces, _ = g['decode_geometry'](chunks)
    P = np.array(points)
    wedge_point = np.array([w[0] for w in wedges])
    uv = np.array([(w[1], w[2]) for w in wedges]) * SIZE
    F = np.array([f[:3] for f in faces])

    D = np.asarray(Image.open(runtime / MAPS[0]).convert('RGB')).astype(np.float32)
    SA = np.asarray(Image.open(runtime / MAPS[1]).convert('RGBA')).astype(np.float32)
    N = np.asarray(Image.open(runtime / MAPS[2]).convert('RGB')).astype(np.float32)
    T = np.asarray(Image.open(runtime / 'VRHorzineHands_T.tga').convert('L').resize((SIZE, SIZE), Image.BILINEAR)) > 128

    owned_image = Image.new('L', (SIZE, SIZE), 0)
    draw = ImageDraw.Draw(owned_image)
    for f in F:
        draw.polygon([tuple(uv[w]) for w in f], fill=255)
    # Stay clear of island borders: the normal map's gutters are not surface.
    inside = np.asarray(owned_image.filter(ImageFilter.MinFilter(9)).filter(ImageFilter.GaussianBlur(3))).astype(np.float32) / 255
    owned = np.asarray(owned_image) > 0

    nx, ny = (N[..., 0] - 128) / 127, (N[..., 1] - 128) / 127
    fine = np.gradient(smooth(np, nx, 2), axis=1) + np.gradient(smooth(np, ny, 2), axis=0)
    broad = np.gradient(smooth(np, nx, 8), axis=1) + np.gradient(smooth(np, ny, 8), axis=0)
    crease = (-fine / FINE_SPAN).clip(0, 1) * inside
    hollow = (-broad / BROAD_SPAN).clip(0, 1) * inside
    raised = (broad / BROAD_SPAN).clip(0, 1) * inside
    rng = np.random.default_rng(76)
    blotch = np.asarray(Image.fromarray(rng.integers(0, 256, (44, 44), dtype=np.uint8)).resize((SIZE, SIZE), Image.BICUBIC)).astype(np.float32) / 127.5 - 1

    skin = T
    thread = ~skin & (D[..., 0] > 90) & (D[..., 0] - D[..., 2] > 20)
    lining = ~skin & ~thread & (D.mean(-1) < 18)            # the sleeve's dark inside stays as it is
    leather = ~skin & ~thread & ~lining
    spec, gloss = SA[..., 0].copy(), SA[..., 3].copy()

    before = {'skin': [round(float(v), 1) for v in np.median(D[skin & owned], 0)],
              'leather': [round(float(v), 1) for v in np.median(D[leather & owned], 0)]}
    # Skin.
    tone = D * np.array(SKIN_GAIN, np.float32)
    tone *= (1 - SKIN_CREASE * crease - SKIN_GRIME * hollow)[..., None]
    tone[..., 0] += SKIN_FLUSH * raised
    tone[..., 1] -= 0.25 * SKIN_FLUSH * raised
    D = np.where(skin[..., None], tone, D)
    spec = np.where(skin, spec * (1 - 0.3 * crease), spec)
    gloss = np.where(skin, gloss * (1 - 0.35 * crease), gloss)
    # Leather.
    worn = D * (1 - LEATHER_CREASE * crease)[..., None] * (1 + 0.03 * blotch)[..., None]
    worn += (LEATHER_RUB * raised)[..., None] * np.array([1.0, 0.96, 0.88], np.float32)
    D = np.where(leather[..., None], worn, D)
    spec = np.where(leather, spec * (1 + RUB_SPEC * raised - 0.25 * crease) * (1 + LEATHER_BLOTCH * blotch), spec)
    gloss = np.where(leather, gloss + RUB_GLOSS * raised, gloss)

    # The wordmark: pressed into the leather under the left forearm.
    pressed, mark_faces = wordmark_pressed(np, Image, ImageFilter, runtime, chunks, P, wedge_point, uv, F, leather)
    D, spec, gloss, N = press(np, D, spec, gloss, N, pressed)

    out = np.dstack([spec, spec, spec, gloss]).clip(0, 255).astype(np.uint8)
    Image.fromarray(D.clip(0, 255).astype(np.uint8)).save(runtime / MAPS[0])
    Image.fromarray(out, 'RGBA').save(runtime / MAPS[1])
    Image.fromarray(N.clip(0, 255).astype(np.uint8)).save(runtime / MAPS[2])
    ys, xs = np.nonzero(pressed > 0.3)
    report.update({'colour_before': before,
                   'colour_after': {'skin': [round(float(v), 1) for v in np.median(D[skin & owned], 0)],
                                    'leather': [round(float(v), 1) for v in np.median(D[leather & owned], 0)]},
                   'wordmark': {'texels': int((pressed > 0.3).sum()), 'faces': mark_faces,
                                'atlas_box': [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]},
                   'maps_sha256': {n: digest(runtime / n) for n in MAPS}})
    report_path.write_text(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision')
    parser.add_argument('--base', required=True)
    args = parser.parse_args()
    print('HAND_SURFACES_DETAILED', json.dumps(main(args.revision, args.base)), flush=True)
