"""Rebalance the hand and wrist-panel maps for KF2's stock first-person arm materials.

In play the gloves rendered as a black silhouette and the watch as pale paint
(two replay captures, 2026-11-06 and 2026-11-10). The maps were authored for a
PBR preview; the game's materials want something else (docs/re/FIRST_PERSON_MATERIALS.md):

- Hands move to the stock gloss-mapped first-person arm material
  (`Chr_Mic_Lib.CHR_1P_Glss_MIC`). Its specular map carries gloss in alpha.
  Stock cloth sleeves sit near specular 57 with gloss 11; ours was 17 with
  one specular power for skin, leather and thread. `_S` becomes RGBA. The
  levels were tuned in the game with a spec x gloss test grid: stock cloth
  values turned our grained leather grey, and high gloss made the grain
  sparkle, so leather sits at 30 with a mid-broad highlight and skin gets a
  tighter one.
- `_T`, the skin transmission mask, is rebuilt from the skin triangles
  themselves. The old 1024 mask bled onto leather edges.
- The watch stays on the plain arm material, with its colour map brought down
  toward stock levels: stock art is dark (gun metal near 40, cloth near 30),
  and the watch's pale metal and straps were the brightest things in a dark
  room. The stock weapon material was tried first: in the game it drew the
  whole watch near black in daylight, straps included, so it is not used.
  `_M` is still written as that material's variation mask (G gloss, B
  occlusion, R 0) and imported, both as the marker that tells the script the
  package carries these maps and for a later return to the weapon material.
  The PBR metallic map it replaces is kept as WatchPBRMetallic.png.

    python tools/rebalance_hand_materials.py <revision>
    python tools/rebalance_hand_materials.py --stage <revision>

Plain Python. The first copies the staged set from build/hand-meshes into
build/watch-detail-20260924/<revision>/runtime and edits it. After
`tools/build-hand-assets.ps1 -InputMesh <runtime>/VRFloatingHands.fbx
-OutputRoot <revision>/package`, the second backs up and replaces the staged
maps and package.
"""
import collections, hashlib, json, runpy, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'build/watch-detail-20260924'
STAGED = ROOT / 'build/hand-meshes'
EDITED = ('VRHorzineHands_S.tga', 'VRHorzineHands_T.tga', 'VRHorzineWatch_D.tga', 'VRHorzineWatch_S.tga',
          'VRHorzineWatch_M.tga')
KEPT = 'WatchPBRMetallic.png'
SIZE = 4096
# Hands: specular level (0-255) and gloss (alpha) per surface.
LEATHER_SPEC, LEATHER_GLOSS = 30.0, 28
THREAD_SPEC, THREAD_GLOSS = 20.0, 8
SKIN_SPEC, SKIN_GLOSS = 0.62, 46          # skin keeps its own map, lowered: at 0.85 and 70 the fingers read wet in daylight
# Watch, on the arm material: colour and specular scales for metal and for
# everything else (straps, leather saddle, rubber).
METAL_COLOUR, SOFT_COLOUR = 0.68, 0.70
METAL_SPEC, SOFT_SPEC_LIFT = 0.85, 10.0
VARIATION_R, VARIATION_B = 0, 235
METAL_GLOSS, SOFT_GLOSS = (60.0, 200.0), 34.0


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def stage(revision):
    """Back up and replace every staged hand file this candidate changed, and the package."""
    runtime, package = ART / revision / 'runtime', ART / revision / 'package'
    receipt = json.loads((package / 'build.json').read_text(encoding='utf-8-sig'))
    if not receipt['success'] or digest(package / 'KF2VRHands.upk') != receipt['package_sha256'].upper():
        raise SystemExit('The candidate package has no passing import record.')
    changed = []
    for source in sorted(runtime.iterdir()):
        name = source.name
        if not (name.startswith(('VRHorzine', 'VRWristwatch.', 'VRFloatingHands.')) and source.suffix.lower() in {'.tga', '.fbx', '.psk'}) and name != KEPT:
            continue
        imported = (receipt['textures_sha256'].get(name) if source.suffix.lower() == '.tga' else
                    receipt['wristwatch_sha256'] if name == 'VRWristwatch.fbx' else
                    receipt['input_sha256'] if name == 'VRFloatingHands.fbx' else
                    receipt['source_psk_sha256'] if name == 'VRFloatingHands.psk' else digest(source))
        if imported is None or imported.upper() != digest(source):
            raise SystemExit(f'{name} is not the file this candidate was imported with.')
        if not (STAGED / name).exists() or digest(STAGED / name) != digest(source):
            changed.append(name)
    backup = ART / revision / 'before-staging'
    targets = [(runtime / n, STAGED / n) for n in changed] +               [(package / n, ROOT / 'build/hand-assets' / n) for n in ('KF2VRHands.upk', 'build.json')]
    for _, destination in targets:
        saved = backup / destination.relative_to(ROOT / 'build')
        if destination.exists() and not saved.exists():
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(destination, saved)
    for source, destination in targets:
        temporary = destination.with_name(destination.name + '.new')
        shutil.copy2(source, temporary)
        temporary.replace(destination)
    print(json.dumps({'staged_revision': revision, 'changed': changed, 'backup': str(backup)}))


