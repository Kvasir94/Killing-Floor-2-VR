"""Overlay renders of every fitted world gun mapping (tools/fit_pickup_frames.py).

Step 1 (python): writes build/world-gun-rigs/fit-review/<weapon>.json with the
stock pickup mesh moved into the rig frame by the inverse fitted mapping, each
pickup vertex's gap to the rig's weapon-only Idle surface, and the rig grips.
Step 2 (Blender, --render): draws the pickup in the rig frame coloured by its
gap to the rig surface, with the primary grip blue and support cyan.

  python tools/render_pickup_fits.py
  blender --background --factory-startup --python tools/render_pickup_fits.py -- --render
"""
import json
import struct
import sys
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / 'AGENTS.md').is_file())
REVIEW = ROOT / 'build/world-gun-rigs/fit-review'


def dump(fits_path=None, only=None):
    import numpy as np
    sys.path[:0] = [str(ROOT / 'tools'), str(ROOT / 'tools/re')]
    from audit_flamethrower_assets import chunks, parse_bones
    from audit_source_assets import read_package
    from inspect_grenade_grips import extract
    import author_world_gun_rigs as rigs
    fits = json.loads(Path(fits_path or ROOT / 'build/world-gun-rigs/pickup-fits.json').read_text())
    table = {r['weapon']: r for r in json.loads((ROOT / 'build/world-gun-rigs/rigs.json').read_text())['rigs']}
    exports = {p.stem.lower(): p for p in (ROOT / 'build/shared-weapon-frames/held-export').rglob('*.psk')}
    animations = {p.stem.lower(): p for p in (ROOT / 'build/shared-weapon-frames/held-export').rglob('*.psa')}
    packages = {p.stem.lower(): p for p in Path('D:/SteamLibrary/steamapps/common/killingfloor2/KFGame/BrewedPC/Packages/Weapons').rglob('*.upk')}
    assets = rigs.class_assets(Path('D:/SteamLibrary/steamapps/common/killingfloor2'))
    profiles = rigs.profiles()
    REVIEW.mkdir(parents=True, exist_ok=True)
    for name, fit in sorted(fits.items()):
        if 'scale' not in fit or name not in table or (only and name not in only):
            continue
        mesh_name, anims = assets(name)
        psk = exports[mesh_name.split('.')[-1].lower()]
        bones = parse_bones(chunks(psk)['REFSKELT'])
        root = [b['name'] for b in bones].index(profiles[name]['root'])
        pose = rigs.idle_pose(bones, [animations[a.split('.')[-1].lower()] for a in anims if a.split('.')[-1].lower() in animations], profiles[name]['idle'])
        points, _, ids = rigs.weapon_points(psk, bones, pose, root, with_ids=True)
        c = chunks(psk)
        wedges = [w[0] for w in struct.iter_unpack('<IffBBH', c['VTXW0000'][2])]
        where = {v: i for i, v in enumerate(ids)}
        tris = []
        for f in struct.iter_unpack('<3HBBI', c['FACE0000'][2]):
            a, b, d = (wedges[f[k]] for k in range(3))
            if a in where and b in where and d in where:
                tris.append([where[a], where[b], where[d]])
        r, t = np.array(fit['rotation']), np.array(fit['origin'])
        package_name, pickup_mesh = fit['pickup'].split('.')
        pickup = extract(packages[package_name.lower()], pickup_mesh)
        # Review in the rig frame (bore along X): the pickup moved by the
        # inverse mapping, coloured by its distance to the rig's surface.
        pv = (np.array(pickup['vertices']) - t) @ r / fit.get('scale', 1.0)
        from fit_pickup_frames import nearest, sample_surface
        _, gap = nearest(pv, sample_surface(points, tris, 20000))
        out = dict(weapon=name, p90=fit['p90'], scale=fit.get('scale', 1.0), pickup_vertices=pv.tolist(), pickup_triangles=pickup['triangles'],
                   pickup_gap=gap.tolist(), rig_vertices=points.tolist(), rig_triangles=tris,
                   primary=list(table[name]['primary']), support=list(table[name]['support']))
        (REVIEW / (name + '.json')).write_text(json.dumps(out))
        wrist = [float(np.sqrt(((pv - np.array(table[name][k])) ** 2).sum(1).min())) for k in ('primary', 'support')]
        print(f"{name:42s} scale={fit.get('scale', 1.0):.3f} quality={fit['quality']:.2f} p90={fit['p90']:.2f} wrist gaps={wrist[0]:.1f},{wrist[1]:.1f}"
              f"{' mirrored art' if fit.get('mirrored_art') else ''}", flush=True)


