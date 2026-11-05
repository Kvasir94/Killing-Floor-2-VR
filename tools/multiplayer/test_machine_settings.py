"""Per-PC launcher choices survive a new release and never leave the profile."""
import json
from pathlib import Path
import tempfile
import unittest

import machine_settings


class MachineSettingsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.profile = self.root / "profile"
        self.old_release, self.new_release = self.root / "old", self.root / "new"
        self.old_release.mkdir(); self.new_release.mkdir()

    def test_old_release_values_carry_into_a_new_release(self):
        (self.old_release / "settings.json").write_text(json.dumps(
            {"game_root": "D:/KF2", "server_name": "Old host", "host_password": "secret", "unrelated": "x"}))
        first = machine_settings.load(self.old_release, self.profile)
        self.assertEqual({"game_root": "D:/KF2", "server_name": "Old host", "host_password": "secret"}, first)
        machine_settings.save(dict(first, address="1.2.3.4", store="steam"), self.profile)
        self.assertEqual(dict(first, address="1.2.3.4", store="steam"),
                         machine_settings.load(self.new_release, self.profile))
        self.assertFalse((self.new_release / "settings.json").exists())

    def test_profile_wins_and_legacy_file_only_fills_gaps(self):
        (self.old_release / "settings.json").write_text(json.dumps({"server_name": "Old", "game_root": "D:/KF2"}))
        machine_settings.save({"server_name": "New", "unknown": "dropped", "address": None}, self.profile)
        self.assertEqual({"server_name": "New", "game_root": "D:/KF2"}, machine_settings.load(self.old_release, self.profile))
        saved = json.loads((self.profile / machine_settings.FILE).read_text())
        self.assertEqual({"server_name": "New"}, saved)

    def test_malformed_files_are_ignored(self):
        (self.old_release / "settings.json").write_text("{")
        self.profile.mkdir()
        (self.profile / machine_settings.FILE).write_text('["not", "an", "object"]')
        self.assertEqual({}, machine_settings.load(self.old_release, self.profile))
        machine_settings.save({"store": "epic"}, self.profile)
        self.assertEqual({"store": "epic"}, machine_settings.load(self.old_release, self.profile))


if __name__ == "__main__":
    unittest.main()
