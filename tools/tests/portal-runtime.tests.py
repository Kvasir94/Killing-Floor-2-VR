"""Verify the isolated overlay never mutates live sources or reuses indices."""
import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("portal_overlay", ROOT / "tools/prepare_portal_runtime.py")
OVERLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OVERLAY)


class PortalOverlayTest(unittest.TestCase):
    def test_shared_sources_stay_unchanged_and_new_profiles_append(self):
        originals = {p.name: p.read_bytes() for p in (ROOT / "script/KF2VR/Classes").glob("*.uc")}
        runs = ROOT / "build/portal-script-runs"
        runs.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="overlay-test-", dir=runs) as temporary:
            snapshot = Path(temporary) / "Sources/KF2VR"
            classes = snapshot / "Classes"
            classes.mkdir(parents=True)
            for name, data in originals.items():
                (classes / name).write_bytes(data)
            bridge = classes / "VRHandsBridge.uc"
            text = bridge.read_text()
            anchor = "    JumpBindIndex=-1"
            self.assertEqual(text.count(anchor), 1)
            text = text.replace(anchor, "    WeaponProfiles(31)=(WeaponClassName=FutureWeapon)\n" + anchor)
            bridge.write_text(text)
            OVERLAY.integrate(snapshot)
            result = bridge.read_text()
            self.assertIn("WeaponProfiles(31)=(WeaponClassName=FutureWeapon)", result)
            self.assertIn("WeaponProfiles(34)=(WeaponClassName=VRWeap_PortalGun", result)
            self.assertIn(".UpdateTrackedInput(", result)
            self.assertNotIn("VRWeap_PortalGun(W)", result)
            self.assertIn("VRWeapDef_PortalGun", (classes / "VRStarterLoadout.uc").read_text())
            OVERLAY.integrate(snapshot)
            self.assertEqual(result, bridge.read_text())
        for name, data in originals.items():
            self.assertEqual((ROOT / "script/KF2VR/Classes" / name).read_bytes(), data)

    def test_external_overlay_rejected(self):
        with self.assertRaises(ValueError):
            OVERLAY.integrate(ROOT / "script/KF2VR")

    def test_duplicate_profile_indices_rejected(self):
        text = "WeaponProfiles(2)=A\nWeaponProfiles(2)=B\n"
        with self.assertRaises(ValueError):
            OVERLAY.append_defaults(text, "WeaponProfiles", ["C"])


if __name__ == "__main__":
    unittest.main()
