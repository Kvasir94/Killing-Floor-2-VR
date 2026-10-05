"""Rig, audit and bake one preserved watch iteration into its own runtime folder."""
import os, runpy, shutil
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
rev=int(os.environ['KF2VR_ART_REVISION'])
OUT=ROOT/'build/watch-detail-20260924'/str(rev)/'runtime'
OUT.mkdir(parents=True,exist_ok=True)
(OUT/'source').mkdir(exist_ok=True)
for name in ['export_watch_detail.py','export_reference_hands.py','rig_reference_hands.py','audit_reference_hands.py','generate_watch_glass.py']:
    shutil.copy2(ROOT/'tools'/name,OUT/'source'/name)
os.environ['KF2VR_ART_EXPORT_DIR']=str(OUT)
runpy.run_path(str(ROOT/'tools/rig_reference_hands.py'))
runpy.run_path(str(ROOT/'tools/audit_reference_hands.py'))
runpy.run_path(str(ROOT/'tools/export_reference_hands.py'))
display=runpy.run_path(str(ROOT/'tools/generate_watch_glass.py'))
display['generate'](OUT/'VRHorzineWatchGlass.tga')
display['generate_glow'](OUT/'VRHorzineWatchGlow.tga')
