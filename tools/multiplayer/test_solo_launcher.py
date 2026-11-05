"""Offline Solo/Host preference and configuration contracts; no game launch."""
import json
import hashlib
import contextlib
import io
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import desktop_settings
import friends
import launch_menu
import workshop_loadout as loadout
import workshop_map
from session import config_hashes, read_ini
from vr_config import values
from workshop_map import MAP_NAME


class SoloLauncherTests(unittest.TestCase):
    def test_range_uses_network_game_and_viewport_in_solo(self):
        user = self.root / "user"
        user.mkdir()
        (user / "KFEngine.ini").write_text("[Core.System]\nPaths=stock\n")
        (user / "KFGame.ini").write_text("[KFGame.KFGameInfo]\n")
        args = self.options("--solo", "--vr", "--map", "KF-VRRange")
        role = friends.configure_role(self.root / "range", "driver", user, self.root / "game", args)
        self.assertTrue(role["args"][0].startswith("KF-VRRange?Game=KF2VRNet.KF2VRRangeGame?"))
        engine = values(read_ini(Path(role["config_root"]) / "KFEngine.ini"), "Engine.Engine")
        self.assertEqual("KF2VRNetClient.KF2VRNetViewportClient", engine["GameViewportClientClassName"])
        self.assertNotIn("-kf2vr-network", role["args"])

    def cached_remilly_fixture(self):
        path = self.root / "cache" / workshop_map.ITEM_ID / "0/Unpublished/BrewedPC" / (MAP_NAME + ".kfm")
        path.parent.mkdir(parents=True)
        content = b"\xc1\x83\x2a\x9e" + b"parser fixture" * 100
        path.write_bytes(content)
        return path, hashlib.sha256(content).hexdigest().upper()

    def test_explicit_solo_remilly_requires_steam_and_keeps_host_features_off(self):
        for selector in (("--test-map",), ("--map", MAP_NAME)):
            args = self.options("--solo", "--vr", "--store", "steam", *selector)
            self.assertTrue(args.test_map)
            self.assertFalse(args.host)
            self.assertEqual(([], 0, False),
                             (args.mods, args.test_map_players, args.inventory_focus))
            for store in ("auto", "epic"):
                with self.subTest(store=store), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    friends.parse_options(["--solo", "--vr", "--store", store, *selector])
        for extra in (("--host",), ("--test-map-players", "6"), ("--inventory-focus",), ("--replay-teammate",)):
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                friends.parse_options(["--solo", "--store", "steam", "--test-map", *extra])

    def test_solo_cache_validation_never_imports_or_downloads_missing_or_changed_map(self):
        with patch.object(workshop_map.shutil, "copy2") as copy, \
                patch.object(workshop_map.subprocess, "run") as run:
            with self.assertRaises(RuntimeError):
                workshop_map.cached_solo_map(self.root / "cache")
            self.assertFalse((self.root / "cache").exists())
            path, expected = self.cached_remilly_fixture()
            before = path.stat().st_mtime_ns
            with patch.object(workshop_map, "SOLO_MAP_SHA256", expected):
                self.assertEqual(path, workshop_map.cached_solo_map(self.root / "cache"))
                self.assertEqual(before, path.stat().st_mtime_ns)
                path.write_bytes(path.read_bytes()[:-1] + b"X")
                with self.assertRaisesRegex(RuntimeError, "differs"):
                    workshop_map.cached_solo_map(self.root / "cache")
                path.write_bytes(b"wrong header" * 100)
                with self.assertRaisesRegex(RuntimeError, "Unreal package"):
                    workshop_map.cached_solo_map(self.root / "cache")
            copy.assert_not_called()
            run.assert_not_called()

    def test_menu_remilly_reads_cache_then_steamcmd_in_place(self):
        steam = self.root / "steamcmd"
        with patch.object(workshop_map.shutil, "copy2") as copy, \
                patch.object(workshop_map.subprocess, "run") as run:
            self.assertIsNone(workshop_map.installed_map(self.root / "cache", steam))
            download = steam / "steamapps/workshop/content/232090" / workshop_map.ITEM_ID / "BrewedPC" / (MAP_NAME + ".kfm")
            download.parent.mkdir(parents=True)
            download.write_bytes(b"\xc1\x83\x2a\x9e" + b"download" * 200)
            self.assertEqual(download, workshop_map.installed_map(self.root / "cache", steam))
            cached, _ = self.cached_remilly_fixture()
            self.assertEqual(cached, workshop_map.installed_map(self.root / "cache", steam))
            copy.assert_not_called()
            run.assert_not_called()

    def test_vr_driver_mounts_menu_remilly_without_test_map(self):
        user = self.root / "user"
        user.mkdir()
        (user / "KFEngine.ini").write_text("[Core.System]\nPaths=stock\nSeekFreePCPaths=stock\nBrewedPCPaths=stock\n")
        (user / "KFGame.ini").write_text("[KFGame.KFGameInfo]\n")
        cached, _ = self.cached_remilly_fixture()
        args = self.options("--solo", "--vr")
        args.menu_map_path = cached
        role = friends.configure_role(self.root / "menu", "driver", user, self.root / "game", args)
        text = read_ini(Path(role["config_root"]) / "KFEngine.ini")
        self.assertIn("Paths=" + str(cached.parent), text)

    def test_solo_remilly_uses_isolated_paths_and_stock_local_game_without_auto_cheats(self):
        self.save_profile(map="KF-Outpost")
        path, expected = self.cached_remilly_fixture()
        original_map = path.read_bytes()
        user = self.root / "user"
        user.mkdir()
        (user / "KFEngine.ini").write_text("[Core.System]\nPaths=stock\nScriptPaths=stock\nSeekFreePCPaths=stock\nBrewedPCPaths=stock\n")
        (user / "KFGame.ini").write_text("[Engine.AccessControl]\n")
        before = config_hashes(user)
        args = self.options("--solo", "--vr", "--store", "steam", "--test-map")
        with patch.object(workshop_map, "SOLO_MAP_SHA256", expected):
            launch_menu.resolve_solo_map(args, [])
        self.assertEqual((MAP_NAME, True, path), (args.map, args.test_map, args.test_map_path))
        role = friends.configure_role(self.root / "run", "driver", user, self.root / "game", args)
        self.assertTrue(role["args"][0].startswith(MAP_NAME + "?Game=KFGameContent.KFGameInfo_Survival"))
        self.assertNotIn("?Mutator=", role["args"][0])
        self.assertNotIn("-kf2vr-network", role["args"])
        self.assertNotIn("enablecheats", " ".join(role["args"]).lower())
        config = read_ini(Path(role["config_root"]) / "KFEngine.ini")
        for key in ("Paths", "SeekFreePCPaths", "BrewedPCPaths"):
            self.assertIn(f"{key}={path.parent}", config)
            self.assertIn(f"{key}=stock", config)
        self.assertEqual(before, config_hashes(user))
        self.assertEqual(original_map, path.read_bytes())
        loadout.save_preferences(args)
        self.assertEqual("KF-Outpost", json.loads((self.profile / "launcher.json").read_text())["map"])
        self.assertFalse((self.root / "server").exists())

    def test_normal_launch_does_not_restore_practice_or_request_cheats(self):
        user = self.root / "user"
        user.mkdir()
        (user / "KFEngine.ini").write_text("[Core.System]\nPaths=stock\nScriptPaths=stock\n"
            "SeekFreePCPaths=stock\nBrewedPCPaths=stock\n")
        (user / "KFGame.ini").write_text("[KF2VR.VRDemo]\nbNormalGame=False\nbRenderDiagnostic=True\n")
        (self.profile / "KFGame.ini").write_text("[KF2VR.VRDemo]\nbNormalGame=False\nbRenderDiagnostic=True\n")
        before = config_hashes(user)
        for mode, name in (("--solo", "driver"), ("--host", "driver"), ("--host", "server")):
            args = self.options(mode, "--vr", "--mods", "none")
            role = friends.configure_role(self.root / (mode[2:] + name), name, user, self.root / "game", args)
            command = " ".join(role["args"]).lower()
            for forbidden in ("enablecheats", "-exec=", "-exec cmd", "vrnetdiagnostics=1", "vrnetautoready=1"):
                self.assertNotIn(forbidden, command)
            text = read_ini(Path(role["config_root"]) / "KFGame.ini")
            controller = values(text, "KF2VRNet.KF2VRNetPlayerController")
            self.assertEqual("false", controller["bDiagnosticSyntheticAutoStart"])
            if mode == "--solo":
                self.assertNotIn("?mutator=", command)
                self.assertEqual({"bNormalGame": "True", "bRenderDiagnostic": "False"}, values(text, "KF2VR.VRDemo"))
        self.assertEqual(before, config_hashes(user))

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.profile = self.root / "profile"
        self.profile.mkdir()

    def save_profile(self, **overrides):
        saved = {"vr": True, "map": "KF-BurningParis", "difficulty": "hard",
                 "game_length": "long", "vr_quality": "balanced", "mods": ["ukfp", "yas"],
                 "damage_popups": True, "test_map_players": 6,
                 "inventory_focus": True}
        saved.update(overrides)
        (self.profile / "launcher.json").write_text(json.dumps(saved), encoding="utf-8")
        return saved

    def options(self, *flags):
        if "--host" in flags:
            flags = (*flags, "--no-workshop-desktop")  # This fixture has no published core package.
        args = friends.parse_options(["--prepare-only", *flags])
        args.profile_root = self.profile
        args.cache_root = self.root / "cache"
        args.server_root = self.root / "server"
        args.address, args.password = "127.0.0.1", "fixture"
        loadout.load_preferences(args)
        return args

    def install_maps(self, *names):
        game = self.root / "game"
        maps = game / "KFGame/BrewedPC/Maps/fixture"
        maps.mkdir(parents=True, exist_ok=True)
        for name in names:
            (maps / (name + ".kfm")).write_bytes(b"map fixture")
        return game

    def test_solo_maps_include_installed_workshop_content(self):
        game = self.install_maps("KF-ZedLanding", "KF-Outpost", "KF-BurningParis", "KF-AshwoodAsylum",
                                 MAP_NAME, *loadout.MAPS)
        outside = game / "KFGame/Cache/other"
        outside.mkdir(parents=True)
        (outside / "KF-CacheOnly.kfm").write_bytes(b"map fixture")
        with patch('installed_map_catalog.user_game_root', return_value=self.root / 'user-game'):
            found = launch_menu.installed_solo_maps(game)
        self.assertEqual(["KF-BurningParis", "KF-Outpost"], found[:2])
        self.assertEqual({"KF-BurningParis", "KF-Outpost", "KF-AshwoodAsylum", "KF-ZedLanding",
                          "KF-CacheOnly", *loadout.MAPS}, set(found))
        self.assertEqual([], launch_menu.installed_solo_maps(self.root / "missing-game"))

    def test_saved_map_falls_back_but_explicit_or_empty_catalog_is_rejected(self):
        maps = ["KF-Outpost", "KF-ZedLanding"]
        for saved_map in (MAP_NAME, next(iter(loadout.MAPS)), "KF-NoLongerInstalled"):
            with self.subTest(saved=saved_map):
                self.save_profile(map=saved_map)
                args = self.options("--solo")
                self.assertFalse(args.map_requested)
                launch_menu.resolve_solo_map(args, maps)
                self.assertEqual("KF-Outpost", args.map)
                self.assertFalse(args.test_map)
        valid = self.options("--solo", "--map", "KF-ZedLanding")
        self.assertTrue(valid.map_requested)
        launch_menu.resolve_solo_map(valid, maps)
        self.assertEqual("KF-ZedLanding", valid.map)
        explicit = self.options("--solo", "--map", next(iter(loadout.MAPS)))
        with self.assertRaises(RuntimeError):
            launch_menu.resolve_solo_map(explicit, maps)
        with self.assertRaises(RuntimeError):
            launch_menu.resolve_solo_map(self.options("--solo"), [])

    def test_solo_save_preserves_host_only_choices_for_the_next_host(self):
        previous = self.save_profile()
        solo = self.options("--solo")
        self.assertTrue(solo.vr)
        self.assertEqual(([], False, 0, False),
                         (solo.mods, solo.damage_popups, solo.test_map_players, solo.inventory_focus))
        solo.map, solo.difficulty, solo.game_length, solo.vr_quality = "KF-Outpost", "suicidal", "medium", "performance"
        loadout.save_preferences(solo)
        saved = json.loads((self.profile / "launcher.json").read_text(encoding="utf-8"))
        for key in ("mods", "damage_popups", "test_map_players", "inventory_focus"):
            self.assertEqual(previous[key], saved[key], key)
        host = self.options("--host")
        self.assertTrue(host.vr)
        self.assertEqual(("KF-Outpost", "suicidal", "medium", "performance"),
                         (host.map, host.difficulty, host.game_length, host.vr_quality))
        self.assertEqual((previous["mods"], True, 6, True),
                         (host.mods, host.damage_popups, host.test_map_players, host.inventory_focus))

    def test_join_stays_desktop_without_an_explicit_vr_request(self):
        self.save_profile(vr=True)
        join = self.options("--address", "example.test")
        self.assertFalse(join.vr)
        self.assertEqual([], join.mods)
        self.assertTrue(self.options("--address", "example.test", "--vr").vr)

    def test_vr_only_options_are_checked_after_the_solo_mode_is_resolved(self):
        for option in (("--eye-render-percent", "75"), ("--vr-quality", "performance")):
            with self.subTest(option=option):
                self.save_profile(vr=True)
                vr = self.options("--solo", *option)
                self.assertTrue(vr.vr)
                friends.validate_play_mode(vr)
                self.save_profile(vr=False)
                desktop = self.options("--solo", *option)
                self.assertFalse(desktop.vr)
                with self.assertRaises(RuntimeError):
                    friends.validate_play_mode(desktop)
        # A saved graphics preset alone does not make a Desktop launch invalid.
        friends.validate_play_mode(self.options("--solo"))

    def test_console_mode_selection_survives_preference_reload_and_next_launch(self):
        for mode in ("--solo", "--host"):
            with self.subTest(mode=mode):
                self.save_profile(vr=False)
                args = self.options(mode, "--menu")
                answers = iter(["1", "1", "0"])
                self.assertTrue(launch_menu.choose_options(args, ["KF-BurningParis"],
                    read=lambda _: next(answers), write=lambda _: None))
                self.assertTrue(args.vr)
                self.assertTrue(args.mode_requested)
                loadout.load_preferences(args)
                self.assertTrue(args.vr)
                loadout.save_preferences(args)
                self.assertTrue(self.options(mode).vr)

    def test_solo_menu_refuses_hidden_host_controls_and_marks_map_selection_explicit(self):
        self.save_profile()
        args = self.options("--solo", "--menu")
        output = []
        answers = iter(["7", "8", "9", "2", "2", "0"])
        with patch.object(launch_menu, "choose_mods") as mods_menu:
            self.assertTrue(launch_menu.choose_options(args, ["KF-BurningParis", "KF-Outpost"],
                read=lambda _: next(answers), write=output.append))
        mods_menu.assert_not_called()
        self.assertFalse(any(re.match(r"\s+[789]\.", line) for line in output))
        self.assertEqual(([], False), (args.mods, args.inventory_focus))
        self.assertTrue(args.map_requested)
        self.assertEqual("KF-Outpost", args.map)
        with self.assertRaises(RuntimeError):
            launch_menu.resolve_solo_map(args, ["KF-BurningParis"])

    def test_solo_and_host_keep_the_same_graphics_and_eye_preferences(self):
        self.save_profile()
        user = self.root / "user"
        user.mkdir()
        (user / "KFEngine.ini").write_text("[Core.System]\nPaths=stock\nScriptPaths=stock\n"
            "SeekFreePCPaths=stock\nBrewedPCPaths=stock\n[Engine.Engine]\nbSmoothFrameRate=True\n", encoding="utf-16")
        (user / "KFGame.ini").write_text("[Engine.AccessControl]\n", encoding="utf-16")
        (user / "KFSystemSettings.ini").write_text("[SystemSettings]\nDynamicShadows=True\n"
            "MaxDrawDistanceScale=1.0\nTextureDetail=3\n", encoding="utf-16")
        before = config_hashes(user)
        roles = []
        for mode in ("--solo", "--host"):
            args = self.options(mode, "--vr", "--mods", "none", "--vr-quality", "performance",
                                "--eye-render-percent", "75", "--map", "KF-Outpost")
            roles.append(friends.configure_role(self.root / mode[2:], "driver", user, self.root / "game", args))
        solo, host = roles
        self.assertEqual(before, config_hashes(user))
        self.assertEqual(("performance", 75), (solo["vr_quality"], solo["eye_render_percent"]))
        self.assertEqual((solo["vr_quality"], solo["eye_render_percent"]),
                         (host["vr_quality"], host["eye_render_percent"]))
        configs = [Path(role["config_root"]) for role in roles]
        settings = [values(read_ini(path / "KFSystemSettings.ini"), "SystemSettings") for path in configs]
        self.assertEqual(settings[0], settings[1])
        self.assertEqual("True", settings[0]["DynamicShadows"])
        self.assertEqual("1.0", settings[0]["MaxDrawDistanceScale"])
        self.assertEqual("3", settings[0]["TextureDetail"])
        for path, role in zip(configs, roles):
            text = read_ini(path / "KFGame.ini")
            for section in ("KF2VR.VRSessionUI", "KF2VRNetClient.KF2VRNetSessionUI"):
                self.assertEqual("75", values(text, section)["EyeRenderPercent"])
            self.assertEqual("75", friends.role_environment({}, role)["KF2VR_EYE_RENDER_PERCENT"])
        self.assertNotIn("-kf2vr-network", solo["args"])
        self.assertIn("-kf2vr-network", host["args"])
        # In-game SaveConfig must reach the session KFGame.ini for export.
        for role in roles:
            self.assertNotIn("-NOINI", role["args"])
            self.assertTrue(any(a.startswith("-GAMEINI=") and a.endswith("KFGame.ini") for a in role["args"]))

    def test_legacy_standing_profiles_cannot_enable_solo_host_or_join(self):
        self.save_profile(standing_holds=True, multiplayer_grabs=True)
        user = self.root / "user"
        user.mkdir()
        (user / "KFEngine.ini").write_text("[Core.System]\nPaths=stock\nScriptPaths=stock\n"
            "SeekFreePCPaths=stock\nBrewedPCPaths=stock\n", encoding="utf-16")
        (user / "KFGame.ini").write_text("[Engine.AccessControl]\n", encoding="utf-16")
        sections = ("KF2VR.VRHandsBridge", "KF2VRNetClient.KF2VRNetHandsBridge")
        (self.profile / "KFGame.ini").write_text("".join(f"[{section}]\nbExperimentalStandingHolds=True\n"
            "bExperimentalInteractions=True\nbZedGrabEnabled=True\n" for section in sections), encoding="utf-16")
        for mode in ("--solo", "--host", "--address"):
            with self.subTest(mode=mode):
                argv = (mode, "example.test") if mode == "--address" else (mode,)
                match = () if mode == "--address" else ("--map", "KF-Outpost")
                args = self.options(*argv, "--vr", "--mods", "none", *match)
                if mode == "--host":
                    server = friends.configure_role(self.root / "server", "server", user, self.root / "game", args)
                    server_text = read_ini(Path(server["config_root"]) / "KFGame.ini")
                    self.assertEqual("false", values(server_text, "KF2VRNet.KF2VRNetGame")["bMultiplayerZedGrabAllowed"])
                role = friends.configure_role(self.root / mode[2:], "driver", user, self.root / "game", args)
                text = read_ini(Path(role["config_root"]) / "KFGame.ini")
                for section in sections:
                    self.assertEqual("False", values(text, section)["bExperimentalStandingHolds"])
                    self.assertEqual("True", values(text, section)["bExperimentalInteractions"])
                    self.assertEqual("True", values(text, section)["bZedGrabEnabled"])
                loadout.save_dlss_preferences(args)
                saved = json.loads((self.profile / "launcher.json").read_text())
                self.assertNotIn("standing_holds", saved)
                self.assertNotIn("multiplayer_grabs", saved)

    def test_hosted_server_and_player_raise_the_stock_net_rate_caps(self):
        self.save_profile(vr=False, mods=[])
        user = self.root / "user"
        user.mkdir()
        (user / "KFEngine.ini").write_text("[Core.System]\nPaths=stock\nScriptPaths=stock\n"
            "SeekFreePCPaths=stock\nBrewedPCPaths=stock\n[Engine.Player]\nConfiguredInternetSpeed=10000\n"
            "ConfiguredLanSpeed=20000\n[IpDrv.TcpNetDriver]\nMaxClientRate=15000\nMaxInternetClientRate=10000\n"
            "DownloadManagers=IpDrv.HTTPDownload\nDownloadManagers=Engine.ChannelDownload\n", encoding="utf-16")
        (user / "KFGame.ini").write_text("[Engine.AccessControl]\n", encoding="utf-16")
        before = config_hashes(user)
        args = self.options("--host", "--desktop", "--map", "KF-Outpost")
        for name in ("server", "driver"):
            role = friends.configure_role(self.root / name, name, user, self.root / "game", args)
            engine = read_ini(Path(role["config_root"]) / "KFEngine.ini")
            self.assertEqual(("150000", "150000"), tuple(values(engine, "Engine.Player")[key]
                             for key in ("ConfiguredInternetSpeed", "ConfiguredLanSpeed")))
            net = values(engine, "IpDrv.TcpNetDriver")
            self.assertEqual(("150000", "150000"), (net["MaxClientRate"], net["MaxInternetClientRate"]))
            if name == "server":
                self.assertEqual(("120", "120"), (net["NetServerMaxTickRate"], net["LanServerMaxTickRate"]))
            else:
                self.assertNotIn("NetServerMaxTickRate", net)
                self.assertNotIn("LanServerMaxTickRate", net)
            self.assertEqual(2, len(re.findall(r"(?m)^DownloadManagers=", engine)))
        self.assertEqual(before, config_hashes(user))

    def test_desktop_player_keeps_their_own_kf2_settings_across_sessions(self):
        self.save_profile(vr=False, mods=[])
        user = self.root / "user"
        user.mkdir()
        (user / "KFEngine.ini").write_text("[Core.System]\nPaths=stock\nScriptPaths=stock\n"
            "SeekFreePCPaths=stock\nBrewedPCPaths=stock\nSavePath=..\\..\\KFGame\\Save\n"
            "ScreenShotPath=..\\..\\KFGame\\Screenshots\n[VoIP]\nbHasVoiceEnabled=true\n"
            "[OnlineSubsystemSteamworks.OnlineSubsystemSteamworks]\nbUseVAC=true\n"
            "ProfileDataDirectory=..\\..\\KFGame\\SaveData\n", encoding="utf-16")
        (user / "KFGame.ini").write_text("[Engine.AccessControl]\nGamePassword=original\n", encoding="utf-16")
        (user / "KFInput.ini").write_text("[KFGame.KFPlayerInput]\nMouseSensitivity=30.0\n"
            'Bindings=(Name="W",Command="GBA_MoveForward")\n', encoding="utf-16")
        (user / "KFSystemSettings.ini").write_text("[SystemSettings]\nResX=2560\nResY=1440\n"
            "Fullscreen=True\n", encoding="utf-16")
        before = config_hashes(user)

        def session(name):
            args = self.options("--host", "--desktop", "--map", "KF-Outpost")
            return friends.configure_role(self.root / name, "driver", user, self.root / "game", args)

        first = session("first")
        configs = Path(first["config_root"])
        self.assertFalse(any(a == "-windowed" or a.startswith(("-ResX=", "-ResY=")) for a in first["args"]))
        engine = read_ini(configs / "KFEngine.ini")
        self.assertEqual("true", values(engine, "VoIP")["bHasVoiceEnabled"])
        self.assertEqual("..\\..\\KFGame\\Screenshots", values(engine, "Core.System")["ScreenShotPath"])
        self.assertEqual("..\\..\\KFGame\\SaveData", values(
            engine, "OnlineSubsystemSteamworks.OnlineSubsystemSteamworks")["ProfileDataDirectory"])
        self.assertEqual("false", values(engine, "OnlineSubsystemSteamworks.OnlineSubsystemSteamworks")["bUseVAC"])

        # The player changes sensitivity, a binding and the resolution in-game;
        # the game also rewrites a connection section the launcher owns.
        (configs / "KFInput.ini").write_text("[KFGame.KFPlayerInput]\nMouseSensitivity=45.0\n"
            'Bindings=(Name="W",Command="GBA_MoveForward")\nBindings=(Name="V",Command="GBA_Melee")\n',
            encoding="utf-16")
        (configs / "KFSystemSettings.ini").write_text("[SystemSettings]\nResX=1920\nResY=1080\n"
            "Fullscreen=True\n", encoding="utf-16")
        game_ini = read_ini(configs / "KFGame.ini")
        (configs / "KFGame.ini").write_text(game_ini.replace("GamePassword=fixture", "GamePassword=fixture\nExtra=1"),
                                            encoding="utf-16")
        desktop_settings.export(configs, user, self.profile)
        self.assertEqual(before, config_hashes(user))

        second = Path(session("second")["config_root"])
        player_input = values(read_ini(second / "KFInput.ini"), "KFGame.KFPlayerInput")
        self.assertEqual("45.0", player_input["MouseSensitivity"])
        self.assertIn('Bindings=(Name="V",Command="GBA_Melee")', read_ini(second / "KFInput.ini"))
        self.assertEqual("1920", values(read_ini(second / "KFSystemSettings.ini"), "SystemSettings")["ResX"])
        self.assertNotIn("Extra=1", read_ini(second / "KFGame.ini"))

        # A later change in stock KF2 wins over the saved KF2-VR copy.
        (user / "KFSystemSettings.ini").write_text("[SystemSettings]\nResX=3840\nResY=2160\n"
            "Fullscreen=True\n", encoding="utf-16")
        third = Path(session("third")["config_root"])
        self.assertEqual("3840", values(read_ini(third / "KFSystemSettings.ini"), "SystemSettings")["ResX"])
        self.assertEqual("45.0", values(read_ini(third / "KFInput.ini"), "KFGame.KFPlayerInput")["MouseSensitivity"])


if __name__ == "__main__":
    unittest.main()
