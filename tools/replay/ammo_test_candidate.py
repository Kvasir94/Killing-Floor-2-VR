"""Explicit candidate path and player-selection guard tests."""
import json
from pathlib import Path
import tempfile
import unittest

from ammo_candidate import digest, verify_candidate


class CandidateGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.pointer = self.root/'build/multiplayer/current-release.json'
        self.pointer.parent.mkdir(parents=True)
        self.pointer.write_text(json.dumps({'release':'player-baseline'}))
        self.before = self.pointer.read_bytes()
        self.record = dict(selected_release='player-baseline',
                           selected_pointer_sha256=digest(self.pointer),
                           candidate_root=str(self.root/'build/multiplayer/releases/candidate'),
                           candidate_manifest_sha256='0'*64)

    def test_changed_player_pointer_refuses_without_overwriting_it(self):
        self.pointer.write_text(json.dumps({'release':'changed-by-user'}))
        current = self.pointer.read_bytes()
        with self.assertRaisesRegex(RuntimeError,'Player selection changed'):
            verify_candidate(self.root,self.record)
        self.assertEqual(current,self.pointer.read_bytes())

    def test_candidate_outside_generated_releases_refuses(self):
        self.record['candidate_root'] = str(self.root/'outside')
        with self.assertRaisesRegex(RuntimeError,'generated repository release'):
            verify_candidate(self.root,self.record)
        self.assertEqual(self.before,self.pointer.read_bytes())

    def test_candidate_manifest_change_refuses(self):
        candidate = Path(self.record['candidate_root'])
        candidate.mkdir(parents=True)
        (candidate/'release.json').write_text('{}')
        with self.assertRaisesRegex(RuntimeError,'manifest has changed'):
            verify_candidate(self.root,self.record)
        self.assertEqual(self.before,self.pointer.read_bytes())


if __name__ == '__main__':
    unittest.main()
