"""Preference export is independent of retryable native-file restoration."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import desktop_settings
import recovery
import vr_config
import watchdog
from session import read_ini, set_ini


class SessionPreferencesTests(unittest.TestCase):
    def record(self, root, *, vr=True, started=True, saved=False):
        config = root / "session" / "driver" / "Config"
        config.mkdir(parents=True)
        text = vr_config.apply_preferences("")
        text = set_ini(text, "KF2VR.VRSessionUI", {"EyeRenderPercent": "60"})
        (config / "KFGame.ini").write_text(text, encoding="utf-16")
        return {"vr": vr, "session_mode": "solo", "cleanup_complete": False,
                "preferences_saved": saved, "user_config_root": str(root / "stock"),
                "roles": [{"role": "server", "pid": 456},
                          {"role": "driver", "pid": 123 if started else None, "config_root": str(config)}]}

    def run_cleanup(self, method, root, record):
        path = root / "session" / "run.json"
        path.write_text(json.dumps(record), encoding="utf-8")
        if method == "recovery":
            recovery.recover_record(path)
        else:
            kernel = Mock()
            kernel.OpenProcess.return_value = None
            with patch.object(watchdog, "api", return_value=kernel), \
                    patch.object(watchdog.sys, "argv", ["watchdog.py", str(path), "1"]):
                watchdog.main()
        return json.loads(path.read_text(encoding="utf-8"))

    def test_server_only_cleanup_never_exports_driver_seeds(self):
        for method in ("recovery", "watchdog"):
            for vr in (True, False):
                with self.subTest(method=method, vr=vr), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    record = self.record(root, vr=vr, started=False)
                    with patch.object(vr_config, "export_preferences") as export_vr, \
                            patch.object(desktop_settings, "export") as export_desktop:
                        result = self.run_cleanup(method, root, record)
                    export_vr.assert_not_called()
                    export_desktop.assert_not_called()
                    self.assertFalse(result["preferences_saved"])

    def test_saved_cleanup_keeps_newer_profile(self):
        for method in ("recovery", "watchdog"):
            with self.subTest(method=method), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                record = self.record(root, saved=True)
                profile = root / "profile"
                profile.mkdir()
                current = set_ini(vr_config.apply_preferences(""), "KF2VR.VRSessionUI", {"EyeRenderPercent": "90"})
                target = profile / "KFGame.ini"
                target.write_text(current, encoding="utf-16")
                before = target.read_bytes()
                with patch.object(vr_config, "profile_root", return_value=profile):
                    result = self.run_cleanup(method, root, record)
                self.assertEqual(target.read_bytes(), before)
                self.assertTrue(result["preferences_saved"])

    def test_started_driver_exports_once_even_if_cleanup_needs_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = self.record(root)
            # An unrelated deployment problem keeps recovery retryable.
            record["native_deployment"] = {"backup": str(root / "outside-session")}
            profile = root / "profile"
            with patch.object(vr_config, "profile_root", return_value=profile):
                result = self.run_cleanup("recovery", root, record)
                self.assertFalse(result["cleanup_complete"])
                self.assertTrue(result["preferences_saved"])
                target = profile / "KFGame.ini"
                self.assertEqual(vr_config.values(read_ini(target), "KF2VR.VRSessionUI")["EyeRenderPercent"], "60")
                target.write_text(set_ini(read_ini(target), "KF2VR.VRSessionUI", {"EyeRenderPercent": "90"}), encoding="utf-16")
                self.run_cleanup("recovery", root, result)
                self.assertEqual(vr_config.values(read_ini(target), "KF2VR.VRSessionUI")["EyeRenderPercent"], "90")

    def test_desktop_export_is_marked_and_not_repeated(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = self.record(root, vr=False)
            with patch.object(desktop_settings, "export") as export:
                vr_config.export_session_preferences(record, root=root / "profile")
                vr_config.export_session_preferences(record, root=root / "profile")
            export.assert_called_once_with(Path(record["roles"][1]["config_root"]), root / "stock", root=root / "profile")
            self.assertTrue(record["preferences_saved"])

    def test_export_failure_remains_retryable(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = self.record(Path(temporary))
            with patch.object(vr_config, "export_preferences", side_effect=OSError("profile busy")):
                with self.assertRaises(OSError):
                    vr_config.export_session_preferences(record)
            self.assertFalse(record["preferences_saved"])


if __name__ == "__main__":
    unittest.main()
