"""Export complete stock knife geometry for VR-only world props.

The mesh stays in its authored RW_Weapon frame with original UVs and material
slots. Runtime components reuse the stock knife materials. No stock throw flag
or installed asset is changed. --check verifies cached source/output hashes.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_floating_hands import bone_data, decode_geometry
from generate_reload_props import read_psk, bind_frames, build_ammo_object, export_static, sha256

ROOT = Path(__file__).resolve().parents[1]
GAME = Path('D:/SteamLibrary/steamapps/common/killingfloor2/KFGame/BrewedPC')
EXPORT = ROOT / 'build/world-weapon-assets/export'
OUT = ROOT / 'build/hand-meshes'
SCHEMA = 'kf2vr/world-knives/1'
MESHES = {
    'Commando': 'WEP_1P_CommandoKnife_MESH.Wep_1stP_CommKnife_Rig',
    'Gunslinger': 'WEP_1P_Gunslinger_Knife_MESH.Wep_1stP_GunslingerKnife_Rig',
    'Firebug': 'WEP_1P_FireBug_Knife_MESH.Wep_1stP_FirebugKnife_Rig',
    'Survivalist': 'WEP_1P_Survival_Knife_MESH.Wep_1stP_SurvivalKnife_Rig',
    'Sharpshooter': 'WEP_1P_Sharpshooter_Knife_MESH.Wep_1stP_SharpshooterKnife_Rig',
    'Berserker': 'WEP_1P_BerserkerKnife_MESH.Wep_1stP_BerserkerKnife_Rig',
    'Support': 'WEP_1P_SupportKnife_MESH.Wep_1stP_SupportKnife_Rig',
    'FieldMedic': 'Wep_1P_Medic_Knife_MESH.Wep_1stP_Medic_Knife_Rig',
    'SWAT': 'wep_1p_swat_knife_mesh.Wep_1stP_SWAT_Knife_Rig',
    'Demolitionist': 'WEP_1P_Demo_Knife_MESH.Wep_1stP_Demo_Knife_Rig',
}


def inputs():
    packages = {p.name.casefold(): p for p in (GAME / 'Packages/Weapons').glob('*/*.upk')}
    result = []
    for perk, mesh in MESHES.items():
        package, name = mesh.split('.')
        result.append((perk, mesh, packages[(package + '.upk').casefold()],
                       EXPORT / package / 'SkeletalMesh3' / (name + '.psk')))
    return result


def current(rows):
    try:
        report = json.loads((OUT / 'VRWorldKnives.json').read_text())
        if report['schema'] != SCHEMA or report['generator_sha256'] != sha256(__file__):
            return False
        if report['reader_sha256'] != sha256(ROOT / 'tools/generate_floating_hands.py'):
            return False
        if report['exporter_sha256'] != sha256(ROOT / 'tools/generate_reload_props.py'):
            return False
        if set(report['props']) != {'VRWorldKnife' + r[0] for r in rows}:
            return False
        for perk, _, package, source in rows:
            prop = report['props']['VRWorldKnife' + perk]
            if prop['package_sha256'] != sha256(package) or prop['source_sha256'] != sha256(source):
                return False
            if prop['fbx_sha256'] != sha256(OUT / ('VRWorldKnife' + perk + '.fbx')):
                return False
        return True
    except (OSError, KeyError, ValueError, TypeError):
        return False


def prepare(rows, umodel):
    for perk, mesh, package, source in rows:
        # Package provenance is checked too: stale PSKs cannot silently survive
        # an installed game update even when the cached file still exists.
        stamp = source.with_suffix('.source.json')
        signature = sha256(package)
        try:
            unchanged = json.loads(stamp.read_text()) == {'package_sha256': signature, 'psk_sha256': sha256(source)}
        except (OSError, ValueError):
            unchanged = False
        if unchanged:
            continue
        package_name, object_name = mesh.split('.')
        completed = subprocess.run([umodel, '-export', '-notex', '-out=' + str(EXPORT),
                                    '-path=' + str(GAME), package_name, object_name],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        if completed.returncode or not source.is_file():
            raise RuntimeError(completed.stdout.decode(errors='replace'))
        stamp.write_text(json.dumps({'package_sha256': signature, 'psk_sha256': sha256(source)}) + '\n')


def export_knife(obj, path):
    import bpy
    import bmesh
    from mathutils import Vector
    report = export_static(obj, path)
    # Standard UE3 UCX collision supplies the rigid body. Damage still queries
    # the original surface triangles, not this convex world-collision proxy.
    # A small support-point hull is sufficient for world rigid-body motion.
    # Detailed tip/edge damage uses the separate original-triangle catalog.
    points = [v.co.copy() for v in obj.data.vertices]
    selected = []
    for x in (-1,0,1):
        for y in (-1,0,1):
            for z in (-1,0,1):
                if x == y == z == 0:
                    continue
                axis = Vector((x,y,z))
                selected.append(max(points,key=lambda p: p.dot(axis)))
    if obj.name == 'VRWorldKnifeFieldMedic':
        # This very thin mesh's hull is rejected by the pinned cooker. Use
        # one stable box for motion; detailed damage remains on its blade.
        low = [min(p[a] for p in points) for a in range(3)]
        high = [max(p[a] for p in points) for a in range(3)]
        for a in range(3):
            if high[a] - low[a] < 1.0:
                center = (high[a] + low[a]) * .5
                low[a], high[a] = center - .5, center + .5
        selected = [Vector((x,y,z)) for x in (low[0],high[0])
                    for y in (low[1],high[1]) for z in (low[2],high[2])]
    bm = bmesh.new()
    for co in selected:
        bm.verts.new(co)
    bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=.001)
    bmesh.ops.convex_hull(bm,input=list(bm.verts),use_existing_faces=False)
    bmesh.ops.delete(bm,geom=[v for v in bm.verts if not v.link_faces],context='VERTS')
    bm.normal_update()
    if len(bm.verts) > 128 or len(bm.faces) > 252:
        raise ValueError(f'{obj.name}: rigid-body hull exceeds PhysX limits')
    hull_mesh = bpy.data.meshes.new(f'UCX_{obj.name}_00')
    hull = bpy.data.objects.new(hull_mesh.name,hull_mesh)
    bpy.context.scene.collection.objects.link(hull)
    bm.to_mesh(hull_mesh); bm.free()
    hulls = [hull]
    bpy.context.view_layer.update()
    for other in bpy.context.view_layer.objects:
        other.select_set(other == obj or other in hulls)
    result = bpy.ops.export_scene.fbx(
        filepath=str(path), use_selection=True, global_scale=1.0,
        axis_forward='-X', axis_up='Z', apply_unit_scale=True,
        apply_scale_options='FBX_SCALE_UNITS', bake_space_transform=False,
        mesh_smooth_type='EDGE', add_leaf_bones=False, bake_anim=False,
        use_mesh_modifiers=False, object_types={'MESH'})
    if result != {'FINISHED'}:
        raise RuntimeError(f'World-knife collision export failed: {path}')
    report['fbx_sha256'] = sha256(path)
    report['collision'] = 'coarse source support-point convex UCX; original triangles for damage'
    report['collision_vertices'] = [len(h.data.vertices) for h in hulls]
    for hull in hulls:
        mesh = hull.data
        bpy.data.objects.remove(hull, do_unlink=True)
        bpy.data.meshes.remove(mesh)
    return report


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--umodel', default='umodel.exe')
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    args = parser.parse_args(argv)
    rows = inputs()
    if args.check:
        return 0 if current(rows) else 1
    prepare(rows, args.umodel)
    if args.prepare:
        return 0
    import bpy
    props = {}
    for perk, mesh, package, source in rows:
        chunks = read_psk(source)
        bones, names = bone_data(chunks)
        points, wedges, faces, weights = decode_geometry(chunks)
        root = names.index('RW_Weapon')
        if any(abs(w.get(root, 0) - 1) > .0001 or sum(v for b, v in w.items() if b != root) > .0001
               for w in weights):
            raise ValueError(f'{mesh}: world knife contains non-root geometry')
        positions, rotations = bind_frames(bones)
        name = 'VRWorldKnife' + perk
        cut = dict(points=points, wedges=wedges, faces=faces,
                   origin=positions[root], rotation=rotations[root])
        obj = build_ammo_object(name, cut)
        # The SDK static FBX importer reflects Y. Cancel it here so the saved
        # world mesh retains the original RW_Weapon frame used by contact/grips.
        for vertex in obj.data.vertices:
            vertex.co.y = -vertex.co.y
        import bmesh
        bm = bmesh.new(); bm.from_mesh(obj.data)
        bmesh.ops.reverse_faces(bm,faces=list(bm.faces))
        bm.normal_update(); bm.to_mesh(obj.data); bm.free()
        prop = export_knife(obj, OUT / (name + '.fbx'))
        prop.update(mesh=mesh, source=str(source), source_sha256=sha256(source),
                    package=str(package), package_sha256=sha256(package),
                    material_slots=sorted({f[3] for f in faces}), frame='RW_Weapon')
        props[name] = prop
        bpy.data.objects.remove(obj, do_unlink=True)
    report = dict(schema=SCHEMA, generator_sha256=sha256(__file__),
                  reader_sha256=sha256(ROOT / 'tools/generate_floating_hands.py'),
                  exporter_sha256=sha256(ROOT / 'tools/generate_reload_props.py'), props=props)
    (OUT / 'VRWorldKnives.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
