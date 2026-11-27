"""Clean the hand maps: skin fragments, stray stitches and the cuff rims.

Texture-only repairs to a hand revision; no mesh, UV or weight changes.

- Skin fragments. The finger skin's UVs include about a hundred small islands
  (up to 30 triangles), each baked on its own, so on the fingertips they show
  as blotches and shards: a different tone per triangle with a dark outline.
  Every such island that the `_T` mask marks as skin is repainted in `_D` and
  `_S` from the colours its corners have in the large islands around it, with
  pore detail from a clean patch of the same map, and its gutter is refilled
  from the same gradient. Triangles of the large islands whose paint steps
  along two whole mesh edges, with no matching step in the normal map, are
  shards of the same kind and get the same repaint.
- Folded UVs. On each thumb pad the skin's UVs fold over themselves, so no
  paint can suit every triangle there. Those patches take the surrounding
  skin's tone, spread inward, plus pores. Small hard-edged dark flecks on
  exposed skin are refilled the same way.
- Stray stitches. A stitch-coloured scrap of a few triangles sits alone on each
  palm. Its texels take the surrounding leather's colour and a flat normal, so
  it stops reading as a stitch.
- Cuff rims. The rolled edge at both arm ends was painted lighter than the
  leather it folds from, so it read as a pale ring. It now runs from the
  leather's colour at the outside into the lining's dark at the inside.

    python tools/clean_hand_skin_and_rims.py <revision>
    python tools/clean_hand_skin_and_rims.py --stage <revision>

The first copies the staged hand set from build/hand-meshes into
build/watch-detail-20260924/<revision>/runtime and edits the maps there. After
`tools/build-hand-assets.ps1 -InputMesh <runtime>/VRFloatingHands.fbx
-OutputRoot <revision>/package` has imported that candidate, the second backs
up and replaces the staged maps and package.
"""
import collections, hashlib, json, runpy, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'build/watch-detail-20260924'
STAGED = ROOT / 'build/hand-meshes'
MAPS = ('VRHorzineHands_D.tga', 'VRHorzineHands_S.tga', 'VRHorzineHands_N.tga')
SIZE = 4096
FRAGMENT_TRIS = 30       # islands this small, under FRAGMENT_PX texels, carry no painted detail
FRAGMENT_PX = 13000
LARGE_TRIS = 50          # islands trusted as the source of corner colours
PAD = 6                  # gutter refilled around each repainted triangle (px)
SHARD_JUMP = 8.0         # colour step (0-255) that must hold along a whole shared edge
SCULPTED_STEP = 10.0     # normal-map step along an edge that marks real form
TINY_PX = 20.0           # triangles under this many texels cannot hold paint
FOLD_MIN_PX = 400        # folded-UV patches smaller than this are edge slivers
FOLD_SIGMA = 18.0        # how far surrounding skin tone reaches into a fold (px)
FLECK_RATIO = 0.75       # a fleck is darker than this fraction of the tone round it
FLECK_MIN_PX, FLECK_MAX_PX = 12, 900
# The rolled-edge block shared by both arms: x, y from the top, width, height
# (tools/build_forearm_bracer.py). Rows run from the outer leather to the lining.
ROLL = (2704, 2848, 64, 48)
LINING = (2784, 2848, 64, 192)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def stage(revision):
    runtime, package = ART / revision / 'runtime', ART / revision / 'package'
    report = json.loads((runtime / 'hand-map-clean.json').read_text())
    receipt = json.loads((package / 'build.json').read_text(encoding='utf-8-sig'))
    if not receipt['success'] or digest(package / 'KF2VRHands.upk') != receipt['package_sha256'].upper():
        raise SystemExit('The candidate package has no passing import record.')
    for name in MAPS:
        if digest(runtime / name) != report['maps_sha256'][name] or receipt['textures_sha256'][name].upper() != report['maps_sha256'][name]:
            raise SystemExit(f'{name} is not the map this candidate was imported with.')
    backup = ART / revision / 'before-staging'
    targets = [(runtime / n, STAGED / n) for n in MAPS] + \
              [(package / n, ROOT / 'build/hand-assets' / n) for n in ('KF2VRHands.upk', 'build.json')]
    for _, destination in targets:
        saved = backup / destination.relative_to(ROOT / 'build')
        if not saved.exists():
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(destination, saved)
    for source, destination in targets:
        temporary = destination.with_name(destination.name + '.new')
        shutil.copy2(source, temporary)
        temporary.replace(destination)
    print(json.dumps({'staged_revision': revision, 'backup': str(backup)}))


