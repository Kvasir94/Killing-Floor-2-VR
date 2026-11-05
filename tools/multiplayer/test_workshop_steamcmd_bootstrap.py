"""Workshop acquisition bootstraps pinned SteamCMD only for an authorized download."""
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import dependencies
import workshop_loadout


class SteamCmdBootstrapTests(unittest.TestCase):
    def test_fresh_copy_bootstraps_before_downloading_and_validates_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = root / "steamapps/common/killingfloor2"
            steam = root / "steamcmd"
            item = "643383080"

            def extract(name, archive, destination):
                self.assertEqual((name, archive, destination), ("steamcmd.zip", steam / "steamcmd.zip", steam))
                (destination / "steamcmd.exe").write_bytes(b"test executable")

            def download(command, **kwargs):
                self.assertTrue((steam / "steamcmd.exe").is_file())
                self.assertEqual(command, [str(steam / "steamcmd.exe"), "+login", "anonymous",
                                          "+workshop_download_item", "232090", item, "validate", "+quit"])
                package = steam / "steamapps/workshop/content/232090" / item / "BrewedPC/KF-BikiniAtoll.kfm"
                package.parent.mkdir(parents=True)
                package.write_bytes(b"\xc1\x83\x2a\x9evalidated map")
                return SimpleNamespace(returncode=0)

            with patch.object(dependencies, "extract_verified", side_effect=extract) as fetched, \
                    patch("subprocess.run", side_effect=download) as process, \
                    patch.object(dependencies, "steamcmd_running", return_value=False):
                result = workshop_loadout.ensure_item(item, game, root / "cache", steam, download=True)
                fetched.assert_called_once()
                process.assert_called_once()
            marker = json.loads((result.parent / "content.json").read_text())
            self.assertEqual(marker["files_sha256"], workshop_loadout.package_hashes(result, item))

    def test_prepare_only_does_not_bootstrap_or_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(dependencies, "extract_verified") as fetched, \
                    patch("subprocess.run") as process:
                with self.assertRaisesRegex(RuntimeError, "643383080 is missing"):
                    workshop_loadout.ensure_item("643383080", root / "steamapps/common/killingfloor2",
                                                  root / "cache", root / "steamcmd", download=False)
                fetched.assert_not_called()
                process.assert_not_called()
            self.assertFalse((root / "steamcmd").exists())

    def test_subscribed_item_does_not_need_steamcmd(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = root / "steamapps/common/killingfloor2"
            package = root / "steamapps/workshop/content/232090/643383080/BrewedPC/KF-BikiniAtoll.kfm"
            package.parent.mkdir(parents=True)
            package.write_bytes(b"\xc1\x83\x2a\x9esubscribed map")
            with patch.object(dependencies, "extract_verified") as fetched, \
                    patch("subprocess.run") as process:
                result = workshop_loadout.ensure_item("643383080", game, root / "cache", root / "steamcmd", download=True)
                self.assertEqual((result / "BrewedPC/KF-BikiniAtoll.kfm").read_bytes(), package.read_bytes())
                fetched.assert_not_called()
                process.assert_not_called()

    def test_restarted_steamcmd_is_waited_for_then_retried(self):
        # A fresh SteamCMD updates itself and restarts; the first run returns before the item exists.
        with tempfile.TemporaryDirectory() as directory:
            steam = Path(directory) / "steamcmd"
            steam.mkdir()
            target = steam / "item.kfm"
            runs = []

            def download(command, **kwargs):
                runs.append(command)
                if len(runs) == 2:
                    target.write_bytes(b"done")
                return SimpleNamespace(returncode=7 if len(runs) == 1 else 0)

            with patch("subprocess.run", side_effect=download), \
                    patch.object(dependencies, "steamcmd_running", side_effect=[True, False, False]) as running, \
                    patch("time.sleep"):
                done, log = dependencies.workshop_download(steam, "1337395223", target.exists)
            self.assertTrue(done)
            self.assertEqual(2, len(runs))
            self.assertEqual(3, running.call_count)
            self.assertEqual(steam / "workshop-1337395223.log", log)

if __name__ == "__main__":
    unittest.main()
