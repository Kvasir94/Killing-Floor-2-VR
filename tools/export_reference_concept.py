"""Validate the authoring pair before baking the same concept revision."""
from pathlib import Path
import runpy
ROOT=Path(__file__).resolve().parents[1]
runpy.run_path(str(ROOT/'tools/audit_reference_hands.py'))
runpy.run_path(str(ROOT/'tools/export_reference_hands.py'))
