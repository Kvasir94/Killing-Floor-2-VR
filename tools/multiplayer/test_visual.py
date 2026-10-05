"""Keep real headset input isolated from the separate replay connection."""
import tempfile
import unittest
import os
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import friends
import workshop_loadout as loadout
from session import read_ini, config_hashes, role_config


class VisualRolesTests(unittest.TestCase):
    def test_locomotion_preview_uses_real_remote_pawn_and_separate_input_phases(self):
        args = friends.parse_options(["--host", "--locomotion-preview", "--prepare-only"])
        self.assertTrue(args.desktop and args.replay_teammate)
        self.assertFalse(args.vr or args.avatar_preview)
        with tempfile.TemporaryDirectory() as tmp:
            roles = self.prepare(Path(tmp), vr=False, locomotion_preview=True)
            for name in ("driver", "teammate"):
                settings = self.settings(roles[name])
                self.assertIn("bDiagnosticLocomotionReplay=true", settings)
                self.assertIn("bDiagnosticAvatarPreview=false", settings)
                self.assertIn("bDiagnosticAutoFire9mm=false", settings)
                self.assertIn("bDiagnosticMovement=false", settings)
            self.assertIn("-kf2vr-hand-replay", roles["teammate"]["args"])
            self.assertNotIn("-kf2vr-hand-replay", roles["driver"]["args"])
        for flags in (["--vr"], ["--avatar-preview"], ["--replay-match"], ["--test-map"], ["--menu"]):
            with self.assertRaises(SystemExit):
                friends.parse_options(["--host", "--locomotion-preview"] + flags)

    def prepare(self, root, vr=True, replay=True, match=False, avatar=False, eye_percent=None, **host_options):
        user = root / "user"
        user.mkdir()
        (user / "KFEngine.ini").write_text("[Core.System]\nPaths=stock\nScriptPaths=stock\n"
            "SeekFreePCPaths=stock\nBrewedPCPaths=stock\n[OnlineSubsystemSteamworks.OnlineSubsystemSteamworks]\nbUseVAC=true\n")
        (user / "KFGame.ini").write_text("[Engine.AccessControl]\nGamePassword=original\n"
            "[KF2VRNet.KF2VRNetPlayerController]\nbDiagnosticAvatarPreview=true\n"
            "bDiagnosticAvatarReplay=true\nbDiagnosticAvatarCamera=true\nbDiagnosticVisualReplay=true\n")
        (user / "KFInput.ini").write_text('[Engine.PlayerInput]\n'
            'Bindings=(Name="SpaceBar",Command="GBA_Jump")\n'
            'Bindings=(Name="F8",Command="PrevViewMode",Alt=False)\n'
            '[KFGame.KFPlayerInput]\nBindings=(Name="W",Command="GBA_MoveForward")\n'
            'Bindings=(Name="F8",Command="PrevViewMode")\n'
            'Bindings=(Name="F8",Command="ModifiedF8",Alt=True)\n'
            '[Engine.Console]\nConsoleKey=Tilde\n')
        before = config_hashes(user)
        args = SimpleNamespace(port=7777, query_port=27015, cache_root=root / "cache",
                               address="127.0.0.1", password="visual-test", vr=vr,
                               replay_teammate=replay, replay_match=match, avatar_preview=avatar,
                               eye_render_percent=eye_percent)
        args.profile_root = root / "profile"
        vars(args).update(host_options)
        with patch.object(friends, "ROOT", root):
            roles = {name: friends.configure_role(root / "run", name, user, root / "game", args)
                     for name in (["server", "driver", "teammate"] if replay else ["server", "driver"])}
        self.assertEqual(before, config_hashes(user))
        return roles

    def settings(self, role):
        return read_ini(Path(role["config_root"]) / "KFGame.ini")

    def test_menu_selections_reach_the_actual_server_role(self):
        from launch_menu import choose_options
        args = friends.parse_options(["--host", "--vr", "--menu"])
        args.profile_root = Path(tempfile.mkdtemp()) / "profile"
        loadout.load_preferences(args)
        answers = iter(["1", "2", "2", "2", "3", "4", "4", "3", "0"])
        self.assertTrue(choose_options(args, ["KF-BurningParis", "KF-Outpost"],
            read=lambda _: next(answers), write=lambda _: None))
        with tempfile.TemporaryDirectory() as tmp:
            roles = self.prepare(Path(tmp), vr=args.vr, replay=False,
                map=args.map, difficulty=args.difficulty, game_length=args.game_length)
            self.assertEqual("KF-Outpost?Game=KF2VRNet.KF2VRNetGame?Difficulty=3?GameLength=2?VRInventoryFocus=0?VRMultiplayerGrabs=0", roles["server"]["args"][0])
            self.assertFalse(roles["driver"]["native_adapter"])

    def test_menu_cancel_and_invalid_map_options(self):
        from launch_menu import choose_options
        args = friends.parse_options(["--host", "--vr", "--menu"])
        args.profile_root = Path(tempfile.mkdtemp()) / "profile"
        loadout.load_preferences(args)
        self.assertFalse(choose_options(args, ["KF-BurningParis"], read=lambda _: "q", write=lambda _: None))
        with redirect_stderr(StringIO()):
            for flags in (["--host", "--map", "KF-Outpost?Game=Other"],
                          ["--host", "--test-map", "--map", "KF-Outpost"],
                          ["--difficulty", "hard"]):
                with self.assertRaises(SystemExit):
                    friends.parse_options(flags)

    def test_headset_receives_no_replay_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            roles = self.prepare(Path(tmp))
            human, replay = roles["driver"], roles["teammate"]
            self.assertIn("-kf2vr-stereo", human["args"])
            self.assertNotIn("-kf2vr-hand-replay", human["args"])
            for key in ("bDiagnosticAutoFire9mm", "bDiagnosticMovement", "bDiagnosticDamage",
                        "bDiagnosticPoseDropout", "bDiagnosticLifecycle", "bDiagnosticVisualReplay"):
                self.assertIn(key + "=false", self.settings(human))
            self.assertIn("bEnableVRClient=true", self.settings(human))
            self.assertIn("-kf2vr-hand-replay", replay["args"])
            self.assertNotIn("-kf2vr-stereo", replay["args"])
            for key in ("bDiagnosticAutoFire9mm", "bDiagnosticMovement", "bDiagnosticVisualReplay"):
                self.assertIn(key + "=true", self.settings(replay))
            self.assertNotEqual(human["config_root"], replay["config_root"])
            self.assertIn("?VRNetRecovery=1", roles["server"]["args"][0])
            self.assertIn("Name=Replay_Teammate", replay["args"][0])
            self.assertNotIn("SpectatorOnly", replay["args"][0])
            self.assertIn("bDiagnosticObserverOnly=false", self.settings(replay))
            for role in roles.values():
                self.assertIn("GamePassword=visual-test", self.settings(role))
            ports = [arg for r in roles.values() for arg in r["args"]
                     if arg.startswith(("-Port=", "-QueryPort="))]
            self.assertEqual(6, len(ports))
            self.assertEqual(6, len({p.split("=")[1] for p in ports}))

    def test_desktop_human_still_uses_native_teammate(self):
        with tempfile.TemporaryDirectory() as tmp:
            roles = self.prepare(Path(tmp), vr=False, match=True)
            self.assertFalse(roles["driver"]["native_adapter"])
            self.assertTrue(roles["teammate"]["native_adapter"])
            self.assertNotIn("?VRNetRecovery=1", roles["server"]["args"][0])

    def test_normal_host_stays_manual(self):
        with tempfile.TemporaryDirectory() as tmp:
            roles = self.prepare(Path(tmp), replay=False)
            self.assertNotIn("VRNetDiagnostics", roles["server"]["args"][0])
            self.assertIn("bDiagnosticObserverDebug=false", self.settings(roles["driver"]))
            for role in roles.values():
                for key in ("bDiagnosticAvatarPreview", "bDiagnosticAvatarReplay", "bDiagnosticAvatarCamera", "bDiagnosticVisualReplay"):
                    self.assertIn(key + "=false", self.settings(role))

    def test_avatar_preview_isolated_to_live_observer(self):
        for vr in (False, True):
            with self.subTest(vr=vr), tempfile.TemporaryDirectory() as tmp:
                roles = self.prepare(Path(tmp), vr=vr, avatar=True)
                human, teammate, server = (roles[k] for k in ("driver", "teammate", "server"))
                self.assertIn("bDiagnosticAvatarPreview=true", self.settings(human))
                self.assertIn("bDiagnosticAvatarReplay=false", self.settings(human))
                self.assertIn("bDiagnosticAvatarCamera=" + ("false" if vr else "true"), self.settings(human))
                self.assertIn("bDiagnosticAvatarPreview=false", self.settings(teammate))
                self.assertIn("bDiagnosticAvatarReplay=true", self.settings(teammate))
                self.assertIn("bDiagnosticAvatarCamera=false", self.settings(teammate))
                self.assertIn("bDiagnosticAvatarPreview=false", self.settings(server))
                self.assertIn("bDiagnosticAvatarReplay=false", self.settings(server))
                self.assertIn("bDiagnosticAvatarCamera=false", self.settings(server))
                for key in ("bDiagnosticAutoFire9mm", "bDiagnosticMovement", "bDiagnosticDamage",
                            "bDiagnosticPoseDropout", "bDiagnosticLifecycle", "bDiagnosticVisualReplay"):
                    self.assertIn(key + "=false", self.settings(human))
                # Preview does not silently enable the aim-at-target damage fixture.
                self.assertIn("bDiagnosticDamage=false", self.settings(teammate))
                # Head/hand replay and fire/reload continue while inspection
                # stays at spawn, without sending repeated forward stick input.
                self.assertIn("bDiagnosticMovement=false", self.settings(teammate))
                self.assertIn("bDiagnosticAutoFire9mm=true", self.settings(teammate))
                self.assertIn("bDiagnosticVisualReplay=true", self.settings(teammate))
                self.assertIn("bDiagnosticRoomMovement=false", self.settings(teammate))
                self.assertIn("?VRNetRecovery=1", server["args"][0])
                self.assertIn("?VRNetClients=2", server["args"][0])
                self.assertIn("-kf2vr-hand-replay", teammate["args"])
                self.assertNotIn("-kf2vr-stereo", teammate["args"])
                self.assertEqual(vr, "-kf2vr-stereo" in human["args"])
                self.assertEqual(vr, human["native_adapter"])
                self.assertNotIn("-kf2vr-hand-replay", human["args"])

    def test_ordinary_visual_replay_does_not_inherit_avatar_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            roles = self.prepare(Path(tmp))
            self.assertIn("bDiagnosticMovement=true", self.settings(roles["teammate"]))
            for role in roles.values():
                self.assertIn("bDiagnosticAvatarPreview=false", self.settings(role))
                self.assertIn("bDiagnosticAvatarReplay=false", self.settings(role))
                self.assertIn("bDiagnosticAvatarCamera=false", self.settings(role))

    def test_base_diagnostic_resets_saved_preview_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.prepare(root)
            user = root / "user"
            before = config_hashes(user)
            for name in ("server", "driver", "observer"):
                role = role_config(root / "automated", name, user, root / "packages",
                                   root / "game", 7777, 27015, root / "cache", True,
                                   native_replay=True)
                for key in ("bDiagnosticAvatarPreview", "bDiagnosticAvatarReplay", "bDiagnosticAvatarCamera", "bDiagnosticVisualReplay"):
                    self.assertIn(key + "=false", self.settings(role))
            self.assertEqual(before, config_hashes(user))

    def test_replay_controls_do_not_depend_on_player_preferences(self):
        from vr_config import values
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.prepare(root)
            user = root / "user"
            path = user / "KFGame.ini"
            path.write_text(path.read_text() + "\n[KF2VR.VRHandsBridge]\n"
                "bInteractiveReloads=True\nMovementHand=1\nPreferredWeaponHand=0\nLocomotionMode=1\n")
            before = config_hashes(user)
            for replay in (False, True):
                role = role_config(root / str(replay), "driver", user, root / "packages",
                    root / "game", 7777, 27015, root / "cache", True, native_replay=replay)
                for section in ("KF2VR.VRHandsBridge", "KF2VRNetClient.KF2VRNetHandsBridge"):
                    settings = values(self.settings(role), section)
                    self.assertEqual(settings["bInteractiveReloads"].lower(), "false" if replay else "true")
                    self.assertEqual(settings["MovementHand"], "0" if replay else "1")
                    self.assertEqual(settings["PreferredWeaponHand"], "1" if replay else "0")
                    self.assertEqual(settings["LocomotionMode"], "0" if replay else "1")
            self.assertEqual(before, config_hashes(user))

    def test_f8_changes_only_live_client_for_selected_mode(self):
        for vr, replay, avatar in ((False, True, True), (True, True, True),
                                    (False, True, False), (False, False, False),
                                    (True, False, False), (True, True, False)):
            with self.subTest(vr=vr, replay=replay, avatar=avatar), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                roles = self.prepare(root, vr=vr, replay=replay, avatar=avatar)
                original = read_ini(root / "user/KFInput.ini")
                for name, role in roles.items():
                    actual = read_ini(Path(role["config_root"]) / "KFInput.ini")
                    command = ("KF2VRAvatarToggleCamera" if avatar and not vr else
                               "KF2VRThirdPersonToggle" if vr and not avatar else None)
                    if name == "driver" and command:
                        self.assertEqual(2, actual.count('Command="' + command + '"'))
                        self.assertNotIn('Command="PrevViewMode"', actual)
                        for retained_command in ("GBA_Jump", "GBA_MoveForward", "ModifiedF8"):
                            self.assertIn('Command="' + retained_command + '"', actual)
                        self.assertIn("ConsoleKey=Tilde", actual)
                        self.assertEqual(actual, friends.preview_camera_binding(actual, command))
                    else:
                        self.assertEqual(original, actual)

    def test_eye_resolution_is_recorded_and_only_in_live_vr_role_environment(self):
        for selected in (None, 50, 75, 100):
            with self.subTest(selected=selected), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                roles = self.prepare(root, vr=True, eye_percent=selected)
                inherited = {"Path": "system-path", "SteamAppId": "232090",
                             "KF2VR_EYE_RENDER_PERCENT": "1", "kf2vr_eye_render_percent": "999",
                             "KF2VR_LOG_PATH": "other-session.log", "Kf2Vr_HAND_REPLAY": "1"}
                before = inherited.copy()
                for name, role in roles.items():
                    environment = friends.role_environment(inherited, role)
                    self.assertEqual("system-path", environment["Path"])
                    self.assertEqual("232090", environment["SteamAppId"])
                    self.assertNotIn("kf2vr_eye_render_percent", environment)
                    self.assertNotIn("Kf2Vr_HAND_REPLAY", environment)
                    if name == "driver":
                        self.assertEqual(75 if selected is None else selected, role["eye_render_percent"])
                        self.assertEqual(str(role["eye_render_percent"]), environment["KF2VR_EYE_RENDER_PERCENT"])
                    else:
                        self.assertNotIn("eye_render_percent", role)
                        self.assertNotIn("KF2VR_EYE_RENDER_PERCENT", environment)
                    if role["native_adapter"]:
                        self.assertEqual(str(Path(role["log"]).with_name("native.log")), environment["KF2VR_LOG_PATH"])
                    else:
                        self.assertNotIn("KF2VR_LOG_PATH", environment)
                self.assertEqual(before, inherited)

    def test_non_vr_role_cannot_inherit_or_forge_eye_resolution_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            roles = self.prepare(Path(tmp), vr=False)
            for role in roles.values():
                self.assertNotIn("eye_render_percent", role)
                environment = friends.role_environment({"kf2vr_eye_render_percent": "75"}, role)
                self.assertNotIn("KF2VR_EYE_RENDER_PERCENT", environment)
                self.assertNotIn("kf2vr_eye_render_percent", environment)
                with self.assertRaises(ValueError):
                    friends.role_environment({}, dict(role, eye_render_percent=75))
        with tempfile.TemporaryDirectory() as tmp:
            driver = self.prepare(Path(tmp), vr=True)["driver"]
            for value in (True, 75.0, "75", 0, 101):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    friends.role_environment({}, dict(driver, eye_render_percent=value))


