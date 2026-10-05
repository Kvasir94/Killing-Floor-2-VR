from datetime import datetime, timedelta, timezone
import csv
import importlib.util
import json
from pathlib import Path
import unittest
import tempfile

spec=importlib.util.spec_from_file_location('steamlink',Path(__file__).parents[1]/'analyze-steamlink-log.py')
steamlink=importlib.util.module_from_spec(spec);spec.loader.exec_module(steamlink)


class SteamLinkLogTest(unittest.TestCase):
    def test_bad_link_fields_and_local_clock(self):
        text='Wed Sep 16 2026 21:38:25.561 [Info] - Bad link event: d=35.3 ms 146.8 mbit/s -> 145.7 mbit/s, ping 9.7 ms, holdoff 0, auto 1'
        rows=steamlink.events(text,-300);self.assertEqual(len(rows),1)
        row=rows[0]
        self.assertEqual(row['unix_ms'],datetime(2026,9,17,2,38,25,561000,tzinfo=timezone.utc).timestamp()*1000)
        self.assertEqual(row['driver_d_ms'],35.3);self.assertEqual(row['ping_ms'],9.7)
        self.assertTrue(row['automatic']);self.assertEqual(steamlink.summarize(rows)['automatic_rate_reductions'],1)

    def test_other_warnings_remain_separate(self):
        prefix='Wed Sep 16 2026 21:38:25.561 [Info] - '
        text='\n'.join(prefix+s for s in ('THROTTLE EVENT: 38619','Reset video stream because test',
                     '[Perf warning] 128.0ms - Encode Time','Link BW: Est 143.5 Mbit/s (auto: 1)'))
        summary=steamlink.summarize(steamlink.events(text,-300))
        self.assertEqual(summary['driver_throttle_markers'],1)
        self.assertEqual(summary['stream_resets'],1)
        self.assertEqual(summary['performance_warnings'][0]['stage'],'Encode Time')
        self.assertEqual(summary['bad_link_events'],0)
        self.assertIsNone(summary['bad_event_ping_ms_range'])

    def test_empty_log_does_not_invent_ping_or_delay(self):
        result=steamlink.summarize(steamlink.events('Unrelated log line',-300))
        self.assertEqual(result['bad_link_events'],0)
        self.assertIsNone(result['bad_event_driver_d_ms_range'])

    def test_phase_edges_log_rotation_and_clock_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);run=root/'run';run.mkdir()
            origin=datetime(2026,9,17,2,0,tzinfo=timezone.utc).timestamp()*1000
            anchor=dict(utc_unix_ms=origin,tick_ms=0,local_utc_offset_minutes=-300)
            batch=dict(success=True,runs=[str(run)],clock_anchor_before=anchor)
            (root/'batch.json').write_text(json.dumps(batch))
            (root/'clock-anchor.json').write_text(json.dumps(anchor))
            (run/'performance.json').write_text(json.dumps(dict(valid=True,percent=100)))
            with (run/'frames.csv').open('w',newline='') as stream:
                writer=csv.DictWriter(stream,fieldnames=['phase','tickMs','intervalMs']);writer.writeheader()
                for phase,start in ((2,0),(4,40000)):
                    writer.writerows(dict(phase=phase,tickMs=start+(i+1)*300,intervalMs=300) for i in range(100))
            def line(tick):
                stamp=datetime.fromtimestamp((origin+tick)/1000,timezone(timedelta(hours=-5))).strftime('%a %b %d %Y %H:%M:%S.000')
                return stamp+' [Info] - Bad link event: d=18.0 ms 150.0 mbit/s -> 149.0 mbit/s, ping 10.0 ms, holdoff 0, auto 1\n'
            before=line(5000)
            (root/'before-driver_vrlink.txt').write_text(before)
            after=before+''.join(line(t) for t in (1000,5000,29000,45000))
            (root/'after-driver_vrlink.txt').write_text(after)
            report=steamlink.analyze(root)
            self.assertEqual(report['runs'][0]['phases']['idle']['bad_link_events'],1)
            self.assertEqual(report['runs'][0]['phases']['horde']['bad_link_events'],1)
            (root/'after-driver_vrlink.txt').write_text('rotated')
            with self.assertRaisesRegex(ValueError,'rotated'):steamlink.analyze(root)
            (root/'after-driver_vrlink.txt').write_text(after)
            (root/'clock-anchor.json').write_text(json.dumps(dict(anchor,utc_unix_ms=origin+1000)))
            with self.assertRaisesRegex(ValueError,'Wall clock'):steamlink.analyze(root)


if __name__=='__main__': unittest.main()
