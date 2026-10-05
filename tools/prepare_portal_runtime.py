"""Register Source weapons and the Portal Gun in an isolated compiler snapshot."""
from pathlib import Path
import argparse
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("source_runtime_overlay", ROOT / "tools/prepare_source_runtime.py")
_source = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_source)
append_defaults = _source.append_defaults


def integrate(snapshot):
    snapshot = Path(snapshot).resolve()
    allowed = (ROOT / "build/portal-script-runs", ROOT / "build/combined-script-runs")
    if not any(snapshot.is_relative_to(path.resolve()) for path in allowed) or snapshot.name != "KF2VR":
        raise ValueError("Portal runtime overlay must stay in its isolated build directory")
    _source.integrate(snapshot)
    classes = snapshot / "Classes"
    bridge = classes / "VRHandsBridge.uc"
    loadout = classes / "VRStarterLoadout.uc"
    # All tracking, input and mesh preparation stay in the item's generic
    # presentation callbacks. This overlay changes registration only.
    bridge.write_text(append_defaults(bridge.read_text(), "WeaponProfiles", [
        "(WeaponClassName=VRWeap_PortalGun,RootBone=RW_Weapon,IdleAnimation=Portal_idle,SupportBone=RW_Weapon,MuzzleSocket=MuzzleFlash,bFirearm=true)"
    ]))
    loadout.write_text(append_defaults(loadout.read_text(), "Definitions", ["class'VRWeapDef_PortalGun'"]))
    print("Registered Portal Gun in", snapshot)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    integrate(parser.parse_args().snapshot)
