"""Make a hand revision's glove leather matte (plain Python).

    python tools/matte_hand_specular.py <new revision> --base <revision>

Copies the base revision's runtime folder to the new revision and rescales
its VRHorzineHands_S map: every texel outside the skin transmission mask
(glove leather, seams, stitching, forearm bracer, cuff roll, lining, plate)
is multiplied by MATTE_SCALE. Skin keeps its stock-level values. Revision 70's
`refine_hand_textures.py` raised glove leather from a flat ~16/255 to ~40/255
on a near-black albedo (~0.13 sRGB luma), which read as wet in the headset;
MATTE_SCALE is the same ratio now applied to that script's and
`paint_forearm_bracer.py`'s leather constants, so a full regeneration gives
the same maps. Geometry, UVs, diffuse, normal and transmission maps are
byte-identical to the base. A report records inputs, outputs and medians.
"""
import argparse, hashlib, json, runpy, shutil
from pathlib import Path
import cv2
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'build/watch-detail-20260924'
MATTE_SCALE = 0.45
SKIN_SHELL_MASKED = 0.3    # skin shells: 61%/96% under _T; leather shells ~1%


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=int)
    parser.add_argument('--base', type=int, required=True)
    args = parser.parse_args()
    source, runtime = ART / str(args.base) / 'runtime', ART / str(args.revision) / 'runtime'
    if runtime.exists():
        raise RuntimeError('This revision already exists; start a new version.')
    shutil.copytree(source, runtime)
    s_path = runtime / 'VRHorzineHands_S.tga'
    before = digest(s_path)
    spec = np.asarray(Image.open(s_path).convert('RGB')).astype(np.float32)
    trans = np.asarray(Image.open(runtime / 'VRHorzineHands_T.tga').convert('L'))
    size = spec.shape[0]
    trans = cv2.resize(trans, (size, size), interpolation=cv2.INTER_LINEAR) > 127
    # Skin is the transmission mask (already cleared on the painted bracer),
    # minus any texel a leather shell covers inside its 24 px padding. Skin
    # shells are mostly under the mask; leather shells almost never are.
    refine = runpy.run_path(str(ROOT / 'tools/refine_hand_textures.py'), run_name='asset_source')
    coverage = np.zeros((size, size), bool)
    other = np.zeros((size, size), bool)
    for mask, _ in refine['uv_masks'](runtime, size).values():
        coverage |= mask
        if trans[mask].mean() < SKIN_SHELL_MASKED:
            other |= mask
    skin = trans & ~other
    leather = coverage & ~skin
    old = spec[..., 0].copy()
    spec[~skin] *= MATTE_SCALE
    Image.fromarray(np.clip(np.rint(spec), 0, 255).astype(np.uint8)).save(s_path)

    def pct(values):
        return [float(v) for v in np.percentile(values, [10, 50, 90, 99])]
    report = {'change': 'Matte glove leather: non-skin specular x%.2f' % MATTE_SCALE,
              'base_revision': args.base, 'matte_scale': MATTE_SCALE,
              'skin_fraction': float(skin.mean()), 'leather_fraction': float(leather.mean()),
              'leather_specular_p10_50_90_99_before': pct(old[leather]),
              'leather_specular_p10_50_90_99_after': pct(spec[..., 0][leather]),
              'skin_specular_median': float(np.median(old[coverage & skin])),
              'input_sha256': {'S': before}, 'output_sha256': {'S': digest(s_path)},
              'generator_sha256': digest(Path(__file__))}
    (runtime / 'specular-matte.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('HAND_SPECULAR_MATTE', json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