class AvatarCaptureTests(unittest.TestCase):
    def capture(self, root, filename, content=b"BM-test-capture", folder="Win64/map", modified=150):
        path = root / "KFGame/Screenshots" / folder / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        os.utime(path, (modified, modified))
        return path

    def collect(self, root, names, expected=6):
        log = "\n".join("KF2VRNet avatar_capture name=" + name for name in names)
        return friends.collect_avatar_captures(root / "run", root / "KFGame/Config", log, 100, 200, expected)

    def test_collects_only_six_exact_logged_current_files_and_preserves_originals(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            names = [f"KF2VR_Avatar_12_34_{index}" for index in range(1, 7)]
            originals = [self.capture(root, "KF-BURNINGPARIS-PC-16-21.12.46" + name + "0.bmp",
                                      content=b"BM-capture-" + name.encode()) for name in names]
            # Near matches and unrelated new images must not enter the receipt.
            untouched = [self.capture(root, names[0] + "9.bmp"),
                         self.capture(root, "KF2VR_Avatar_12_35_10.bmp"),
                         self.capture(root, "unrelated.bmp")]
            result = self.collect(root, names)
            self.assertTrue(result["collection_complete"])
            self.assertFalse(result["capture_missing"])
            self.assertFalse(result["visual_acceptance_verified"])
            self.assertEqual(6, len(list((root / "run/captures").iterdir())))
            for entry, original in zip(result["entries"], originals):
                self.assertEqual("copied", entry["status"])
                info, = entry["files"]
                self.assertEqual(str(original.resolve()), info["source_path"])
                self.assertEqual(friends.digest(original), info["source_sha256"])
                self.assertEqual(info["source_sha256"], info["copied_sha256"])
                self.assertEqual(original.read_bytes(), Path(info["copied_path"]).read_bytes())
                self.assertEqual(150, original.stat().st_mtime)
            self.assertTrue(all(path.exists() for path in untouched))

    def test_stale_and_future_matches_are_retained_without_becoming_captures(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            name = "KF2VR_Avatar_12_34_1"
            old = self.capture(root, name + "0.bmp", modified=99)
            future = self.capture(root, name + ".bmp", folder="future", modified=201)
            result = self.collect(root, [name], expected=1)
            self.assertFalse(result["collection_complete"])
            self.assertTrue(result["capture_missing"])
            entry, = result["entries"]
            self.assertEqual("missing", entry["status"])
            self.assertEqual({str(old.resolve()), str(future.resolve())},
                             {item["source_path"] for item in entry["stale_sources"]})
            self.assertFalse((root / "run/captures").exists())

    def test_multiple_current_matches_are_explicitly_ambiguous(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            name = "KF2VR_Avatar_12_34_1"
            sources = [self.capture(root, name + "0.bmp", folder=folder) for folder in ("one", "two")]
            result = self.collect(root, [name], expected=1)
            self.assertEqual("ambiguous", result["entries"][0]["status"])
            self.assertEqual(2, len(result["entries"][0]["matching_sources"]))
            self.assertTrue(result["capture_missing"])
            self.assertFalse(result["all_logged_captures_collected"])
            self.assertTrue(all(path.exists() for path in sources))
            self.assertFalse((root / "run/captures").exists())

    def test_invalid_or_absent_logged_names_cannot_select_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.capture(root, "KF2VR_Avatar_12_34_10.bmp")
            result = self.collect(root, ["../../KF2VR_Avatar_12_34_1", "KF2VR_Avatar_1"])
            self.assertEqual(2, len(result["invalid_requests"]))
            self.assertFalse(result["collection_complete"])
            self.assertTrue(result["capture_missing"])
            self.assertEqual([], result["entries"])
            self.assertTrue(original.exists())
            empty = self.collect(root, [])
            self.assertEqual(6, empty["missing_request_count"])
            self.assertTrue(empty["capture_missing"])
            self.assertFalse(empty["visual_acceptance_verified"])

    def test_collection_is_idempotent_and_never_overwrites_a_different_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            name = "KF2VR_Avatar_12_34_1"
            original = self.capture(root, name + ".BMP")
            first = self.collect(root, [name], expected=1)
            self.assertTrue(first["collection_complete"])
            self.assertEqual(first, self.collect(root, [name], expected=1))
            target = Path(first["entries"][0]["files"][0]["copied_path"])
            target.write_bytes(b"existing different evidence")
            again = self.collect(root, [name], expected=1)
            self.assertEqual("copy_failed", again["entries"][0]["status"])
            self.assertEqual(b"existing different evidence", target.read_bytes())
            self.assertEqual(b"BM-test-capture", original.read_bytes())
            self.assertFalse(again["collection_complete"])

    def test_distinct_request_bound_and_incomplete_six_capture_sequence_are_visible(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            name = "KF2VR_Avatar_12_34_1"
            self.capture(root, name + "0.bmp")
            partial = self.collect(root, [name, name])
            self.assertEqual(2, len(partial["request_events"]))
            self.assertTrue(partial["all_logged_captures_collected"])
            self.assertEqual(5, partial["missing_request_count"])
            self.assertFalse(partial["collection_complete"])
            many = self.collect(root, [f"KF2VR_Avatar_{world}_34_1" for world in range(7)])
            self.assertTrue(many["search_errors"])
            self.assertFalse(many["collection_complete"])

    def test_unstarted_client_and_unreadable_log_do_not_mask_fixture_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            role = {"log": str(root / "not_started/game.log")}
            empty = friends.avatar_capture_receipt(root / "run", root / "KFGame/Config", role, 100)
            self.assertEqual(6, empty["missing_request_count"])
            self.assertFalse(empty["collection_complete"])
            with patch.object(friends, "log_text", side_effect=PermissionError("log read denied")):
                with self.assertRaisesRegex(RuntimeError, "original fixture failure"):
                    try:
                        raise RuntimeError("original fixture failure")
                    finally:
                        failed = friends.avatar_capture_receipt(root / "run", root / "KFGame/Config", role, 100)
            self.assertEqual("collection_failed", failed["status"])
            self.assertEqual(["log read denied"], failed["search_errors"])
            self.assertTrue(failed["capture_missing"])
            self.assertFalse(failed["visual_acceptance_verified"])


class AvatarOptionsTests(unittest.TestCase):
    def test_normal_vr_launch_defaults_to_manual_unbounded_play_and_default_resolution(self):
        args = friends.parse_options(["--host", "--vr"])
        self.assertIsNone(args.duration)
        self.assertIsNone(args.eye_render_percent)
        self.assertFalse(args.prepare_only)
        self.assertFalse(args.avatar_preview)
        self.assertFalse(args.replay_teammate)
        for percent in (50, 75, 100):
            args = friends.parse_options(["--host", "--vr", "--eye-render-percent", str(percent)])
            self.assertEqual(percent, args.eye_render_percent)

    def test_test_map_requires_explicit_launch_option(self):
        self.assertFalse(friends.parse_options(["--host"]).test_map)
        self.assertTrue(friends.parse_options(["--host", "--test-map"]).test_map)

    def test_eye_resolution_rejects_non_vr_and_invalid_cli_values(self):
        # A host with neither play-mode flag has not chosen the flat screen:
        # the profile decides, so a scale is a legitimate request there.
        self.assertEqual(75, friends.parse_options(["--host", "--eye-render-percent", "75"]).eye_render_percent)
        cases = [["--eye-render-percent", "75"],
                 ["--host", "--desktop", "--eye-render-percent", "75"],
                 ["--host", "--avatar-preview", "--eye-render-percent", "75"]]
        cases += [["--host", "--vr", "--eye-render-percent", value]
                  for value in ("0", "49", "101", "75.0", "1e2", "true", "-50",
                                "75 -kf2vr-hand-replay", "75\n100", "99999999999999999999")]
        for argv in cases:
            with self.subTest(argv=argv), redirect_stderr(StringIO()), self.assertRaises(SystemExit) as error:
                friends.parse_options(argv)
            self.assertEqual(2, error.exception.code)

    def test_avatar_cleanup_ends_live_observation_before_pose_producer(self):
        owned = [({"role": name}, object()) for name in ("server", "driver", "teammate")]
        original = owned.copy()
        self.assertEqual([owned[1], owned[2], owned[0]], friends.cleanup_order(owned, True))
        self.assertEqual(list(reversed(owned)), friends.cleanup_order(owned, False))
        self.assertEqual(original, owned)
        # Failed/partial startup still orders only processes actually owned.
        self.assertEqual([owned[1], owned[0]], friends.cleanup_order(owned[:2], True))
        self.assertEqual(owned[:1], friends.cleanup_order(owned[:1], True))
        self.assertEqual([], friends.cleanup_order([], True))

    def test_f8_binding_preserves_lf_and_crlf_without_double_translation(self):
        for newline in ("\n", "\r\n"):
            original = newline.join(('[Engine.PlayerInput]', 'Bindings=(Name="W",Command="Forward")',
                                     'Bindings=(Name="F8",Command="PrevViewMode")', ''))
            actual = friends.preview_camera_binding(original)
            self.assertEqual(actual, friends.preview_camera_binding(actual))
            self.assertIn('Bindings=(Name="W",Command="Forward")' + newline, actual)
            self.assertNotIn("\r\r\n", actual)
            self.assertEqual(actual.count(newline), actual.count("\n"))

    def test_solo_desktop_preview_enables_separate_replay(self):
        args = friends.parse_options(["--host", "--avatar-preview", "--prepare-only"])
        self.assertTrue(args.replay_teammate)
        self.assertTrue(args.prepare_only)
        self.assertFalse(args.vr)
        self.assertFalse(args.replay_match)

    def test_headset_preview_is_explicit(self):
        args = friends.parse_options(["--host", "--avatar-preview", "--vr"])
        self.assertTrue(args.vr)
        self.assertTrue(args.replay_teammate)

    def test_preview_rejects_remote_join_and_enemy_wave_mode(self):
        for argv in (["--avatar-preview"], ["--host", "--avatar-preview", "--replay-match"]):
            with self.subTest(argv=argv), redirect_stderr(StringIO()):
                with self.assertRaises(SystemExit) as error:
                    friends.parse_options(argv)
                self.assertEqual(2, error.exception.code)


if __name__ == "__main__":
    unittest.main()
