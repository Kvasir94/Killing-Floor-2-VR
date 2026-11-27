"""Bare metal on the wrist panel's worn edges (Kvasir94's pick E2, "a livelier watch").

The watch's metal was one even cloud of paint: no part of it looked handled.
Real hardware loses its finish first on the outside corners, so this pass finds
the mesh's own convex edges and rubs the paint thin along them, unevenly:

- Blender step: every edge of the exported watch where two faces meet at more
  than MIN_ANGLE degrees, bend outward and are shaded as a crease (so not the
  facets of a round cable or pin) is written out as a line in texture space,
  with its angle.
- Paint step: those lines become a soft mask a fraction of a millimetre wide,
  broken up by slow and fine noise so only some stretches are worn, kept to the
  metal parts (the PBR metallic map), and blended into `_D` (toward bare steel)
  and `_S` (brighter). Leather, cable and rubber parts are left alone.

No mesh, UV or normal-map change.

    blender --background --factory-startup --python tools/wear_watch_edges.py -- <revision>
    python tools/wear_watch_edges.py <revision>
    python tools/rebalance_hand_materials.py --stage <revision>   # after the package import

The first copies the staged hand set into build/watch-detail-20260924/<revision>/runtime
and writes watch-convex-edges.json there; the second paints that copy.
"""
import hashlib, json, random, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'build/watch-detail-20260924'
STAGED = ROOT / 'build/hand-meshes'
SIZE = 4096
MAPS = ('VRHorzineWatch_D.tga', 'VRHorzineWatch_S.tga')
METALLIC = 'WatchPBRMetallic.png'
MIN_ANGLE, FULL_ANGLE = 28.0, 65.0      # degrees between the two faces: where wear starts and where it is full
HARD_ANGLE = 15.0                       # the shading normals must also differ by this much across the edge
LINE_PX, SOFT_PX = 9, 2                 # about 0.45 mm on the case at this atlas's density
COVER, FINE = 0.42, 0.45                # slow noise below COVER leaves an edge untouched; FINE roughens the rest
BARE, BARE_SPEC = (124.0, 122.0, 116.0), 205.0
AMOUNT = 0.80                           # how far a fully worn texel goes toward bare metal


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def find_edges(revision):
    """Blender: the convex edges of the watch as texture-space lines."""
    import bpy, math, runpy
    seat = runpy.run_path(str(ROOT / 'tools/seat_watch_keepers.py'), run_name='asset_source')
    runtime = ART / revision / 'runtime'
    out = runtime / 'watch-convex-edges.json'
    if out.exists():
        raise RuntimeError('This candidate already has its edge list; preserve it and start a new revision.')
    runtime.mkdir(parents=True, exist_ok=True)
    for p in STAGED.iterdir():
        if p.is_file() and (p.name == METALLIC or (p.name.startswith(('VRFloatingHands.', 'VRWristwatch.', 'VRHorzine'))
                                                 and p.suffix.lower() in {'.fbx', '.psk', '.tga'})):
            shutil.copy2(p, runtime / p.name)
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.context.scene.unit_settings.system = 'METRIC'
    bpy.context.scene.unit_settings.scale_length = 0.01
    watch = seat['load_watch'](runtime / 'VRWristwatch.fbx')
    me = watch.data
    # The export splits vertices at hard edges and seams, so edges are matched by position.
    key = [tuple(round(c, 3) for c in v.co) for v in me.vertices]
    normals = [n.vector.copy() for n in me.corner_normals]
    uv = me.uv_layers.active.data
    sides = {}
    for p in me.polygons:
        if p.area < 1e-7:
            continue
        loops = list(p.loop_indices)
        for i, la in enumerate(loops):
            lb = loops[(i + 1) % len(loops)]
            ka, kb = key[me.loops[la].vertex_index], key[me.loops[lb].vertex_index]
            if ka == kb:
                continue
            sides.setdefault((ka, kb) if ka < kb else (kb, ka), []).append((p.index, la, lb) if ka < kb else (p.index, lb, la))
    lines, seen, soft = [], 0, 0
    for pair in sides.values():
        if len(pair) != 2:
            continue
        (fa, a0, a1), (fb, b0, b1) = pair
        A, B = me.polygons[fa], me.polygons[fb]
        angle = math.degrees(A.normal.angle(B.normal, 0.0))
        if angle < MIN_ANGLE:
            continue
        seen += 1
        # A faceted round part is shaded smooth: its faces share one normal along the edge. Only a
        # crease the shading also breaks is a real corner.
        if max(normals[a0].angle(normals[b0], 0.0), normals[a1].angle(normals[b1], 0.0)) < math.radians(HARD_ANGLE):
            soft += 1
            continue
        # Outward bend: the neighbour's centre lies behind this face's plane.
        if (B.center - A.center).dot(A.normal) >= 0:
            continue
        for l0, l1 in ((a0, a1), (b0, b1)):
            p, q = uv[l0].uv, uv[l1].uv
            lines.append([round(p.x, 6), round(p.y, 6), round(q.x, 6), round(q.y, 6), round(angle, 1)])
    out.write_text(json.dumps({'watch_sha256': digest(runtime / 'VRWristwatch.fbx'), 'sharp_edges': seen, 'smooth_shaded': soft, 'lines': lines}))
    return {'sharp_edges': seen, 'smooth_shaded': soft, 'convex_lines': len(lines)}


