"""Small CPU-only regressions for the release/launcher failures found in play."""
import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import acceptance
import friends
import vr_config
from evidence import verify_paired_smoke
from session import read_ini
from workshop_map import MAP_NAME, ensure_map, validate_map

ROOT = Path(__file__).resolve().parents[2]


class PlayableContractTests(unittest.TestCase):
    def test_teleport_reach_and_recharge_never_come_from_a_profile(self):
        # The 2026-09-26 playtest profile still carried the 650 UU sprint-parity
        # preset; exact-preset migration only knew the later 1350 one.
        defaults = vr_config.DEFAULTS["KF2VR.VRHandsBridge"]
        for stale in ({"TeleportRange": "650.0", "TeleportSustainedSpeed": "500.0",
                       "TeleportMinCooldown": "1.0", "TeleportMaxCooldown": "1.30"},
                      {"TeleportRange": "1350.0", "TeleportSustainedSpeed": "1690.0",
                       "TeleportMinCooldown": "0.25", "TeleportMaxCooldown": "0.80"},
                      {"TeleportRange": "1100.0"}):
            merged = vr_config.merged(defaults, stale)
            for key in vr_config.SHIPPED_TUNING:
                self.assertEqual(defaults[key], merged[key])

    def test_stale_override_does_not_bypass_package_integrity(self):
        import json
        from contextlib import redirect_stdout
        from io import StringIO
        from release_state import digest, main

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "build/multiplayer"
            release = base / "releases/test-release"
            release.mkdir(parents=True)
            artifact = release / "game.u"
            artifact.write_bytes(b"built package")
            manifest = release / "release.json"
            manifest.write_text(json.dumps({"files_sha256": {"game.u": digest(artifact)},
                "workspace_sources_sha256": {"runtime.py": "built"}}))
            (base / "current-release.json").write_text(json.dumps({
                "release": release.name, "manifest_sha256": digest(manifest)}))
            args = ["--workspace", str(root)]
            with patch("release_state.workspace_sources", return_value={"runtime.py": "edited"}):
                with self.assertRaisesRegex(RuntimeError, "AllowStale"):
                    main(args)
                output = StringIO()
                with redirect_stdout(output):
                    main(args + ["--allow-stale"])
                self.assertIn("Launching stale package by request: test-release", output.getvalue())
                with redirect_stdout(StringIO()), patch("builtins.input", side_effect=["invalid", "1"]):
                    self.assertIsNone(main(args + ["--menu"]))
                for choice in ("", "q"):
                    with redirect_stdout(StringIO()), patch("builtins.input", return_value=choice):
                        self.assertEqual(2, main(args + ["--menu"]))
                for interruption in (EOFError, KeyboardInterrupt):
                    with redirect_stdout(StringIO()), patch("builtins.input", side_effect=interruption):
                        self.assertEqual(2, main(args + ["--menu"]))
                with patch("release_state.workspace_sources", return_value={"runtime.py": "built"}), \
                        redirect_stdout(StringIO()), patch("builtins.input") as prompt:
                    main(args + ["--menu"])
                    prompt.assert_not_called()
                artifact.write_bytes(b"damaged package")
                with self.assertRaisesRegex(RuntimeError, "Release file missing or changed"):
                    main(args + ["--allow-stale"])
                with patch("builtins.input") as prompt:
                    with self.assertRaisesRegex(RuntimeError, "Release file missing or changed"):
                        main(args + ["--menu"])
                    prompt.assert_not_called()
                artifact.write_bytes(b"built package")
                manifest.write_text(manifest.read_text() + " ")
                with self.assertRaisesRegex(RuntimeError, "manifest has changed"):
                    main(args + ["--allow-stale"])

    def test_offline_test_edits_do_not_invalidate_playable_sources(self):
        from release_state import workspace_sources, verify_workspace

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in workspace_sources(ROOT):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("baseline", encoding="utf-8")
            test = root / "tools/multiplayer/test_example.py"
            test.write_text("original test", encoding="utf-8")
            manifest = {"workspace_sources_sha256": workspace_sources(root)}
            self.assertNotIn("tools/multiplayer/test_example.py", manifest["workspace_sources_sha256"])
            test.write_text("changed test", encoding="utf-8")
            verify_workspace(root, manifest)
            test.unlink()
            verify_workspace(root, manifest)
            test.write_text("new test", encoding="utf-8")
            verify_workspace(root, manifest)

            runtime = root / "tools/multiplayer/friends.py"
            runtime.write_text("changed runtime", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "friends.py"):
                verify_workspace(root, manifest)
            runtime.write_text("baseline", encoding="utf-8")
            added = root / "tools/multiplayer/new_runtime.py"
            added.write_text("new runtime", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "new_runtime.py"):
                verify_workspace(root, manifest)
            added.unlink()
            runtime.unlink()
            with self.assertRaisesRegex(RuntimeError, "friends.py"):
                verify_workspace(root, manifest)

    def test_nonzero_defaults_and_saved_override_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "Config"; config.mkdir()
            (config / "KFGame.ini").write_text("[KF2VR.VRSessionUI]\nSnapTurnDegrees=0\nSmoothTurnScale=0\nEyeRenderPercent=75.5\n")
            self.assertEqual(75, vr_config.import_preferences(config, root=root / "profile"))
            text = read_ini(config / "KFGame.ini")
            for section in ("KF2VR.VRSessionUI", "KF2VRNetClient.KF2VRNetSessionUI"):
                values = vr_config.values(text, section)
                self.assertEqual("30", values["SnapTurnDegrees"])
                self.assertEqual("0.5", values["SmoothTurnScale"])
            text = text.replace("EyeRenderPercent=75", "EyeRenderPercent=80")
            (config / "KFGame.ini").write_text(text, encoding="utf-16")
            vr_config.export_preferences(config, root / "profile")
            self.assertEqual(80, vr_config.import_preferences(config, root=root / "profile"))
            self.assertEqual(85, vr_config.import_preferences(config, root=root / "profile", eye_percent=85))

    def test_profile_whitelist_does_not_import_diagnostics(self):
        saved = "[KF2VR.VRHandsBridge]\nbDualHandReplay=True\nChestGrenadeOffset=(X=12,Y=0,Z=0)\n"
        text = vr_config.apply_preferences("", saved)
        self.assertNotIn("bDualHandReplay", text)
        self.assertIn("ChestGrenadeOffset=" + vr_config.DEFAULTS["KF2VR.VRHandsBridge"]["ChestGrenadeOffset"], text)

    def test_profile_carries_preferences_that_have_no_shipped_default(self):
        saved = ("[KF2VR.VRHandsBridge]\nFirearmAimYawDegrees=2.5\n"
                 "SelectorFavorites=KFWeap_Pistol_9mm\nSelectorFavorites=KFWeap_Pistol_Deagle\n")
        text = vr_config.apply_preferences("", saved)
        for section in ("KF2VR.VRHandsBridge", "KF2VRNetClient.KF2VRNetHandsBridge"):
            values = vr_config.items(text, section)
            self.assertEqual("2.5", values["FirearmAimYawDegrees"])
            self.assertEqual(["KFWeap_Pistol_9mm", "KFWeap_Pistol_Deagle"], values["SelectorFavorites"])

    def test_legacy_bridge_geometry_migrates_once_and_session_edits_win(self):
        session = "KF2VR.VRSessionUI"
        bridge = "KF2VR.VRHandsBridge"
        legacy = f"[{bridge}]\nSpatialMenuDistance=2.1\nSpatialMenuHeight=-0.3\nSpatialMenuScale=1.2\n"
        migrated = vr_config.apply_preferences("", legacy)
        for section in (session, vr_config.ALIASES[session], bridge, vr_config.ALIASES[bridge]):
            geometry = vr_config.values(migrated, section)
            self.assertEqual("2.1", geometry["SpatialMenuDistance"])
            self.assertEqual("-0.3", geometry["SpatialMenuHeight"])
            self.assertEqual("1.2", geometry["SpatialMenuScale"])
        # Resetting the session to defaults must not resurrect bridge-only edits.
        reset = f"[{session}]\nMenuPlacementRevision=1\nSpatialMenuDistance=1.5\nSpatialMenuHeight=0\nSpatialMenuScale=1.0\n" + legacy
        current = vr_config.apply_preferences("", reset)
        self.assertEqual("1.5", vr_config.values(current, bridge)["SpatialMenuDistance"])
        # A pre-migration customized session also beats conflicting bridge values.
        customized = f"[{session}]\nSpatialMenuDistance=1.8\n" + legacy
        self.assertEqual("1.8", vr_config.values(vr_config.apply_preferences("", customized), session)["SpatialMenuDistance"])

    def test_session_geometry_bounds_and_network_export_match_native_panel(self):
        session = "KF2VR.VRSessionUI"
        bridge = "KF2VR.VRHandsBridge"
        for key, invalid in (("SpatialMenuDistance", "0.5"), ("SpatialMenuScale", "2"),
                             ("SpatialMenuHeight", "nan"), ("SpatialMenuHeight", "0.6")):
            result = vr_config.values(vr_config.apply_preferences("", f"[{session}]\n{key}={invalid}\n"), session)
            self.assertEqual(vr_config.DEFAULTS[session][key], result[key])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "Config"; config.mkdir()
            text = vr_config.apply_preferences("", "")
            from session import set_ini
            text = set_ini(text, vr_config.ALIASES[session], {"SpatialMenuDistance": "2.4", "SpatialMenuHeight": "-0.4", "SpatialMenuScale": "1.4"})
            (config / "KFGame.ini").write_text(text, encoding="utf-16")
            vr_config.export_preferences(config, root / "profile", network=True)
            saved = read_ini(root / "profile/KFGame.ini")
            for section in (session, vr_config.ALIASES[session], bridge, vr_config.ALIASES[bridge]):
                self.assertEqual("2.4", vr_config.values(saved, section)["SpatialMenuDistance"])
                self.assertEqual("1.4", vr_config.values(saved, section)["SpatialMenuScale"])

    def test_chest_default_migration_preserves_calibration(self):
        default = vr_config.DEFAULTS["KF2VR.VRHandsBridge"]["ChestGrenadeOffset"]
        for old in ("(X=12,Y=0,Z=0)", "(X=10,Y=-18,Z=-6)"):
            self.assertEqual(default, vr_config.normalized("ChestGrenadeOffset", old, default))
        custom = "(X=15,Y=2,Z=-10)"
        self.assertEqual(custom, vr_config.normalized("ChestGrenadeOffset", custom, default))

    def test_smoke_stays_small_and_missing_evidence_fails(self):
        self.assertEqual(["pistol_smoke"], [name for name, _ in acceptance.scenarios("smoke")])
        self.assertFalse(verify_paired_smoke("", "")["passed"])
        logs = []
        for mode in ("NM_DedicatedServer", "NM_Client"):
            logs.append("\n".join(f"KF2VRNet paired_case index={i} phase={phase} passed=True netmode={mode}"
                for i in (0, 1) for phase in ("ready", "left_fire", "right_fire", "reload", "restore")))
        logs[1] += "\n" + "\n".join(f"KF2VRNet playable_contract phase={p} passed=True netmode=NM_Client"
            for p in ("settings", "comfort_signals", "chest_anchor"))
        self.assertTrue(verify_paired_smoke(*logs)["passed"])
        self.assertFalse(verify_paired_smoke(logs[0], logs[1].replace("phase=reload", "phase=missing", 1))["passed"])
        self.assertFalse(acceptance.passed_run({"runtime_pass": True}, "release", "hash"))

    def test_emulated_acceptance_does_not_require_physical_headset(self):
        record = {"runtime_pass": True, "user_config_preserved": True,
                  "cleanup_errors": [], "finished_utc": "2026-10-03T00:00:00Z",
                  "release": "release", "release_manifest_sha256": "hash",
                  "headset_accepted": False}
        self.assertTrue(acceptance.passed_run(record, "release", "hash"))
        self.assertTrue(acceptance.OPTIONAL_HEADSET_FEEDBACK)
        self.assertTrue(all("headset" not in check.lower() for check in acceptance.MANUAL_CHECKS))
        record["runtime_pass"] = False
        self.assertFalse(acceptance.passed_run(record, "release", "hash"))

    def test_test_map_requires_real_unreal_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(RuntimeError):
                ensure_map(root / "cache", root / "steamcmd", download=False)
            path = root / (MAP_NAME + ".kfm")
            path.write_bytes(b"\xc1\x83\x2a\x9e" + bytes(2048))
            self.assertEqual(path, validate_map(path))
            path.write_bytes(b"not a map" + bytes(2048))
            with self.assertRaises(RuntimeError):
                validate_map(path)

    def test_portal_gun_is_a_solo_only_option(self):
        from contextlib import redirect_stderr
        from io import StringIO
        import workshop_loadout as loadout
        self.assertIsNone(friends.parse_options(["--solo"]).portal_gun)
        self.assertTrue(friends.parse_options(["--solo", "--portal-gun"]).portal_gun)
        self.assertFalse(friends.parse_options(["--solo", "--no-portal-gun"]).portal_gun)
        with redirect_stderr(StringIO()):
            for args in (["--host", "--portal-gun"], ["--portal-gun"], ["--no-portal-gun"]):
                with self.assertRaises(SystemExit):
                    friends.parse_options(args)
        args = friends.parse_options(["--solo", "--vr"])
        with tempfile.TemporaryDirectory() as tmp:
            args.profile_root = Path(tmp)
            loadout.load_preferences(args)
            self.assertFalse(args.portal_gun)
            args.portal_gun = True
            loadout.save_preferences(args)
            again = friends.parse_options(["--solo", "--vr"])
            again.profile_root = Path(tmp)
            loadout.load_preferences(again)
            self.assertTrue(again.portal_gun)

    def test_bad_test_map_modes_rejected_and_explicit_scale_validated(self):
        from contextlib import redirect_stderr
        from io import StringIO
        with redirect_stderr(StringIO()):
            for args in (["--test-map"], ["--host", "--test-map", "--replay-teammate"], ["--eye-render-percent", "75"]):
                with self.assertRaises(SystemExit):
                    friends.parse_options(args)
        self.assertTrue(friends.parse_options(["--host", "--test-map"]).test_map)
        self.assertFalse(friends.parse_options([]).inventory_focus)
        self.assertTrue(friends.parse_options(["--host", "--inventory-focus"]).inventory_focus)
        self.assertFalse(friends.parse_options(["--no-inventory-focus"]).inventory_focus)


if __name__ == "__main__":
    unittest.main()