def main(revision):
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
    runtime = ART / revision / 'runtime'
    report_path = runtime / 'hand-material-rebalance.json'
    if report_path.exists():
        raise RuntimeError('This candidate was already rebalanced; preserve it and start a new revision.')
    runtime.mkdir(parents=True, exist_ok=True)
    for p in STAGED.iterdir():
        if p.is_file() and p.name.startswith(('VRFloatingHands.', 'VRWristwatch.', 'VRHorzine')) \
                and p.suffix.lower() in {'.fbx', '.psk', '.tga'}:
            shutil.copy2(p, runtime / p.name)
    report = {'base_sha256': {n: digest(STAGED / n) for n in EDITED}}

    # ---- Hands ----
    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    points, wedges, faces, _ = g['decode_geometry'](g['read_psk'](runtime / 'VRFloatingHands.psk'))
    P = np.array(points)
    wedge_point = np.array([w[0] for w in wedges])
    uv = np.array([(w[1], w[2]) for w in wedges]) * SIZE
    F = np.array([f[:3] for f in faces])
    weld = {}
    point_id = np.array([weld.setdefault(tuple(np.round(p, 4)), len(weld)) for p in P])
    corner = point_id[wedge_point[F]]
    parent = list(range(len(weld)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for a, b, c in corner:
        parent[find(a)] = find(b)
        parent[find(b)] = find(c)
    shell = np.array([find(c[0]) for c in corner])
    size_of = collections.Counter(shell.tolist())
    old_T = np.asarray(Image.open(runtime / 'VRHorzineHands_T.tga').convert('L'))
    T_up = np.asarray(Image.fromarray(old_T).resize((SIZE, SIZE), Image.NEAREST)) > 128
    centre = uv[F].mean(1).astype(int).clip(0, SIZE - 1)
    face_skin = T_up[centre[:, 1], centre[:, 0]]
    skin_shells = [s for s, n in size_of.most_common(6) if n > 3000 and face_skin[shell == s].mean() > 0.3]
    if len(skin_shells) != 2:
        raise RuntimeError(f'Expected two skin shells, found {len(skin_shells)}')
    is_skin_face = np.isin(shell, skin_shells) & face_skin
    # Exact masks: later faces draw over earlier ones, so draw skin last only
    # where it is the owner; a second image records any ownership at all.
    owned_image = Image.new('L', (SIZE, SIZE), 0)
    skin_image = Image.new('L', (SIZE, SIZE), 0)
    draw_owned, draw_skin = ImageDraw.Draw(owned_image), ImageDraw.Draw(skin_image)
    for fi in np.argsort(is_skin_face, kind='stable'):
        poly = [tuple(uv[w]) for w in F[fi]]
        draw_owned.polygon(poly, fill=255)
        draw_skin.polygon(poly, fill=255 if is_skin_face[fi] else 0)
    owned = np.asarray(owned_image) > 0
    skin = np.asarray(skin_image) > 0
    # Gutters keep the class the old mask gave them, so mips do not pull leather values onto skin edges.
    skin = np.where(owned, skin, T_up)

    D = np.asarray(Image.open(runtime / 'VRHorzineHands_D.tga').convert('RGB')).astype(np.float32)
    S = np.asarray(Image.open(runtime / 'VRHorzineHands_S.tga').convert('RGB')).astype(np.float32)
    thread = ~skin & (D[..., 0] > 90) & (D[..., 0] - D[..., 2] > 20)
    leather = ~skin & ~thread
    level = S.mean(-1)
    leather_now = float(np.median(level[leather & owned]))
    thread_now = float(np.median(level[thread & owned]))
    spec = level.copy()
    spec[leather] = level[leather] * (LEATHER_SPEC / max(leather_now, 1.0))
    spec[thread] = level[thread] * (THREAD_SPEC / max(thread_now, 1.0))
    spec[skin] = level[skin] * SKIN_SPEC
    # The end lining and plate stay dull: they are the inside of a sleeve.
    dull = leather & (D.mean(-1) < 18)
    spec[dull] = level[dull]
    gloss = np.full((SIZE, SIZE), LEATHER_GLOSS, np.float32)
    gloss[thread] = THREAD_GLOSS
    gloss[skin] = SKIN_GLOSS
    out = np.dstack([spec, spec, spec, gloss]).clip(0, 255).astype(np.uint8)
    Image.fromarray(out, 'RGBA').save(runtime / 'VRHorzineHands_S.tga')
    T_new = Image.fromarray((skin * 255).astype(np.uint8)).resize(old_T.shape[::-1], Image.BOX)
    Image.merge('RGB', [T_new] * 3).save(runtime / 'VRHorzineHands_T.tga')
    report['hands'] = {'leather_spec': [round(leather_now, 1), LEATHER_SPEC], 'thread_spec': [round(thread_now, 1), THREAD_SPEC],
                       'skin_spec': round(float(np.median(level[skin & owned])), 1),
                       'gloss': {'leather': LEATHER_GLOSS, 'thread': THREAD_GLOSS, 'skin': SKIN_GLOSS},
                       'transmission_mask_texels_changed': int((np.asarray(T_new) > 128).sum() - (old_T > 128).sum())}

    # ---- Watch ----
    metallic_path = runtime / 'VRHorzineWatch_M.tga'
    kept = STAGED / KEPT
    metallic_image = Image.open(kept if kept.exists() else metallic_path).convert('L')
    metallic_image.save(runtime / KEPT)
    m = np.asarray(metallic_image.resize((SIZE, SIZE), Image.BILINEAR)).astype(np.float32) / 255
    rough = np.asarray(Image.open(runtime / 'VRHorzineWatch_R.tga').convert('L').resize((SIZE, SIZE), Image.BILINEAR)).astype(np.float32) / 255
    WD = np.asarray(Image.open(runtime / 'VRHorzineWatch_D.tga').convert('RGB')).astype(np.float32)
    WS = np.asarray(Image.open(runtime / 'VRHorzineWatch_S.tga').convert('RGB')).astype(np.float32)
    tone = WD.mean(-1)
    used = tone > 3
    metal = m > 0.5
    before = {'metal_colour': round(float(np.median(tone[metal & used])), 1), 'metal_spec': round(float(np.median(WS.mean(-1)[metal & used])), 1),
              'soft_spec': round(float(np.median(WS.mean(-1)[~metal & used])), 1)}
    colour = WD * (SOFT_COLOUR + (METAL_COLOUR - SOFT_COLOUR) * m[..., None])
    soft_spec = (WS + SOFT_SPEC_LIFT) * used[..., None]
    spec = soft_spec * (1 - m[..., None]) + WS * METAL_SPEC * m[..., None]
    spec *= used[..., None]
    gloss = SOFT_GLOSS * (1 - m) + ((1 - rough) * 255 * 0.9).clip(*METAL_GLOSS) * m
    variation = np.dstack([np.full_like(gloss, VARIATION_R), gloss, np.full_like(gloss, VARIATION_B)])
    Image.fromarray(colour.clip(0, 255).astype(np.uint8)).save(runtime / 'VRHorzineWatch_D.tga')
    Image.fromarray(spec.clip(0, 255).astype(np.uint8)).save(runtime / 'VRHorzineWatch_S.tga')
    Image.fromarray(variation.clip(0, 255).astype(np.uint8)).save(metallic_path)
    report['watch'] = {'before': before,
                       'after': {'metal_colour': round(float(np.median(colour.mean(-1)[metal & used])), 1),
                                 'metal_spec': round(float(np.median(spec.mean(-1)[metal & used])), 1),
                                 'soft_spec': round(float(np.median(spec.mean(-1)[~metal & used])), 1),
                                 'metal_gloss': round(float(np.median(gloss[metal & used])), 1)}}
    report['maps_sha256'] = {n: digest(runtime / n) for n in EDITED}
    report_path.write_text(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    if sys.argv[1:2] == ['--stage']:
        stage(sys.argv[2])
    else:
        print('HAND_MATERIALS_REBALANCED', json.dumps(main(sys.argv[1])), flush=True)
