"""Exercise the actual combined registration in an isolated snapshot."""
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from prepare_combined_runtime import integrate


class CombinedRegistrationTest(unittest.TestCase):
    def test_registration(self):
        runs = ROOT / "build/combined-script-runs"
        runs.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="registration-test-", dir=runs) as temporary:
            self.assertTrue(Path(temporary).resolve().is_relative_to(runs.resolve()))
            snapshot = Path(temporary) / "Sources/KF2VR"
            classes = snapshot / "Classes"
            classes.mkdir(parents=True)
            for source in (ROOT / "script/KF2VR/Classes").glob("*.uc"):
                (classes / source.name).write_bytes(source.read_bytes())
            for name in ("VREngineerMutator", "VRPortedTraderRegistry"):
                source = ROOT / f"script/EngineerStaging/Classes/{name}.uc"
                (classes / source.name).write_bytes(source.read_bytes())
            integrate(snapshot)
            bridge = (classes / "VRHandsBridge.uc").read_text()
            loadout = (classes / "VRStarterLoadout.uc").read_text()
            for stock in ("KFWeap_AssaultRifle_SCAR", "KFWeap_AssaultRifle_AK12", "KFWeap_Revolver_SW500", "KFWeap_Flame_Flamethrower", "KFWeap_Rifle_M14EBR"):
                self.assertIn(stock, bridge)
            self.assertIn("class'KFWeapDef_Flamethrower'", loadout)
            self.assertIn("class'KFWeapDef_M14EBR'", loadout)
            self.assertIn("class'VRSourceWeapon'", loadout)
            self.assertTrue((snapshot / "Localization/INT/KF2VR.int").is_file())


if __name__ == "__main__":
    unittest.main()
