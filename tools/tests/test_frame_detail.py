import importlib.util
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('detail',Path(__file__).parents[1]/'analyze-frame-detail.py')
detail=importlib.util.module_from_spec(spec);spec.loader.exec_module(detail)

class DetailTest(unittest.TestCase):
    def test_complete_windows_nested_xr_and_vm_estimate(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'adapter.log').write_text('''tick_ms=1000 BenchmarkCapture phase=2 previous=1
tick_ms=2000 FrameTiming elapsedMs=5000 presents=500 otherMs=2000 worldMs=3000
tick_ms=2000 XrDetail revision=1 cumulative=1 waitFrameMs=100
tick_ms=7000 FrameTiming elapsedMs=5000 presents=500 otherMs=2000 worldMs=3000
tick_ms=7000 VmSample revision=1 calls=100000 samples=400 dispatchMs=2 bodyMs=4
tick_ms=7000 XrDetail revision=1 cumulative=1 waitFrameMs=150
tick_ms=8000 BenchmarkCapture phase=3 previous=2
''')
            phase=detail.breakdown(root)['phases']['idle']
            self.assertEqual(phase['windows'],1)
            self.assertEqual(phase['accounted_ms_per_frame'],10)
            self.assertEqual(phase['vm_sampling']['estimated_dispatch_ms_per_frame'],1)
            self.assertEqual(phase['xr_nested_ms_per_frame']['waitFrameMs'],.1)
            self.assertNotIn('sceneSetupMs',phase['cpu_ms_per_frame'])

    def test_incomplete_phase_has_no_breakdown(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory)/'adapter.log').write_text('tick_ms=1000 BenchmarkCapture phase=2 previous=1\n')
            self.assertEqual(detail.breakdown(directory)['phases'],{})

if __name__=='__main__':unittest.main()
