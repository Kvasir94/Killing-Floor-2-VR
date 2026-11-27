"""Manifest checks, command lines, result reading and the report for replay campaigns
(python -m unittest tools/replay/campaign_test.py)."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import campaign


def entry(**fields):
    base = dict(id='e1', runner='solo', script='s/a.kfs', areas=['reload'], kind='logic', tier='core')
    base.update(fields)
    return base


class ManifestTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root/'s').mkdir()
        (self.root/'s/a.kfs').write_text('end\n', encoding='utf-8')

    def tearDown(self):
        self.temp.cleanup()

    def problems(self, *entries):
        return campaign.validate(list(entries), root=self.root)

    def test_a_good_manifest_has_no_problems(self):
        self.assertEqual([], self.problems(
            entry(weapons=['all'], matrix={'preset': ['advanced'], 'var.start': ['empty', 'partial']}),
            entry(id='e2', runner='mp', clients=2, zeds=True, matrix={'var.role': ['actor', 'observer']}),
            entry(id='e3', runner='mp', after='e2', vars={'phase': 'check'}, skip='needs a hand-made config')))

    def test_bad_entries_are_named(self):
        cases = [
            (entry(id='e1', runner='host'), 'runner'),
            (entry(script='s/missing.kfs'), 'no script'),
            (entry(kind='pretty'), 'kind'),
            (entry(clients=2), 'clients'),
            (entry(runner='mp', weapons=['all']), 'catalog'),
            (entry(extra=['--fixture', 'x']), 'campaign sets'),
            (entry(runner='mp', extra=['--parallel', '2']), 'scripted_mp.py has no'),
            (entry(after='nobody'), 'not an earlier entry'),
            (entry(matrix={'var.mode': []}), 'matrix'),
            (entry(colour='red'), 'unknown fields'),
        ]
        for bad, text in cases:
            with self.subTest(text=text):
                self.assertTrue(any(text in p for p in self.problems(bad)), self.problems(bad))
        self.assertTrue(any('duplicate' in p for p in self.problems(entry(), entry())))
        self.assertTrue(any('same runner' in p for p in self.problems(entry(), entry(id='e2', runner='mp', after='e1'))))

    def test_filters_and_chains(self):
        entries = [entry(id='late', tier='long'), entry(id='a', tier='issue', areas=['melee']),
                   entry(id='b', tier='issue', after='a', kind='evidence'), entry(id='c')]
        self.assertEqual(['a', 'b'], [e['id'] for e in campaign.select(entries, areas=['melee', 'hud'])
                                      + campaign.select(entries, kinds=['evidence'])])
        self.assertEqual([['c'], ['a', 'b'], ['late']], [[e['id'] for e in u] for u in campaign.units(entries)])


class CommandTest(unittest.TestCase):
    def test_solo_command_on_a_lane(self):
        command = campaign.build_command(
            entry(weapons=['9mm', 'ar15'], vars={'perk': 'KFPerk_Support'}, matrix={'var.start': ['empty', 'partial']},
                  extra=['--families', 'pump']),
            candidate='C:/r', output='C:/out/e1', lane='a', wait=60, python='py', root=Path('R'))
        self.assertEqual(command, ['py', str(Path('R/tools/replay/scripted.py')), '--script', str(Path('R/s/a.kfs')),
                                   '--candidate', 'C:/r', '--output', 'C:/out/e1', '--wait', '60', '--fixture', 'a',
                                   '--weapons', '9mm,ar15', '--var', 'perk=KFPerk_Support',
                                   '--matrix', 'var.start=empty,partial', '--families', 'pump'])

    def test_mp_command_on_the_shared_install(self):
        command = campaign.build_command(entry(runner='mp', clients=2, zeds=True), candidate='c', output='o', python='py')
        self.assertTrue(command[1].endswith('scripted_mp.py'))
        self.assertNotIn('--fixture', command)
        self.assertEqual(command[-3:], ['--clients', '2', '--zeds'])

    def test_case_count_and_timeout(self):
        self.assertEqual(12, campaign.case_count(entry(weapons=['a', 'b'], matrix={'x': ['1', '2', '3'], 'y': ['1', '2']})))
        self.assertEqual(2*campaign.ALL_WEAPONS, campaign.case_count(entry(weapons=['all'], matrix={'var.s': ['e', 'p']})))
        self.assertEqual(3, campaign.case_count(entry(extra=['--loops', '3'])))
        self.assertEqual(77, campaign.child_timeout(entry(timeout=77), 90, 3600))
        self.assertGreater(campaign.child_timeout(entry(weapons=['a', 'b']), 90, 3600), 3600 + 2*90)


class ResultsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)/'campaign'

    def tearDown(self):
        self.temp.cleanup()

    def test_solo_and_mp_rows_become_cases_with_relative_links(self):
        out = self.root/'e1'
        session = out/'session1'
        (session/'captures').mkdir(parents=True)
        (session/'captures/index.html').write_text('x')
        (out/'batch.json').write_text(json.dumps([
            dict(loop=1, weapon='9mm', settings='preset-advanced', passed=True, ended='end', errors=[], failed=[],
                 captures=3, summary=str(session/'summary.md')),
            dict(n=2, weapon=None, settings='', passed=False, ended='runner-error', failed=[], errors=['boom'],
                 captures=0, client=0, summary=str(out))]))
        cases = campaign.read_cases(out, self.root)
        self.assertEqual(cases[0]['summary'], 'e1/session1/summary.md')
        self.assertEqual(cases[0]['captures_index'], 'e1/session1/captures/index.html')
        self.assertEqual(cases[1]['summary'], 'e1/batch.md')
        self.assertIsNone(cases[1]['captures_index'])
        self.assertEqual(campaign.first_failure(cases[1]), 'boom')

    def test_bmps_with_a_png_go_and_others_stay(self):
        captures = self.root/'e1/session1/captures'
        (captures/'originals').mkdir(parents=True)
        for path, data in (('originals/a.bmp', b'b' * 10), ('a.png', b'p'), ('originals/b.bmp', b'b'),
                           ('c.bmp', b'b'), ('c.png', b'p')):
            (captures/path).write_bytes(data)
        self.assertEqual((2, 11), campaign.prune_bmps(self.root/'e1', self.root))
        self.assertFalse((captures/'originals/a.bmp').exists())
        self.assertTrue((captures/'originals/b.bmp').exists())
        self.assertFalse((captures/'c.bmp').exists())
        self.assertEqual((0, 0), campaign.prune_bmps(self.root, self.root))           # never the campaign root
        self.assertEqual((0, 0), campaign.prune_bmps(self.root.parent, self.root))    # never outside it

    def test_resume_keeps_finished_unchanged_entries(self):
        a, b, c = entry(id='a'), entry(id='b'), entry(id='c', skip='why')
        done = dict(campaign.new_record(a), status='done', cases=[dict(passed=True)])
        stale = dict(campaign.new_record(b), status='timeout')
        gone = dict(campaign.new_record(entry(id='old')), status='running')
        records = campaign.merge_resume({'entries': [done, stale, gone]}, [a, dict(b, weapons=['9mm']), c])
        self.assertEqual([('a', 'done'), ('b', 'pending'), ('old', 'interrupted'), ('c', 'skipped')],
                         [(r['id'], r['status']) for r in records])
        changed = campaign.merge_resume({'entries': [done]}, [dict(a, weapons=['ar15'])])
        self.assertEqual('pending', changed[0]['status'])

    def test_totals_exit_status_and_report(self):
        ok = dict(campaign.new_record(entry(id='ok', kind='visual')), status='done', output='ok',
                  cases=[dict(weapon='KFGameContent.KFWeap_Pistol_9mm', settings='', passed=True, ended='end', failed=[],
                              errors=[], captures=2, summary='ok/summary.md', captures_index='ok/captures/index.html')])
        bad = dict(campaign.new_record(entry(id='bad', areas=['reload', 'melee'])), status='done', output='bad',
                   cases=[dict(weapon='ar15', settings='preset-classic', passed=False, ended='end', errors=[],
                               failed=['reload-hints.kfs:30 expect R.ammo=0 (want > 0)'], captures=0,
                               summary='bad/summary.md', captures_index=None)])
        skipped = campaign.new_record(entry(id='skip', skip='needs a user config'))
        self.assertFalse(campaign.failed([ok, skipped]))
        self.assertTrue(campaign.failed([ok, bad]))
        self.assertTrue(campaign.failed([ok, campaign.new_record(entry(id='p'))]))   # never ran
        totals = campaign.summarize([ok, bad, skipped])
        self.assertEqual((2, 1, 1), (totals['cases'], totals['passed'], totals['failed']))
        text = campaign.report(dict(name='c', manifest='m', candidate='r', lanes=['a'], mp_lane=None,
                                    started_utc='t0', updated_utc='t1', entries=[ok, bad, skipped]))
        self.assertIn('ar15 preset-classic: reload-hints.kfs:30 expect R.ammo=0 (want > 0)', text)
        self.assertIn('[captures](ok/captures/index.html)', text)
        self.assertIn('## Frames to review', text)
        self.assertIn('- skip (s/a.kfs): needs a user config', text)
        self.assertEqual(2, text.count('| bad |'))   # listed under both of its areas


if __name__ == '__main__':
    unittest.main()
