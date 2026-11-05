"""The option registry is the launch contract: flags, shipped defaults and help."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import friends
import launch_menu
import settings_registry as registry
import workshop_loadout


class SettingsRegistryTests(unittest.TestCase):
    def test_defaults_are_valid_values(self):
        for option in registry.OPTIONS:
            with self.subTest(option=option.dest):
                self.assertIn(option.category, registry.CATEGORIES)
                self.assertIn(option.stability, ("stable", "experimental", "developer", "hidden"))
                self.assertIn(option.store, (None, "launcher", "vr-ini", "machine"))
                if option.ps_values:
                    self.assertEqual(len(option.ps_values), len(option.choices))
                if option.default is None:
                    continue
                if option.choices:
                    self.assertIn(option.default, option.choices)
                if option.minimum is not None:
                    self.assertTrue(option.minimum <= option.default <= option.maximum)

    def test_unique_flags_and_switches(self):
        flags = [o.flag for o in registry.OPTIONS if o.flag]
        switches = [o.ps.lower() for o in registry.OPTIONS if o.ps]
        self.assertEqual(len(flags), len(set(flags)))
        self.assertEqual(len(switches), len(set(switches)))

    def test_cli_leaves_remembered_choices_to_the_profile(self):
        args = friends.parse_options([])
        for option in registry.OPTIONS:
            if not option.flag:
                continue
            with self.subTest(option=option.dest):
                value = getattr(args, option.dest)
                if option.remembered:
                    self.assertIn(value, (None, False))
                elif option.dest not in ("server_root", "cache_root"):
                    self.assertEqual(value, option.default)

    def test_empty_profile_resolves_to_registry_defaults(self):
        with tempfile.TemporaryDirectory() as folder:
            args = friends.parse_options(["--host"])
            args.profile_root = Path(folder)
            workshop_loadout.load_preferences(args)
            for option in registry.OPTIONS:
                if option.store != "launcher":
                    continue
                with self.subTest(option=option.dest):
                    self.assertEqual(getattr(args, option.dest), registry.default(option.dest))
            self.assertEqual("medium", args.game_length)
            self.assertTrue(args.workshop_desktop)

    def test_old_parked_profile_keys_are_ignored_and_dropped_on_save(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "launcher.json").write_text(json.dumps(
                {"breacher": True, "zed_defense": True, "multiplayer_grabs": True, "standing_holds": True,
                 "portal_gun": True, "map": "KF-Outpost"}))
            args = friends.parse_options(["--host"])
            args.profile_root = root
            workshop_loadout.load_preferences(args)
            self.assertEqual("KF-Outpost", args.map)
            workshop_loadout.save_preferences(args)
            saved = json.loads((root / "launcher.json").read_text())
            self.assertFalse(set(workshop_loadout.RETIRED_KEYS) & set(saved))
            self.assertEqual("KF-Outpost", saved["map"])

    def test_vr_ini_default_matches_shipped_preferences(self):
        shipped = json.loads((Path(__file__).resolve().parents[1] / "vr-defaults.json").read_text())
        self.assertEqual(int(shipped["KF2VR.VRSessionUI"]["EyeRenderPercent"]), registry.default("eye_render_percent"))

    def test_choice_tables_share_the_registry_values(self):
        self.assertEqual(tuple(launch_menu.DIFFICULTIES), registry.DIFFICULTIES)
        self.assertEqual(tuple(launch_menu.LENGTHS), registry.GAME_LENGTHS)
        self.assertEqual(tuple(workshop_loadout.HEADSET_PRESETS), registry.HEADSET_PRESETS)
        for quality, scale in workshop_loadout.HEADSET_PRESETS.values():
            self.assertIn(quality, registry.VR_QUALITIES)
            self.assertTrue(50 <= scale <= 100)

    def test_help_states_real_defaults_without_parked_content(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(SystemExit):
            friends.parse_options(["--help"])
        cli = " ".join(output.getvalue().split())
        shell = registry.powershell_help()
        for word in ("breacher", "zed-defense", "multiplayer-grabs", "standing-holds", "portal"):
            self.assertNotIn(word, cli.lower())
        for word in ("Breacher", "ZedDefense", "MultiplayerGrabs", "StandingHolds", "Portal", "-DevGui"):
            self.assertNotIn(word, shell)
        self.assertIn("initially quality", cli)
        self.assertIn("-VrQuality quality|balanced|performance", shell)


if __name__ == "__main__":
    unittest.main()
