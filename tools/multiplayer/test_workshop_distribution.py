"""Portable Workshop layout, copying and Steam-config behavior."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

from workshop_distribution import configure_account, contained, copy_lease, digest, launch_options, local_lock, mirror, set_launch_options

SPEC = importlib.util.spec_from_file_location("workshop_stage", Path(__file__).resolve().parents[1] / "workshop/stage_workshop.py")
STAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAGE)

VDF = '''// player config
"UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "apps" {
"999" { "LaunchOptions" "unrelated" }
"232090" { "Other" "keep" }
} } } } }
'''


class WorkshopDistributionTests(unittest.TestCase):
    def release(self, root):
        app = root / "release/app"
        for name in ("Packages/KF2VR.u", "Packages/KF2VRNet.u", "Packages/KF2VRNetClient.u",
                     "Packages/KF2VRHands.upk", "tools/multiplayer/friends.py"):
            path = app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        hashes = {p.relative_to(app).as_posix(): digest(p) for p in app.rglob("*") if p.is_file()}
        (app / "release.json").write_text(json.dumps({"build_id": "test", "files_sha256": hashes}), encoding="utf-8")
        # A used copy must not put these into the Workshop payload.
        (app / "settings.json").write_text('"private"')
        return app.parent

    def test_stage_and_mirror_reconstruct_manifest_without_private_files_or_duplicate_packages(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            release = self.release(root)
            STAGE.stage(release, root / "stage", "Test update")
            item = root / "stage/Upload"
            self.assertFalse((item / "KF2VR/app/settings.json").exists())
            self.assertFalse((item / "KF2VR/app/Packages/KF2VR.u").exists())
            self.assertEqual(len(list(item.rglob("KF2VR.u"))), 1)
            app = mirror(item, root / "writable")
            self.assertEqual(digest(app / "Packages/KF2VR.u"), digest(release / "app/Packages/KF2VR.u"))
            self.assertFalse((app / "settings.json").exists())

    def test_update_preserves_user_state_and_removes_only_obsolete_shipped_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            release = self.release(root)
            STAGE.stage(release, root / "stage", "Test")
            app = mirror(root / "stage/Upload", root / "writable")
            (app / "settings.json").write_text("calibration")
            (app / "sessions").mkdir()
            (app / "sessions/pending.json").write_text("recovery")
            (app / "old.py").write_text("old shipped code")
            record = json.loads((app / "release.json").read_text())
            record["files_sha256"]["old.py"] = digest(app / "old.py")
            (app / "release.json").write_text(json.dumps(record))
            mirror(root / "stage/Upload", root / "writable")
            self.assertFalse((app / "old.py").exists())
            self.assertEqual((app / "settings.json").read_text(), "calibration")
            self.assertEqual((app / "sessions/pending.json").read_text(), "recovery")

    def test_stage_refuses_reuse_overlap_and_tampered_payload(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            release = self.release(root)
            out = root / "stage"
            STAGE.stage(release, out, "Test")
            with self.assertRaises(FileExistsError):
                STAGE.stage(release, out, "Test")
            with self.assertRaises(ValueError):
                STAGE.stage(release, release / "app/stage", "Test")
            (release / "app/Packages/KF2VR.u").write_bytes(b"changed")
            with self.assertRaises(ValueError):
                STAGE.stage(release, root / "broken", "Test")
            self.assertFalse((root / "broken").exists())

    def test_manifest_paths_cannot_escape(self):
        with tempfile.TemporaryDirectory() as temp:
            for name in ("../secret", "C:/secret", "/secret", "a\\b", "a/../b", "a//b", "a/./b"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    contained(temp, name)

    def test_launch_options_roundtrip_escaped_values_and_other_fields(self):
        option = '"D:\\Games\\a {folder}\\Play.cmd" %command% -name "Renée"'
        text = set_launch_options(VDF, option)
        self.assertEqual(launch_options(text), option)
        self.assertIn('"999" { "LaunchOptions" "unrelated" }', text)
        self.assertIn('"Other" "keep"', text)
        self.assertIsNone(launch_options(set_launch_options(text, None)))

    def test_setup_restores_previous_options_and_touches_only_selected_account(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config, other = root / "selected.vdf", root / "other.vdf"
            original = set_launch_options(VDF, '-foo "bar"')
            config.write_text(original, encoding="utf-8")
            other.write_text(VDF, encoding="utf-8")
            configure_account(config, root / "Play.cmd")
            self.assertIn("Play.cmd", launch_options(config.read_text()))
            self.assertTrue(launch_options(config.read_text()).endswith('%command% -foo "bar"'))
            configure_account(config, root / "Play.cmd", remove=True)
            self.assertEqual(config.read_text(), original)
            self.assertEqual(other.read_text(), VDF)
            self.assertFalse(config.with_name(config.name + ".kf2vr-launch.json").exists())

    def test_existing_wrapper_remains_the_normal_game_command(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / "localconfig.vdf"
            previous = '"C:\\My wrapper\\normal.cmd" %command% -novid'
            config.write_text(set_launch_options(VDF, previous))
            configure_account(config, Path(temp) / "Play.cmd")
            self.assertTrue(launch_options(config.read_text()).endswith(previous))
            self.assertEqual(launch_options(config.read_text()).count("%command%"), 1)
            configure_account(config, Path(temp) / "Play.cmd", remove=True)
            self.assertEqual(launch_options(config.read_text()), previous)

    def test_absent_options_restore_absence_and_manual_changes_are_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / "localconfig.vdf"
            config.write_text(VDF)
            configure_account(config, Path(temp) / "Play.cmd")
            configured = config.read_text()
            config.write_text(set_launch_options(configured, "user edit"))
            with self.assertRaises(ValueError):
                configure_account(config, Path(temp) / "Play.cmd", remove=True)
            self.assertEqual(launch_options(config.read_text()), "user edit")
            config.write_text(configured)
            configure_account(config, Path(temp) / "Play.cmd", remove=True)
            self.assertIsNone(launch_options(config.read_text()))

    def test_malformed_config_is_not_changed(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / "localconfig.vdf"
            config.write_text(VDF[:-5])
            original = config.read_bytes()
            with self.assertRaises(ValueError):
                configure_account(config, Path(temp) / "Play.cmd")
            self.assertEqual(config.read_bytes(), original)
            self.assertFalse(config.with_name(config.name + ".kf2vr-launch.json").exists())

    def test_writable_copy_is_single_launcher(self):
        with tempfile.TemporaryDirectory() as temp:
            with local_lock(Path(temp) / "launcher.lock"):
                with self.assertRaises((RuntimeError, BlockingIOError)):
                    with local_lock(Path(temp) / "launcher.lock"):
                        self.fail("Second launcher acquired the same writable copy")

    @unittest.skipUnless(os.name == "nt", "Windows session mutex")
    def test_worker_keeps_copy_protected_after_chooser_lock_ends(self):
        name = "Local\\KF2VR-Workshop-test-" + uuid.uuid4().hex
        code = "from workshop_distribution import copy_lease\nimport sys\nwith copy_lease(sys.argv[1]):\n print('ready',flush=True)\n input()\n"
        with tempfile.TemporaryDirectory() as temp:
            with subprocess.Popen([sys.executable, "-c", code, name], cwd=Path(__file__).parent,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as worker:
                try:
                    self.assertEqual(worker.stdout.readline().strip(), "ready")
                    with local_lock(Path(temp) / "chooser.lock"):
                        pass
                    with self.assertRaises(RuntimeError):
                        with copy_lease(name):
                            self.fail("Active worker allowed a payload update")
                finally:
                    worker.communicate("\n", timeout=10)
            with copy_lease(name):
                pass


if __name__ == "__main__":
    unittest.main()
