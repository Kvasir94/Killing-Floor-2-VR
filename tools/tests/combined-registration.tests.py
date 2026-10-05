"""Exercise both actual combined registration modes in isolated snapshots."""
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from prepare_combined_runtime import integrate


class CombinedRegistrationTest(unittest.TestCase):
    def check_mode(self, enabled):
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
            integrate(snapshot, enable_portals=enabled)
            bridge = (classes / "VRHandsBridge.uc").read_text()
            loadout = (classes / "VRStarterLoadout.uc").read_text()
            trader = (classes / "VRPortedTraderRegistry.uc").read_text()
            self.assertEqual("WeaponClassName=VRWeap_PortalGun" in bridge, enabled)
            self.assertEqual("class'VRWeapDef_PortalGun'" in loadout, enabled)
            self.assertEqual('"KF2VR.VRWeapDef_PortalGun"' in trader, enabled)
            for stock in ("KFWeap_AssaultRifle_SCAR", "KFWeap_AssaultRifle_AK12", "KFWeap_Revolver_SW500", "KFWeap_Flame_Flamethrower", "KFWeap_Rifle_M14EBR"):
                self.assertIn(stock, bridge)
            self.assertIn("class'KFWeapDef_Flamethrower'", loadout)
            self.assertIn("class'KFWeapDef_M14EBR'", loadout)
            self.assertIn("class'VRSourceWeapon'", loadout)
            self.assertTrue((snapshot / "Localization/INT/KF2VR.int").is_file())

    def test_portals_disabled(self):
        self.check_mode(False)

    def test_explicit_portal_opt_in(self):
        self.check_mode(True)


if __name__ == "__main__":
    unittest.main()
