import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from saved_motion import inspect_clip,stage_clip,sha256

class SavedMotionTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)/'source.kfm';self.path.write_bytes(b'bounded test input')
        self.samples=[{'seconds':0,'map':'KF-BurningParis','boundary':1,'synthetic':True},
                      {'seconds':8,'map':'KF-BurningParis','boundary':2,'synthetic':True}]

    def inspect(self):
        with patch('saved_motion.read_clip',return_value=self.samples):return inspect_clip(self.path)

    def test_stage_preserves_original_and_refuses_overwrite(self):
        source=self.inspect();dest=Path(self.tmp.name)/'review/clip-1.kfm'
        stage_clip(source,dest)
        self.assertEqual(sha256(dest),source['sha256'])
        self.assertEqual(self.path.read_bytes(),b'bounded test input')
        with self.assertRaises(FileExistsError):stage_clip(source,dest)

    def test_source_change_after_validation_rejected(self):
        source=self.inspect();self.path.write_bytes(b'changed')
        with self.assertRaises(ValueError):stage_clip(source,Path(self.tmp.name)/'review.kfm')

    def test_duration_bounds(self):
        for seconds in (.4,241):
            self.samples[-1]['seconds']=seconds
            with self.assertRaises(ValueError):self.inspect()

    def test_map_and_respawn_boundaries_rejected(self):
        for boundary in (8,16):
            self.samples[-1]['boundary']=boundary
            with self.assertRaises(ValueError):self.inspect()

    def test_missing_or_different_map_rejected(self):
        for name in ('None','KF-Outpost'):
            self.samples[-1]['map']=name
            with self.assertRaises(ValueError):self.inspect()

    def test_input_label_and_duration_derived_from_file(self):
        self.samples[-1]['synthetic']=False
        source=self.inspect()
        self.assertIn('synthetic flag false',source['input'])
        self.assertEqual(source['observation_seconds'],13)

if __name__=='__main__':unittest.main()