def noise(np, Image, rng, period):
    n = SIZE // period + 2
    grid = np.array([[rng.random() for _ in range(n)] for _ in range(n)], dtype=np.float32)
    im = Image.fromarray((grid * 255).astype(np.uint8)).resize((n * period, n * period), Image.BICUBIC)
    return np.asarray(im, dtype=np.float32)[:SIZE, :SIZE] / 255.0


def paint(revision):
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
    runtime = ART / revision / 'runtime'
    report_path = runtime / 'watch-edge-wear.json'
    if report_path.exists():
        raise RuntimeError('This candidate already has its edge wear; preserve it and start a new revision.')
    found = json.loads((runtime / 'watch-convex-edges.json').read_text())
    if found['watch_sha256'] != digest(runtime / 'VRWristwatch.fbx'):
        raise SystemExit('The edge list was made from a different watch mesh.')
    report = {'base_sha256': {n: digest(runtime / n) for n in MAPS}, 'convex_lines': len(found['lines'])}
    D = np.asarray(Image.open(runtime / MAPS[0]).convert('RGB')).astype(np.float32)
    S = np.asarray(Image.open(runtime / MAPS[1]).convert('RGB')).astype(np.float32)
    metal = np.asarray(Image.open(runtime / METALLIC).convert('L').resize((SIZE, SIZE), Image.BILINEAR)).astype(np.float32) / 255.0
    metal = np.clip((metal - 0.4) / 0.2, 0, 1)

    # Draw sharper edges last so they win where lines cross.
    mask = Image.new('L', (SIZE, SIZE), 0)
    draw = ImageDraw.Draw(mask)
    for u0, v0, u1, v1, angle in sorted(found['lines'], key=lambda l: l[4]):
        level = 0.35 + 0.65 * min(1.0, (angle - MIN_ANGLE) / (FULL_ANGLE - MIN_ANGLE))
        draw.line([(u0 * SIZE, (1 - v0) * SIZE), (u1 * SIZE, (1 - v1) * SIZE)], fill=int(255 * level), width=LINE_PX)
    edge = np.asarray(mask.filter(ImageFilter.GaussianBlur(SOFT_PX)), dtype=np.float32) / 255.0

    rng = random.Random(20261110)
    slow = 0.65 * noise(np, Image, rng, 96) + 0.35 * noise(np, Image, rng, 31)
    fine = noise(np, Image, rng, 5)
    worn = np.clip((slow - COVER) / 0.14, 0, 1) * (1 - FINE + FINE * fine)
    used = D.max(-1) > 2                      # unused atlas texels are black; leave them black
    wear = edge * worn * metal * used * AMOUNT

    D2 = D + wear[..., None] * (np.array(BARE, dtype=np.float32) - D)
    S2 = S + wear[..., None] * np.maximum(BARE_SPEC - S, 0)
    Image.fromarray(D2.clip(0, 255).astype(np.uint8), 'RGB').save(runtime / MAPS[0])
    Image.fromarray(S2.clip(0, 255).astype(np.uint8), 'RGB').save(runtime / MAPS[1])
    touched = wear > 0.04
    report.update({'texels_worn': int(touched.sum()), 'share_of_metal': round(float(touched.sum() / max(1, (metal > 0.5).sum())), 4),
                   'mean_wear_where_worn': round(float(wear[touched].mean()), 3),
                   'maps_sha256': {n: digest(runtime / n) for n in MAPS}})
    report_path.write_text(json.dumps(report, indent=1))
    return report


if __name__ == '__main__':
    try:
        import bpy  # noqa: F401
        inside_blender = True
    except ImportError:
        inside_blender = False
    if inside_blender:
        print('WATCH_CONVEX_EDGES', json.dumps(find_edges(sys.argv[sys.argv.index('--') + 1])), flush=True)
    else:
        print('WATCH_EDGES_WORN', json.dumps(paint(sys.argv[1])), flush=True)
