"""Regenerate the authored glove/watch from public generators and local KF2 inputs.

Run through blender_build_runner.py. This route creates its own authoring scene
instead of consuming an ignored developer scene or historical hand baseline.
"""
import bpy
import json
import os
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/hand-meshes'
revision = 59
if (OUT / 'VRFloatingHands.fbx').exists():
    raise RuntimeError('Hand output already exists; preserve it and use a clean checkout.')
OUT.mkdir(parents=True, exist_ok=True)
generated = runpy.run_path(str(ROOT / 'tools/build_reference_hands.py'),
                           init_globals={'REVISION': revision}, run_name='public_hand_authoring')
authoring = ROOT / 'build/hand-redesign-20260924' / f'{revision:02d}-horzine-study.blend'
bpy.ops.wm.save_as_mainfile(filepath=str(authoring))
runpy.run_path(str(ROOT / 'tools/rig_reference_hands.py'))
os.environ['KF2VR_ART_REVISION'] = str(revision)
os.environ['KF2VR_ART_EXPORT_DIR'] = str(OUT)
runpy.run_path(str(ROOT / 'tools/export_reference_hands.py'))
display = runpy.run_path(str(ROOT / 'tools/generate_watch_glass.py'))
display['generate'](OUT / 'VRHorzineWatchGlass.tga')
display['generate_glow'](OUT / 'VRHorzineWatchGlow.tga')
runpy.run_path(str(ROOT / 'tools/build_watch_font.py'))
font = ROOT / 'build/hand-redesign-20260924/runtime/VRHorzineWatchFont.tga'
import shutil
shutil.copy2(font, OUT / font.name)
print('Public-source hand/watch generation ready:', OUT, flush=True)
