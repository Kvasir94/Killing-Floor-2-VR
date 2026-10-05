"""Launcher-only assembly keeps player data and game binaries out of the bundle."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_launcher
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
            for name in ("install-multiplayer-server.ps1", "vr-defaults.json", "dependency-pins.json"):
                (source / "tools" / name).write_text("{}")
            (source / "private.log").write_text("private local data")
            (source / "release.json").write_text("private playable identity")

            def extract(name, archive, destination):
                destination.mkdir()
                (destination / "python.exe").write_bytes(b"test runtime")

            output = folder / "launcher"
            with patch.object(build_launcher, "ROOT", source), \
                 patch.object(build_launcher, "extract_verified", side_effect=extract), \
                 patch.object(build_launcher, "add_tkinter") as tkinter, \
                 patch.object(build_launcher, "check_portable_launchers") as check:
                self.assertEqual(output, build_launcher.build_launcher(output))
                tkinter.assert_called_once_with(output / "app/runtime")
                check.assert_called_once_with(output / "app", output / "app/runtime/python.exe")
            manifest = json.loads((output / "app/launcher-build.json").read_text())
            self.assertFalse(manifest["playable"])
            for name, expected in manifest["files_sha256"].items():
                self.assertFalse(Path(name).is_absolute())
                self.assertEqual(digest(output / name), expected)
            for name in ("private.log", "release.json", "Native", "Packages", "sessions"):
                self.assertFalse((output / "app" / name).exists())
            self.assertTrue((output / "Start KF2-VR.cmd").is_file())

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
