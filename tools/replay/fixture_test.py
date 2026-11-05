"""Lane names, locks and roots for per-lane replay fixtures (python -m unittest tools/replay/fixture_test.py)."""
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixture


class LaneTest(unittest.TestCase):
    def test_shared_install_without_a_lane(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop('KF2VR_FIXTURE', None)
            self.assertIsNone(fixture.lane())
            self.assertEqual(fixture.GLOBAL_LOCK, fixture.lock_name())
            self.assertEqual(fixture.source_root(), fixture.game_root())

    def test_a_lane_gets_its_own_lock_and_copy(self):
        with mock.patch.dict(os.environ, {'KF2VR_FIXTURE': 'logic'}):
            self.assertEqual('logic', fixture.lane())
            self.assertEqual(fixture.GLOBAL_LOCK+'_logic', fixture.lock_name())
            self.assertEqual(fixture.FIXTURES/'logic'/'killingfloor2', fixture.game_root())

    def test_bad_lane_names_are_refused(self):
        for name in ('Logic', '../x', 'a b', '', 'x'*30):
            with self.subTest(name=name):
                if name:
                    with self.assertRaises(ValueError):
                        fixture.lane(name)

    def test_a_fixture_is_never_made_inside_build_or_the_install(self):
        with mock.patch.object(fixture, 'FIXTURES', fixture.ROOT/'build'/'fixtures'):
            with self.assertRaises(RuntimeError):
                fixture.create('harness')


class CopyTest(unittest.TestCase):
    def test_a_copy_never_inherits_the_native_proxy(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root/'install'
            (source/'Binaries/Win64').mkdir(parents=True)
            (source/'KFGame/BrewedPC').mkdir(parents=True)
            for name in ('KFGame.exe', 'dinput8.dll', 'openxr_loader.dll'):
                (source/'Binaries/Win64'/name).write_bytes(b'x')
            (source/'KFGame/BrewedPC/pkg.upk').write_bytes(b'y')
            with mock.patch.object(fixture, 'source_root', return_value=source),                  mock.patch.object(fixture, 'FIXTURES', root/'fixtures'):
                target = fixture.create('harness')
            self.assertTrue((target/'Binaries/Win64/KFGame.exe').exists())
            self.assertFalse((target/'Binaries/Win64/dinput8.dll').exists())
            self.assertFalse((target/'Binaries/Win64/openxr_loader.dll').exists())
            self.assertTrue(os.path.samefile(source/'KFGame/BrewedPC/pkg.upk', target/'KFGame/BrewedPC/pkg.upk'))


if __name__ == '__main__':
    unittest.main()
