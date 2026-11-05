"""Stable launch/profile contract; no game runtime or source-text assertions."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import friends
import launch_menu
import vr_config
import workshop_loadout
from session import read_ini


class StableFeaturesTests(unittest.TestCase):
    def test_legacy_alias_profiles_disable_every_parked_flag_and_keep_ammo(self):
        for section in ("KF2VR.VRHandsBridge", "KF2VRNetClient.KF2VRNetHandsBridge"):
            for preset in range(4):
                with self.subTest(section=section, preset=preset):
                    saved = f"[{section}]\n" + "".join(f"{key}=True\n{key.lower()}=True\n" for key in vr_config.PARKED_FLAGS)
                    saved += (f"ReloadPreset={preset}\nAmmoRuleSettingsRevision=1\nbKeepChamberedRound=True\n"
                              "bLoseReloadAmmo=False\nbRecoverMagazineAmmo=True\nbDisableGravityPull=False\n"
                              "bFreeWeaponCycling=True\nbSupportHandCarry=True\n")
                    for baseline in ("", vr_config.apply_preferences("")):
                        result = vr_config.apply_preferences(baseline, saved)
                        again = vr_config.apply_preferences(result, saved)
                        self.assertEqual(vr_config.values(result, "KF2VR.VRHandsBridge"),
                                         vr_config.values(again, "KF2VR.VRHandsBridge"))
                        for target in ("KF2VR.VRHandsBridge", "KF2VRNetClient.KF2VRNetHandsBridge"):
                            values = vr_config.values(result, target)
                            for key in vr_config.PARKED_FLAGS:
                                self.assertEqual("False", values[key])
                                self.assertNotIn(key.lower(), values)
                            self.assertEqual(("True", "False", "True"), tuple(values[k] for k in vr_config.AMMO_OPTIONS))
                            self.assertEqual(str(preset), values["ReloadPreset"])
                            for key in ("bFreeWeaponCycling", "bSupportHandCarry"):
                                self.assertEqual("True", values[key])
                            self.assertEqual("False", values["bDisableGravityPull"])

    def test_export_also_clears_parked_flags_without_recombining_legacy_ammo(self):
        for network in (False, True):
            with self.subTest(network=network), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); config = root / "config"; config.mkdir()
                section = "KF2VRNetClient.KF2VRNetHandsBridge" if network else "KF2VR.VRHandsBridge"
                text = f"[{section}]\nbRealisticAmmo=False\n" + "".join(f"{k}=True\n" for k in vr_config.PARKED_FLAGS)
                (config / "KFGame.ini").write_text(text, encoding="utf-16")
                vr_config.export_preferences(config, root / "profile", network=network)
                saved = read_ini(root / "profile/KFGame.ini")
                values = vr_config.values(saved, "KF2VR.VRHandsBridge")
                self.assertEqual({"False"}, {values[k] for k in vr_config.PARKED_FLAGS})
                self.assertEqual({"False"}, {values[k] for k in vr_config.AMMO_OPTIONS})

    def test_old_enable_switches_are_rejected_and_absent_from_help(self):
        for argv in (("--host", "--vr", "--multiplayer-grabs"), ("--solo", "--vr", "--standing-holds"),
                     ("--vr", "--address", "example.test", "--standing-holds"),
                     ("--solo", "--vr", "--portal-gun"), ("--solo", "--no-portal-gun")):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                friends.parse_options(list(argv))
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(SystemExit):
            friends.parse_options(["--help"])
        self.assertNotIn("standing-holds", output.getvalue())
        self.assertNotIn("multiplayer-grabs", output.getvalue())

    def test_optional_content_is_parked_across_old_profiles_and_overrides(self):
        import stable_features, package, breacher
        self.assertFalse(stable_features.experimental_content_enabled())
        self.assertFalse(package.valid_script_inventory(set(package.CORE_PACKAGES) | {"KF2TD.u"}))
        for flags in (("--breacher",), ("--zed-defense",), ("--breacher-level", "25"), ("--breacher-skills", "12121")):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                friends.parse_options(["--solo", "--vr", *flags])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "launcher.json").write_text(json.dumps({"breacher": True, "zed_defense": True}))
            for mode in ("--solo", "--host"):
                args = friends.parse_options([mode, "--vr"]); args.profile_root = root
                workshop_loadout.load_preferences(args)
                self.assertFalse(hasattr(args, "breacher") or hasattr(args, "zed_defense"))
                workshop_loadout.save_preferences(args)
                saved = json.loads((root / "launcher.json").read_text())
                self.assertFalse(set(workshop_loadout.RETIRED_KEYS) & set(saved))
                # The content module keeps its own gate for acceptance builds.
                args.breacher = True
                with self.assertRaisesRegex(RuntimeError, "parked"):
                    breacher.prepare(args, root, {})
        old = "[KF2VR.VRSessionUI]\nLocalMutators=Existing.Mod,kF2Breacher.BreacherMutator,KF2TD.Example\n"
        prefs = vr_config.values(vr_config.apply_preferences("", old), "KF2VR.VRSessionUI")
        self.assertEqual("Existing.Mod", prefs["LocalMutators"])

    def test_host_restores_ordinary_grabs_without_legacy_experimental_toggles(self):
        args = friends.parse_options(["--host", "--vr"])
        with tempfile.TemporaryDirectory() as tmp:
            args.profile_root = Path(tmp)
            (args.profile_root / "launcher.json").write_text(json.dumps({"standing_holds": True, "multiplayer_grabs": True}))
            workshop_loadout.load_preferences(args)
            self.assertIn("?VRMultiplayerGrabs=1", launch_menu.host_url(args))
            output = []
            self.assertTrue(launch_menu.choose_options(args, [args.map], read=lambda _: "", write=output.append))
            menu = "\n".join(output).lower()
            for word in ("standing", "zed grabbing", "multiplayer grabs", "breacher", "zed defense"):
                self.assertNotIn(word, menu)
