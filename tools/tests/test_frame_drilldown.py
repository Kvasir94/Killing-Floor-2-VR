import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('drilldown',Path(__file__).parents[1]/'analyze-frame-drilldown.py')
drill=importlib.util.module_from_spec(spec);spec.loader.exec_module(drill)


def write(path, rows):
    with path.open('w',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)


class DrilldownTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.frames=[];self.spans=[]
        for fid in range(1,4):
            row=dict(tickMs=fid*10,frame=fid,threadId=1,phase=4,phaseStable=1,intervalMs=10,
                     threadCpuMs=8,cpuCounterValid=1,spanOverflow=0,**{s:0 for s in drill.STAGES})
            row.update(otherMs=3,leftSceneMs=7);self.frames.append(row)
            self.spans.extend([dict(startMs=(fid-1)*10,endMs=(fid-1)*10+3,frame=fid,stage='otherMs'),
                               dict(startMs=(fid-1)*10+3,endMs=fid*10,frame=fid,stage='leftSceneMs')])
        self.save()

    def tearDown(self):self.temp.cleanup()
    def save(self):
        write(self.root/'frame-stages.csv',self.frames);write(self.root/'frame-spans.csv',self.spans)

    def test_accounting_and_cpu_aggregate(self):
        p=drill.analyze(self.root)['phases']['horde']
        self.assertEqual(p['mean_ms'],10);self.assertEqual(p['thread_cpu_fraction'],.8)
        self.assertEqual(p['stages']['leftSceneMs']['mean_ms'],7)
        self.assertAlmostEqual(sum(s['share_of_wall_time'] for s in p['stages'].values()),1)

    def test_missing_time_or_missing_frame_rejected(self):
        self.frames[0]['otherMs']=2;self.save()
        with self.assertRaisesRegex(ValueError,'Unaccounted'):drill.analyze(self.root)
        self.frames[0]['otherMs']=3;self.frames.pop(1);self.save()
        with self.assertRaisesRegex(ValueError,'Missing or reordered frame'):drill.analyze(self.root)

    def test_missing_or_overlapping_spans_rejected(self):
        self.spans.pop(0);self.save()
        with self.assertRaisesRegex(ValueError,'do not account'):drill.analyze(self.root)
        self.spans[1]['startMs']=9;self.save()
        with self.assertRaises(ValueError):drill.analyze(self.root)

    def test_overflow_is_reported_not_silently_complete(self):
        self.frames[0]['spanOverflow']=2;self.spans=self.spans[2:];self.save()
        self.assertEqual(drill.analyze(self.root)['phases']['horde']['span_overflows'],2)

    def test_stack_stage_and_frame_join_inclusive_deduplicates(self):
        (self.root/'stack-receipt.json').write_text(json.dumps(dict(thread_id=1,samples=3,aborted=False)))
        write(self.root/'stack-samples.csv',[dict(tickMs=t,sample=i,pausedMs=.04,contextOk=1,depth=2) for i,t in [(1,2),(2,5),(3,40)]])
        write(self.root/'stack-frames.csv',[dict(sample=i,depth=d,module='engine.dll',symbol='recur',rva='123') for i in [1,2,3] for d in [0,1]])
        r=drill.analyze(self.root);self.assertEqual(r['matched_stack_samples'],2)
        self.assertEqual(r['unmatched_or_excluded_stack_samples'],1)
        self.assertEqual(r['phases']['horde']['stages']['leftSceneMs']['inclusive_hotspots'],[('engine.dll!recur',1)])
        self.assertEqual(len(r['phases']['horde']['worst_frames'][0]['samples']),2)
        self.frames[0]['phaseStable']=0;self.save()
        self.assertEqual(drill.analyze(self.root)['matched_stack_samples'],0)

    def test_symbol_html_cannot_break_script(self):
        r=drill.analyze(self.root);r['note']='</script><img onerror=alert(1)>'
        target=self.root/'report.html';drill.write_html(r,target)
        text=target.read_text();self.assertEqual(text.count('</script>'),1)
        self.assertIn('\\u003c/script>',text)

    def test_unwind_failure_cannot_invent_callers(self):
        (self.root/'stack-receipt.json').write_text(json.dumps(dict(thread_id=1,samples=1,aborted=False)))
        write(self.root/'stack-samples.csv',[dict(tickMs=2,sample=1,pausedMs=.04,contextOk=1,depth=3)])
        write(self.root/'stack-frames.csv',[dict(sample=1,depth=d,module=m,symbol=s,rva='123') for d,m,s in
              [(0,'ntdll.dll','ZwQueryVirtualMemory'),(1,'unknown',''),(2,'engine.dll','bogus_tail')]])
        r=drill.analyze(self.root)
        inclusive=r['phases']['horde']['stages']['otherMs']['inclusive_hotspots']
        self.assertEqual(inclusive,[('ntdll.dll!ZwQueryVirtualMemory',1)])
        self.assertEqual(r['stacks_with_unmapped_tail_discarded'],1)

    def test_truncated_trace_cannot_pass_full_frame_coverage(self):
        write(self.root/'frames.csv',[dict(phase=4,submitted=1,renderable=1,focused=1,headTracked=1,menu=0)])
        with self.assertRaisesRegex(ValueError,'coverage differs'):drill.analyze(self.root)


if __name__=='__main__':unittest.main()
