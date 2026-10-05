"""Paint the forearm bracer, cuff roll, lining and end plate texels (plain Python).

    python tools/paint_forearm_bracer.py <revision>

Runs after `tools/build_forearm_bracer.py`, using its `forearm-bracer.json`.
The left forearm skin texels (both hands share these UVs) become dark leather
matching the glove: solid-noise grain evaluated at each texel's 3D position,
so it stays continuous across UV seams; a stitched seam along the underside;
a folded, stitched hem at the open end. Normals are written in the maps'
DirectX tangent convention from each triangle's UV derivatives. The roll,
lining and end-plate blocks are uniform around the ring: a worn leather edge,
lining darkening with depth, and a near-black plate. Gutters next to painted
texels are re-dilated and the skin transmission mask is cleared there.
"""
import hashlib, json, runpy, sys
from pathlib import Path
import cv2
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SIZE = 4096
LEATHER = np.array([31, 33, 30], np.float32)        # glove leather median (sRGB)
WORN = np.array([74, 69, 60], np.float32)           # glove edge-wear p90
THREAD = np.array([118, 104, 82], np.float32)
# Revision 72: x0.45 (were 39/24/22/45) to match the matte glove leather.
LEATHER_SPEC, SEAM_SPEC, THREAD_SPEC, WORN_SPEC = 17.5, 11.0, 10.0, 20.0
NORMAL_XY_STD = 0.17                                # glove grain is ~0.19
STITCH_PERIOD, STITCH_HALF_WIDTH = 0.32, 0.045      # cm
SEAM_ROW_CM, HEM_ROW_CM = 0.30, 0.40


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def hash01(ix, iy, iz, seed):
    h = (ix.astype(np.int64) * 73856093) ^ (iy.astype(np.int64) * 19349663) ^ (iz.astype(np.int64) * 83492791) ^ (seed * 2654435761)
    h &= 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0x5BD1E995) & 0xFFFFFFFF
    h ^= h >> 15
    return h.astype(np.float64) / 4294967296.0


def value_noise(p, freq, seed):
    q = p * freq
    i = np.floor(q).astype(np.int64)
    f = q - i
    f = f * f * (3 - 2 * f)
    out = 0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (f[:, 0] if dx else 1 - f[:, 0]) * (f[:, 1] if dy else 1 - f[:, 1]) * (f[:, 2] if dz else 1 - f[:, 2])
                out = out + w * hash01(i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz, seed)
    return out * 2 - 1


def fbm(p, freq, octaves, seed):
    total, amp, norm = 0, 1.0, 0
    for o in range(octaves):
        total = total + amp * value_noise(p, freq * 2 ** o, seed + o)
        norm += amp
        amp *= 0.5
    return total / norm


class Side:
    def __init__(self, s):
        self.o = np.array(s['frame_origin'])
        self.m = np.array(s['frame_rows'])
        self.c = np.array(s['axis_point'])
        self.a = np.array(s['axis_dir'])
        self.ref = np.array(s['ref'])
        self.side_ref = np.array(s['side_ref'])
        self.cut = s['cut_along_cm']
        self.limit = s['paint_limit_along_cm']
        self.hem = s['hem']

    def local(self, p):
        return (np.asarray(p) - self.o) @ self.m.T

    def cyl(self, q):
        d = q - self.c
        s = d @ self.a
        r = d - np.outer(s, self.a)
        return s, r, np.linalg.norm(r, axis=1), np.arctan2(r @ self.side_ref, r @ self.ref)


def stitch(across, phase):
    inside = np.clip(1 - (across / STITCH_HALF_WIDTH) ** 2, 0, 1)
    fr = phase - np.floor(phase)
    along = np.clip(np.minimum(fr - 0.10, 0.74 - fr) / 0.08, 0, 1)
    return np.sqrt(inside) * along


