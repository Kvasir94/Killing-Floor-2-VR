import importlib.util
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('summary',Path(__file__).parents[1]/'summarize-vr-benchmark.py')
summary=importlib.util.module_from_spec(spec);spec.loader.exec_module(summary)

class BusyTest(unittest.TestCase):
    def busy(self,log,threaded=False):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory)/'adapter.log').write_text(log)
            return summary.busy_ms(directory,threaded)

    def test_one_thread_splits_buckets_and_reports_cpu(self):
        horde=self.busy('''tick_ms=1000 BenchmarkCapture phase=4 previous=3
tick_ms=7000 FrameTiming elapsedMs=5000 presents=500 otherMs=1000 worldMs=3000 xrBeginMs=500
tick_ms=7000 ThreadCpu revision=1 presentThreadCpuMs=4000 threaded=0
tick_ms=8000 BenchmarkCapture phase=5 previous=4
''')['horde']
        self.assertEqual((horde['work'],horde['game'],horde['render'],horde['game_cpu']),(9,2,6,8))
        self.assertNotIn('render_cpu',horde)

    def test_threaded_reports_each_thread_not_buckets(self):
        horde=self.busy('''tick_ms=1000 BenchmarkCapture phase=4 previous=3
tick_ms=7000 FrameTiming elapsedMs=5000 presents=500 otherMs=4000 xrBeginMs=1000
tick_ms=7000 ThreadCpu revision=1 presentThreadCpuMs=3000 threaded=1
tick_ms=7000 GameThreadTiming revision=1 elapsedMs=5000 frames=500 cpuMs=2500 renderWaitMs=1500
tick_ms=8000 BenchmarkCapture phase=5 previous=4
''')['horde']
        self.assertEqual((horde['game_cpu'],horde['render_cpu'],horde['game_blocked']),(5,6,5))
        self.assertNotIn('game',horde)

    def test_threaded_variant_without_thread_logs_hides_split(self):
        horde=self.busy('''tick_ms=1000 BenchmarkCapture phase=4 previous=3
tick_ms=7000 FrameTiming elapsedMs=5000 presents=500 otherMs=4000
tick_ms=8000 BenchmarkCapture phase=5 previous=4
''',threaded=True)['horde']
        self.assertNotIn('game',horde)
        self.assertIsNone(horde['render_cpu'])

if __name__=='__main__':
    unittest.main()
