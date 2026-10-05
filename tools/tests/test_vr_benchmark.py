import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('benchmark',Path(__file__).parents[1]/'analyze-vr-benchmark.py')
benchmark=importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class BenchmarkTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        record=dict(performance_benchmark=True,success=True,benchmark_measure_seconds=30,
            render_performance=dict(eye_render_percent=100,frame_timings=True,vm_timings=False),
            render_experiment=dict(revision=1,variant='Optimized',identity_reuse=True,settings_cache=True),
            runtime_controls_before=dict(effective_controls_sha256='controls'),
            runtime_controls_after=dict(effective_controls_sha256='controls'),
            script_sha256='script',original_config_sha256={'KFGame.ini':'same'},
            native_files=[dict(destination='D:/game/dinput8.dll',sha256='native')])
        (self.root/'run.json').write_text(json.dumps(record))
        (self.root/'game.log').write_text('KF2VR_BENCHMARK scenario=idle-horde-v1 anchor=A\n'
            + 'KF2VR_RENDER_AB revision=1 settingsCache=True\n'
            + 'KF2VR_BENCHMARK horde=' + ';'.join(['Monster:100']*12) + '\n'
            + 'KF2VR_BENCHMARK phase=complete passed=True reason=completed\n')
        (self.root/'adapter.log').write_text('RenderPerformance eyeRenderPercent=100 frameTimings=1 vmTimings=0\n'
            'RenderExperiment revision=1 identityReuse=1\n'
            'Game XR ready recommendedEye=2244x2352\n'+
            ''.join(f'BenchmarkCapture phase={i} previous={i-1}\n' for i in range(1,6)))
        self.rows=[]
        tick=0
        for phase in (2,4):
            tick+=10000
            for _ in range(3000):
                tick+=10
                self.rows.append(dict(tickMs=tick,intervalMs=10,phase=phase,submitted=1,renderable=1,
                    focused=1,headTracked=1,menu=0,width=2244,height=2352,periodMs=8.333,
                    headX=0,headY=1,headZ=0,headQx=0,headQy=0,headQz=0,headQw=1,
                    pawnX=100,pawnY=200,pawnZ=0))

    def analyze(self):
        with (self.root/'frames.csv').open('w',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=self.rows[0].keys())
            writer.writeheader();writer.writerows(self.rows)
        return benchmark.analyze(self.root)

    def test_exact_percentiles_and_fps(self):
        result=self.analyze()
        idle=result['phases']['idle']
        self.assertEqual(idle['application_fps'],100)
        self.assertEqual(idle['p99_ms'],10)
        self.assertEqual(idle['over_90_budget'],0)
        self.assertEqual(idle['over_120_budget'],3000)
        self.assertIsNone(result['reprojection'])

    def test_interrupted_runtime_rejected(self):
        for field,value in [('focused',0),('headTracked',0),('renderable',0),('submitted',0),('menu',1),
                            ('width',1683),('periodMs',0),('intervalMs',float('nan'))]:
            with self.subTest(field=field):
                old=self.rows[100][field];self.rows[100][field]=value
                with self.assertRaises(ValueError): self.analyze()
                self.rows[100][field]=old

    def test_incomplete_duration_rejected(self):
        self.rows=self.rows[:1000]+self.rows[3000:]
        with self.assertRaises(ValueError): self.analyze()

    def test_user_reported_headset_shutdown_rejected(self):
        (self.root/'invalidated.json').write_text(json.dumps(dict(reason='User reported headset shut off')))
        with self.assertRaisesRegex(ValueError, 'explicitly invalidated.*headset shut off'):
            self.analyze()

    def test_native_interruption_marker_rejected(self):
        with (self.root/'adapter.log').open('a') as stream:
            stream.write('BenchmarkCapture invalid=1 reason=tracking-focus-or-visibility phase=2\n')
        with self.assertRaisesRegex(ValueError, 'Native capture reported'):
            self.analyze()

    def test_missing_horde_signature_rejected(self):
        game=(self.root/'game.log').read_text()
        (self.root/'game.log').write_text('\n'.join(line for line in game.splitlines() if ' horde=' not in line))
        with self.assertRaises(ValueError): self.analyze()

    def test_missing_interior_frame_rejected(self):
        del self.rows[500]
        with self.assertRaises(ValueError): self.analyze()

    def test_motion_rejected(self):
        self.rows[100]['headX']=.2
        with self.assertRaises(ValueError): self.analyze()

    def test_disparate_runs_rejected(self):
        a=self.analyze()
        b=json.loads(json.dumps(a))
        b['runtime_controls_sha256']='different'
        with self.assertRaises(ValueError): benchmark.compare([a,b])
        b=json.loads(json.dumps(a));b['native_sha256']='different'
        with self.assertRaises(ValueError): benchmark.compare([a,b])
        b=json.loads(json.dumps(a));b['horde']=b['horde'].replace('Monster:100','Elite:200',1)
        with self.assertRaises(ValueError): benchmark.compare([a,b])

    def test_adaptive_runtime_period_is_reported(self):
        self.rows[100]['periodMs']=25
        a=self.analyze()
        self.assertEqual(a['phases']['idle']['runtime_period_range_ms'],[8.333,25])
        b=json.loads(json.dumps(a));b['phases']['horde']['runtime_period_ms']=33.333
        self.assertTrue(benchmark.compare([a,b])['valid'])

    def test_requested_mode_requires_live_evidence(self):
        record=json.loads((self.root/'run.json').read_text())
        record['render_experiment']=dict(revision=1,variant='Baseline',identity_reuse=False,settings_cache=False)
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaises(ValueError): self.analyze()
        native=(self.root/'adapter.log').read_text().replace('identityReuse=1','identityReuse=0')
        (self.root/'adapter.log').write_text(native)
        with self.assertRaises(ValueError): self.analyze()
        game=(self.root/'game.log').read_text().replace('settingsCache=True','settingsCache=False')
        (self.root/'game.log').write_text(game)
        self.assertEqual(self.analyze()['variant'],'Baseline')

    def test_controls_changed_during_run_rejected(self):
        record=json.loads((self.root/'run.json').read_text())
        record['runtime_controls_after']['effective_controls_sha256']='changed'
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaises(ValueError): self.analyze()

    def test_code_ab_isolates_code_and_reports_repeat_variation(self):
        result=self.analyze()
        runs=[json.loads(json.dumps(result)) for _ in range(4)]
        for run,mode,time in zip(runs,['Baseline','Optimized','Optimized','Baseline'],[12,10,10.2,12.2]):
            run['variant']=mode
            for phase in run['phases'].values():phase['mean_ms']=time
        report=benchmark.compare(runs,'CodeAB')
        opt=report['comparisons']['horde']['Optimized']
        self.assertAlmostEqual(opt['frame_time_reduction_percent'],100*(1-10.1/12.1))
        self.assertEqual(opt['interpretation'],'all treatment repeats faster in this batch')
        runs[1]['percent']=75
        with self.assertRaises(ValueError):benchmark.compare(runs,'CodeAB')
        runs[1]['percent']=100;runs[1]['frame_timings']=False
        with self.assertRaises(ValueError):benchmark.compare(runs,'CodeAB')
        runs[1]['frame_timings']=True
        runs[1]['phases']['horde']['mean_ms']=12.3
        self.assertIn('overlap',benchmark.compare(runs,'CodeAB')['comparisons']['horde']['Optimized']['interpretation'])
        with self.assertRaises(ValueError):benchmark.compare(runs,'Resolution')

    def test_timing_off_requires_record_and_native_agreement(self):
        record=json.loads((self.root/'run.json').read_text())
        record['render_performance']['frame_timings']=False
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaises(ValueError):self.analyze()
        (self.root/'adapter.log').write_text((self.root/'adapter.log').read_text().replace('frameTimings=1','frameTimings=0'))
        result=self.analyze()
        runs=[json.loads(json.dumps(result)) for _ in range(4)]
        for run,on in zip(runs,[False,True,True,False]):run['frame_timings']=on
        self.assertTrue(benchmark.compare(runs,'TimingOverhead')['valid'])
        with self.assertRaises(ValueError):benchmark.compare(runs,'CodeAB')

    def test_quick_ab_is_explicitly_unreplicated(self):
        optimized=self.analyze()
        baseline=json.loads(json.dumps(optimized));baseline['variant']='Baseline'
        report=benchmark.compare([baseline,optimized],'CodeABQuick')
        self.assertEqual(report['comparisons']['horde']['Optimized']['interpretation'],'insufficient repeats')
        with self.assertRaises(ValueError):benchmark.compare([optimized,baseline],'CodeABQuick')
        optimized['percent']=75
        with self.assertRaises(ValueError):benchmark.compare([baseline,optimized],'CodeABQuick')

    def test_explicit_cross_run_angle_tolerance(self):
        import math
        a=self.analyze();b=json.loads(json.dumps(a))
        for label in ('idle','horde'):
            a['phases'][label]['head_rotation_start']=[0,0,0,1]
            b['phases'][label]['head_rotation_start']=[0,math.sin(math.radians(3.99)/2),0,math.cos(math.radians(3.99)/2)]
        with self.assertRaisesRegex(ValueError,'Cross-run view mismatch'):benchmark.compare([a,b])
        self.assertEqual(benchmark.compare([a,b],cross_run_angle_degrees=4)['cross_run_angle_tolerance_degrees'],4)
        b['phases']['idle']['head_start'][0]+=0.1
        with self.assertRaisesRegex(ValueError,'Cross-run view mismatch'):benchmark.compare([a,b],cross_run_angle_degrees=4)

    def test_diagnostic_stacks_cannot_be_fps_evidence(self):
        (self.root/'stack-samples.csv').write_text('sample\n1\n')
        with self.assertRaisesRegex(ValueError,'diagnostic run'):self.analyze()
        (self.root/'stack-samples.csv').unlink()
        record=json.loads((self.root/'run.json').read_text())
        record['render_performance']['stack_sampling']=True
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError,'diagnostic run'):self.analyze()

    def test_frame_trace_must_match_between_trials(self):
        a=self.analyze();b=json.loads(json.dumps(a));b['frame_drilldown']=True
        with self.assertRaisesRegex(ValueError,'instrumentation must match'):benchmark.compare([a,b])

    def test_frame_trace_requires_live_evidence(self):
        record=json.loads((self.root/'run.json').read_text());record['render_performance']['frame_drilldown']=True
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError,'live evidence'):self.analyze()
        with (self.root/'adapter.log').open('a') as stream:stream.write('FrameDrilldown enabled=1 revision=1\n')
        with self.assertRaisesRegex(ValueError,'Missing frame drilldown'):self.analyze()
        (self.root/'frame-stages.csv').touch()
        self.assertTrue(self.analyze()['frame_drilldown'])

    def test_fast_vm_mode_requires_live_evidence(self):
        record=json.loads((self.root/'run.json').read_text())
        record['render_experiment']['fast_vm_identity']=True
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError,'VM entry read mode'):self.analyze()
        with (self.root/'adapter.log').open('a') as stream:stream.write('VmEntryExperiment revision=1 fastIdentity=1\n')
        self.assertTrue(self.analyze()['fast_vm_identity'])

    def test_fast_vm_comparison_keeps_other_controls_fixed(self):
        checked=self.analyze();fast=json.loads(json.dumps(checked));fast['fast_vm_identity']=True
        result=benchmark.compare([checked,fast],'VmIdentityQuick')
        self.assertEqual(result['comparisons']['horde']['FastEntry']['interpretation'],'insufficient repeats')
        with self.assertRaises(ValueError):benchmark.compare([checked,fast],'Resolution')
        fast['variant']='Baseline'
        with self.assertRaises(ValueError):benchmark.compare([checked,fast],'VmIdentityQuick')

    def test_metadata_cache_requires_live_evidence(self):
        record=json.loads((self.root/'run.json').read_text())
        record['render_experiment']['metadata_cache']=True
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError,'Metadata cache mode'):self.analyze()
        with (self.root/'adapter.log').open('a') as stream:stream.write('MetadataExperiment revision=1 fieldCache=1\n')
        with self.assertRaisesRegex(ValueError,'no recorded live hits'):self.analyze()
        with (self.root/'adapter.log').open('a') as stream:stream.write('MetadataCache revision=1 cumulative=1 hits=100 misses=5 invalidations=0\n')
        self.assertTrue(self.analyze()['metadata_cache'])
        self.assertEqual(self.analyze()['metadata_cache_cumulative_counts']['hits'],100)
        with (self.root/'adapter.log').open('a') as stream:stream.write('MetadataCache revision=1 cumulative=1 hits=99 misses=5 invalidations=0\n')
        with self.assertRaisesRegex(ValueError,'counters regressed'):self.analyze()
        record['render_experiment']['metadata_cache']=False
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError,'Metadata cache mode'):self.analyze()

    def test_metadata_comparison_isolates_cache_and_reports_no_repeats(self):
        uncached=self.analyze();cached=json.loads(json.dumps(uncached));cached['metadata_cache']=True
        report=benchmark.compare([uncached,cached],'MetadataQuick')
        self.assertEqual(report['comparisons']['horde']['CachedMetadata']['interpretation'],'insufficient repeats')
        with self.assertRaises(ValueError):benchmark.compare([cached,uncached],'MetadataQuick')
        with self.assertRaises(ValueError):benchmark.compare([uncached,cached],'VmIdentityQuick')
        for field,value in [('fast_vm_identity',True),('variant','Baseline'),('percent',75),('frame_timings',False)]:
            with self.subTest(field=field):
                changed=json.loads(json.dumps(cached));changed[field]=value
                with self.assertRaises(ValueError):benchmark.compare([uncached,changed],'MetadataQuick')

    def test_competing_workload_evidence_rejected(self):
        record=json.loads((self.root/'run.json').read_text())
        record['workload_contamination']={'competing_processes':[{'name':'blender','pid':42}]}
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError,'Competing host workload'):self.analyze()
        del record['workload_contamination'];record['workload_guard']={'revision':1}
        (self.root/'run.json').write_text(json.dumps(record))
        evidence=self.root/'host-workloads.jsonl'
        evidence.write_text('{"competing_processes":[]}\n')
        with self.assertRaisesRegex(ValueError,'incomplete workload evidence'):self.analyze()
        evidence.write_text('{"competing_processes":[]}\n'*2)
        self.assertTrue(self.analyze()['workload_guard'])
        with evidence.open('a') as stream:stream.write('{"competing_processes":[{"name":"blender"}]}\n')
        with self.assertRaisesRegex(ValueError,'Competing host workload'):self.analyze()

    def test_workload_instrumentation_must_match(self):
        a=self.analyze();b=json.loads(json.dumps(a));b['workload_guard']=True
        with self.assertRaisesRegex(ValueError,'workload instrumentation'):benchmark.compare([a,b])

    def test_prepass_requires_both_eyes_and_no_constructor_override(self):
        record=json.loads((self.root/'run.json').read_text())
        record['render_experiment']['depth_prepass']='Disabled'
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError,'readback mapping'):self.analyze()
        with (self.root/'adapter.log').open('a') as stream:stream.write('RenderPassReadback revision=1 verified=1\n')
        with self.assertRaisesRegex(ValueError,'live depth prepass'):self.analyze()
        for row in self.rows:
            row.update(depthPrepassLeft=0,depthPrepassRight=0,prepassOverrideLeft=0,prepassOverrideRight=0)
        self.assertEqual(self.analyze()['depth_prepass'],'Disabled')
        for column in ('depthPrepassLeft','depthPrepassRight','prepassOverrideLeft','prepassOverrideRight'):
            with self.subTest(column=column):
                self.rows[100][column]=1
                with self.assertRaisesRegex(ValueError,'live depth prepass'):self.analyze()
                self.rows[100][column]=0

    def test_prepass_comparison_changes_only_prepass(self):
        enabled=self.analyze();enabled['depth_prepass']='Enabled'
        disabled=json.loads(json.dumps(enabled));disabled['depth_prepass']='Disabled'
        report=benchmark.compare([enabled,disabled],'DepthPrepassQuick')
        self.assertEqual(report['comparisons']['horde']['PrepassDisabled']['interpretation'],'insufficient repeats')
        with self.assertRaises(ValueError):benchmark.compare([disabled,enabled],'DepthPrepassQuick')
        with self.assertRaises(ValueError):benchmark.compare([enabled,disabled],'Resolution')
        for field,value in [('metadata_cache',True),('fast_vm_identity',True),('variant','Baseline'),('percent',75),('frame_timings',False)]:
            with self.subTest(field=field):
                changed=json.loads(json.dumps(disabled));changed[field]=value
                with self.assertRaises(ValueError):benchmark.compare([enabled,changed],'DepthPrepassQuick')

    def test_hand_writes_require_live_successful_commits(self):
        record=json.loads((self.root/'run.json').read_text());record['render_experiment']['batch_hand_writes']=True
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError,'Hand write mode'):self.analyze()
        with (self.root/'adapter.log').open('a') as stream:stream.write('HandWriteExperiment revision=1 batched=1\n')
        with self.assertRaisesRegex(ValueError,'no recorded live'):self.analyze()
        with (self.root/'adapter.log').open('a') as stream:stream.write('HandWriteBatch revision=1 cumulative=1 commits=2 rangeQueries=2 writes=60 failures=0\n')
        self.assertEqual(self.analyze()['hand_write_cumulative_counts']['writes'],60)
        with (self.root/'adapter.log').open('a') as stream:stream.write('HandWriteBatch invalid=1 reason=update-refused\n')
        with self.assertRaisesRegex(ValueError,'refused an update'):self.analyze()

    def test_hand_write_comparison_holds_other_treatments_fixed(self):
        old=self.analyze();batched=json.loads(json.dumps(old));batched['batch_hand_writes']=True
        self.assertEqual(benchmark.compare([old,batched],'HandWriteQuick')['comparisons']['horde']['BatchedWrites']['interpretation'],'insufficient repeats')
        with self.assertRaises(ValueError):benchmark.compare([batched,old],'HandWriteQuick')
        with self.assertRaises(ValueError):benchmark.compare([old,batched],'DepthPrepassQuick')
        for field,value in [('metadata_cache',True),('fast_vm_identity',True),('variant','Baseline'),('percent',75),('frame_timings',False),('depth_prepass','Disabled')]:
            with self.subTest(field=field):
                changed=json.loads(json.dumps(batched));changed[field]=value
                with self.assertRaises(ValueError):benchmark.compare([old,changed],'HandWriteQuick')


    def test_cpu_path_modes_require_live_markers(self):
        record=json.loads((self.root/'run.json').read_text())
        record['render_experiment'].update(checked_reads=False,per_eye_presentation=False)
        (self.root/'run.json').write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError,'Script read mode'):self.analyze()
        with (self.root/'adapter.log').open('a') as stream:stream.write('ReadExperiment revision=1 guardedReads=1\n')
        with self.assertRaisesRegex(ValueError,'Presentation finalize mode'):self.analyze()
        with (self.root/'adapter.log').open('a') as stream:stream.write('PresentationExperiment revision=1 perEyeFinalize=0\n')
        result=self.analyze()
        self.assertEqual((result['checked_reads'],result['per_eye_presentation']),(False,False))

    def test_cpu_path_comparison_holds_other_treatments_fixed(self):
        legacy=self.analyze();lean=json.loads(json.dumps(legacy))
        lean.update(checked_reads=False,per_eye_presentation=False)
        self.assertEqual(benchmark.compare([legacy,lean],'CpuPathQuick')['comparisons']['horde']['LeanCpuPath']['interpretation'],'insufficient repeats')
        with self.assertRaises(ValueError):benchmark.compare([lean,legacy],'CpuPathQuick')
        with self.assertRaises(ValueError):benchmark.compare([legacy,lean],'HandWriteQuick')
        for field,value in [('metadata_cache',True),('batch_hand_writes',True),('per_eye_presentation',True),('variant','Baseline'),('percent',75),('frame_timings',False)]:
            with self.subTest(field=field):
                changed=json.loads(json.dumps(lean));changed[field]=value
                with self.assertRaises(ValueError):benchmark.compare([legacy,changed],'CpuPathQuick')


if __name__=='__main__': unittest.main()
