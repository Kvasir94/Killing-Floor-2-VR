"""Cut whole-tool hologram shells from stock 1P rigs for world tool offers.

Run with Blender (headless is fine):
  & 'C:\\Program Files\\Blender Foundation\\Blender 5.2\\blender.exe' --background \
      --python tools/generate_tool_holograms.py

Writes build/hand-meshes/VRGlowTool_<rig>.fbx: every face of the rig as one
single-section shell in the RW_Weapon bone frame, the same construction as the
reload-hint shells (generate_reload_props.py). VRDoorWelding draws it with the
reload hint ring material as the grabbable welder at a door. tools/
build-hand-assets.ps1 imports it through its existing VRGlow*_*.fbx glob.
"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_reload_props import (SHELL_OFFSET, bind_frames, build_ammo_object,  # noqa: E402
                                   export_static, rig_geometry, sha256)

# A hologram needs the silhouette, not the rig's detail: the full two-way
# shell is 26k triangles for a translucent prop drawn at every door.
TARGET_TRIANGLES = 6000

RIGS = ('build/welder-audit/export/WEP_1P_Welder_MESH/SkeletalMesh3/Wep_1stP_Welder_Rig.psk',)


def cut_tool(psk_path):
    bones, names, points, wedges, faces, _owner = rig_geometry(psk_path)
    positions, rotations = bind_frames(bones)
    frame = names.index('RW_Weapon')
    return {'kind': 'Tool', 'bone': 'RW_Weapon', 'points': points, 'wedges': wedges,
            'faces': faces, 'origin': positions[frame], 'rotation': rotations[frame]}


def decimate(obj):
    import bpy
    triangles = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    if triangles <= TARGET_TRIANGLES:
        return obj
    modifier = obj.modifiers.new('Hologram', 'DECIMATE')
    modifier.ratio = TARGET_TRIANGLES / triangles
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    return obj


def main():
    root = Path(__file__).resolve().parents[1]
    out = root / 'build/hand-meshes'
    # This is a build input, not a prerequisite manual audit. Export the stock
    # tool when a clean checkout has no cached rig.
    for rig in RIGS:
        source = root / rig
        if not source.is_file():
            export_root = source.parents[2]
            subprocess.run([
                'umodel.exe', '-export', '-notex',
                '-out=' + str(export_root),
                '-path=D:/SteamLibrary/steamapps/common/killingfloor2/KFGame/BrewedPC',
                source.parents[1].name, source.stem,
            ], check=True)
            if not source.is_file():
                raise FileNotFoundError(source)
    cuts = [(root / r, cut_tool(root / r)) for r in RIGS]
    import bpy
    bpy.ops.wm.read_factory_settings(use_empty=True)
    report = {'generator': 'tools/generate_tool_holograms.py', 'generator_sha256': sha256(__file__), 'props': {}}
    for rig, cut in cuts:
        name = 'VRGlowTool_' + rig.stem
        summary = export_static(decimate(build_ammo_object(name, cut, SHELL_OFFSET)), out / (name + '.fbx'))
        summary.update({'source_psk': str(rig), 'source_psk_sha256': sha256(rig),
                        'provenance': 'stock KF2 tool rig; whole-tool hologram shell in the RW_Weapon frame'})
        report['props'][name] = summary
        print(f"{name}: {summary['triangles']} tris bounds {summary['bounds_min']}..{summary['bounds_max']}")
    (out / 'VRToolHolograms.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    return 0


if __name__ == '__main__':
    result = main()
    if result:
        raise SystemExit(result)
