import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import game_install as game


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifests = self.root / "manifests"
        self.manifests.mkdir()
        self.epic = self.root / "Epic KF2"
        self.exe(self.epic)
        self.item = dict(AppName="Finch", InstallLocation=str(self.epic),
                         bIsIncompleteInstall=False, LaunchExecutable="Binaries/Win64/KFGame.exe",
                         AppVersionString="537162")

    def exe(self, root):
        path = root / game.EXECUTABLE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"test executable")

    def write_item(self, **changes):
        (self.manifests / "game.item").write_text(json.dumps({**self.item, **changes}), encoding="utf-8-sig")

    def test_completed_epic_with_spaces(self):
        self.write_item()
        found = game.epic_installations(self.manifests)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].root, self.epic)
        self.assertEqual(found[0].store, "epic")

    def test_incomplete_missing_or_malformed_completion_rejected(self):
        for value in (True, None, "false", 0):
            self.write_item(bIsIncompleteInstall=value)
            self.assertEqual(game.epic_installations(self.manifests), [])
        item = dict(self.item)
        del item["bIsIncompleteInstall"]
        (self.manifests / "game.item").write_text(json.dumps(item))
        self.assertEqual(game.epic_installations(self.manifests), [])

    def test_bad_manifest_and_wrong_app_do_not_hide_valid_install(self):
        self.write_item()
        (self.manifests / "bad.item").write_text("{")
        (self.manifests / "array.item").write_text("[]")
        self.assertEqual(len(game.epic_installations(self.manifests)), 1)
        self.write_item(AppName="Other")
        self.assertEqual(game.epic_installations(self.manifests), [])

    def test_missing_executable_or_wrong_launch_path_rejected(self):
        self.write_item(LaunchExecutable="../elsewhere.exe")
        self.assertEqual(game.epic_installations(self.manifests), [])
        self.write_item()
        (self.epic / game.EXECUTABLE).unlink()
        self.assertEqual(game.epic_installations(self.manifests), [])

    def test_steam_custom_library_and_install_directory(self):
        steam = self.root / "Steam"
        library = self.root / "Games"
        (steam / "steamapps").mkdir(parents=True)
        (library / "steamapps").mkdir(parents=True)
        escaped = str(library).replace("\\", "\\\\")
        (steam / "steamapps/libraryfolders.vdf").write_text('"libraryfolders" { "1" { "path" "' + escaped + '" } }')
        manifest = library / "steamapps/appmanifest_232090.acf"
        manifest.write_text('"AppState" { "appid" "232090" "StateFlags" "4" "installdir" "KF2 custom" "buildid" "13316885" }')
        root = library / "steamapps/common/KF2 custom"
        self.exe(root)
        self.assertEqual(game.steam_installations([steam])[0].root, root)
        manifest.write_text(manifest.read_text().replace('"4"', '"6"'))
        self.assertEqual(game.steam_installations([steam]), [])

    def test_selection_requires_choice_only_for_multiple_installs(self):
        epic = game.Installation("epic", self.epic)
        steam = game.Installation("steam", self.root / "Steam")
        self.assertEqual(game.select([epic]), epic)
        with self.assertRaisesRegex(ValueError, "Choose"):
            game.select([steam, epic])
        self.assertEqual(game.select([steam, epic], store="epic"), epic)
        self.assertEqual(game.select([steam, epic], root=self.epic), epic)
        with self.assertRaisesRegex(ValueError, "No completed"):
            game.select([], store="steam")

    def test_recognition_does_not_enable_epic_native_support(self):
        install = game.Installation("epic", self.epic)
        identity = dict(sha256=game.EPIC_SHA256, recognized=True, binary_store="epic")
        with patch.object(game, "fingerprint", return_value=identity):
            with self.assertRaisesRegex(ValueError, "does not support"):
                game.validate_native(install, [game.STEAM_SHA256])
            self.assertEqual(game.validate_native(install, [game.EPIC_SHA256]), identity)
            with self.assertRaisesRegex(ValueError, "Unrecognized"):
                game.validate_native(game.Installation("steam", self.epic), [game.EPIC_SHA256])

    def test_unknown_hash_rejected_even_if_release_claims_support(self):
        install = game.Installation("epic", self.epic)
        identity = game.fingerprint(install)
        self.assertFalse(identity["recognized"])
        with self.assertRaisesRegex(ValueError, "Unrecognized"):
            game.validate_native(install, [identity["sha256"]])


if __name__ == "__main__":
    unittest.main()
