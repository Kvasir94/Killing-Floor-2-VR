import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('runtime',Path(__file__).parents[1]/'analyze-runtime-monitor.py')
runtime=importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimePhasesTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.csv=self.root/'runtime.csv'
        (self.root/'run.json').write_text(json.dumps(dict(success=True,process_id=77)))
        (self.root/'performance.json').write_text(json.dumps(dict(valid=True)))
        frames=[];self.rows=[]
        for phase,start in ((2,10000),(4,50000)):
            frames.extend(dict(phase=phase,tickMs=start+(i+1)*300,intervalMs=300) for i in range(100))
            for i in range(121):
                tick=start+i*250
                row=dict(scenePid=77,frameIndex=phase*1000+i,firstObservedTickMs=tick,
                         observedTickMs=tick+1000,firstPollGapMs=250,refreshHz=120,refreshError=0,
                         motionSmoothingEnabled=0,motionSmoothingSupported=0,throttled=0,predicted=2,
                         reprojectionFlags=4,presents=1,dropped=0,misPresented=0)
                row.update({key:0 for key in ('preSubmitGpuMs','postSubmitGpuMs','totalRenderGpuMs',
                    'compositorGpuMs','compositorCpuMs','clientIntervalMs','presentCpuMs',
                    'waitPresentCpuMs','submitMs','transferLatencyMs')})
                self.rows.append(row)
        self.write(self.root/'frames.csv',frames)

    @staticmethod
    def write(path,rows):
        with path.open('w',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=rows[0].keys());writer.writeheader();writer.writerows(rows)

    def analyze(self):
        self.write(self.csv,self.rows)
        return runtime.measured_phases(self.csv,self.root)

    def test_uses_first_observation_and_excludes_other_pid_and_phase_edges(self):
        self.rows[0]['dropped']=999
        foreign=dict(self.rows[20],scenePid=88,dropped=999)
        self.rows.insert(21,foreign)
        result=self.analyze();idle=result['phases']['idle']
        self.assertTrue(idle['available']);self.assertEqual(idle['frames_observed'],105)
        self.assertEqual(idle['dropped'],0);self.assertEqual(idle['observed_coverage_ms'],26000)
        self.assertEqual(idle['missing_frame_indices'],0)
        self.assertFalse(idle['application_gpu_fields_available'])
        self.assertIsNone(result['wireless_delivery']);self.assertIsNone(result['delivered_fps'])

    def test_long_poll_gaps_do_not_masquerade_as_coverage(self):
        for row in self.rows: row['firstPollGapMs']=700
        self.assertFalse(self.analyze()['phases']['horde']['available'])

    def test_partial_phase_does_not_masquerade_as_complete_coverage(self):
        self.rows = [r for r in self.rows if not 37500 <= r['firstObservedTickMs'] <= 40000]
        self.assertFalse(self.analyze()['phases']['idle']['available'])

    def test_old_collectors_cannot_claim_phase_attribution(self):
        for row in self.rows: del row['firstObservedTickMs'];del row['firstPollGapMs']
        self.assertFalse(self.analyze()['phases']['idle']['available'])
        self.assertTrue(runtime.analyze(self.csv)['available'])

    def test_duplicate_frame_rejected(self):
        self.rows.insert(21,dict(self.rows[20]))
        with self.assertRaisesRegex(ValueError,'Duplicate'):self.analyze()

    def test_nonfinite_observation_rejected(self):
        self.rows[20]['transferLatencyMs']=float('nan')
        with self.assertRaisesRegex(ValueError,'Nonfinite'):self.analyze()

    def test_failed_application_not_attributed(self):
        (self.root/'performance.json').write_text(json.dumps(dict(valid=False)))
        with self.assertRaisesRegex(ValueError,'validated'):self.analyze()


if __name__=='__main__': unittest.main()