def leather(side, q):
    """Height, colour, specular for 3D points q (left frame, cm)."""
    s, r_vec, r, th = side.cyl(q)
    ds = s - side.cut
    grain = 0.6 * fbm(q, 9.0, 3, 11) + 0.4 * value_noise(q, 23.0, 5)
    mottle = fbm(q, 0.7, 3, 29)
    w = (np.pi - np.abs(th)) * r                    # arc distance from the underside seam
    seam = np.exp(-(w / 0.05) ** 2)
    panel = np.exp(-(w / 0.13) ** 2)
    rows = np.maximum(stitch(np.abs(np.abs(w) - SEAM_ROW_CM), s / STITCH_PERIOD),
                      stitch(np.abs(ds - HEM_ROW_CM), (th * r) / STITCH_PERIOD) * (side.hem > 0))
    fold = np.exp(-((ds - side.hem) / 0.05) ** 2) * (side.hem > 0)
    edge = np.clip(1 - ds / 0.2, 0, 1)
    height = grain * 0.35 - 1.0 * seam - 0.3 * panel - 0.7 * fold + 1.4 * rows
    wear = np.clip(0.55 * np.exp(-((np.abs(w) - 0.14) / 0.05) ** 2) + 0.6 * edge + 0.35 * fold
                   + 0.15 * np.clip(mottle, 0, 1), 0, 1)
    colour = LEATHER * (1 + 0.16 * mottle[:, None] + 0.10 * grain[:, None])
    colour = colour * (1 - 0.45 * seam[:, None])
    colour = colour + (WORN - colour) * wear[:, None] * 0.6
    colour = colour + (THREAD * (0.75 + 0.25 * rows[:, None]) - colour) * (rows[:, None] > 0.05)
    spec = LEATHER_SPEC * (0.85 + 0.15 * grain) + (WORN_SPEC - LEATHER_SPEC) * wear
    spec = spec + (SEAM_SPEC - spec) * seam
    spec = np.where(rows > 0.05, THREAD_SPEC, spec)
    return height, colour, spec


def rasterize(tris_uv):
    """Texels (y, x) covered by each UV triangle, with barycentrics."""
    ys, xs, ids, bs = [], [], [], []
    for k, uv in enumerate(tris_uv):
        pts = uv * SIZE - 0.5
        x0, y0 = np.floor(pts.min(0)).astype(int) - 1
        x1, y1 = np.ceil(pts.max(0)).astype(int) + 1
        gx, gy = np.meshgrid(np.arange(max(0, x0), min(SIZE, x1 + 1)), np.arange(max(0, y0), min(SIZE, y1 + 1)))
        (ax, ay), (bx, by), (cx, cy) = pts
        det = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
        if abs(det) < 1e-9:
            continue
        l1 = ((gx - ax) * (cy - ay) - (cx - ax) * (gy - ay)) / det
        l2 = ((bx - ax) * (gy - ay) - (gx - ax) * (by - ay)) / det
        l0 = 1 - l1 - l2
        tol = 0.7 / max(1.0, np.sqrt(abs(det)))
        m = (l0 > -tol) & (l1 > -tol) & (l2 > -tol)
        ys.append(gy[m]); xs.append(gx[m]); ids.append(np.full(m.sum(), k))
        bs.append(np.stack([l0[m], l1[m], l2[m]], 1))
    return np.concatenate(ys), np.concatenate(xs), np.concatenate(ids), np.concatenate(bs)


