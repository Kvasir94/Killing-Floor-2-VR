"""Run a source asset generator with pinned addon source and factory preferences."""
import bpy
import json
import runpy
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
pins = json.loads((ROOT / 'tools/art-dependency-pins.json').read_text())
cache = ROOT / 'build/art-dependencies'
sys.path[:0] = [str(cache / 'source' / pins['psk_importer']['root']),
               str(cache / 'library'),
               str(ROOT / 'tools'), str(ROOT / 'third_party')]
import io_scene_psk_psa
io_scene_psk_psa.register()
args = sys.argv[sys.argv.index('--') + 1:]
if not args:
    raise RuntimeError('Pass the repository-relative generator after --.')
script = (ROOT / args[0]).resolve()
if not script.is_relative_to(ROOT):
    raise RuntimeError('Generator must be inside this checkout.')
sys.argv = [str(script)] + args[1:]
runpy.run_path(str(script), run_name='__main__')
