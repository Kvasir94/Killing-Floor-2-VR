"""Launch real role configuration with small local Workshop package fixtures."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import friends
import workshop_loadout as loadout
from launch_menu import choose_options, host_url, installed_maps
from session import read_ini, config_hashes


class WorkshopLoadoutTests(unittest.TestCase):
    def test_saved_admin_auto_cheats_are_disabled_only_in_session_copies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args = self.args(root, "--mods", "ukfp,aal")
            game, user = root / "game", root / "user"
            bases = [game / "KFGame/Config", args.server_root / "KFGame/Config", user]
            original = "[AAL.AAL]\nVersion=2\nbAutoEnableCheats=True\n[AAL.AdminList]\nAdminId=preserved\n"
            for base in bases:
                for platform in ("", "PCServer", "Eos"):
                    folder = base / platform
                    folder.mkdir(parents=True, exist_ok=True)
                    (folder / "KFAAL.ini").write_text(original)
            for name in ("server", "driver"):
                configs = root / "run" / name / "Config"
                configs.mkdir(parents=True)
                (configs / "KFAAL.ini").write_text(original)
                role = {"role": name, "config_root": str(configs), "args": []}
                loadout.configure_mod_settings(role, args, game, user)
                for target in role["mod_config"]["destinations"]:
                    for path in Path(target["root"]).rglob("KFAAL.ini"):
                        text = read_ini(path)
                        self.assertIn("bAutoEnableCheats=False", text)
                        self.assertNotIn("bAutoEnableCheats=True", text)
                        self.assertIn("AdminId=preserved", text)
            for base in bases:
                for platform in ("", "PCServer", "Eos"):
                    self.assertEqual(original, (base / platform / "KFAAL.ini").read_text())

    def test_session_record_retries_a_transient_windows_share_violation(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "run.json"
            original_replace = Path.replace
            attempts = 0

            def replace_once_locked(path, target):
                nonlocal attempts
                attempts += 1
                if attempts == 1:
                    raise PermissionError(5, "Access is denied", str(path))
                return original_replace(path, target)

            with patch.object(Path, "replace", replace_once_locked), patch("friends.time.sleep"):
                friends.save_session_record(output, {"status": "prepared"})

            self.assertEqual(attempts, 2)
            self.assertEqual(output.read_text(encoding="utf-8"), '{\n  "status": "prepared"\n}')
            self.assertFalse(output.with_suffix(".tmp").exists())

    def args(self, root, *flags):
        args = friends.parse_options(["--host", "--vr", "--prepare-only", *flags])
        args.profile_root = root / "profile"
        args.cache_root = root / "cache"
        args.server_root = root / "server"
        args.address, args.password = "127.0.0.1", "test"
        loadout.load_preferences(args)
        return args

    def packages(self, game, item):
        root = game.parents[1] / "workshop/content/232090" / item / "BrewedPC"
        root.mkdir(parents=True, exist_ok=True)
        for name in loadout.REQUIRED_PACKAGES[item]:
            (root / name).write_bytes(b"\xc1\x83\x2a\x9e" + name.encode())
        return root

    def test_default_and_reduced_selection_use_one_patch_loader(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.args(Path(tmp), "--test-map", "--mods", "legacy")
            url = host_url(args)
            self.assertIn("?Game=KF2VRNet.KF2VRNetGame?", url)
            self.assertEqual(url.count("?Mutator="), 1)
            for option in ("LoadFHUD", "LoadYAS", "LoadAAL", "LoadCVC", "LoadLTI", "UnsuppressLogs"):
                self.assertIn(f"?{option}=1", url)
            self.assertIn("?AllowDamagePopups=0", url)
            self.assertIn("?LoadFHUDExt=0", url)
            self.assertIn("?FakePlayers=6", url)
            args.test_map = False
            self.assertIn("?FakePlayers=0", host_url(args))
            args.mods = loadout.parse_mods("yas")
            self.assertIn("?LoadYAS=1", host_url(args))
            self.assertIn("?LoadLTI=0", host_url(args))
            args.mods = []
            self.assertNotIn("Mutator=", host_url(args))
            self.assertNotIn("FakePlayers=", host_url(args))

    def test_menu_and_explicit_override_survive_new_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args = self.args(root, "--menu", "--mods", "legacy")
            answers = iter(["8", "6", "7", "8", "", "7", "0"])
            self.assertTrue(choose_options(args, ["KF-BurningParis"],
                read=lambda _: next(answers), write=lambda _: None))
            self.assertTrue(args.inventory_focus)
            self.assertIn("?VRInventoryFocus=1", host_url(args))
            loadout.save_preferences(args)
            again = self.args(root)
            self.assertNotIn("lti", again.mods)
            self.assertTrue(again.damage_popups)
            self.assertEqual(again.test_map_players, 0)
            overridden = self.args(root, "--mods", "ukfp", "--damage-popups", "--test-map-players", "6")
            self.assertEqual(overridden.mods, ["ukfp"])
            self.assertTrue(overridden.damage_popups)
            self.assertFalse(loadout.damage_popups_enabled(overridden))
            overridden.vr = False
            self.assertTrue(loadout.damage_popups_enabled(overridden))
            self.assertEqual(overridden.test_map_players, 6)
            diagnostic = self.args(root, "--replay-teammate")
            self.assertEqual(diagnostic.mods, [])
            self.assertNotIn("Mutator=", host_url(diagnostic))

    def test_every_launcher_selection_survives_the_next_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            chosen = self.args(root, "--map", "KF-Outpost", "--difficulty", "hard",
                               "--game-length", "long", "--vr-quality", "performance",
                               "--inventory-focus")
            loadout.save_preferences(chosen)
            again = friends.parse_options(["--host", "--prepare-only"])
            again.profile_root = root / "profile"
            loadout.load_preferences(again)
            self.assertEqual(("KF-Outpost", "hard", "long", "performance"),
                             (again.map, again.difficulty, again.game_length, again.vr_quality))
            self.assertTrue(again.inventory_focus)
            self.assertTrue(again.vr)
            # An explicit switch overrides the saved value for that launch, and
            # the launch then remembers what it was actually played with.
            override = friends.parse_options(["--host", "--desktop", "--prepare-only", "--difficulty", "normal"])
            override.profile_root = root / "profile"
            loadout.load_preferences(override)
            self.assertEqual(("KF-Outpost", "normal"), (override.map, override.difficulty))
            self.assertFalse(override.vr)
            loadout.save_preferences(override)
            after = friends.parse_options(["--host", "--prepare-only"])
            after.profile_root = root / "profile"
            loadout.load_preferences(after)
            self.assertFalse(after.vr)
            self.assertEqual("normal", after.difficulty)
            # A diagnostic scenario takes the shipped defaults, never the profile.
            scenario = friends.parse_options(["--host", "--vr", "--prepare-only", "--replay-teammate"])
            scenario.profile_root = root / "profile"
            loadout.load_preferences(scenario)
            self.assertEqual(("KF-BurningParis", "normal", "short"),
                             (scenario.map, scenario.difficulty, scenario.game_length))
            self.assertEqual([], scenario.mods)

    def test_installs_all_required_packages_and_configures_both_roles(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args = self.args(root, "--mods", "ukfp,yas", "--map", "KF-TF2_Gorge")
            game = root / "steamapps/common/killingfloor2"
            requested = [value[1] for value in loadout.MODS.values()] + [loadout.MAPS[args.map]]
            for item in requested:
                self.packages(game, item)
            user = root / "user"
            user.mkdir()
            (user / "KFEngine.ini").write_text("[Core.System]\nPaths=stock\nScriptPaths=stock\n"
                "SeekFreePCPaths=stock\nBrewedPCPaths=stock\n[IpDrv.TcpNetDriver]\n"
                "DownloadManagers=IpDrv.HTTPDownload\n")
            (user / "KFGame.ini").write_text("[Engine.AccessControl]\nGamePassword=original\n")
            (user / "KFUnofficialPatch.ini").write_text("[UnofficialKFPatch.UKFPHUDInteraction]\nbDisableDamagePopups=True\n")
            before = config_hashes(user)
            content = loadout.prepare_content(args, game, root / "steamcmd")
            self.assertEqual({x["workshop_id"] for x in content}, set(requested))
            roles = [friends.configure_role(root / "run", role, user, game, args) for role in ("server", "driver")]
            self.assertEqual(before, config_hashes(user))
            for role in roles:
                engine = read_ini(Path(role["config_root"]) / "KFEngine.ini")
                for item in content:
                    for name in item["files_sha256"]:
                        self.assertIn(str((Path(item["root"]) / name).parent), engine)
                self.assertLess(engine.index("DownloadManagers=OnlineSubsystemSteamworks.SteamWorkshopDownload"),
                                engine.index("DownloadManagers=IpDrv.HTTPDownload"))
                self.assertTrue(any(x.startswith("-CONFIGSUBDIR=") for x in role["args"]))
                for target in role["mod_config"]["destinations"]:
                    config = Path(target["root"])
                    self.assertIn("bDisableDamagePopups=True", read_ini(config / "KFUnofficialPatch.ini"))
                    self.assertIn("Version=0", read_ini(config / "KFYAS.ini"))
                    self.assertNotIn("AdminId=", read_ini(config / "KFAAL.ini"))
                    self.assertNotIn("Item=", read_ini(config / "KFLTI.ini"))
                if role["role"] == "server":
                    self.assertEqual(role["args"][0], host_url(args))
                    for item in requested:
                        self.assertIn("ServerSubscribedWorkshopItems=" + item, engine)
                else:
                    self.assertNotIn("?Mutator=", role["args"][0])
            self.assertIn("KF-MountainPass_zfix", installed_maps(game, args.server_root))
            self.assertTrue(all(name in installed_maps(game, args.server_root) for name in loadout.MAPS))

    def test_missing_dependency_and_changed_cache_fail_before_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args = self.args(root, "--mods", "ukfp")
            game = root / "steamapps/common/killingfloor2"
            for value in loadout.MODS.values():
                if value[1] != "2864857909":
                    self.packages(game, value[1])
            with patch.object(loadout.subprocess, "run") as process:
                with self.assertRaisesRegex(RuntimeError, "2864857909 is missing"):
                    loadout.prepare_content(args, game, root / "steamcmd")
                process.assert_not_called()
            self.packages(game, "2864857909")
            loadout.prepare_content(args, game, root / "steamcmd")
            cached = args.cache_root / "1819268190/content/BrewedPC/FriendlyHUD.u"
            cached.write_bytes(cached.read_bytes() + b"changed")
            with self.assertRaisesRegex(RuntimeError, "cache changed"):
                loadout.prepare_content(args, game, root / "steamcmd")

    def test_missing_cached_package_is_restored_only_from_matching_steam_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            game = root / "steamapps/common/killingfloor2"
            self.packages(game, "2875147606")
            cache = root / "cache"
            loadout.ensure_item("2875147606", game, cache, root / "steamcmd", download=False)
            cached = cache / "2875147606/content/BrewedPC/UnofficialKFPatch.u"
            cached.unlink()

            restored = loadout.ensure_item("2875147606", game, cache, root / "steamcmd", download=False)

            self.assertTrue((restored / "BrewedPC/UnofficialKFPatch.u").is_file())

    def test_partial_copy_does_not_count_as_an_installed_patch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            game = root / "steamapps/common/killingfloor2"
            source = self.packages(game, "2875147606")
            (source / "UnofficialKFPatch_LevelTransition.u").unlink()
            with self.assertRaisesRegex(RuntimeError, "incomplete"):
                loadout.ensure_item("2875147606", game, root / "cache", root / "steamcmd", download=False)
            self.assertFalse((root / "cache/2875147606/content.json").exists())


if __name__ == "__main__":
    unittest.main()