def main():
    revision = sys.argv[1]
    runtime = ROOT / 'build/watch-detail-20260924' / revision / 'runtime'
    report_path = runtime / 'bracer-paint.json'
    if report_path.exists():
        raise RuntimeError('This revision was already painted; start a new version.')
    layout = json.loads((runtime / 'forearm-bracer.json').read_text())
    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    chunks = g['read_psk'](runtime / 'VRFloatingHands.psk')
    points, wedges, faces, weights = g['decode_geometry'](chunks)
    _, names = g['bone_data'](chunks)
    left = Side(layout['sides']['Left'])
    blocks = layout['blocks_px']
    P = np.array(points)
    UV = np.array([(w[1], w[2]) for w in wedges])
    tri_w = np.array([f[:3] for f in faces])
    tri_p = np.array([[wedges[w][0] for w in f[:3]] for f in faces])
    left_pt = np.array([names[max(w, key=w.get)].startswith('Left') for w in weights])
    Q = left.local(P)
    s_all, _, _, _ = left.cyl(Q)
    # Faces carrying ordinary (non-block) UVs of the left forearm skin.
    uv_px = UV[tri_w] * SIZE
    in_block = np.zeros(len(faces), bool)
    for bx, by, bw, bh in blocks.values():
        in_block |= ((uv_px[..., 0] >= bx - 1) & (uv_px[..., 0] <= bx + bw + 1) &
                     (uv_px[..., 1] >= by - 1) & (uv_px[..., 1] <= by + bh + 1)).all(1)
    parent = list(range(len(points)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for t in tri_p:
        for i in t[1:]:
            ra, rb = find(t[0]), find(i)
            if ra != rb:
                parent[rb] = ra
    shell = np.array([find(t[0]) for t in tri_p])
    cands = {}
    for k in np.nonzero(left_pt[tri_p].all(1))[0]:
        cands.setdefault(shell[k], []).append(k)
    skin = min(cands, key=lambda sh: s_all[tri_p[cands[sh]]].min())
    sel = np.array([k for k in cands[skin] if not in_block[k] and s_all[tri_p[k]].min() < left.limit])
    maps = {k: np.asarray(Image.open(runtime / f'VRHorzineHands_{k}.tga').convert('RGB')).astype(np.float32).copy() for k in 'DNS'}
    before = {k: digest(runtime / f'VRHorzineHands_{k}.tga') for k in 'DNST'}
    ys, xs, ids, bary = rasterize(UV[tri_w[sel]])
    fk = sel[ids]
    q = np.einsum('nk,nkj->nj', bary, Q[tri_p[fk]])
    keep = left.cyl(q)[0] < left.limit
    ys, xs, fk, q = ys[keep], xs[keep], fk[keep], q[keep]
    # Per-face tangent frame from UV derivatives (v runs down the image).
    p0, p1, p2 = (Q[tri_p[sel]][:, i] for i in range(3))
    t0, t1, t2 = (UV[tri_w[sel]][:, i] for i in range(3))
    e1, e2 = p1 - p0, p2 - p0
    d1, d2 = t1 - t0, t2 - t0
    det = d1[:, 0] * d2[:, 1] - d2[:, 0] * d1[:, 1]
    det = np.where(np.abs(det) < 1e-12, 1e-12, det)
    T = (e1 * d2[:, 1:2] - e2 * d1[:, 1:2]) / det[:, None]
    B = (e2 * d1[:, 0:1] - e1 * d2[:, 0:1]) / det[:, None]
    N = np.cross(e1, e2)
    N /= np.linalg.norm(N, axis=1, keepdims=True)
    centre = (p0 + p1 + p2) / 3
    _, rv, _, _ = left.cyl(centre)
    N *= np.sign(np.sum(N * rv, axis=1, keepdims=True) + 1e-12)
    Tn = T - N * np.sum(N * T, 1, keepdims=True)
    Tn /= np.linalg.norm(Tn, axis=1, keepdims=True)
    Bn = np.cross(N, Tn) * np.sign(np.sum(np.cross(N, Tn) * B, 1, keepdims=True) + 1e-12)
    index = {k: i for i, k in enumerate(sel)}
    li = np.array([index[k] for k in fk])
    eps = 0.008
    h, colour, spec = leather(left, q)
    ht = (leather(left, q + eps * Tn[li])[0] - leather(left, q - eps * Tn[li])[0]) / (2 * eps)
    hb = (leather(left, q + eps * Bn[li])[0] - leather(left, q - eps * Bn[li])[0]) / (2 * eps)
    # Gain from the median slope, so the grain (not the few steep stitches) sets it.
    k = NORMAL_XY_STD / max(1e-6, float(np.median(np.hypot(ht, hb))) / np.sqrt(2))
    n = np.stack([-k * ht, -k * hb, np.ones_like(ht)], 1)
    n /= np.linalg.norm(n, axis=1, keepdims=True)
    painted = np.zeros((SIZE, SIZE), bool)
    painted[ys, xs] = True
    maps['D'][ys, xs] = np.clip(colour, 0, 255)
    maps['N'][ys, xs] = (n * 127.5 + 127.5)
    maps['S'][ys, xs] = np.clip(spec, 0, 255)[:, None]
    # Cuff blocks (uniform around the ring), with an 8 px clamped margin.
    base = LEATHER
    for name, (bx, by, bw, bh) in blocks.items():
        gy, gx = np.mgrid[by - 8:by + bh + 8, bx - 8:bx + bw + 8]
        v = np.clip((gy - by + 0.5) / bh, 0, 1)
        u = np.clip((gx - bx + 0.5) / bw, 0, 1)
        if name == 'roll':
            rim = np.sin(np.pi * v)
            col = base[None, None] + (WORN - base)[None, None] * (0.25 + 0.45 * rim)[..., None]
            sp = LEATHER_SPEC + (WORN_SPEC - LEATHER_SPEC) * rim
        elif name == 'lining':
            f = v * v * (3 - 2 * v)
            col = (base * 0.75)[None, None] * (1 - f)[..., None] + np.array([5, 5, 5], np.float32) * f[..., None]
            sp = 9 * (1 - f) + 2 * f
        else:
            rr = np.clip(np.hypot(u - 0.5, v - 0.5) * 2, 0, 1)
            col = np.array([7, 7, 8], np.float32)[None, None] * (1 + 0.6 * rr ** 4)[..., None]
            sp = 3 + 2 * rr ** 4
        maps['D'][gy, gx] = col
        maps['N'][gy, gx] = [128, 128, 255]
        maps['S'][gy, gx] = np.asarray(sp, np.float32)[..., None]
        painted[gy, gx] = True
    # Re-dilate gutters next to painted texels; the rest of the atlas is untouched.
    refine = runpy.run_path(str(ROOT / 'tools/refine_hand_textures.py'), run_name='asset_source')
    coverage = np.zeros((SIZE, SIZE), bool)
    for mask, _ in refine['uv_masks'](runtime, SIZE).values():
        coverage |= mask
    near = cv2.dilate(painted.astype(np.uint8), np.ones((3, 3), np.uint8), iterations=refine['PAD_PIXELS'] + 4).astype(bool)
    ring = cv2.dilate(coverage.astype(np.uint8), np.ones((3, 3), np.uint8), iterations=refine['PAD_PIXELS']).astype(bool)
    target = ring & ~coverage & near & ~painted
    for key in 'DNS':
        grown = refine['fill'](maps[key], coverage | painted, target)
        maps[key][target] = grown[target]
        Image.fromarray(np.clip(np.rint(maps[key]), 0, 255).astype(np.uint8)).save(runtime / f'VRHorzineHands_{key}.tga')
    t_path = runtime / 'VRHorzineHands_T.tga'
    trans = np.asarray(Image.open(t_path).convert('RGB')).copy()
    small = cv2.resize(painted.astype(np.uint8) * 255, trans.shape[:2][::-1], interpolation=cv2.INTER_AREA) > 0
    small = cv2.dilate(small.astype(np.uint8), np.ones((3, 3), np.uint8), iterations=2).astype(bool)
    trans[small] = 0
    Image.fromarray(trans).save(t_path)
    report = {'change': 'Leather bracer, cuff roll, lining and end plate texels',
              'painted_texels': int(painted.sum()), 'gutter_texels_refilled': int(target.sum()),
              'painted_faces': int(len(sel)), 'normal_gain': k, 'blocks_px': blocks,
              'inputs_sha256': before,
              'outputs_sha256': {key: digest(runtime / f'VRHorzineHands_{key}.tga') for key in 'DNST'},
              'generator_sha256': digest(Path(__file__))}
    report_path.write_text(json.dumps(report, indent=2))
    print('HAND_BRACER_PAINTED', json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
