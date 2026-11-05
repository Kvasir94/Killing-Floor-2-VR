"""The shared settings definition resolves, and a fresh profile reads as the recommended styles."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import launcher_settings as model
import settings_registry
import vr_config


class SettingsDefinitionTests(unittest.TestCase):
    def test_every_preset_option_resolves_to_its_own_label(self):
        base = model.defaults()
        for preset, definition in model.PRESET_DEFS.items():
            numbers = [option["number"] for option in definition["options"] if "number" in option]
            self.assertEqual(sorted(numbers), list(range(len(numbers))), preset)
            self.assertIn(definition["recommended"], [option["id"] for option in definition["options"]])
            for name, values in model.preset_targets(preset).items():
                with self.subTest(preset=preset, option=name):
                    for key, value in values.items():
                        setting = model.BY_KEY[key]
                        if setting.kind == "toggle":
                            self.assertIsInstance(value, bool)
                        elif setting.kind == "choice":
                            self.assertIn(value, dict(setting.choices))
                    self.assertEqual(name, model.preset_name(preset, dict(base, **values)))
                    self.assertEqual(name, model.preset_basis(preset, dict(base, **values)))

    def test_owner_is_the_preset_that_sets_the_value(self):
        owned = {}
        for preset, definition in model.PRESET_DEFS.items():
            if definition.get("row") is False: continue
            for values in model.preset_targets(preset).values():
                owned.update(dict.fromkeys(values, preset))
        for setting in model.SETTINGS:
            if setting.key in owned:
                self.assertEqual(owned[setting.key], setting.owner, setting.key)
            elif setting.owner != "player":
                self.assertIn(setting.owner, model.PRESET_DEFS, setting.key)

    def test_fresh_profile_reads_as_button_reloads_standard_ammo_and_snap_30(self):
        shipped = json.loads((Path(model.__file__).resolve().parents[1] / "vr-defaults.json").read_text())
        self.assertEqual(shipped, vr_config.DEFAULTS)
        with tempfile.TemporaryDirectory() as temporary, patch("vr_config.profile_root", return_value=Path(temporary)):
            values = model.load(SimpleNamespace(eye_render_percent=None, vr_quality="quality"))
        self.assertEqual("Button", model.preset_name("reload_mode", values))
        self.assertEqual("Standard", model.preset_name("ammo_rules", values))
        self.assertEqual(("True", "30"), (values["bSnapTurn"], values["SnapTurnDegrees"]))
        self.assertEqual("0", shipped[model.HANDS]["ReloadPreset"])
        self.assertEqual("0", shipped[model.SESSION]["QuickSetupRevision"])
        for preset in ("grip_mode", "hud_preset", "locomotion"):
            self.assertEqual(model.preset_recommended(preset), model.preset_name(preset, values), preset)

    def test_every_entry_has_a_surface(self):
        rows, labels = [], []
        for entry in model.PAGE_ROWS:
            with self.subTest(key=entry["key"]):
                self.assertIn(entry["depth"], ("everyday", "customize", "setup"))
                if entry["depth"] == "setup":
                    self.assertEqual("Setup", entry["category"])
                else:
                    self.assertIn(entry["category"], model.TABS)
                if entry["depth"] == "customize":
                    self.assertTrue(entry.get("group"))
                self.assertTrue(entry["label"] and (entry.get("help") or entry.get("kind") == "preset"))
                if entry.get("kind") == "preset":
                    rows.append(entry["preset"])
                labels.append(entry["label"])
        self.assertEqual(len(labels), len(set(labels)))
        self.assertEqual({p for p, d in model.PRESET_DEFS.items() if d.get("row") is not False}, set(rows))
        launcher = {option.dest for option in settings_registry.OPTIONS}
        for setting in model.SETTINGS:
            with self.subTest(setting=setting.key):
                self.assertIn(setting.store, ("launcher", "graphics", *model.SECTIONS))
                self.assertIn(setting.applies, ("live", "next_launch", "launch_only"))
                if setting.store == "launcher":
                    self.assertIn(setting.key, launcher)
                if setting.calibration and setting.kind == "number":
                    self.assertTrue(setting.group.startswith("Calibrate"))
                for key, allowed in setting.requires:
                    needed = model.BY_KEY[key]
                    options = (True, False) if needed.kind == "toggle" else dict(needed.choices)
                    self.assertTrue(set(allowed) <= set(options), (key, allowed))
                    self.assertTrue(setting.requires_reason.startswith("Only with"))
        # CYCLE BY HAND is gone (R50); it is never a launcher surface.
        self.assertNotIn("bManualPump", model.BY_KEY)

    def test_first_time_setup_cards_name_real_settings_and_presets(self):
        setup = model.FIRST_TIME_SETUP
        self.assertEqual(("session", "QuickSetupRevision"), (setup["flag"]["store"], setup["flag"]["key"]))
        self.assertEqual(8, len(setup["cards"]))
        for card in setup["cards"]:
            if "preset" in card:
                self.assertIn(card["preset"], model.PRESET_DEFS)
                continue
            keys = [card["setting"]] if "setting" in card else card["settings"]
            for key in keys:
                self.assertIn(key, model.BY_KEY)
            recommended = {card["setting"]: card["recommended"]} if "setting" in card else card["recommended"]
            for key, value in recommended.items():
                self.assertIn(value, dict(model.BY_KEY[key].choices), key)

    def test_first_time_setup_flag_is_shared_with_the_headset_section(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertTrue(model.first_time_setup_pending(root))
            model.complete_first_time_setup(root)
            self.assertFalse(model.first_time_setup_pending(root))
            from session import read_ini
            self.assertEqual("1", vr_config.values(read_ini(root / "KFGame.ini"), model.SESSION)["QuickSetupRevision"])

    def test_hand_edit_of_an_owned_value_reads_custom_based_on_the_nearest_style(self):
        values = dict(model.defaults(), **dict(model.RELOAD_PRESETS["Manual"], bEmptyTriggerReloads=False))
        self.assertEqual("Custom", model.preset_name("reload_mode", values))
        self.assertEqual("Manual", model.preset_basis("reload_mode", values))
        self.assertTrue(model.changed_from_style(model.BY_KEY["bEmptyTriggerReloads"], values, model.defaults()))
        self.assertFalse(model.changed_from_style(model.BY_KEY["bGrabReleasesMagazine"], values, model.defaults()))
        # A value no preset owns never changes a label (R51).
        self.assertEqual("Manual", model.preset_name("reload_mode", dict(values, bEmptyTriggerReloads=True, bReloadHints=False)))


if __name__ == "__main__":
    unittest.main()