def render():
    """Side, top and rear views in the rig frame, each twice with the same
    framing: the rig's weapon-only Idle mesh in grey, then the fitted pickup
    coloured by its gap to the rig (green under 1 UU, yellow 1-3, red over 3).
    Grips are blue (primary) and cyan (support) dots in both."""
    import bpy
    from mathutils import Vector
    only = [a for a in sys.argv[sys.argv.index('--render') + 1:]]
    files = sorted(f for f in REVIEW.glob('KFWeap_*.json') if not only or f.stem in only)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'
    scene.display.shading.color_type = 'VERTEX'
    scene.render.resolution_x, scene.render.resolution_y = 520, 260
    for f in files:
        data = json.loads(f.read_text())
        objs = []
        me = bpy.data.meshes.new('pickup'); me.from_pydata(data['pickup_vertices'], [], data['pickup_triangles']); me.update()
        colours = me.color_attributes.new('gap', 'FLOAT_COLOR', 'POINT')
        for i, g in enumerate(data['pickup_gap']):
            colours.data[i].color = (0.1, 0.8, 0.2, 1) if g < 1 else ((0.95, 0.85, 0.1, 1) if g < 3 else (0.95, 0.1, 0.1, 1))
        o = bpy.data.objects.new('pickup', me); scene.collection.objects.link(o); objs.append(o)
        rm = bpy.data.meshes.new('rig'); rm.from_pydata(data['rig_vertices'], [], data['rig_triangles']); rm.update()
        grey = rm.color_attributes.new('gap', 'FLOAT_COLOR', 'POINT')
        for d in grey.data: d.color = (0.6, 0.6, 0.62, 1)
        rig = bpy.data.objects.new('rig', rm); scene.collection.objects.link(rig); objs.append(rig)
        for key, colour in (('primary', (0.1, 0.3, 1, 1)), ('support', (0.0, 1.0, 1.0, 1))):
            bpy.ops.mesh.primitive_uv_sphere_add(radius=1.2, location=data[key])
            s = bpy.context.active_object
            c = s.data.color_attributes.new('gap', 'FLOAT_COLOR', 'POINT')
            for d in c.data: d.color = colour
            objs.append(s)
        pts = [Vector(p) for p in data['pickup_vertices'] + data['rig_vertices']]
        lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
        hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
        centre, span = (lo + hi) / 2, hi - lo
        # The frame is twice as wide as it is tall.
        sizes = dict(side=max(span.x, 2 * span.z), top=max(span.x, 2 * span.y), rear=max(span.y, 2 * span.z))
        for view, d, up in (('side', Vector((0, -1, 0)), 'Z'), ('top', Vector((0, 0, 1)), 'Y'), ('rear', Vector((-1, 0, 0)), 'Z')):
            size = max(sizes[view], 10)
            cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); scene.collection.objects.link(cam)
            cam.data.type = 'ORTHO'; cam.data.ortho_scale = size * 1.08
            cam.location = centre + d * size * 2
            cam.rotation_euler = (-d).to_track_quat('-Z', up).to_euler()
            scene.camera = cam
            for shown, suffix in ((rig, '_rig'), (o, '')):
                o.hide_render, rig.hide_render = shown is not o, shown is not rig
                scene.render.filepath = str(REVIEW / 'png' / f"{data['weapon']}_{view}{suffix}.png")
                bpy.ops.render.render(write_still=True)
            bpy.data.objects.remove(cam)
        for o in objs:
            bpy.data.objects.remove(o)


def sheet(only=None, per_page=6):
    """Review pages, fit-review/sheet/page_NN.png: a row per gun (side and top
    views), rig then fitted pickup for each view."""
    from PIL import Image, ImageDraw
    out = REVIEW / 'sheet'
    out.mkdir(parents=True, exist_ok=True)
    names = [f.stem for f in sorted(REVIEW.glob('KFWeap_*.json')) if not only or f.stem in only]
    names = [n for n in names if all((REVIEW / 'png' / f'{n}_{v}{k}.png').is_file() for v in ('side', 'top') for k in ('', '_rig'))]
    w, h = 260, 130
    for page in range(0, len(names), per_page):
        group = names[page:page + per_page]
        img = Image.new('RGB', (4 * w, len(group) * (h + 14)), 'white')
        for row, n in enumerate(group):
            y = row * (h + 14)
            scale = json.loads((REVIEW / (n + '.json')).read_text()).get('scale', 1.0)
            ImageDraw.Draw(img).text((4, y), n + ('' if scale == 1.0 else f'   pickup scale {scale:.3f}'), fill='black')
            for col, (v, k) in enumerate((('side', '_rig'), ('side', ''), ('top', '_rig'), ('top', ''))):
                img.paste(Image.open(REVIEW / 'png' / f'{n}_{v}{k}.png').convert('RGB').resize((w, h)), (col * w, y + 14))
        img.save(out / f'page_{page // per_page:02d}.png')


if __name__ == '__main__':
    if '--render' in sys.argv:
        render()
    elif '--sheet' in sys.argv:
        sheet(sys.argv[sys.argv.index('--sheet') + 1:] or None)
    else:
        args = sys.argv[1:]
        dump(args[0] if args else None, args[1:] or None)
