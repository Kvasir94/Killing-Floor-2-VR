"""Clean a runtime hand revision's baked textures in place (plain Python).

    python tools/refine_hand_textures.py <revision>

Reads the revision's PSK UVs and rewrites its VRHorzineHands_* maps:
- diffuse: near-black strips baked into the finger skin islands are refilled
  from the surrounding valid skin;
- every map: island colour is dilated PAD_PIXELS into the gutter, so the
  mips used at arm's length no longer blend gutter colour into island edges
  (the dark outline along finger silhouettes);
- specular: replaces the flat 13-20/255 bake with stock-level skin variation
  (skin ~ stock median; leather matte, ~17 median; seams/stitching duller), shaped
  by the normal map so grain and creases catch light;
- adds VRHorzineHands_T, a skin-only transmission mask for Tex2d_SSSMask.
Geometry and UVs are untouched. A report records inputs, outputs and counts.
"""
import hashlib, json, runpy, sys
from pathlib import Path
import cv2
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
PAD_PIXELS = 24
STRIP_LUMA = 0.10
# Revision 72: leather/seam x0.45 (were 42/22). The revision 70 values put
# ~40/255 specular on ~0.13-luma leather and read as wet in the headset.
SKIN_SPEC, LEATHER_SPEC, SEAM_SPEC = 40.0, 19.0, 10.0
MASK_SIZE = 1024


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def luma(rgb):
    return rgb[..., :3].astype(np.float32) @ np.array([.3, .59, .11], np.float32) / 255


def uv_masks(runtime, size):
    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    chunks = g['read_psk'](runtime / 'VRFloatingHands.psk')
    points, wedges, faces, _ = g['decode_geometry'](chunks)
    parent = list(range(len(points)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for face in faces:
        for i in face[1:3]:
            ra, rb = find(wedges[face[0]][0]), find(wedges[i][0])
            if ra != rb:
                parent[rb] = ra
    by_shell = {}
    for face in faces:
        by_shell.setdefault(find(wedges[face[0]][0]), []).append(face)
    masks = {}
    for shell, shell_faces in by_shell.items():
        image = Image.new('L', (size, size), 0)
        draw = ImageDraw.Draw(image)
        for face in shell_faces:
            draw.polygon([(wedges[i][1] * size, wedges[i][2] * size) for i in face[:3]], fill=255)
        masks[shell] = (np.asarray(image) > 0, len(shell_faces))
    return masks


def fill(image, valid, target):
    """Grow valid pixels into target ring by ring (normalized 3x3 averaging)."""
    image = image.astype(np.float32).copy()
    valid = valid.copy()
    kernel = np.ones((3, 3), np.float32)
    for _ in range(4096):
        todo = target & ~valid
        if not todo.any():
            break
        weight = cv2.filter2D(valid.astype(np.float32), -1, kernel, borderType=cv2.BORDER_CONSTANT)
        grow = todo & (weight > 0)
        if not grow.any():
            break
        for c in range(image.shape[2]):
            total = cv2.filter2D(image[..., c] * valid, -1, kernel, borderType=cv2.BORDER_CONSTANT)
            image[..., c][grow] = total[grow] / weight[grow]
        valid |= grow
    return image


def main():
    revision = sys.argv[1]
    runtime = ROOT / 'build/watch-detail-20260924' / revision / 'runtime'
    report_path = runtime / 'texture-refine.json'
    if report_path.exists():
        raise RuntimeError('Textures of this revision were already refined; start a new version.')
    names = {k: runtime / f'VRHorzineHands_{k}.tga' for k in 'DNS'}
    before = {k: digest(p) for k, p in names.items()}
    maps = {k: np.asarray(Image.open(p).convert('RGB')) for k, p in names.items()}
    size = maps['D'].shape[0]
    masks = uv_masks(runtime, size)
    coverage = np.zeros((size, size), bool)
    for mask, _ in masks.values():
        coverage |= mask
    diffuse_luma = luma(maps['D'])
    # Skin: the two largest shells (one per hand, shared UVs) that are light.
    ranked = sorted(masks.values(), key=lambda m: -m[1])
    skin = np.zeros_like(coverage)
    for mask, _ in ranked[:4]:
        if diffuse_luma[mask].mean() > .3:
            skin |= mask
    strips = skin & (diffuse_luma < STRIP_LUMA)
    strips = cv2.dilate(strips.astype(np.uint8), np.ones((3, 3), np.uint8), iterations=2).astype(bool) & skin
    diffuse = fill(maps['D'], skin & ~strips, strips)
    diffuse[~strips] = maps['D'][~strips]
    ring = cv2.dilate(coverage.astype(np.uint8), np.ones((3, 3), np.uint8), iterations=PAD_PIXELS).astype(bool)
    diffuse = fill(diffuse, coverage, ring & ~coverage)
    normal = fill(maps['N'], coverage, ring & ~coverage)
    # Specular from surface class, modulated by the tangent normal: faces that
    # tilt away from the surface (grain pits, creases, seams) are duller.
    n = maps['N'].astype(np.float32) / 127.5 - 1
    flat = np.clip(n[..., 2], 0, 1)
    detail = cv2.GaussianBlur(diffuse_luma, (0, 0), 1.5)
    base = np.where(skin, SKIN_SPEC, np.where(diffuse_luma > .24, SEAM_SPEC, LEATHER_SPEC)).astype(np.float32)
    spec = base * (0.55 + 0.45 * flat ** 4) * (0.8 + 0.4 * np.clip(detail / max(1e-3, float(detail[coverage].mean())), 0, 1.5))
    spec = np.repeat(np.clip(spec, 0, 255)[..., None], 3, axis=2)
    spec = fill(spec, coverage, ring & ~coverage)
    spec[~ring] = maps['S'][~ring]
    outputs = {'D': diffuse, 'N': normal, 'S': spec}
    for k, image in outputs.items():
        Image.fromarray(np.clip(np.rint(image), 0, 255).astype(np.uint8)).save(names[k])
    skin_pad = cv2.dilate(skin.astype(np.uint8), np.ones((3, 3), np.uint8), iterations=PAD_PIXELS)
    transmission = cv2.resize(skin_pad * 255, (MASK_SIZE, MASK_SIZE), interpolation=cv2.INTER_AREA)
    transmission_path = runtime / 'VRHorzineHands_T.tga'
    Image.fromarray(np.repeat(transmission[..., None], 3, axis=2)).save(transmission_path)
    report = {'change': 'Refill finger-skin strips, widen gutter padding, stock-level specular, skin transmission mask',
              'pad_pixels': PAD_PIXELS, 'strip_pixels_refilled': int(strips.sum()),
              'skin_fraction': float(skin.mean()), 'coverage_fraction': float(coverage.mean()),
              'specular_skin_median': float(np.median(spec[skin][:, 0])),
              'specular_other_median': float(np.median(spec[coverage & ~skin][:, 0])),
              'inputs_sha256': before, 'outputs_sha256': {**{k: digest(p) for k, p in names.items()},
                                                          'T': digest(transmission_path)}}
    report_path.write_text(json.dumps(report, indent=2))
    print('HAND_TEXTURES_REFINED', json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
