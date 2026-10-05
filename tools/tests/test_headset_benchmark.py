import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('headset',Path(__file__).parents[1]/'analyze-headset-benchmark.py')
headset = importlib.util.module_from_spec(spec)
spec.loader.exec_module(headset)


class HeadsetBenchmarkTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.session = dict(game_pid=77,collector_clean_exit=True,controls_unchanged=True,context={},phases=[
            dict(label=label,start_tick_ms=start,end_tick_ms=start+30000,headset_worn=True,active_play=True)
            for label,start in [('noncombat',10000),('combat',50000)]])
        self.rows = []
        for phase in self.session['phases']:
            for i in range(121):
                row = dict(scenePid=77,frameIndex=len(self.rows)+1,firstObservedTickMs=phase['start_tick_ms']+i*250,
                           firstPollGapMs=250,refreshHz=90,refreshError=0,motionSmoothingEnabled=0,
                           motionSmoothingSupported=0,throttled=0,predicted=0,reprojectionFlags=4,
                           presents=1,dropped=0,misPresented=0)
                row.update({k:0 for k in ['preSubmitGpuMs','postSubmitGpuMs','totalRenderGpuMs','compositorGpuMs',
                    'compositorCpuMs','presentCpuMs','waitPresentCpuMs','submitMs','transferLatencyMs']})
                row['clientIntervalMs'] = 10 if i%2 else 20
                self.rows.append(row)

    def analyze(self):
        (self.root/'session.json').write_text(json.dumps(self.session))
        with (self.root/'runtime.csv').open('w',newline='') as stream:
            writer = csv.DictWriter(stream,fieldnames=self.rows[0].keys())
            writer.writeheader(); writer.writerows(self.rows)
        return headset.analyze(self.root)

    def test_cadence_uses_mean_interval_and_mode_is_not_reprojection(self):
        result = self.analyze()
        self.assertTrue(result['valid'])
        phase = result['phases'][0]
        self.assertAlmostEqual(phase['application_timing']['application_fps'],1000/(1580/105))
        self.assertEqual(phase['cpu_reprojection_reason_fraction'],0)
        self.assertEqual(phase['repeat_presents'],0)
        self.assertIsNone(result['delivered_headset_fps'])

    def test_unsupported_application_intervals_do_not_claim_fps(self):
        for row in self.rows: row['clientIntervalMs'] = 0
        result = self.analyze()
        self.assertFalse(result['valid'])
        self.assertIsNone(result['phases'][0]['application_timing'])

    def test_removed_headset_unconfirmed_not_valid(self):
        self.session['phases'][1]['headset_worn'] = False
        self.assertFalse(self.analyze()['valid'])

    def test_missing_history_not_valid(self):
        del self.rows[30]
        self.assertFalse(self.analyze()['valid'])

    def test_foreign_pid_excluded(self):
        self.rows.append(dict(self.rows[30],scenePid=999,dropped=900))
        self.assertEqual(self.analyze()['phases'][0]['dropped'],0)

    def test_failed_collector_not_valid(self):
        self.session['collector_clean_exit'] = False
        self.assertFalse(self.analyze()['valid'])

    def test_truncated_phase_not_valid_even_with_twenty_seconds(self):
        self.session['phases'][1]['end_tick_ms'] += 30000
        self.assertFalse(self.analyze()['valid'])


if __name__ == '__main__': unittest.main()
