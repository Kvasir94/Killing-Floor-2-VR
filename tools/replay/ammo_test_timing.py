"""Replay launcher deadline behavior; no sleeps or game simulation."""
import unittest
from ammo_timing import readiness_seen, startup_budget, startup_milestones, timeout_phase


class StartupDeadlineTests(unittest.TestCase):
    def test_log_milestones_distinguish_world_load_from_ready(self):
        log = ('[0010.00] ScriptLog: KF2VR_DEMO phase=waiting\n'
               '[0114.60] Log: Bringing World KF-OUTPOST up for play\n'
               '[0128.00] ScriptLog: KF2VR_DEMO phase=playable\n'
               '[0129.00] ScriptLog: KF2VR_AMMO_SETUP action=close-startup-shell\n'
               '[0131.00] ScriptLog: KF2VR_RELOAD_OBSERVER phase=ready case=normal\n'
               '[0132.00] ScriptLog: KF2VR_RELOAD_OBSERVER phase=ready case=normal\n')
        self.assertEqual(dict(world_loaded=114.6,engine_playable=128,
                              initial_shell_closed=129,reload_ready=131),startup_milestones(log))
        self.assertFalse(readiness_seen(log.split('[0131.00]')[0],'normal'))

    def test_engine_playable_or_wrong_case_cannot_release_readiness(self):
        for log in ('phase=playable','KF2VR_RELOAD_OBSERVER phase=setup case=normal',
                    'KF2VR_RELOAD_OBSERVER phase=ready case=dual',
                    'KF2VR_RELOAD_OBSERVER phase=ready case=normal-extra'):
            self.assertFalse(readiness_seen(log,'normal'))
        self.assertTrue(readiness_seen('[123] ScriptLog: KF2VR_RELOAD_OBSERVER phase=ready case=normal preset=Advanced','normal'))

    def test_cold_load_has_bounded_readiness_allowance(self):
        budget = startup_budget(360, reload_case=True)
        self.assertEqual(240,budget)
        self.assertIsNone(timeout_phase(114.6,360,budget,False))
        self.assertIsNone(timeout_phase(180,360,budget,False))
        self.assertEqual('startup',timeout_phase(240,360,budget,False))

    def test_readiness_keeps_session_bounded(self):
        self.assertIsNone(timeout_phase(250,360,240,True))
        self.assertEqual('session',timeout_phase(360,360,240,True))
        self.assertEqual('startup',timeout_phase(360,360,240,False))

    def test_explicit_limits_and_legacy_budget(self):
        self.assertEqual(120,startup_budget(360))
        self.assertEqual(180,startup_budget(180,reload_case=True))
        self.assertEqual(300,startup_budget(360,300,reload_case=True))
        for total, requested in ((29,None),(601,None),(360,0),(360,601)):
            with self.subTest(total=total,requested=requested):
                with self.assertRaises(ValueError):startup_budget(total,requested,reload_case=True)


if __name__ == '__main__':
    unittest.main()
