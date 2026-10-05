"""Offline disposable fixture configuration contracts; never launches a game."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess

from run_local_test_fixture import configure_fixture_voice, launch_owned_fixture
from session import config_hashes, read_ini


class LocalTestFixtureConfigTests(unittest.TestCase):
    def test_owned_launch_uses_ue3_quotes_clean_environment_and_captured_console(self):
        with tempfile.TemporaryDirectory() as directory:
            role = {"native_adapter": True, "log": str(Path(directory) / "game.log"),
                    "args": ["KF-Outpost", "-ENGINEINI=D:/Run Folder/KFEngine.ini"]}
            parent = {"PATH": "unchanged", "kf2vr_test_control": "old", "KF2VR_CAPTURE_ROOT": "old"}
            with patch("run_local_test_fixture.subprocess.Popen") as popen:
                child = launch_owned_fixture(Path("D:/Game Folder/KFGame.exe"), role, parent)
                self.assertIs(child, popen.return_value)
                command, = popen.call_args.args
                options = popen.call_args.kwargs
                self.assertIn('-ENGINEINI="D:/Run Folder/KFEngine.ini"', command)
                self.assertEqual(subprocess.DEVNULL, options["stdin"])
                self.assertEqual(subprocess.STDOUT, options["stderr"])
                self.assertEqual(role["console_log"], options["stdout"].name)
                self.assertTrue(options["stdout"].closed)
                self.assertEqual({"KF2VR_LOG_PATH"}, {key for key in options["env"] if key.upper().startswith("KF2VR_")})
                self.assertEqual("232090", options["env"]["SteamAppId"])
                self.assertEqual("232090", options["env"]["SteamGameId"])
                self.assertEqual("unchanged", options["env"]["PATH"])
                self.assertEqual("old", parent["kf2vr_test_control"])
            self.assertTrue(Path(role["console_log"]).is_file())

    def test_default_preserves_voice_and_refreshes_copied_config_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            config = run / "off/driver/Config"
            config.mkdir(parents=True)
            path = config / "KFEngine.ini"
            original = "[VoIP]\nbHasVoiceEnabled=true\n"
            path.write_text(original, encoding="utf-16")
            before = path.read_bytes()
            role = {"config_root": str(config)}
            configure_fixture_voice(run, role)
            self.assertEqual(before, path.read_bytes())
            self.assertEqual(config_hashes(config), role["config_hashes"])
            self.assertNotIn("test_override", role)

    def test_optin_changes_only_disposable_copy_and_labels_voice_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            user = root / "user/KFEngine.ini"
            user.parent.mkdir()
            user.write_text("[VoIP]\nbHasVoiceEnabled=true\n", encoding="utf-16")
            before = user.read_bytes()
            run = root / "run"
            config = run / "enabled/driver/Config"
            config.mkdir(parents=True)
            copy = config / "KFEngine.ini"
            copy.write_bytes(before)
            role = {"config_root": str(config)}
            configure_fixture_voice(run, role, True)
            self.assertIn("bHasVoiceEnabled=false", read_ini(copy))
            self.assertEqual(before, user.read_bytes())
            self.assertIn("voice coexistence unverified", role["test_override"])
            self.assertEqual(config_hashes(config), role["config_hashes"])
            with self.assertRaises(RuntimeError):
                configure_fixture_voice(run, {"config_root": str(user.parent)}, True)
            self.assertEqual(before, user.read_bytes())


if __name__ == "__main__":
    unittest.main()
