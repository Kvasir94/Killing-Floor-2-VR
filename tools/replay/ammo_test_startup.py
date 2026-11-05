"""Startup-log parser tests; text and counters are not game acceptance evidence."""
import unittest
from ammo_startup import StartupProgress, startup_state


class StartupDiagnosticTests(unittest.TestCase):
    def test_empty_initial_snapshot_is_not_log_progress(self):
        tracker = StartupProgress('normal')
        empty = tracker.observe(0, '', counters={'read_bytes':0})
        self.assertEqual('not-ready-awaiting-first-observation',empty['diagnosis'])
        self.assertIsNone(empty['log_quiet_seconds'])
        self.assertIsNone(empty['process_quiet_seconds'])
        progress = tracker.observe(1, '', counters={'read_bytes':4096})
        self.assertEqual('not-ready-process-activity-observed',progress['diagnosis'])
        self.assertFalse(progress['ready'])

    def test_cold_world_load_is_progress_but_never_ready(self):
        tracker = StartupProgress('normal')
        log = '[15.33] Log: Steam Client API initialized 1\n'
        tracker.observe(16, log, counters={'read_bytes':100})
        stalled = tracker.observe(200, log, counters={'read_bytes':100})
        self.assertEqual('not-ready-no-recent-observed-progress', stalled['diagnosis'])
        self.assertFalse(stalled['hang_proven'])
        activity = tracker.observe(220, log, counters={'read_bytes':200})
        self.assertEqual('not-ready-process-activity-observed', activity['diagnosis'])
        world = tracker.observe(227.08, log+'[227.08] Log: Bringing World KF-OUTPOST up for play\n')
        self.assertEqual('world-loaded', world['phase'])
        self.assertFalse(world['ready'])
        self.assertEqual(227.08, world['milestones_log_seconds']['world_loaded'])

    def test_steam_failure_is_explicit_and_not_an_ammo_failure(self):
        result = StartupProgress('normal').observe(16.24,
            '[16.20] Log: Steam Client API initialized 0\n'
            '[16.24] Log: STEAM is required to play the game.\n[16.24] Log: appRequestExit(1)\n')
        self.assertEqual('explicit-steam-client-failure', result['diagnosis'])
        self.assertFalse(result['ready'])
        self.assertFalse(result['hang_proven'])
        self.assertIsNone(result['process_counters'])

    def test_latest_steam_state_and_exact_case_readiness(self):
        text = ('Steam Client API initialized 0\nSteam Client API initialized 1\n'
                '[198.19] ScriptLog: KF2VR_DEMO phase=playable\n'
                '[199] KF2VR_RELOAD_OBSERVER phase=ready case=dual\n')
        normal = startup_state(text, 'normal')
        self.assertEqual('observer-setup', normal['phase'])
        self.assertTrue(normal['steam_client_initialized'])
        self.assertFalse(normal['ready'])
        self.assertEqual('observer-ready', startup_state(text, 'dual')['phase'])

    def test_unknown_activity_remains_unknown_and_diagnostics_do_not_expose_log(self):
        tracker = StartupProgress('normal')
        tracker.observe(1, 'private-ticket-content')
        result = tracker.observe(80, 'private-ticket-content')
        self.assertIsNone(result['process_quiet_seconds'])
        self.assertNotIn('private-ticket', str(result))
        self.assertEqual('not-ready-no-recent-observed-progress', result['diagnosis'])
        with self.assertRaises(ValueError): tracker.observe(-1, '')
        with self.assertRaises(ValueError): StartupProgress('other')


if __name__ == '__main__':
    unittest.main()
