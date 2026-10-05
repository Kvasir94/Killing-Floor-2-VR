"""Focused regressions for preference isolation and interrupted restoration."""
import json
import io
import contextlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import MagicMock

import friends
import vr_config
from native_fixture import NativeDeployment
from session import digest, read_ini, set_ini
from workshop_loadout import load_preferences, save_preferences


class AlphaTests(unittest.TestCase):
    def test_vr_preflight_accepts_runtime_without_system_vc_redistributable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            library = root / "runtime.dll"
            library.write_bytes(b"runtime manifest target")
            manifest = root / "openxr.json"
            manifest.write_text(json.dumps({"runtime": {"library_path": library.name}}))
            registry = MagicMock()
            registry.QueryValueEx.return_value = (str(manifest), 1)
            with patch.dict("sys.modules", {"winreg": registry}), \
                    patch.dict("os.environ", {"SystemRoot": str(root)}), \
                    contextlib.redirect_stdout(io.StringIO()):
                friends.preflight({"build_id": "test", "game_sha256": "test"}, root, True)

    def test_reload_hints_default_on_without_enabling_reload_gameplay(self):
        bridge = "KF2VR.VRHandsBridge"
        for saved, expected in (("", "True"), (f"[{bridge}]\nbReloadHints=False\n", "False"),
                                (f"[{bridge}]\nbReloadHints=invalid\n", "True")):
            text = vr_config.apply_preferences("", saved)
            for section in (bridge, vr_config.ALIASES[bridge]):
                prefs = vr_config.values(text, section)
                self.assertEqual(expected, prefs["bReloadHints"])
                self.assertEqual("False", prefs["bInteractiveReloads"])
                self.assertEqual("False", prefs["bManualPump"])

    def test_reload_hint_choice_survives_mode_and_reload_changes(self):
        bridge = "KF2VR.VRHandsBridge"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); config = root / "config"; config.mkdir()
            profile = root / "profile"
            vr_config.import_preferences(config, root=profile)
            # Start in Solo, turn reloads off in multiplayer, then re-enable
            # them in Solo. None of these operations should restore hints.
            for network, edits, hints, reloads, pump in (
                    (False, {"bReloadHints": "False", "bInteractiveReloads": "True"}, "False", "True", "False"),
                    (True, {"bInteractiveReloads": "False"}, "False", "False", "False"),
                    (False, {"bInteractiveReloads": "True", "bManualPump": "True"}, "False", "True", "True"),
                    (True, {"bReloadHints": "True"}, "True", "True", "True")):
                active = vr_config.ALIASES[bridge] if network else bridge
                text = set_ini(read_ini(config / "KFGame.ini"), active, edits)
                (config / "KFGame.ini").write_text(text, encoding="utf-16")
                vr_config.export_preferences(config, profile, network=network)
                # A fresh next session must import the saved choice, including
                # the active alias winning over the other mode's stale value.
                (config / "KFGame.ini").write_text("", encoding="utf-16")
                vr_config.import_preferences(config, root=profile)
                for section in (bridge, vr_config.ALIASES[bridge]):
                    prefs = vr_config.values(read_ini(config / "KFGame.ini"), section)
                    self.assertEqual((hints, reloads, pump),
                                     (prefs["bReloadHints"], prefs["bInteractiveReloads"], prefs["bManualPump"]))

    def test_engine_saveconfig_dump_persists_choice_but_not_capture_switches(self):
        # The engine rewrites the session KFGame.ini as ANSI with every config
        # property of the saved class, not only keys the launcher seeded.
        for network in (False, True):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); config = root / "config"; config.mkdir()
                profile = root / "profile"
                vr_config.import_preferences(config, root=profile)
                active = vr_config.ALIASES["KF2VR.VRHandsBridge"] if network else "KF2VR.VRHandsBridge"
                text = set_ini(read_ini(config / "KFGame.ini"), active, {
                    "bInteractiveReloads": "True", "bBreakActionCapture": "True", "bUsabilityCapture": "True"})
                (config / "KFGame.ini").write_text(text, encoding="ascii")
                vr_config.export_preferences(config, profile, network=network)
                (config / "KFGame.ini").write_text("", encoding="utf-16")
                vr_config.import_preferences(config, root=profile)
                imported = read_ini(config / "KFGame.ini")
                for section in ("KF2VR.VRHandsBridge", vr_config.ALIASES["KF2VR.VRHandsBridge"]):
                    self.assertEqual("True", vr_config.values(imported, section)["bInteractiveReloads"])
                self.assertNotIn("Capture", imported)

    def test_pre_revision_profile_movement_hand_resets_to_left_once(self):
        bridge = "KF2VR.VRHandsBridge"
        legacy = f"[{bridge}]\nMovementHand=1\nPreferredWeaponHand=0\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); config = root / "config"; config.mkdir()
            profile = root / "profile"; profile.mkdir()
            (profile / "KFGame.ini").write_text(legacy, encoding="utf-16")
            vr_config.import_preferences(config, root=profile)
            session = read_ini(config / "KFGame.ini")
            self.assertEqual(("0", "0"), tuple(vr_config.values(session, bridge)[k]
                                               for k in ("MovementHand", "PreferredWeaponHand")))
            # A right-hand choice made in the headset after the reset is kept.
            text = set_ini(session, bridge, {"MovementHand": "1"})
            (config / "KFGame.ini").write_text(text, encoding="ascii")
            vr_config.export_preferences(config, profile, network=False)
            saved = read_ini(profile / "KFGame.ini")
            self.assertEqual(vr_config.PROFILE_REVISION, vr_config.profile_revision(saved))
            vr_config.import_preferences(config, root=profile)
            self.assertEqual("1", vr_config.values(read_ini(config / "KFGame.ini"), bridge)["MovementHand"])

    def test_both_modes_export_the_active_alias_without_overwriting_other_choice(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); config = root / "config"; config.mkdir()
            profile = root / "profile"
            text = vr_config.apply_preferences("", "[KF2VR.VRHandsBridge]\nbZedGrabEnabled=False\nbMeleeHitStop=False")
            # Solo edits must win over the stale network alias.
            text = set_ini(text, "KF2VR.VRHandsBridge", {"bZedGrabEnabled": "True"})
            (config / "KFGame.ini").write_text(text, encoding="utf-16")
            vr_config.export_preferences(config, profile, network=False)
            vr_config.import_preferences(config, root=profile)
            prefs = vr_config.values(read_ini(config / "KFGame.ini"), "KF2VRNetClient.KF2VRNetHandsBridge")
            self.assertEqual(("True", "False"), (prefs["bZedGrabEnabled"], prefs["bMeleeHitStop"]))
            text = set_ini(read_ini(config / "KFGame.ini"), "KF2VRNetClient.KF2VRNetHandsBridge", {"bMeleeHitStop": "True"})
            (config / "KFGame.ini").write_text(text, encoding="utf-16")
            vr_config.export_preferences(config, profile, network=True)
            prefs = vr_config.values(read_ini(profile / "KFGame.ini"), "KF2VR.VRHandsBridge")
            self.assertEqual(("True", "True"), (prefs["bZedGrabEnabled"], prefs["bMeleeHitStop"]))

    def test_host_permission_defaults_off_and_saved_choice_survives(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = friends.parse_options(["--host", "--vr"]); args.profile_root = Path(tmp)
            load_preferences(args)
            self.assertFalse(args.multiplayer_grabs)
            self.assertEqual([], args.mods)
            args.multiplayer_grabs = True
            save_preferences(args)
            next_args = friends.parse_options(["--host", "--desktop"]); next_args.profile_root = Path(tmp)
            load_preferences(next_args)
            self.assertTrue(next_args.multiplayer_grabs)
            self.assertFalse(next_args.vr)

    def deployment(self, root):
        source, target = root / "source", root / "target"
        source.mkdir(); target.mkdir()
        for name in ("dinput8.dll", "openxr_loader.dll"):
            (source / name).write_bytes(b"owned")
        (target / "openxr_loader.dll").write_bytes(b"original")
        receipt = {"artifacts_sha256": {p.name: digest(p) for p in source.iterdir()}}
        return NativeDeployment(source, target, root / "backup", receipt, digest)

    def test_reboot_recovery_and_repeat_restore(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = self.deployment(Path(tmp)); first.install()
            recovered = NativeDeployment(first.source, first.destination, first.backup, first.receipt, digest)
            self.assertEqual([], recovered.restore())
            self.assertEqual([], recovered.restore())
            self.assertEqual(b"original", (first.destination / "openxr_loader.dll").read_bytes())
            self.assertFalse((first.destination / "dinput8.dll").exists())

    def test_partial_install_restores_only_journaled_owned_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            deployment = self.deployment(Path(tmp))
            original_save = deployment._save
            def interrupted(journal):
                original_save(journal)
                if "dinput8.dll" in journal["files"]:
                    raise OSError("power loss before proxy install")
            with patch.object(deployment, "_save", side_effect=interrupted):
                with self.assertRaises(OSError):
                    deployment.install()
            self.assertEqual([], deployment.restore())
            self.assertEqual(b"original", (deployment.destination / "openxr_loader.dll").read_bytes())

    def test_corrupt_backup_and_external_proxy_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            deployment = self.deployment(Path(tmp)); deployment.install()
            (deployment.backup / "openxr_loader.dll").write_bytes(b"corrupt")
            (deployment.destination / "dinput8.dll").write_bytes(b"other mod")
            self.assertEqual(2, len(deployment.restore()))
            self.assertEqual(b"other mod", (deployment.destination / "dinput8.dll").read_bytes())
            self.assertFalse(json.loads(deployment.journal_path.read_text())["complete"])

    def test_diagnostics_does_not_export_secrets_or_raw_session_text(self):
        from diagnostics import summarize
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); run = root / "sessions/one"; run.mkdir(parents=True)
            (root / "release.json").write_text(json.dumps({"build_id": "test", "files_sha256": {}}))
            (run / "run.json").write_text(json.dumps({"session_mode": "join", "password": "secret123",
                "error": "failed connecting secret123 to 192.0.2.1 C:/Users/Personal", "roles": []}))
            output = json.dumps(summarize(root))
            for secret in ("secret123", "192.0.2.1", "Personal", str(root)):
                self.assertNotIn(secret, output)

    def test_native_digest_reads_headset_and_pacing_numbers(self):
        from diagnostics import native_digest
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "native.log"
            self.assertEqual({}, native_digest(path))
            path.write_text(
                "RenderPerformance eyeRenderPercent=75 frameTimings=0 vmTimings=0\n"
                "Game XR ready thread=1 atlas=100x50 runtime=Oculus version=1.1.49 system=Meta Quest 3 recommendedEye=2064x2208\n"
                "FramePacing mode=lite intervals=400 overflow=0 meanMs=11.2 p50Ms=11.1 p95Ms=13.0 p99Ms=20.0 maxMs=40.0 "
                "over90=30 over120=400 presents=400 over90Total=30 runtimePeriodMs=11.111\n"
                "FramePacing mode=lite intervals=100 overflow=0 meanMs=12.0 p50Ms=11.1 p95Ms=15.0 p99Ms=20.0 maxMs=40.0 "
                "over90=20 over120=100 presents=500 over90Total=50 runtimePeriodMs=11.111\n", encoding="utf-8")
            digest = native_digest(path)
            self.assertEqual({"runtime": "Oculus", "runtime_version": "1.1.49", "system": "Meta Quest 3",
                              "recommended_eye": "2064x2208"}, digest["headset"])
            self.assertEqual(75, digest["eye_render_percent"])
            pacing = digest["frame_pacing"]
            self.assertEqual((2, 500, 50, 500, 15.0, 15.0, 11.111),
                             (pacing["windows"], pacing["intervals"], pacing["over90_total"], pacing["over120_total"],
                              pacing["p95_ms_last"], pacing["p95_ms_worst"], pacing["runtime_period_ms"]))
            self.assertEqual(11.36, pacing["mean_ms_weighted"])

    def test_sent_logs_keep_session_logs_without_passwords_or_join_codes(self):
        from diagnostics import collect_logs
        import zipfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); run = root / "sessions/one"; (run / "driver").mkdir(parents=True)
            (root / "release.json").write_text(json.dumps({"build_id": "test", "files_sha256": {}}))
            (root / "settings.json").write_text(json.dumps({"host_password": "hostpass9"}))
            (run / "run.json").write_text(json.dumps({"session_mode": "host", "roles": [], "note": "hostpass9"}))
            (run / "driver/game.log").write_bytes("LoadMap: 1.2.3.4:7777/KF-X?Password=abc123?game=KF2VRNet\n"
                                                  "code KF2VR1:QUJDREVG end\nScriptWarning: kept\n".encode("utf-16"))
            target = collect_logs(root, root)
            with zipfile.ZipFile(target) as archive:
                text = "".join(archive.read(name).decode("utf-8") for name in archive.namelist())
                self.assertTrue(any(name.endswith("-game.log") for name in archive.namelist()))
            self.assertIn("ScriptWarning: kept", text)
            for secret in ("abc123", "QUJDREVG", "hostpass9"):
                self.assertNotIn(secret, text)

    def test_report_anonymizes_every_entry_and_preserves_originals(self):
        from diagnostics import collect_logs
        import zipfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); run = root / "sessions/PrivateTester"; run.mkdir(parents=True)
            (root / "logs").mkdir()
            (root / "build/multiplayer/steamcmd").mkdir(parents=True)
            (root / "release.json").write_text(json.dumps({"build_id": "alpha-test-p2", "git_head": "abcdef123456"}))
            payload = {
                "session_mode": "join", "roles": [], "player_name": "PrivateTester",
                "steam_id": 76561198012345678, "address": "192.0.2.17",
                "args": ["198.51.100.4:7777?Name=PrivateTester?Password=joinpass",
                         "-AUTH_TOKEN=private-token", "-username PrivateTester"],
                "path": "C:\\Users\\PrivateTester\\My Documents\\KF2",
                "note": "PrivateTester visited alpha.example.net", "access_token": "private-token",
                "refresh_tokens": ["private-refresh"], "authorization": {"header": "private-auth"},
            }
            (run / "run.json").write_text(json.dumps(payload))
            original = ('ScriptWarning: retained\nPlayerName="PrivateTester" SteamID=76561198012345678\n'
                        '192.0.2.17 [2001:db8::17]:7777 localhost ::1\n'
                        'C:\\Users\\PrivateTester\\My Documents\\log.txt\n'
                        '/home/PrivateTester/game.log\nemail private@example.net\n'
                        'Authorization: Bearer private-bearer\nhttps://account:private-url@alpha.example.net/private\n'
                        'STEAM_0:1:123456 [U:1:987654] Username PrivateTester\n')
            (run / "native.log").write_bytes(original.encode("utf-16"))
            (root / "logs/PrivateTester-error.txt").write_text(original)
            (root / "build/multiplayer/steamcmd/install-PrivateTester.log").write_text(original)
            (run / "settings.json").write_text('{"password": "excluded-setting"}')
            (run / "config.ini").write_text("password=excluded-config")
            (run / "crash.dmp").write_bytes(b"excluded-dump")
            before = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
            with patch.dict("os.environ", {"USERNAME": "PrivateTester", "USERPROFILE": "C:\\Users\\PrivateTester"}), \
                    patch("diagnostics.hardware_context", return_value={}):
                target = collect_logs(root, root)
            with zipfile.ZipFile(target) as archive:
                names = archive.namelist()
                text = "\n".join(archive.read(name).decode("utf-8") for name in names)
                self.assertTrue(any(name.startswith("launcher/") for name in names))
                self.assertTrue(any(name.startswith("installer/") for name in names))
                report = json.loads(archive.read("summary.json"))
                self.assertEqual("alpha-test-p2", report["build_id"])
            self.assertIn("ScriptWarning: retained", text)
            for private in ("PrivateTester", "76561198012345678", "192.0.2.17", "198.51.100.4", "2001:db8::17",
                            "::1", "private@example.net", "alpha.example.net", "private-token", "private-bearer",
                            "private-url", "joinpass", "private-refresh", "private-auth", "STEAM_0:1:123456", "[U:1:987654]",
                            "C:\\Users", "/home/", "excluded-setting", "excluded-config", "excluded-dump"):
                self.assertNotIn(private, text + "\n".join(names))
            for path, data in before.items():
                self.assertEqual(data, path.read_bytes())

    def test_report_summary_failure_never_archives_exception_text(self):
        from diagnostics import collect_logs
        import zipfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch("diagnostics.summarize", side_effect=OSError("C:/Users/PrivateTester 192.0.2.17")):
                target = collect_logs(root, root)
            with zipfile.ZipFile(target) as archive:
                self.assertEqual(["summary.json"], archive.namelist())
                text = archive.read("summary.json").decode()
                self.assertNotIn("PrivateTester", text)
                self.assertNotIn("192.0.2.17", text)

    def test_tampered_dependency_is_rejected_before_extraction(self):
        from dependencies import extract_verified
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "python.zip"; archive.write_bytes(b"tampered")
            target = Path(tmp) / "runtime"
            with self.assertRaisesRegex(RuntimeError, "differs from reviewed pin"):
                extract_verified("python-3.14.3-embed-amd64.zip", archive, target)
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
