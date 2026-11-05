"""Session merge and per-case log split for scripted replays (python -m unittest tools/replay/scripted_test.py)."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kfs
import scripted


def compiled(text):
    return kfs.Compiler().compile_text(text, 'case.kfs')


class SessionTest(unittest.TestCase):
    def test_merge_offsets_lines_and_carries_settings(self):
        a, b = compiled('set bLoseReloadAmmo=True\nwait 1s\nend'), compiled('set bLoseReloadAmmo=True\nwait 2s\nend')
        merged = scripted.merge_cases([(1, 'w1', 'x', a), (2, 'w2', '', b)])
        self.assertEqual(merged.ops[0], '1|case|n=1|weapon=w1|label=x|timeout=600|stall=25')
        self.assertEqual(merged.settings, {'bLoseReloadAmmo': 'True'})
        with self.assertRaises(ValueError):
            scripted.merge_cases([(1, 'w1', '', a), (2, 'w2', '', compiled('wait 1s'))])
        self.assertEqual(merged.where(int(merged.ops[1].split('|')[0])), 'case.kfs:2')
        second = next(op for op in merged.ops if '|case|n=2' in op)
        self.assertEqual(merged.where(int(second.split('|')[0])), 'case 2 w2 -')
        self.assertEqual(merged.where(int(merged.ops[-1].split('|')[0])), 'case.kfs:3')

    def test_loop_targets_shift_with_their_case(self):
        a = compiled('repeat until R.ammo == 0 max 3 {\n wait 1s\n}\nend')
        merged = scripted.merge_cases([(1, 'w1', '', a), (2, 'w2', '', a)])
        loops = [(i, op) for i, op in enumerate(merged.ops) if '|loop|' in op]
        for index, op in loops:
            target = int(op.split('|to=')[1].split('|')[0])
            self.assertTrue(merged.ops[target].split('|')[1] == 'wait' and target < index)
            self.assertNotIn('|case|', ''.join(merged.ops[target:index]))

    def test_case_split_and_pending(self):
        a = compiled('wait 1s\nexpect R.ammo == 0\nend')
        cases = [(1, 'w1', '', a), (2, 'w2', '', a), (3, 'w3', '', a)]
        merged = scripted.merge_cases(cases)
        log = '\n'.join([
            'KF2VR_SCRIPT case n=1 label=- weapon=w1',
            'KF2VR_SCRIPT line=3 t=1 check=expect probe=R.ammo value=0 op=== expected=0 passed=true',
            'KF2VR_SCRIPT case-end n=1 label=- reason=end passed=true checks=1 failures=0',
            'KF2VR_SCRIPT case n=2 label=- weapon=w2',
            'KF2VR_SCRIPT line=8 t=2 check=expect probe=R.ammo value=3 op=== expected=0 passed=false'])
        rows, pending = scripted.case_results(log, cases, {n: c for n, _, _, c in cases}, merged, 'fatal-log-line')
        self.assertEqual([(r['n'], r['passed'], r['ended']) for r in rows],
                         [(1, True, 'end'), (2, False, 'launch-fatal-log-line')])
        self.assertEqual(pending, [3])
        self.assertIn('R.ammo=3', rows[1]['failed'][0])


    def test_dirty_slate_fails_the_case_that_left_it(self):
        a = compiled('wait 1s\nend')
        cases = [(1, 'w1', '', a), (2, 'w2', '', a)]
        log = '\n'.join([
            'KF2VR_SCRIPT case n=1 label=- weapon=w1',
            'KF2VR_SCRIPT case-end n=1 label=- reason=end passed=true checks=0 failures=0',
            'KF2VR_SCRIPT case-dirty after=1 before=2 left=,active-reload,carried-ammo'])
        rows, pending = scripted.case_results(log, cases, {n: c for n, _, _, c in cases},
                                              scripted.merge_cases(cases), 'exited')
        self.assertFalse(rows[0]['passed'])
        self.assertIn('active-reload', rows[0]['failed'][0])
        self.assertEqual(pending, [2])


if __name__ == '__main__':
    unittest.main()


class ObserverCompileWaitTest(unittest.TestCase):
    def test_waits_through_a_running_game_and_a_busy_fixture(self):
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'Observer'
            replies = iter(['Existing game/editor/server; deferred.', 'Development fixture is busy.', None])
            def attempt(packages, out):
                text = next(replies)
                if text is None:
                    return 'package'
                (out.parent/'observer-compile.log').write_text(text, encoding='utf-8')
                raise RuntimeError('Observer compile failed')
            with mock.patch.object(scripted, '_compile_observer', attempt), mock.patch.object(scripted.time, 'sleep'):
                self.assertEqual('package', scripted.compile_observer(Path('pk'), output, 600))

    def test_a_real_compile_error_fails_at_once(self):
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'Observer'
            def attempt(packages, out):
                (out.parent/'observer-compile.log').write_text('Error, Bad expression', encoding='utf-8')
                raise RuntimeError('Observer compile failed')
            with mock.patch.object(scripted, '_compile_observer', attempt), mock.patch.object(scripted.time, 'sleep'):
                with self.assertRaises(RuntimeError):
                    scripted.compile_observer(Path('pk'), output, 600)


class PruneTest(unittest.TestCase):
    def test_bulky_copies_go_and_logs_stay(self):
        import json, tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path in ('Observer/Script/KF2VRHands.upk', 'session1/Packages/KF2VR.u', 'session1/driver/game.log',
                         'session1/summary.md', 'SharedNativeBackup/dinput8.dll', 'slot1/session1/ReplayNativeBackup/x.dll'):
                (root/path).parent.mkdir(parents=True, exist_ok=True); (root/path).write_text('x')
            (root/'SharedNativeBackup/deployment.json').write_text(json.dumps({'files': {'dinput8.dll': {'restored': True}}}))
            (root/'slot1/session1/ReplayNativeBackup/deployment.json').write_text(json.dumps({'files': {'x.dll': {'restored': False}}}))
            scripted.prune_run(root)
            self.assertFalse((root/'Observer/Script').exists())
            self.assertFalse((root/'session1/Packages').exists())
            self.assertFalse((root/'SharedNativeBackup').exists())
            self.assertTrue((root/'slot1/session1/ReplayNativeBackup').exists())   # not restored: kept
            self.assertTrue((root/'session1/driver/game.log').exists())
            self.assertTrue((root/'session1/summary.md').exists())
