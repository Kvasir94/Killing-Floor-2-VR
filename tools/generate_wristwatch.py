"""Generate the KF2-VR wrist computer: a chunky field watch on a leather cuff.

Normally driven through the Blender MCP (execute_blender_code runs
``build_wristwatch`` in the live session). Headless fallback:
  & 'C:\\Program Files\\Blender Foundation\\Blender 5.2\\blender.exe' --background --python tools/generate_wristwatch.py

Local frame, centimetres (= Unreal units), origin at the centre of the HUD
screen quad that VRSpatialHUD places on the support wrist:
  -X  out of the screen toward the eyes (palmar direction)
  +Y  across the wrist, along the text
  +Z  toward the elbow, text up
The display quad is 5.6 x 3.8 cm and 0.025 cm thick at X = 0.

Fit: the floating hands are cut at the wrist bone plane. VRSpatialHUD puts
the origin 2.2 cm proximal of that plane and 3.25 cm palmar of the wrist bone,
so the cut sits at Z = -2.2 and the wrist axis at X = WRIST_X. The cuff is a
superellipse sized from VRFloatingHands' wrist cross-section; it overlaps the
heel of the hand by 0.65 cm so the cut never shows, and carries the case.

Material slots (VRHUDPanel tints each with a flat colour of the same order):
  0 blackened gunmetal case   1 display backing / voids   2 ember enamel guards
  3 worn brass fittings       4 oiled leather cuff        5 olive canvas webbing
  6 machined steel bezel
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

MATERIALS = [
    ('WatchCase', (0.05, 0.054, 0.06), 0.85, 0.40),
    ('WatchScreen', (0.004, 0.005, 0.006), 0.0, 0.08),
    ('WatchAccent', (0.62, 0.12, 0.025), 0.0, 0.42),
    ('WatchBrass', (0.52, 0.34, 0.11), 1.0, 0.35),
    ('WatchLeather', (0.10, 0.058, 0.034), 0.0, 0.62),
    ('WatchWebbing', (0.13, 0.12, 0.075), 0.0, 0.88),
    ('WatchSteel', (0.33, 0.34, 0.35), 1.0, 0.28),
]
CASE, SCREEN, ACCENT, BRASS, LEATHER, WEBBING, STEEL = range(7)

# Screen quad and aperture.
QUAD_W, QUAD_H = 5.6, 3.8
APERTURE_W, APERTURE_H = 5.72, 3.92

# Wrist cross-section measured from VRFloatingHands (left wrist, hand-bone
# frame): 7.0 cm across, 5.15 cm palmar-dorsal, centred 3.66 cm behind the
# screen when the screen is 3.25 cm palmar of the bone.
WRIST_X = 3.66
CUFF_A, CUFF_B, CUFF_N = 3.95, 2.72, 2.8     # inner superellipse semi-axes (Y, X)
CUFF_DISTAL, CUFF_PROXIMAL = -2.85, 3.0      # Z extent; the hand cut is at -2.2
CUFF_THICK = 0.32
WRIST_CUT_Z = -2.2


def superellipse(theta: float, a: float, b: float, n: float = CUFF_N):
    c, s = math.cos(theta), math.sin(theta)
    y = a * math.copysign(abs(c) ** (2.0 / n), c)
    x = b * math.copysign(abs(s) ** (2.0 / n), s)
    # +sin is the palmar side, i.e. toward -X from the wrist axis.
    return y, WRIST_X - x


def rrect(w: float, h: float, r: float, seg: int = 5):
    pts = []
    corners = ((w / 2 - r, -h / 2 + r, -90), (w / 2 - r, h / 2 - r, 0),
               (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180))
    for cy, cz, a0 in corners:
        for i in range(seg + 1):
            a = math.radians(a0 + 90 * i / seg)
            pts.append((cy + r * math.cos(a), cz + r * math.sin(a)))
    return pts


class Builder:
    def __init__(self, bm):
        self.bm = bm
        self.parts = []   # (faces, closed) for normal recalculation

    def quad_strip(self, rows, mats, closed_rows=True, closed_cols=True):
        """rows: list of vertex rings. mats: material per row gap."""
        faces = []
        nr, nc = len(rows), len(rows[0])
        for i in range(nr if closed_rows else nr - 1):
            ra, rb = rows[i], rows[(i + 1) % nr]
            m = mats[i] if isinstance(mats, (list, tuple)) else mats
            for j in range(nc if closed_cols else nc - 1):
                k = (j + 1) % nc
                f = self.bm.faces.new((ra[j], ra[k], rb[k], rb[j]))
                f.material_index = m
                faces.append(f)
        return faces

    def cap(self, ring, mat):
        f = self.bm.faces.new(ring)
        f.material_index = mat
        return f

    def stack_x(self, rings, mats, center=(0.0, 0.0), seg=5, cap_first=None, cap_last=None):
        """Loft rounded rectangles along X. rings: (x, w, h, r[, y offset])."""
        cy, cz = center
        verts = []
        for ring in rings:
            x, w, h, r = ring[:4]
            dy = ring[4] if len(ring) > 4 else 0.0
            verts.append([self.bm.verts.new((x, cy + dy + y, cz + z)) for y, z in rrect(w, h, r, seg)])
        faces = self.quad_strip(verts, mats, closed_rows=False)
        if cap_first is not None:
            faces.append(self.cap(verts[0], cap_first))
        if cap_last is not None:
            faces.append(self.cap(verts[-1], cap_last))
        self.parts.append(faces)
        return verts, faces

    def sweep_cuff(self, profile, mat, count=72):
        """Sweep a closed (offset, z) profile around the wrist superellipse."""
        rows = []
        for i in range(count):
            t = 2 * math.pi * i / count
            ring = []
            for s, z in profile:
                y, x = superellipse(t, CUFF_A + s, CUFF_B + s)
                ring.append(self.bm.verts.new((x, y, z)))
            rows.append(ring)
        faces = self.quad_strip(rows, mat)
        self.parts.append(faces)
        return faces

    def cylinder(self, center, axis, radius, depth, mat, segments=12, radii=None, bevel=0.0):
        """Closed cylinder along a unit axis ('X', 'Y' or 'Z'), optional per-vertex radii."""
        from mathutils import Vector
        ax = {'X': Vector((1, 0, 0)), 'Y': Vector((0, 1, 0)), 'Z': Vector((0, 0, 1))}[axis]
        u = Vector((0, 1, 0)) if axis != 'Y' else Vector((0, 0, 1))
        v = ax.cross(u)
        c = Vector(center)
        profile = [(-depth / 2, 1.0), (depth / 2 - bevel, 1.0)]
        if bevel > 0:
            profile.append((depth / 2, 1.0 - bevel / radius))
        rings = []
        for h, scale in profile:
            ring = []
            for i in range(segments):
                a = 2 * math.pi * i / segments
                r = (radii[i] if radii else radius) * scale
                ring.append(self.bm.verts.new(c + ax * h + (u * math.cos(a) + v * math.sin(a)) * r))
            rings.append(ring)
        faces = self.quad_strip(rings, mat, closed_rows=False)
        faces.append(self.cap(rings[0], mat))
        faces.append(self.cap(rings[-1], mat))
        self.parts.append(faces)
        return faces

    def box(self, matrix, size, mat):
        """Box of size (sx, sy, sz) transformed by a 4x4 matrix."""
        import bmesh
        from mathutils import Matrix
        res = bmesh.ops.create_cube(self.bm, size=1.0)
        bmesh.ops.transform(self.bm, matrix=matrix @ Matrix.Diagonal((*size, 1.0)), verts=res['verts'])
        faces = list({f for v in res['verts'] for f in v.link_faces})
        for f in faces:
            f.material_index = mat
        self.parts.append(faces)
        return faces

    def prism(self, outline, x0, x1, mat):
        """Extrude a convex (y, z) outline from X=x0 (back) to X=x1 (front)."""
        back = [self.bm.verts.new((x0, y, z)) for y, z in outline]
        front = [self.bm.verts.new((x1, y, z)) for y, z in outline]
        faces = self.quad_strip([back, front], mat, closed_rows=False)
        faces.append(self.cap(back, mat))
        faces.append(self.cap(front, mat))
        self.parts.append(faces)
        return faces


def cuff_frame(theta: float, s: float):
    """Surface point, outward normal and tangent of the cuff at theta, offset s."""
    from mathutils import Vector
    y0, x0 = superellipse(theta, CUFF_A + s, CUFF_B + s)
    y1, x1 = superellipse(theta + 1e-3, CUFF_A + s, CUFF_B + s)
    p = Vector((x0, y0, 0.0))
    tangent = (Vector((x1, y1, 0.0)) - p).normalized()
    normal = tangent.cross(Vector((0, 0, 1)))
    if normal.dot(p - Vector((WRIST_X, 0, 0))) < 0:
        normal = -normal
    return p, normal, tangent


def build_geometry(bm):
    import bmesh
    from mathutils import Matrix, Vector
    b = Builder(bm)

    # 1. Leather cuff with rolled welts at both ends.
    zd, zp = CUFF_DISTAL, CUFF_PROXIMAL
    t = CUFF_THICK
    welt = t + 0.1
    cuff_profile = [
        (0.0, zd + 0.05), (0.0, zp - 0.05), (0.08, zp), (t - 0.02, zp), (welt, zp - 0.10),
        (welt, zp - 0.42), (t, zp - 0.50), (t, zd + 0.50), (welt, zd + 0.42),
        (welt, zd + 0.10), (t - 0.02, zd), (0.08, zd),
    ]
    b.sweep_cuff(cuff_profile, LEATHER)

    # Dark interior of the open sleeve end, facing the elbow.
    void_z = zp - 0.7
    ring = []
    for i in range(48):
        y, x = superellipse(2 * math.pi * i / 48, CUFF_A - 0.02, CUFF_B - 0.02)
        ring.append(bm.verts.new((x, y, void_z)))
    void = b.cap(ring, SCREEN)
    void.normal_update()
    if void.normal.z < 0:
        void.normal_flip()

    # Brass rivets in each welt.
    for z in (zp - 0.26, zd + 0.26):
        for i in range(10):
            theta = 2 * math.pi * (i + 0.5) / 10
            p, n, tan = cuff_frame(theta, welt)
            p.z = z
            axis_m = Matrix((tan, Vector((0, 0, 1)), n)).transposed().to_4x4()
            axis_m.translation = p + n * 0.03
            res = bmesh.ops.create_uvsphere(bm, u_segments=8, v_segments=4, radius=0.11)
            bmesh.ops.transform(bm, matrix=axis_m @ Matrix.Diagonal((1, 1, 0.55, 1)), verts=res['verts'])
            faces = list({f for v in res['verts'] for f in v.link_faces})
            for f in faces:
                f.material_index = BRASS
            b.parts.append(faces)

    # 2. Canvas webbing strap around the cuff.
    strap_half = 1.25
    so, st = t, t + 0.18
    strap_profile = [(so, -strap_half), (so, strap_half), (st - 0.04, strap_half),
                     (st, strap_half - 0.04), (st, -strap_half + 0.04), (st - 0.04, -strap_half)]
    b.sweep_cuff(strap_profile, WEBBING)

    # Brass buckle on the -Y side of the strap.
    theta = math.pi
    p, n, tan = cuff_frame(theta, st)
    frame = Matrix((tan, Vector((0, 0, 1)), n)).transposed().to_4x4()
    frame.translation = p + n * 0.07
    bw, bh, bar = 1.3, 3.1, 0.22
    for off, size in (((0, bh / 2 - bar / 2, 0), (bw, bar, 0.14)),
                      ((0, -bh / 2 + bar / 2, 0), (bw, bar, 0.14)),
                      ((bw / 2 - bar / 2, 0, 0), (bar, bh, 0.14)),
                      ((-bw / 2 + bar / 2, 0, 0), (bar, bh, 0.14))):
        b.box(frame @ Matrix.Translation(off), size, BRASS)
    b.box(frame @ Matrix.Translation((0.05, 0, 0.03)), (0.12, bh - 0.3, 0.12), STEEL)   # prong bar
    b.box(frame @ Matrix.Translation((-1.25, 0, 0.0)), (0.55, 2.7, 0.2), LEATHER)       # keeper

    # 3. Case: skirt into the cuff, walls, deck, raised steel bezel, screen well.
    case_rings = [
        (1.55, 6.3, 4.9, 0.9),
        (0.55, 7.0, 5.7, 1.2),
        (-0.05, 7.0, 5.7, 1.2),
        (-0.15, 6.8, 5.5, 1.1),
        (-0.15, 6.3, 4.62, 0.85),
        (-0.34, 6.3, 4.62, 0.85),
        (-0.42, 6.14, 4.46, 0.77),
        (-0.42, 5.98, 4.30, 0.62),
        (-0.10, APERTURE_W, APERTURE_H, 0.40),
        (0.04, APERTURE_W, APERTURE_H, 0.40),
    ]
    case_mats = [CASE, CASE, CASE, CASE, STEEL, STEEL, STEEL, STEEL, CASE]
    verts, faces = b.stack_x(case_rings, case_mats, seg=6, cap_first=CASE, cap_last=SCREEN)
    screen_face = faces[-1]

    # 4. Ember enamel side guards with brass bolts.
    # Each guard leans in toward the bezel and is chamfered on top.
    for side in (-1, 1):
        rings = [(1.45, 0.95, 5.0, 0.40, 3.62), (0.20, 0.95, 5.0, 0.40, 3.62),
                 (-0.42, 0.78, 4.7, 0.34, 3.55), (-0.56, 0.56, 4.4, 0.24, 3.52)]
        rings = [(x, w, h, r, side * dy) for x, w, h, r, dy in rings]
        b.stack_x(rings, ACCENT, seg=4, cap_first=ACCENT, cap_last=ACCENT)
        cy = side * 3.52
        for z in (-1.65, 1.65):
            b.cylinder((-0.60, cy, z), 'X', 0.17, 0.12, BRASS, segments=6)
        # Grip ribs between the bolts.
        for z in (-0.5, 0.0, 0.5):
            b.box(Matrix.Translation((-0.58, cy, z)), (0.08, 0.42, 0.14), CASE)

    # Knurled brass crown (+Y) and steel pushers (-Y) on the guards' outer walls.
    radii = [0.38 if i % 2 == 0 else 0.33 for i in range(24)]
    b.cylinder((0.35, 4.33, 0.0), 'Y', 0.38, 0.5, BRASS, segments=24, radii=radii, bevel=0.06)
    b.cylinder((0.35, 4.08, 0.0), 'Y', 0.18, 0.3, STEEL, segments=10)
    for z in (-1.35, 1.35):
        b.cylinder((0.35, -4.22, z), 'Y', 0.24, 0.36, STEEL, segments=12, bevel=0.05)
        b.cylinder((0.35, -4.06, z), 'Y', 0.29, 0.12, CASE, segments=12)

    # 5. Deck details. Top (+Z, toward the elbow): screws, nameplate, hex badge, lamp.
    deck_x = -0.15
    for y in (-2.55, 2.55):
        for z in (-2.57, 2.57):
            b.cylinder((deck_x - 0.04, y, z), 'X', 0.15, 0.1, BRASS, segments=6)
    b.box(Matrix.Translation((deck_x - 0.03, -0.35, 2.58)), (0.07, 2.6, 0.34), STEEL)
    hexagon = [(0.19 * math.cos(math.radians(60 * i + 30)) + 1.3,
                0.19 * math.sin(math.radians(60 * i + 30)) + 2.58) for i in range(6)]
    b.prism(hexagon, deck_x + 0.02, deck_x - 0.12, BRASS)
    b.cylinder((deck_x - 0.05, 1.85, 2.58), 'X', 0.12, 0.12, ACCENT, segments=10)

    # Bottom (-Z): KF2 hazard chevrons in ember on the gunmetal deck.
    for i in range(-3, 4):
        yc = i * 0.62
        slant = [(yc - 0.28, -2.74), (yc - 0.02, -2.74), (yc + 0.28, -2.42), (yc + 0.02, -2.42)]
        b.prism(slant, deck_x + 0.02, deck_x - 0.05, ACCENT)

    return b, screen_face


def assign_uvs(bm, screen_face):
    uv = bm.loops.layers.uv.new('UVMap')
    for f in bm.faces:
        n = f.normal
        axis = max(range(3), key=lambda i: abs(n[i]))
        for loop in f.loops:
            co = loop.vert.co
            if f is screen_face:
                loop[uv].uv = ((co.y + APERTURE_W / 2) / APERTURE_W, (APERTURE_H / 2 - co.z) / APERTURE_H)
                continue
            a, c = [(1, 2), (0, 2), (0, 1)][axis]
            loop[uv].uv = (co[a] / 12.0 + 0.5, co[c] / 12.0 + 0.5)


def build_wristwatch(name: str = 'VRWristwatch'):
    """Build the watch object in the current scene (replacing one of the same name)."""
    import bpy
    import bmesh

    old = bpy.data.objects.get(name)
    if old is not None:
        bpy.data.objects.remove(old)
    old_mesh = bpy.data.meshes.get(name)
    if old_mesh is not None:
        bpy.data.meshes.remove(old_mesh)

    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    for mname, color, metallic, roughness in MATERIALS:
        mat = bpy.data.materials.get(mname) or bpy.data.materials.new(mname)
        mat.diffuse_color = (*color, 1.0)
        bsdf = mat.node_tree.nodes.get('Principled BSDF') if mat.node_tree else None
        if bsdf is None:
            try:
                mat.use_nodes = True
                bsdf = mat.node_tree.nodes.get('Principled BSDF')
            except Exception:
                bsdf = None
        if bsdf is not None:
            bsdf.inputs['Base Color'].default_value = (*color, 1.0)
            bsdf.inputs['Metallic'].default_value = metallic
            bsdf.inputs['Roughness'].default_value = roughness
        mesh.materials.append(mat)

    bm = bmesh.new()
    builder, screen_face = build_geometry(bm)
    for faces in builder.parts:
        live = [f for f in faces if f.is_valid]
        if live:
            bmesh.ops.recalc_face_normals(bm, faces=live)
    screen_face.normal_update()
    if screen_face.normal.x > 0:
        screen_face.normal_flip()
    assign_uvs(bm, screen_face)

    for f in bm.faces:
        f.smooth = True
    for e in bm.edges:
        e.smooth = len(e.link_faces) == 2 and e.calc_face_angle(math.pi) < math.radians(40)
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    return obj


def export_wristwatch(obj, output_fbx: Path, output_blend: Path | None = None) -> dict:
    import bpy
    scene = bpy.context.scene
    scene.unit_settings.system = 'METRIC'
    scene.unit_settings.scale_length = 0.01
    scene.unit_settings.length_unit = 'CENTIMETERS'
    output_fbx.parent.mkdir(parents=True, exist_ok=True)
    for o in bpy.context.view_layer.objects:
        o.select_set(o == obj)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.fbx(
        filepath=str(output_fbx), use_selection=True, global_scale=1.0,
        axis_forward='-X', axis_up='Z', apply_unit_scale=True,
        apply_scale_options='FBX_SCALE_UNITS', bake_space_transform=False,
        mesh_smooth_type='EDGE', add_leaf_bones=False, bake_anim=False,
        use_mesh_modifiers=False, object_types={'MESH'})
    if output_blend:
        output_blend.parent.mkdir(parents=True, exist_ok=True)
        bpy.data.libraries.write(str(output_blend), {obj}, fake_user=True)

    data = output_fbx.read_bytes()
    mesh = obj.data
    co = [v.co for v in mesh.vertices]
    tris = sum(len(p.vertices) - 2 for p in mesh.polygons)
    per_slot = [0] * len(MATERIALS)
    for p in mesh.polygons:
        per_slot[p.material_index] += 1
    return {
        'generator': 'tools/generate_wristwatch.py',
        'output_fbx': str(output_fbx),
        'fbx_sha256': hashlib.sha256(data).hexdigest(),
        'fbx_size_bytes': len(data),
        'vertices': len(mesh.vertices),
        'faces': len(mesh.polygons),
        'triangles': tris,
        'material_slots': [m[0] for m in MATERIALS],
        'faces_per_slot': per_slot,
        'bounds_min': [min(v[i] for v in co) for i in range(3)],
        'bounds_max': [max(v[i] for v in co) for i in range(3)],
        'screen_quad_cm': [QUAD_W, QUAD_H],
        'aperture_cm': [APERTURE_W, APERTURE_H],
        'wrist_axis_x_cm': WRIST_X,
        'cuff_inner_semi_axes_cm': [CUFF_A, CUFF_B],
        'cuff_z_cm': [CUFF_DISTAL, CUFF_PROXIMAL],
    }


def main():
    import bpy
    parser = argparse.ArgumentParser(description='Generate the KF2-VR wristwatch FBX.')
    parser.add_argument('--fbx', default='build/hand-meshes/VRWristwatch.fbx')
    parser.add_argument('--blend', default='build/hand-meshes/VRWristwatch.blend')
    parser.add_argument('--report', default='build/hand-meshes/VRWristwatch.json')
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    obj = build_wristwatch()
    summary = export_wristwatch(obj, root / args.fbx, root / args.blend if args.blend else None)
    (root / args.report).write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(f"Generated wristwatch: {summary['output_fbx']} ({summary['triangles']} tris)")


if __name__ == '__main__':
    main()
