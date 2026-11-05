"""Render each gun's physical reload zones from the player's eye.

Reads the zone dump (tools/reload_zone_report.py --json, or the committed
tools/reload-zone-baseline.json) and, for each gun, draws its stock 1P rig in
the reload root bone's frame with what the player is shown and works:

  cyan     the generated magazine and well hint shells, and the entry ring
           where the game draws it (VRInteractiveReload.AmmoRingLocal)
  white    the insert path from that entry to the seat (white dot), where
           the ghost and seated ammunition end
  amber    the slide/pump/action hint shell and the sampled rack stroke

Run with Blender (headless):
  blender --background --python tools/render_reload_zones.py -- [--zones FILE] [--out DIR] [Class ...]

Writes one PNG per gun/start and contact.png. Geometry is the bind pose: a
shell on a moving part, and a path sampled in a cylinder's or barrel's own
frame, show where that part rests, not where it opens to. Read-only on game assets.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))

import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
from generate_reload_props import bind_frames, read_psk, rig_geometry  # noqa: E402
from reload_sound_map import export_file  # noqa: E402

PROPS = ROOT / 'build/hand-meshes'
props_dir = PROPS
SIZE = (640, 480)
COLOURS = {'gun': (0.42, 0.42, 0.44, 1), 'ammo': (0.1, 0.75, 1.0, 1), 'action': (1.0, 0.62, 0.1, 1),
           'path': (0.95, 0.95, 0.95, 1)}
# The player's eye for a held reload, in the root frame (+X bore, +Z up): behind
# the grip, above it and to the support side, looking down at the action.
EYE = Vector((-1.0, -0.55, 0.75)).normalized()


def material(kind):
    mat = bpy.data.materials.get(kind) or bpy.data.materials.new(kind)
    mat.diffuse_color = COLOURS[kind]
    return mat


def mesh_object(name, verts, faces, kind):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.materials.append(material(kind))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def frames(bones, names):
    positions, rotations = bind_frames(bones)
    return {n: Matrix.Translation(positions[i]) @ rotations[i].to_matrix().to_4x4() for i, n in enumerate(names)}


def gun_mesh(psk, to_root):
    bones, names, points, wedges, faces, owner = rig_geometry(psk)
    verts = [tuple(to_root @ Vector(p)) for p in points]
    # Reversed winding, as the PSK importer and the shell cutter read it.
    tris = [(wedges[f[2]][0], wedges[f[1]][0], wedges[f[0]][0]) for f in faces]
    return mesh_object('gun', verts, tris, 'gun')


def shell(name, bone_frame, kind):
    """A generated hint shell, imported from its FBX into the root frame."""
    path = props_dir / (name + '.fbx')
    if not path.exists():
        return None
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=str(path), global_scale=1.0, axis_forward='-X', axis_up='Z',
                             use_custom_normals=False)
    new = [o for o in bpy.data.objects if o not in before and o.type == 'MESH']
    for obj in new:
        obj.matrix_world = bone_frame @ obj.matrix_world
        obj.data.materials.clear()
        obj.data.materials.append(material(kind))
    return new


def rig_vector(v):
    """A runtime (UE, left-handed) bone-frame vector in the PSK export's frame,
    which mirrors Y: the Reconstructor's idle canister is +11.16 Y in game and
    -11.16 Y in its PSK."""
    return Vector((v[0], -v[1], v[2]))


def segment(name, a, b, radius, kind):
    a, b = Vector(a), Vector(b)
    length = (b - a).length
    if length < 1e-3:
        return
    bpy.ops.mesh.primitive_cylinder_add(radius=radius, depth=length, vertices=12, location=(a + b) / 2)
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = (b - a).to_track_quat('Z', 'Y').to_euler()
    obj.data.materials.append(material(kind))
    obj.show_in_front = True


def ring(name, at, normal, radius, kind):
    bpy.ops.mesh.primitive_torus_add(major_radius=radius, minor_radius=radius * 0.12, location=at)
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = Vector(normal).to_track_quat('Z', 'Y').to_euler()
    obj.data.materials.append(material(kind))
    obj.show_in_front = True


def reset_scene():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for mesh in list(bpy.data.meshes):
        bpy.data.meshes.remove(mesh)
    scene = bpy.context.scene
    scene.unit_settings.system = 'METRIC'
    scene.unit_settings.scale_length = 0.01
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'
    scene.display.shading.color_type = 'MATERIAL'
    scene.display.shading.show_cavity = True
    scene.render.resolution_x, scene.render.resolution_y = SIZE
    scene.render.film_transparent = False
    scene.world = scene.world or bpy.data.worlds.new('World')
    scene.display.shading.background_type = 'VIEWPORT'
    scene.display.shading.background_color = (0.08, 0.09, 0.11)
    return scene


def render(key, zone, out):
    psk = export_file('SkeletalMesh3', zone['mesh'], '.psk')
    if not psk:
        return f'{key}: no rig export'
    scene = reset_scene()
    bones, names = rig_geometry(psk)[:2]
    bind = frames(bones, names)
    root = zone.get('root') or 'RW_Weapon'
    if root not in bind:
        return f'{key}: root {root} not in rig'
    to_root = bind[root].inverted()
    gun = gun_mesh(psk, to_root)
    for part, kind in (('mag', 'ammo'), ('well', 'ammo'), ('slide', 'action')):
        bone = zone.get('glow_' + part, 'none').split('!')[0]
        if bone in ('none', '') or bone not in bind:
            continue
        shell(f"VRGlow{part.capitalize()}_{zone['mesh']}", to_root @ bind[bone], kind)
    entry, seat = rig_vector(zone['entry']), rig_vector(zone['seat'])
    ring_at = rig_vector(zone.get('ring', zone['entry']))
    # Cylinder and hinged-barrel paths are sampled in that part's own frame.
    frame = zone.get('frame', 'None')
    if frame not in ('None', '') and frame in bind:
        to_frame = to_root @ bind[frame]
        entry, seat, ring_at = to_frame @ entry, to_frame @ seat, to_frame @ ring_at
    if zone.get('status') == 'sampled':
        segment('path', entry, seat, 0.2, 'path')
        # VRInteractiveReload.AmmoRingLocal; the ghost and the seated ammo
        # end at the seat.
        ring('entry', ring_at, seat - entry if (seat - entry).length > 1e-3 else (0, 0, 1), 3.0, 'ammo')
        bpy.ops.mesh.primitive_uv_sphere_add(radius=0.6, location=seat)
        bpy.context.object.data.materials.append(material('path'))
        bpy.context.object.show_in_front = True
    if zone.get('rack_sampled') and zone.get('rack_stroke', 0) > 0:
        rest = rig_vector(zone['rack_rest'])
        segment('rack', rest, rest + rig_vector(zone['rack_axis']) * zone['rack_stroke'], 0.35, 'action')
    # Frame the gun and its zones from the player's eye.
    lo = Vector([min(v.co[i] for v in gun.data.vertices) for i in range(3)])
    hi = Vector([max(v.co[i] for v in gun.data.vertices) for i in range(3)])
    focus = (seat + (lo + hi) / 2) / 2 if zone.get('status') == 'sampled' else (lo + hi) / 2
    reach = max((hi - lo).length * 0.95, 24)
    cam_data = bpy.data.cameras.new('eye')
    cam_data.lens = 35
    cam_data.clip_start, cam_data.clip_end = 0.5, 2000
    cam = bpy.data.objects.new('eye', cam_data)
    scene.collection.objects.link(cam)
    cam.location = focus + EYE * reach
    cam.rotation_euler = (focus - cam.location).to_track_quat('-Z', 'Y').to_euler()
    scene.camera = cam
    bpy.ops.object.text_add(location=(0, 0, 0))
    label = bpy.context.object
    label.data.body = key.replace('KFWeap_', '')
    label.data.size = 0.018
    label.parent = cam
    label.location = (-0.24, -0.175, -0.5)
    label.data.materials.append(material('path'))
    scene.render.filepath = str(out / (key.replace('/', '_') + '.png'))
    bpy.ops.render.render(write_still=True)
    return ''


def contact_sheet(paths, out, columns=6):
    import numpy as np
    columns = min(columns, len(paths))
    w, h = SIZE
    rows = math.ceil(len(paths) / columns)
    sheet = np.zeros((rows * h, columns * w, 4), dtype=np.float32)
    for i, path in enumerate(paths):
        img = bpy.data.images.load(str(path))
        pixels = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
        r, c = rows - 1 - i // columns, i % columns
        sheet[r * h:(r + 1) * h, c * w:(c + 1) * w] = pixels
        bpy.data.images.remove(img)
    image = bpy.data.images.new('contact', columns * w, rows * h, alpha=True)
    image.pixels[:] = sheet.ravel()
    image.filepath_raw = str(out / 'contact.png')
    image.file_format = 'PNG'
    image.save()


def main():
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument('--zones', type=Path, default=ROOT / 'tools/reload-zone-baseline.json')
    parser.add_argument('--out', type=Path, default=ROOT / 'build/reload-zone-renders')
    parser.add_argument('--start', default='empty', help='empty, partial or all')
    parser.add_argument('--props', type=Path, default=PROPS, help='hint shell FBX folder (generate_reload_props --out)')
    parser.add_argument('classes', nargs='*')
    args = parser.parse_args(argv)
    global props_dir
    props_dir = args.props
    zones = json.loads(args.zones.read_text(encoding='utf-8'))
    args.out.mkdir(parents=True, exist_ok=True)
    rendered, skipped = [], []
    for key in sorted(zones):
        weapon, start = key.split('/')
        if args.classes and weapon not in args.classes:
            continue
        if args.start != 'all' and start != args.start:
            continue
        problem = render(key, zones[key], args.out)
        if problem:
            skipped.append(problem)
        else:
            rendered.append(args.out / (key.replace('/', '_') + '.png'))
    if rendered:
        contact_sheet(rendered, args.out)
    print(f'RELOAD_ZONE_RENDERS rendered={len(rendered)} skipped={len(skipped)} out={args.out}')
    for line in skipped:
        print('  skipped ' + line)


if __name__ == '__main__':
    main()