class Union:
    def __init__(self, n):
        self.parent = list(range(n))

    def find(self, a):
        parent = self.parent
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def join(self, a, b):
        self.parent[self.find(a)] = self.find(b)


def triangle_area(t):
    return abs((t[1][0] - t[0][0]) * (t[2][1] - t[0][1]) - (t[2][0] - t[0][0]) * (t[1][1] - t[0][1])) / 2


def window_mean(image, x, y, r=2):
    return image[max(0, y - r):y + r + 1, max(0, x - r):x + r + 1].reshape(-1, image.shape[-1]).mean(0)


def clean_patch(np, hp, allowed, size=128, step=64):
    """The quietest size x size window of high-pass detail that lies wholly inside `allowed`."""
    best, where = None, None
    for y in range(0, SIZE - size, step):
        for x in range(0, SIZE - size, step):
            if not allowed[y:y + size, x:x + size].all():
                continue
            score = float(np.percentile(np.abs(hp[y:y + size, x:x + size]), 99))
            if best is None or score < best:
                best, where = score, (x, y)
    if where is None:
        raise RuntimeError('No clean reference patch found')
    x, y = where
    patch = hp[y:y + size, x:x + size]
    # Mirror into a 2x tile so it repeats without a seam.
    top = np.concatenate([patch, patch[:, ::-1]], 1)
    return np.concatenate([top, top[::-1]], 0), where


