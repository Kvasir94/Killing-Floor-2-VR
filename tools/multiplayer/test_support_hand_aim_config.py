"""Physical-stock preference defaults and cross-mode profile persistence."""
from pathlib import Path
import tempfile
import unittest

from session import read_ini, set_ini
import vr_config


class SupportHandAimConfigTests(unittest.TestCase):
    bridge = "KF2VR.VRHandsBridge"
    key = "bDisableSupportHandAim"

    def test_missing_key_preserves_support_hand_alignment(self):
        for saved in ("", f"[{self.bridge}]\nPreferredWeaponHand=0\n"):
            text = vr_config.apply_preferences("", saved)
            for section in (self.bridge, vr_config.ALIASES[self.bridge]):
                self.assertEqual("False", vr_config.values(text, section)[self.key])

    def test_invalid_value_falls_back_to_existing_alignment(self):
        text = vr_config.apply_preferences("", f"[{self.bridge}]\n{self.key}=invalid\n")
        for section in (self.bridge, vr_config.ALIASES[self.bridge]):
            self.assertEqual("False", vr_config.values(text, section)[self.key])

    def test_each_mode_saves_choice_for_both_primary_hands_and_other_mode(self):
        for network in (False, True):
            for primary_hand in (0, 1):
                with self.subTest(network=network, primary_hand=primary_hand):
                    with tempfile.TemporaryDirectory() as tmp:
                        root = Path(tmp)
                        config = root / "Config"
                        config.mkdir()
                        profile = root / "Profile"
                        section = vr_config.ALIASES[self.bridge] if network else self.bridge
                        text = vr_config.apply_preferences("")
                        # Turn the option off and then back on in the selected
                        # mode; the latest saved choice must win on relaunch.
                        for disabled in ("True", "False"):
                            text = set_ini(text, section, {
                                self.key: disabled, "PreferredWeaponHand": str(primary_hand)})
                            (config / "KFGame.ini").write_text(text, encoding="utf-16")
                            vr_config.export_preferences(config, profile, network=network)
                            (config / "KFGame.ini").write_text("", encoding="utf-16")
                            vr_config.import_preferences(config, root=profile)
                            text = read_ini(config / "KFGame.ini")
                            for target in (self.bridge, vr_config.ALIASES[self.bridge]):
                                prefs = vr_config.values(text, target)
                                self.assertEqual(disabled, prefs[self.key])
                                self.assertEqual(str(primary_hand), prefs["PreferredWeaponHand"])


if __name__ == "__main__":
    unittest.main()
