"""Bundled range discovery and launch URL contracts; no game execution."""
from pathlib import Path
from types import SimpleNamespace
import json
import tempfile
import unittest

import range_map
import launch_menu
import package


class RangeMapTests(unittest.TestCase):
    def test_discovery_requires_bundled_map_and_does_not_duplicate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(["KF-Outpost"], range_map.include_bundled(["KF-Outpost"], root))
            path = root / "Packages" / "KF-VRRange.kfm"
            path.parent.mkdir()
            path.write_bytes(b"map")
            maps = range_map.include_bundled(["KF-Outpost"], root)
            self.assertEqual(["KF-Outpost", "KF-VRRange"], maps)
            self.assertEqual(maps, range_map.include_bundled(maps, root))

    def test_only_range_selects_sandbox_game(self):
        args = SimpleNamespace(map="KF-VRRange", mods=[])
        self.assertIn("?Game=" + range_map.GAME_CLASS + "?", launch_menu.host_url(args))
        args.map = "KF-Outpost"
        self.assertIn("?Game=" + launch_menu.NORMAL_GAME + "?", launch_menu.host_url(args))

    def test_package_refuses_stale_map_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            built = root / "build/range"
            built.mkdir(parents=True)
            output = root / "release"
            (output / "Packages").mkdir(parents=True)
            author = root / "author.py"
            author.write_text("original")
            source = built / "KF-VRRange.kfm"
            source.write_bytes(b"authored map")
            (built / "build.json").write_text(json.dumps({"success": True,
                "inputs_sha256": {"author.py": package.digest(author)},
                "package_sha256": package.digest(source)}))
            package.copy_range_map(root, output)
            self.assertEqual(source.read_bytes(), (output / "Packages" / source.name).read_bytes())
            author.write_text("changed geometry")
            with self.assertRaisesRegex(RuntimeError, "inputs changed"):
                package.copy_range_map(root, output)
