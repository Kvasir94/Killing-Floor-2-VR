"""Launcher-only assembly keeps player data and game binaries out of the bundle."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_launcher
import package
from package import LAUNCHER_MODULES
from release_state import digest


class LauncherBuildTests(unittest.TestCase):
    def test_standalone_bundle_uses_shipped_inventory_and_relative_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            source = folder / "source"
            source.mkdir()
            (source / "LICENSE").write_text("project license")
            tools = source / "tools/multiplayer"
            tools.mkdir(parents=True)
            for name in LAUNCHER_MODULES:
                (tools / name).write_text("# audited module\n")
            (tools / "linux-desktop.sh").write_text("#!/usr/bin/env bash\n")
            (tools / "epic_desktop_install.ps1").write_text("# standalone Epic installer\n")
            (tools / "assets").mkdir()
            (tools / "assets/kf2vr-icon.png").write_bytes(b"\x89PNG test icon")
            epic = source / "tools/epic-pack"
            epic.mkdir()
            (epic / "Install KF2VR for Epic.bat").write_bytes(b"@echo off\r\n")
            for name in ("install-multiplayer-server.ps1", "vr-defaults.json", "settings-definition.json", "dependency-pins.json"):
                (source / "tools" / name).write_text("{}")
            (source / "private.log").write_text("private local data")
            (source / "release.json").write_text("private playable identity")

            def extract(name, archive, destination):
                destination.mkdir()
                (destination / "python.exe").write_bytes(b"test runtime")

            output = folder / "launcher"
            with patch.object(build_launcher, "ROOT", source), \
                 patch.object(build_launcher, "extract_verified", side_effect=extract), \
                 patch.object(build_launcher, "add_qt") as qt, \
                 patch.object(build_launcher, "check_portable_launchers") as check:
                self.assertEqual(output, build_launcher.build_launcher(output))
                qt.assert_called_once_with(output / "app/runtime")
                for name in ("LGPL-3.0.txt", "GPL-3.0.txt", "Qt-for-Python-NOTICE.txt"):
                    self.assertTrue((output / "app/notices" / name).is_file())
                check.assert_called_once_with(output / "app", output / "app/runtime/python.exe")
            manifest = json.loads((output / "app/launcher-build.json").read_text())
            self.assertFalse(manifest["playable"])
            for name, expected in manifest["files_sha256"].items():
                self.assertFalse(Path(name).is_absolute())
                self.assertEqual(digest(output / name), expected)
            for name in ("private.log", "release.json", "Native", "Packages", "sessions"):
                self.assertFalse((output / "app" / name).exists())
            self.assertTrue((output / "Start KF2-VR.cmd").is_file())
            for name in ("tools/multiplayer/epic_desktop_install.ps1", "tools/epic-pack/Install KF2VR for Epic.bat"):
                self.assertEqual((source / name).read_bytes(), (output / "app" / name).read_bytes())
                self.assertIn("app/" + name, manifest["files_sha256"])

    def test_qt_payload_is_only_what_the_launcher_loads(self):
        for name in ("PySide6/QtCore.pyd", "PySide6/QtGui.pyd", "PySide6/QtWidgets.pyd", "PySide6/Qt6Widgets.dll",
                     "PySide6/plugins/platforms/qwindows.dll", "shiboken6/Shiboken.pyd"):
            self.assertTrue(package.qt_wanted(name), name)
        for name in ("PySide6/QtWebEngineCore.pyd", "PySide6/QtSvg.pyd", "PySide6/Qt6Qml.dll", "PySide6/opengl32sw.dll",
                     "PySide6/translations/qt_de.qm", "PySide6/plugins/styles/qmodernwindowsstyle.dll",
                     "shiboken6/include/shiboken6/shiboken.h"):
            self.assertFalse(package.qt_wanted(name), name)

    def test_qt_wheels_are_pinned_and_verified(self):
        for wheel in package.QT_WHEELS:
            self.assertRegex(package.PINS[wheel]["sha256"], r"^[0-9A-F]{64}$")
            self.assertTrue(package.PINS[wheel]["url"].startswith("https://files.pythonhosted.org/"))

    def test_existing_destination_is_preserved_before_assembly(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            original = output / "keep.txt"
            original.write_bytes(b"keep")
            with patch.object(build_launcher, "copy_launcher_tools") as copy:
                with self.assertRaisesRegex(ValueError, "never replaced"):
                    build_launcher.build_launcher(output)
                copy.assert_not_called()
            self.assertEqual(original.read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
