"""Offline Solo/Host preference and configuration contracts; no game launch."""
import json
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
import launch_state
import workshop_loadout as loadout
from session import config_hashes, read_ini
from vr_config import values
from workshop_map import MAP_NAME


class SoloLauncherTests(unittest.TestCase):
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
                 "inventory_focus": True, "multiplayer_grabs": True}
        saved.update(overrides)
        (self.profile / "launcher.json").write_text(json.dumps(saved), encoding="utf-8")
        return saved

    def options(self, *flags):
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

    def test_solo_maps_require_client_files_and_exclude_host_workshop_content(self):
        game = self.install_maps("KF-ZedLanding", "KF-Outpost", "KF-BurningParis", "KF-AshwoodAsylum",
                                 MAP_NAME, *loadout.MAPS)
        outside = game / "KFGame/Cache/other"
        outside.mkdir(parents=True)
        (outside / "KF-CacheOnly.kfm").write_bytes(b"map fixture")
        self.assertEqual(["KF-BurningParis", "KF-Outpost", "KF-AshwoodAsylum", "KF-ZedLanding"],
                         launch_menu.installed_solo_maps(game))
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
        self.assertEqual(([], False, 0, False, False),
                         (solo.mods, solo.damage_popups, solo.test_map_players,
                          solo.inventory_focus, solo.multiplayer_grabs))
        solo.map, solo.difficulty, solo.game_length, solo.vr_quality = "KF-Outpost", "suicidal", "medium", "performance"
        loadout.save_preferences(solo)
        saved = json.loads((self.profile / "launcher.json").read_text(encoding="utf-8"))
        for key in ("mods", "damage_popups", "test_map_players", "inventory_focus", "multiplayer_grabs"):
            self.assertEqual(previous[key], saved[key], key)
        host = self.options("--host")
        self.assertTrue(host.vr)
        self.assertEqual(("KF-Outpost", "suicidal", "medium", "performance"),
                         (host.map, host.difficulty, host.game_length, host.vr_quality))
        self.assertEqual((previous["mods"], True, 6, True, True),
                         (host.mods, host.damage_popups, host.test_map_players,
                          host.inventory_focus, host.multiplayer_grabs))

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
        self.assertEqual(([], False, False), (args.mods, args.inventory_focus, args.multiplayer_grabs))
        self.assertTrue(args.map_requested)
        self.assertEqual("KF-Outpost", args.map)
        with self.assertRaises(RuntimeError):
            launch_menu.resolve_solo_map(args, ["KF-BurningParis"])

    def test_launch_state_exposes_client_solo_maps_separately_from_host_maps(self):
        self.save_profile()
        game = self.install_maps("KF-Outpost", MAP_NAME, next(iter(loadout.MAPS)))
        with patch.object(loadout, "profile_root", return_value=self.profile):
            state = launch_state.describe(game, self.root / "server", self.root / "package")
        self.assertEqual(["KF-Outpost"], state["solo_maps"])
        self.assertIn(MAP_NAME, state["maps"])
        self.assertIn(next(iter(loadout.MAPS)), state["maps"])
        self.assertEqual(state, json.loads(json.dumps(state)))

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
        self.assertEqual("False", settings[0]["DynamicShadows"])
        self.assertEqual("0.8", settings[0]["MaxDrawDistanceScale"])
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
            self.assertEqual(("40000", "40000"), tuple(values(engine, "Engine.Player")[key]
                             for key in ("ConfiguredInternetSpeed", "ConfiguredLanSpeed")))
            net = values(engine, "IpDrv.TcpNetDriver")
            self.assertEqual(("40000", "40000"), (net["MaxClientRate"], net["MaxInternetClientRate"]))
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
