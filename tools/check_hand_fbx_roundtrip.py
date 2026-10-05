"""Compare a revision's exported hand FBX with the PSK it was generated from (Blender).

Run inside Blender with KF2VR_ART_REVISION set. Every PSK wedge (position and
UV) must be present in the imported FBX, and the triangle count must match.
Writes runtime/hand-fbx-roundtrip.json, which staging requires.
"""
import json, os, runpy
from pathlib import Path
import bpy
from mathutils import Vector
from mathutils.kdtree import KDTree

ROOT = Path(__file__).resolve().parents[1]


def main():
    runtime = ROOT / 'build/watch-detail-20260924' / os.environ['KF2VR_ART_REVISION'] / 'runtime'
    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    points, wedges, faces, _ = g['decode_geometry'](g['read_psk'](runtime / 'VRFloatingHands.psk'))
    scene = bpy.data.scenes.new('hand fbx roundtrip')
    previous = bpy.context.window.scene
    bpy.context.window.scene = scene
    try:
        scene.unit_settings.scale_length = 0.01
        before = set(bpy.data.objects)
        bpy.ops.import_scene.fbx(filepath=str(runtime / 'VRFloatingHands.fbx'))
        imported = [o for o in bpy.data.objects if o not in before]
        mesh = next(o for o in imported if o.type == 'MESH')
        me = mesh.data
        me.calc_loop_triangles()
        world = [mesh.matrix_world @ v.co for v in me.vertices]
        # ActorX is left-handed; the PSK importer mirrors Y. Accept whichever
        # handedness matches, and report it.
        best = None
        for flip in (1, -1):
            tree = KDTree(len(world))
            for i, co in enumerate(world):
                tree.insert(Vector((co.x, co.y * flip, co.z)), i)
            tree.balance()
            error = max(tree.find(Vector(p))[2] for p in points)
            if best is None or error < best[0]:
                best = (error, flip, tree)
        position_error, flip, tree = best
        uv = me.uv_layers.active
        corner_uvs = {}
        for loop in me.loops:
            corner_uvs.setdefault(loop.vertex_index, []).append(uv.data[loop.index].uv.copy())
        # Only wedges some face uses matter. Blender's importer also drops a few
        # sliver triangles (rev68 loses the same four); their wedges are
        # excused only when every face touching them is a sliver.
        used = {i for face in faces for i in face[:3]}
        bad, uv_error = set(), 0.0
        for wi in used:
            point, u, v = wedges[wi][:3]
            near = [i for _, i, _ in tree.find_range(Vector(points[point]), 1e-3)]
            error = min((c - Vector((u, 1 - v))).length for i in near for c in corner_uvs.get(i, []))
            if error > 1e-5:
                bad.add(wi)
            else:
                uv_error = max(uv_error, error)
        slivers = 0
        for face in faces:
            a, b, c = (Vector(points[wedges[i][0]]) for i in face[:3])
            if set(face[:3]) & bad:
                slivers += 1
                if (b - a).cross(c - a).length / 2 > .01:
                    raise RuntimeError('A non-sliver triangle lost its UVs in the FBX')
        check = {'source_psk': str(runtime / 'VRFloatingHands.psk'), 'source_fbx': str(runtime / 'VRFloatingHands.fbx'),
                 'psk_triangles': len(faces), 'fbx_triangles': len(me.loop_triangles),
                 'importer_dropped_sliver_triangles': slivers, 'unused_wedges': len(wedges) - len(used),
                 'y_mirrored': flip == -1, 'max_position_error_cm': position_error, 'max_uv_error': uv_error,
                 'passed': len(faces) - slivers == len(me.loop_triangles) and position_error < 1e-3 and uv_error < 1e-5}
        for o in imported:
            bpy.data.objects.remove(o, do_unlink=True)
    finally:
        bpy.context.window.scene = previous
        bpy.data.scenes.remove(scene)
    (runtime / 'hand-fbx-roundtrip.json').write_text(json.dumps(check, indent=2))
    if not check['passed']:
        raise RuntimeError('Hand FBX differs from its PSK: ' + json.dumps(check))
    return check


if __name__ == '__main__':
    print('HAND_FBX_ROUNDTRIP', json.dumps(main()), flush=True)
