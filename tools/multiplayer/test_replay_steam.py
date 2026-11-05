"""Steam process prerequisites for the isolated replay launcher."""
from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

REPLAY = Path(__file__).resolve().parents[1] / 'replay'
sys.path.insert(0, str(REPLAY))
spec = importlib.util.spec_from_file_location('steam_replay_runner_test', REPLAY / 'run.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SteamPrerequisiteTests(unittest.TestCase):
    def check(self, processes=None, session=1, active_pid=42, dll='client.dll', exists=True):
        return runner.validate_steam_prerequisite(
            [{'pid': 42, 'session_id': 1}] if processes is None else processes,
            session, active_pid, dll, dll_exists=lambda _: exists)

    def test_live_matching_same_session_does_not_claim_authentication(self):
        self.assertEqual(dict(process_ready=True, authentication_verified=False, stale_active_process=False), self.check())

    def test_missing_steam_or_other_session_is_actionable(self):
        for processes in ([], [{'pid': 42, 'session_id': 2}]):
            with self.subTest(processes=processes):
                with self.assertRaisesRegex(RuntimeError, 'not running in this Windows session.*open Steam'):
                    self.check(processes=processes)

    def test_stale_active_process_with_one_live_client_is_accepted(self):
        for active_pid in (None, 99, '42'):
            with self.subTest(active_pid=active_pid):
                self.assertTrue(self.check(active_pid=active_pid)['stale_active_process'])

    def test_stale_active_process_with_several_clients_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'ActiveProcess does not match'):
            self.check(processes=[{'pid': 42, 'session_id': 1}, {'pid': 43, 'session_id': 1}], active_pid=99)

    def test_active_process_from_other_session_cannot_match(self):
        with self.assertRaisesRegex(RuntimeError, 'ActiveProcess does not match'):
            self.check(processes=[{'pid': 42, 'session_id': 2}, {'pid': 43, 'session_id': 1}])

    def test_missing_client_dll_is_rejected(self):
        for dll, exists in ((None, True), ('', True), ('missing.dll', False)):
            with self.subTest(dll=dll, exists=exists):
                with self.assertRaisesRegex(RuntimeError, 'no existing SteamClientDll64'):
                    self.check(dll=dll, exists=exists)

    def test_client_dll_is_checked_as_a_file(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(RuntimeError, 'no existing SteamClientDll64'):
                runner.validate_steam_prerequisite([{'pid': 42, 'session_id': 1}], 1, 42, str(root))
            dll = root / 'client.dll'
            dll.write_bytes(b'fixture')
            self.assertTrue(runner.validate_steam_prerequisite(
                [{'pid': 42, 'session_id': 1}], 1, 42, str(dll))['process_ready'])

    def test_tasklist_csv_reads_only_steam_and_numeric_session_fields(self):
        text = ('"steam.exe","42","Console","1","135,000 K"\n'
                '"steamwebhelper.exe","43","Console","1","100 K"\n'
                '"STEAM.EXE","44","RDP-Tcp#1","2","100 K"\n')
        self.assertEqual([{'pid': 42, 'session_id': 1}, {'pid': 44, 'session_id': 2}],
                         runner.parse_steam_processes(text))
        self.assertEqual([], runner.parse_steam_processes('INFO: No matching tasks are running.'))
        with self.assertRaisesRegex(RuntimeError, 'Could not read'):
            runner.parse_steam_processes('"steam.exe","bad","Console","1","100 K"')

    def test_plan_does_not_require_steam(self):
        with patch.object(sys, 'argv', ['run.py', '--batch', '--plan']), \
                patch.object(runner, 'steam_preflight') as check, redirect_stdout(io.StringIO()):
            runner.batch_main()
        check.assert_not_called()

    def test_failed_runtime_preflight_stops_batch_as_startup_failure(self):
        receipt = dict(preflight_error='Steam is not running in this Windows session',
                       startup_diagnostics=dict(phase='steam-prerequisite-unavailable'))
        result = runner.runtime_job_result(receipt, 1, False, '')
        self.assertEqual('FAILED-STARTUP', result['status'])
        self.assertIn(receipt['preflight_error'], result['errors'])
        self.assertEqual('steam-prerequisite-unavailable', result['startup_phase'])

    def test_game_log_notices_remain_visible_without_inventing_a_failure(self):
        receipt = dict(observer_complete=True, exit_code=0,
                       geometry_observations=dict(geometry_rows=13, callback_rows=18))
        log = ('[0001.00] Error: GSA config unavailable\r\n'
               '[0002.00] Warning: Missing font\r\n'
               '[0003.00] Warning: Missing font\r\n')
        result = runner.runtime_job_result(receipt, 0, True, log)
        self.assertEqual('OBSERVED-BOUNDED', result['status'])
        self.assertEqual([], result['errors'])
        self.assertEqual([dict(message='GSA config unavailable', count=1),
                          dict(message='Missing font', count=2)], result['log_notices'])
        self.assertEqual((13, 18), (result['geometry_rows'], result['callback_rows']))


if __name__ == '__main__':
    unittest.main()