def main(revision):
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
    runtime = ART / revision / 'runtime'
    report_path = runtime / 'hand-map-clean.json'
    if report_path.exists():
        raise RuntimeError('This candidate was already cleaned; preserve it and start a new revision.')
    runtime.mkdir(parents=True, exist_ok=True)
    for p in STAGED.iterdir():
        if p.is_file() and p.name.startswith(('VRFloatingHands.', 'VRWristwatch.', 'VRHorzine')) \
                and p.suffix.lower() in {'.fbx', '.psk', '.tga'}:
            shutil.copy2(p, runtime / p.name)
    report = {'base_sha256': {n: digest(STAGED / n) for n in MAPS + ('VRFloatingHands.psk',)}}

    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    points, wedges, faces, _ = g['decode_geometry'](g['read_psk'](runtime / 'VRFloatingHands.psk'))
    P = np.array(points)
    wedge_point = np.array([w[0] for w in wedges])
    uv = np.array([(w[1], w[2]) for w in wedges]) * SIZE     # pixels, y from the top
    F = np.array([f[:3] for f in faces])
    weld = {}
    point_id = np.array([weld.setdefault(tuple(np.round(p, 4)), len(weld)) for p in P])
    corner = point_id[wedge_point[F]]                         # welded point per face corner

    shells = Union(len(weld))
    for a, b, c in corner:
        shells.join(a, b)
        shells.join(b, c)
    shell = np.array([shells.find(c[0]) for c in corner])
    size_of = collections.Counter(shell.tolist())

    D = np.asarray(Image.open(runtime / MAPS[0]).convert('RGB')).astype(np.float32)
    S = np.asarray(Image.open(runtime / MAPS[1]).convert('RGB')).astype(np.float32)
    N = np.asarray(Image.open(runtime / MAPS[2]).convert('RGB')).copy()
    T = np.asarray(Image.open(runtime / 'VRHorzineHands_T.tga').convert('L').resize((SIZE, SIZE), Image.NEAREST)) > 128
    centre = uv[F].mean(1).astype(int).clip(0, SIZE - 1)
    face_skin = T[centre[:, 1], centre[:, 0]]

    # The two skin shells are the big ones the mask marks as skin.
    skin_shells = [s for s, n in size_of.most_common(6) if n > 3000 and face_skin[shell == s].mean() > 0.3]
    if len(skin_shells) != 2:
        raise RuntimeError(f'Expected two skin shells, found {len(skin_shells)}')
    in_skin = np.isin(shell, skin_shells)

    # UV islands of the skin shells: faces joined across edges whose corners share UVs.
    islands = Union(len(F))
    seen = {}
    for fi in np.nonzero(in_skin)[0]:
        f = F[fi]
        for a, b in ((0, 1), (1, 2), (2, 0)):
            key = tuple(sorted((int(point_id[wedge_point[w]]), round(float(uv[w][0]), 2), round(float(uv[w][1]), 2)) for w in (f[a], f[b])))
            if key in seen:
                islands.join(fi, seen[key])
            else:
                seen[key] = fi
    island = np.full(len(F), -1)
    for fi in np.nonzero(in_skin)[0]:
        island[fi] = islands.find(fi)
    island_size = collections.Counter(island[in_skin].tolist())
    island_px = collections.Counter()
    for fi in np.nonzero(in_skin)[0]:
        island_px[island[fi]] += triangle_area(uv[F[fi]])
    fragment = np.array([in_skin[fi] and face_skin[fi] and island_size[island[fi]] <= FRAGMENT_TRIS
                         and island_px[island[fi]] < FRAGMENT_PX for fi in range(len(F))])
    large = np.array([in_skin[fi] and island_size[island[fi]] >= LARGE_TRIS for fi in range(len(F))])

    # Which face owns each texel: 0 none, else face index + 1.
    owner_image = Image.new('I', (SIZE, SIZE), 0)
    draw = ImageDraw.Draw(owner_image)
    for fi, f in enumerate(F):
        draw.polygon([tuple(uv[w]) for w in f], fill=fi + 1)
    owner = np.asarray(owner_image)
    owned = owner > 0
    owner_face = np.where(owned, owner - 1, 0)

    def high_pass(image):
        blurred = np.asarray(Image.fromarray(image.clip(0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(8))).astype(np.float32)
        return image - blurred
    skin_area = owned & large[owner_face] & face_skin[owner_face] & T
    skin_detail, skin_patch = clean_patch(np, high_pass(D), skin_area)
    glove_shells = [s for s, n in size_of.most_common(6) if n > 3000 and s not in skin_shells]
    leather_area = owned & np.isin(shell, glove_shells)[owner_face] & ~T
    leather_detail, leather_patch = clean_patch(np, high_pass(D), leather_area, size=64, step=16)
    leather = np.median(D[leather_area], 0)
    leather_spec = np.median(S[leather_area], 0)

    # Shards inside the large islands: a triangle whose paint differs from its
    # neighbours along whole mesh edges. Painted detail (nails, creases) does
    # not follow the triangulation, so a jump that holds along an entire edge,
    # on two or more edges of one triangle, marks a triangle baked from the
    # wrong source. Worst first, so a clean triangle between two shards stays.
    def side_samples(image, fi, k):
        """Values of `image` just inside face `fi` along the edge opposite its corner k."""
        tri = uv[F[fi]]
        a, b, c = tri[(k + 1) % 3], tri[(k + 2) % 3], tri[k]
        edge = b - a
        length = max(1e-6, float(np.hypot(*edge)))
        normal = np.array([-edge[1], edge[0]]) / length
        height = float((c - a) @ normal)
        inward = normal * np.sign(height) * min(3.0, 0.3 * abs(height))
        out = []
        for t in (0.2, 0.35, 0.5, 0.65, 0.8):
            at = (a + edge * t + inward).astype(int).clip(0, SIZE - 1)
            out.append(window_mean(image, at[0], at[1], 1))
        return np.array(out)
    relief = N.astype(np.float32)
    edge_faces = collections.defaultdict(list)
    for fi in np.nonzero(in_skin & face_skin)[0]:
        for k in range(3):
            edge_faces[tuple(sorted((corner[fi][(k + 1) % 3], corner[fi][(k + 2) % 3])))].append((fi, k))
    jumps = collections.defaultdict(dict)       # face -> {other face: jump}
    for pair in edge_faces.values():
        if len(pair) != 2:
            continue
        (fa, ka), (fb, kb) = pair
        # The two faces walk their shared edge in opposite directions.
        jump = float(np.median(np.abs(side_samples(D, fa, ka) - side_samples(D, fb, kb)[::-1]).max(1)))
        # A step in the normal map along the same edge is sculpted form (a nail's
        # border, a crease): the colour belongs there.
        sculpted = float(np.median(np.abs(side_samples(relief, fa, ka) - side_samples(relief, fb, kb)[::-1]).max(1)))
        if jump > SHARD_JUMP and sculpted < SCULPTED_STEP:
            jumps[fa][fb] = jump
            jumps[fb][fa] = jump
    shard = np.zeros(len(F), bool)
    while True:
        worst = max((fi for fi in jumps if len(jumps[fi]) >= 2), key=lambda fi: sum(jumps[fi].values()), default=None)
        if worst is None:
            break
        shard[worst] = True
        for other in list(jumps[worst]):
            del jumps[other][worst]
        del jumps[worst]
    # Triangles too small to hold paint take their corners' colours too.
    tiny = np.array([in_skin[fi] and face_skin[fi] and triangle_area(uv[F[fi]]) < TINY_PX for fi in range(len(F))])
    repaint = fragment | shard | tiny

    # Corner colours from the large islands, spread over points that have none.
    samples = collections.defaultdict(list)
    for fi in np.nonzero(large & face_skin & ~shard)[0]:
        tri = uv[F[fi]]
        for k in range(3):
            at = (0.7 * tri[k] + 0.15 * (tri[(k + 1) % 3] + tri[(k + 2) % 3])).astype(int).clip(0, SIZE - 1)
            samples[corner[fi][k]].append(np.concatenate([window_mean(D, at[0], at[1]), window_mean(S, at[0], at[1])]))
    colour = {p: np.median(np.array(v), 0) for p, v in samples.items()}
    neighbours = collections.defaultdict(set)
    for fi in np.nonzero(in_skin)[0]:
        a, b, c = corner[fi]
        neighbours[a].update((b, c)); neighbours[b].update((a, c)); neighbours[c].update((a, b))
    wanted = {p for fi in np.nonzero(repaint)[0] for p in corner[fi]}
    for _ in range(12):
        missing = [p for p in wanted if p not in colour]
        if not missing:
            break
        filled = {}
        for p in missing:
            near = [colour[q] for q in neighbours[p] if q in colour]
            if near:
                filled[p] = np.mean(near, 0)
            else:
                wanted.update(neighbours[p])
        colour.update(filled)
    skipped = 0

    def paint(fi, values, images, detail, mine):
        """Fill face `fi` and its gutter with a gradient through its corner values."""
        tri = uv[F[fi]]
        x0, y0 = np.floor(tri.min(0)).astype(int) - PAD
        x1, y1 = np.ceil(tri.max(0)).astype(int) + PAD + 1
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, SIZE), min(y1, SIZE)
        ys, xs = np.mgrid[y0:y1, x0:x1]
        px, py = xs + 0.5, ys + 0.5
        (ax, ay), (bx, by), (cx, cy) = tri
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-6:
            return 0
        wa = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / den
        wb = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / den
        wc = 1 - wa - wb
        # Distance outside each edge, in pixels.
        heights = [abs(den) / max(1e-6, np.hypot(*(tri[(k + 1) % 3] - tri[(k + 2) % 3]))) for k in range(3)]
        inside = np.minimum.reduce([wa * heights[0], wb * heights[1], wc * heights[2]])
        local_owner = owner[y0:y1, x0:x1]
        take = (inside >= -PAD) & ((local_owner == 0) | mine[np.where(local_owner > 0, local_owner - 1, 0)])
        take &= (inside >= 0) | (local_owner == 0)     # never repaint a neighbour's interior
        w = np.stack([wa, wb, wc], -1).clip(-0.5, 1.5)
        w /= w.sum(-1, keepdims=True)
        channels = 0
        for image in images:
            n = image.shape[-1]
            value = w @ values[:, channels:channels + n]
            if detail is not None and channels == 0:
                value = value + detail[ys % detail.shape[0], xs % detail.shape[1]]
            image[y0:y1, x0:x1][take] = value[take].clip(0, 255)
            channels += n
        return int((take & (inside >= 0)).sum())

    texels = 0
    fragment_faces = np.nonzero(fragment)[0]
    Dn, Sn = D.copy(), S.copy()                 # paint from the untouched maps
    for fi in np.nonzero(repaint)[0]:
        if any(p not in colour for p in corner[fi]):
            skipped += 1
            continue
        texels += paint(fi, np.array([colour[p] for p in corner[fi]]), (Dn, Sn), skin_detail, repaint)
    D, S = Dn, Sn
    report['skin_repaint'] = {'fragment_islands': len({island[fi] for fi in fragment_faces}),
                              'fragment_triangles': len(fragment_faces), 'shard_triangles': int((shard & ~fragment).sum()),
                              'tiny_triangles': int((tiny & ~fragment & ~shard).sum()),
                              'skipped': skipped, 'texels': texels, 'detail_patch_xy': list(skin_patch)}
    report['repainted_faces'] = [int(fi) for fi in np.nonzero(repaint)[0]]

    # Folded UVs: where one hand's skin triangles overlap each other in the map
    # (the thumb pad), no paint can suit them all, and the bake left shards.
    # Those patches take the surrounding skin's tone, spread in, plus pores.
    side = P[wedge_point[F[:, 0]], 0] > 0
    fold = np.zeros((SIZE, SIZE), bool)
    blocks = np.zeros((SIZE, SIZE), bool)
    blocks[ROLL[1] - 16:LINING[1] + LINING[3] + 16, ROLL[0] - 16:ROLL[0] + 352] = True
    for hand in (side, ~side):
        count = np.zeros((SIZE, SIZE), np.uint8)
        for fi in np.nonzero(hand & in_skin & face_skin)[0]:
            tri = uv[F[fi]]
            if triangle_area(tri) < 4:
                continue
            mid = tri.mean(0)
            arm = tri - mid
            reach = np.linalg.norm(arm, axis=1, keepdims=True)
            inner = mid + arm * np.clip((reach - 1.5) / np.maximum(reach, 1e-6), 0, 1)   # shared edges are not overlap
            x0, y0 = np.floor(inner.min(0)).astype(int)
            x1, y1 = np.ceil(inner.max(0)).astype(int) + 1
            stamp = Image.new('L', (x1 - x0, y1 - y0), 0)
            ImageDraw.Draw(stamp).polygon([tuple(q - np.array([x0, y0])) for q in inner], fill=1)
            count[y0:y1, x0:x1] += np.asarray(stamp)
        fold |= count >= 2
    fold &= T & ~blocks
    opened = Image.fromarray((fold * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(5)).filter(ImageFilter.MaxFilter(5))

    def blobs(labels, smallest, largest):
        """Connected patches of `labels` between two sizes, as arrays of (y, x)."""
        seen = np.zeros_like(labels)
        for y, x in zip(*np.nonzero(labels)):
            if seen[y, x]:
                continue
            stack, cells = [(y, x)], []
            seen[y, x] = True
            while stack:
                cy, cx = stack.pop()
                cells.append((cy, cx))
                for ny, nx in ((cy - 1, cx), (cy + 1, cx), (cy, cx - 1), (cy, cx + 1)):
                    if 0 <= ny < SIZE and 0 <= nx < SIZE and labels[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
            if smallest <= len(cells) <= largest:
                yield np.array(cells)

    def spread_in(cells, grow):
        """Refill a patch of skin from the tone around it, plus pores."""
        margin = int(FOLD_SIGMA * 3)
        y0, x0 = np.maximum(cells.min(0) - margin, 0)
        y1, x1 = np.minimum(cells.max(0) + margin + 1, SIZE)
        patch = np.zeros((y1 - y0, x1 - x0), bool)
        patch[cells[:, 0] - y0, cells[:, 1] - x0] = True
        patch = np.asarray(Image.fromarray((patch * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(grow))) > 0
        source = (T[y0:y1, x0:x1] & owned[y0:y1, x0:x1] & ~patch).astype(np.float32)
        radius = int(FOLD_SIGMA * 3)
        kernel = np.exp(-0.5 * (np.arange(-radius, radius + 1) / FOLD_SIGMA) ** 2)

        def blur(a):
            same = lambda r: np.convolve(r, kernel)[radius:radius + len(r)]
            return np.apply_along_axis(same, 0, np.apply_along_axis(same, 1, a))
        weight = np.maximum(blur(source), 1e-4)
        ys, xs = np.mgrid[y0:y1, x0:x1]
        pores = skin_detail[ys % skin_detail.shape[0], xs % skin_detail.shape[1]]
        for image, detail in ((D, pores), (S, None)):
            region = image[y0:y1, x0:x1]
            for ch in range(3):
                spread = blur(region[..., ch] * source) / weight
                if detail is not None:
                    spread = spread + detail[..., ch]
                region[..., ch][patch] = spread[patch].clip(0, 255)
        return [int(x0), int(y0), int(x1 - x0), int(y1 - y0)], int(patch.sum())
    done = [spread_in(cells, 13) for cells in blobs(np.asarray(opened) > 0, FOLD_MIN_PX, SIZE * SIZE)]
    report['folded_uv_patches'] = {'patches': [d[0] for d in done], 'texels': sum(d[1] for d in done)}

    # Dark flecks: a small, hard-edged blot much darker than the skin round it
    # is leftover bake, not anatomy (creases and nail edges are soft and long).
    tone = D.mean(-1)
    around = np.asarray(Image.fromarray(tone.clip(0, 255).astype(np.uint8)).filter(ImageFilter.MedianFilter(31))).astype(np.float32)
    exposed = owned & T & in_skin[owner_face] & ~blocks
    fleck = exposed & (tone < FLECK_RATIO * around)
    done = [spread_in(cells, 7) for cells in blobs(fleck, FLECK_MIN_PX, FLECK_MAX_PX)]
    report['dark_flecks'] = {'patches': [d[0] for d in done], 'texels': sum(d[1] for d in done)}

    # Stray stitches: a stitch-coloured shell of a few faces with no stitch within 0.6 cm of it.
    small = [s for s, n in size_of.items() if n <= 40]
    centroid, tan = {}, {}
    for s in small:
        fs = np.nonzero(shell == s)[0]
        centroid[s] = P[wedge_point[F[fs]].ravel()].mean(0)
        c = np.array([window_mean(D, x, y, 1) for x, y in centre[fs]]).mean(0)
        tan[s] = c[0] > 90 and c[0] - c[2] > 20
    tan_shells = [s for s in small if tan[s]]
    centres = np.array([centroid[s] for s in tan_shells])
    stray = []
    for s in tan_shells:
        d = np.linalg.norm(centres - centroid[s], axis=1)
        if ((d > 0.08) & (d < 0.6)).sum() == 0:
            stray.append(s)
    stray_face = np.isin(shell, stray)
    flat = np.array([128, 128, 255], np.float32)
    values = np.tile(np.concatenate([leather, leather_spec, flat]), (3, 1))
    Nf = N.astype(np.float32)
    stray_texels = sum(paint(fi, values, (D, S, Nf), leather_detail, stray_face) for fi in np.nonzero(stray_face)[0])
    N = Nf.clip(0, 255).astype(np.uint8)
    report['stray_stitches'] = {'shells': len(stray), 'triangles': int(stray_face.sum()), 'texels': stray_texels,
                                'at': [[round(float(v), 2) for v in centroid[s]] for s in stray]}

    # Cuff rims: leather at the outside, turning into the lining's dark at the inside.
    x, y, w, h = ROLL
    before = D[y:y + h, x:x + w].mean((0, 1))
    if not (40 < before.mean() < 70):
        raise RuntimeError(f'The rolled-edge block is not where it was painted ({before})')
    lx, ly, lw, _ = LINING
    lining_top = D[ly:ly + 4, lx:lx + lw].mean((0, 1))
    lining_spec = S[ly:ly + 4, lx:lx + lw].mean((0, 1))
    t = (np.arange(h) + 0.5) / h
    fade = np.clip((t - 0.4) / 0.6, 0, 1)
    fade = fade * fade * (3 - 2 * fade)
    crest = 4.0 * np.exp(-((t - 0.3) / 0.14) ** 2)             # a faint worn line on the fold
    rows = leather[None, :] * (1 - fade[:, None]) + lining_top[None, :] * fade[:, None] + crest[:, None]
    ys, xs = np.mgrid[0:h, 0:w]
    grain = leather_detail[ys % leather_detail.shape[0], xs % leather_detail.shape[1]] * (1 - fade)[:, None, None]
    D[y:y + h, x:x + w] = (rows[:, None, :] + grain).clip(0, 255)
    S[y:y + h, x:x + w] = (leather_spec[None, :] * (1 - fade[:, None]) + lining_spec[None, :] * fade[:, None])[:, None, :]
    # The block's gutter held the old pale colour; refill it from the new rows.
    for image in (D, S):
        image[y:y + h, x - 8:x] = image[y:y + h, x:x + 1]
        image[y:y + h, x + w:x + w + 8] = image[y:y + h, x + w - 1:x + w]
        image[y - 8:y, x - 8:x + w + 8] = image[y:y + 1, x - 8:x + w + 8]
    report['cuff_rim'] = {'block': list(ROLL), 'colour_before': [round(float(v), 1) for v in before],
                          'colour_after': [round(float(v), 1) for v in D[y:y + h, x:x + w].mean((0, 1))],
                          'leather': [round(float(v), 1) for v in leather]}

    Image.fromarray(D.clip(0, 255).astype(np.uint8)).save(runtime / MAPS[0])
    Image.fromarray(S.clip(0, 255).astype(np.uint8)).save(runtime / MAPS[1])
    Image.fromarray(N).save(runtime / MAPS[2])
    report['maps_sha256'] = {n: digest(runtime / n) for n in MAPS}
    report_path.write_text(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    if sys.argv[1:2] == ['--stage']:
        stage(sys.argv[2])
    else:
        print('HAND_MAPS_CLEANED', json.dumps(main(sys.argv[1])), flush=True)
