"""Network replay selection, launch routing and strict session-receipt handling."""
import importlib.util
from contextlib import nullcontext
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

REPLAY = Path(__file__).resolve().parents[1]/'replay'
sys.path.insert(0, str(REPLAY))
spec = importlib.util.spec_from_file_location('replay_network_suite_test', REPLAY/'network_suite.py')
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)


class NetworkSuiteTests(unittest.TestCase):
    def test_fixed_smoke_runs_both_families_once(self):
        jobs = suite.plan_network(['9mm', '1858'], ['replication'])
        self.assertEqual(1, len(jobs))
        self.assertEqual('PLANNED', jobs[0]['status'])
        self.assertEqual(['1858', '9mm'], jobs[0]['actual_weapons'])

    def test_fixed_smoke_does_not_silently_expand_a_subset(self):
        for weapons in (['9mm'], ['1858']):
            with self.subTest(weapons=weapons):
                jobs = suite.plan_network(weapons, ['replication'])
                self.assertEqual(['SKIPPED-UNSUPPORTED'], [j['status'] for j in jobs])
                self.assertEqual(weapons, jobs[0]['actual_weapons'])
                self.assertIn('select both', jobs[0]['reason'])

    def test_physical_reload_supports_only_existing_9mm_route(self):
        jobs = suite.plan_network(['9mm', 'deagle'], ['network-reload'])
        self.assertEqual(['PLANNED', 'SKIPPED-UNSUPPORTED'], [j['status'] for j in jobs])
        self.assertEqual([['9mm'], ['deagle']], [j['actual_weapons'] for j in jobs])

    def test_aliases_deduplicate_and_unsupported_weapons_stay_visible(self):
        jobs = suite.plan_network(['9mm,1858,bow'], ['all', 'network-smoke', 'physical-reload'])
        self.assertEqual(4, len(jobs))
        self.assertEqual(2, sum(j['status'] == 'PLANNED' for j in jobs))
        self.assertEqual(['bow'], jobs[1]['actual_weapons'])
        self.assertEqual(['1858', 'bow'], jobs[3]['actual_weapons'])
        with self.assertRaises(ValueError):
            suite.plan_network(['9mm'], ['invented-test'])

    def test_commands_use_workspace_runner_unselected_release_and_lan(self):
        candidate = Path('candidate')
        jobs = [j for j in suite.plan_network(['9mm', '1858'], ['all']) if j['status'] == 'PLANNED']
        for job in jobs:
            command = suite.network_command(candidate, job, Path('output'), Path('game'), Path('server'), Path('user'))
            self.assertEqual(str(suite.ROOT/'tools/multiplayer/session.py'), command[1])
            self.assertEqual('candidate', command[command.index('--release')+1])
            self.assertIn('--lan-no-voice', command)
            self.assertNotIn('--online-server', command)
            self.assertNotIn('--run', command)
            command = suite.network_command(candidate, job, Path('output'), Path('game'), Path('server'), Path('user'), True)
            self.assertEqual('--run', command[-1])
        smoke = suite.network_command(candidate, jobs[0], Path('output'), Path('game'), Path('server'), Path('user'))
        self.assertIn('--paired-weapons', smoke)
        self.assertEqual('1', smoke[smoke.index('--clients')+1])
        physical = suite.network_command(candidate, jobs[1], Path('output'), Path('game'), Path('server'), Path('user'))
        self.assertIn('--physical-reload-9mm', physical)
        self.assertNotIn('--paired-weapons', physical)

    def receipt(self, job):
        key = 'paired_smoke' if job['route'] == 'paired-weapons' else 'physical_reload_9mm'
        return dict(release='candidate', release_manifest_sha256='HASH', runtime_pass=True,
                    user_config_preserved=True, cleanup_errors=[], finished_utc='finished',
                    input_isolation_pass=True, native_replay_pass=True, roles=[dict(pid=123)],
                    **{key: dict(passed=True)})

    def test_completed_matching_receipt_is_bounded_only(self):
        for job in (j for j in suite.plan_network(['9mm', '1858'], ['all']) if j['status'] == 'PLANNED'):
            result = suite.network_result(self.receipt(job), job, 'candidate', 'HASH', 0, True, [''])
            self.assertEqual('PASS-BOUNDED-NETWORK', result['status'])
            self.assertFalse(result['headset_accepted'])
            self.assertFalse(result['remote_network_accepted'])

    def test_failed_missing_or_wrong_receipts_never_pass(self):
        job = suite.plan_network(['9mm'], ['network-reload'])[0]
        receipt = self.receipt(job)
        for key, value in (('release', 'other'), ('release_manifest_sha256', 'other'),
                           ('runtime_pass', False), ('user_config_preserved', False),
                           ('cleanup_errors', ['files retained']), ('finished_utc', ''),
                           ('input_isolation_pass', False), ('native_replay_pass', False),
                           ('physical_reload_9mm', dict(passed=False))):
            with self.subTest(key=key):
                bad = dict(receipt, **{key: value})
                result = suite.network_result(bad, job, 'candidate', 'HASH', 0, True, [''])
                self.assertEqual('FAILED', result['status'])
                self.assertTrue(result['errors'])
        for text in ('ScriptWarning: Accessed None', 'ScriptError: failure', 'Critical: error', 'Fatal error: crash'):
            with self.subTest(text=text):
                self.assertEqual('FAILED', suite.network_result(receipt, job, 'candidate', 'HASH', 0, True, [text])['status'])
        self.assertEqual('FAILED', suite.network_result(receipt, job, 'candidate', 'HASH', 1, True, [''])['status'])

    def test_prepared_receipt_never_claims_runtime(self):
        job = suite.plan_network(['9mm'], ['network-reload'])[0]
        receipt = dict(release='candidate', release_manifest_sha256='HASH', status='prepared')
        result = suite.network_result(receipt, job, 'candidate', 'HASH', 0, False, [''])
        self.assertEqual('PREPARED', result['status'])
        self.assertEqual([], result['pids'])

    def execute_mock(self, *, run, fail_cleanup=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = root/'build/multiplayer/releases/candidate'
            candidate.mkdir(parents=True)
            (candidate/'release.json').write_text('{}')
            (candidate.parent.parent/'current-release.json').write_text('{"release":"rollback"}')
            manifest_hash = suite.digest(candidate/'release.json')
            jobs = suite.plan_network(['9mm', '1858'], ['all'])
            calls = []

            def fake_run(command, **kwargs):
                calls.append(command)
                destination = Path(command[command.index('--output-root')+1])/'session'
                destination.mkdir()
                job = next(j for j in jobs if j['route'] == (
                    'paired-weapons' if '--paired-weapons' in command else 'physical-reload-9mm'))
                receipt = (self.receipt(job) if run else dict(
                    release='candidate', status='prepared'))
                receipt['release_manifest_sha256'] = manifest_hash
                receipt['roles'] = []
                if fail_cleanup:
                    receipt['cleanup_errors'] = ['owned files retained']
                (destination/'run.json').write_text(json.dumps(receipt))
                from types import SimpleNamespace
                return SimpleNamespace(returncode=0)

            with patch.object(suite, 'ROOT', root), \
                    patch.object(suite, 'verify_release', return_value={}), \
                    patch.object(suite, 'verify_workspace'), patch.object(suite, 'verify_server'), \
                    patch.object(suite, 'config_hashes', return_value={}), \
                    patch.object(suite.subprocess, 'run', side_effect=fake_run), \
                    patch.object(suite, 'game_test_gate', return_value=nullcontext()) as gate, \
                    patch('run.steam_preflight', return_value=dict(process_ready=True)) as steam:
                result = suite.execute_network(candidate, jobs, root/'build/network',
                    game_root=root/'game', server_root=root/'server', user_config=root/'user', run=run)
            self.assertEqual(run, gate.called)
            self.assertEqual(run, steam.called)
            self.assertEqual('{"release":"rollback"}', (candidate.parent.parent/'current-release.json').read_text())
            self.assertTrue((root/'build/network/network.json').exists())
            return result, calls

    def test_prepare_adapter_uses_existing_routes_without_runtime_prerequisite(self):
        result, calls = self.execute_mock(run=False)
        self.assertEqual([], result['errors'])
        self.assertEqual(2, len(calls))
        self.assertFalse(result['runtime_invoked'])
        self.assertTrue(result['selection_preserved'])
        self.assertEqual(['PREPARED', 'PREPARED', 'SKIPPED-UNSUPPORTED'],
                         [j['status'] for j in result['jobs']])

    def test_adapter_stops_after_failed_cleanup_and_retains_receipt_paths(self):
        result, calls = self.execute_mock(run=True, fail_cleanup=True)
        self.assertEqual(1, len(calls))
        self.assertTrue(result['errors'])
        self.assertTrue(result['runtime_invoked'])
        self.assertEqual(['FAILED', 'NOT-RUN', 'SKIPPED-UNSUPPORTED'],
                         [j['status'] for j in result['jobs']])
        self.assertIn('receipt', result['jobs'][0]['logs'])


if __name__ == '__main__':
    unittest.main()
