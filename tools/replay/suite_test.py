"""Suite config/selection and adversarial log parsing; no gameplay simulation."""
from pathlib import Path
import tempfile
import unittest

from ammo_test_analyze import good
from ammo_test_payload import payload
from reload_test_trace import geometry_log
from run import plan_batch
from session import read_ini
from suite import analyze_suite, configure_suite, group_cases


def hold_log(weapon='KFWeap_Pistol_9mm'):
    return good().replace('weaponClass=9mm', 'weaponClass='+weapon)+'\n'+payload(seq=3)


def transcript(cases, logs):
    lines = ['KF2VR_INPUT_ISOLATION phase=installed']
    for i, (case, log) in enumerate(zip(cases, logs), 1):
        lines += [f'KF2VR_REPLAY_SUITE phase=begin index={i} weapon={case["weapon"]} mode={case["case"]} '
                  f'tests={"geometry" if case["geometry_input"] else "hold"}', log,
                  f'KF2VR_REPLAY_SUITE phase=end index={i} passed=True reason=completed']
    lines.append(f'KF2VR_REPLAY_SUITE phase=complete count={len(cases)} passed=True')
    native = '\n'.join(['ReplayInputIsolationProbe passed=1']+
                       [f'ReplayInputCase index={i+1} accepted=1' for i in range(len(cases))])
    return '\n'.join(lines), native


class SuiteTests(unittest.TestCase):
    def test_four_weapons_and_geometry_share_one_launch(self):
        jobs = plan_batch(['9mm,deagle,ar15,thompson'], ['hold', 'geometry'], ['normal', 'dual'])
        groups = group_cases(jobs)
        self.assertEqual(1, len(groups))
        self.assertEqual(5, len(groups[0]))
        self.assertTrue(jobs[groups[0][-1]]['geometry_input'])
        self.assertEqual(7, sum(j['status'] == 'SKIPPED-UNSUPPORTED' for j in jobs))

    def test_case_config_is_isolated_and_lists_ordered_modules(self):
        jobs = plan_batch(['9mm,deagle'], ['hold'], ['normal'])
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); path=root/'KFGame.ini'
            path.write_text('[Other]\nKeep=True\n', encoding='utf-16')
            configure_suite(root, jobs)
            text = read_ini(path)
            self.assertIn('Cases=9mm|normal|hold|', text)
            self.assertIn('Cases=deagle|normal|hold|', text)
            self.assertIn('CaseTimeoutSeconds=140', text)
            self.assertIn('Keep=True', text)

    def test_each_real_case_has_its_own_parser_and_class_identity(self):
        cases = plan_batch(['9mm,deagle'], ['hold'], ['normal'])
        text, native = transcript(cases, [hold_log(), hold_log('KFWeap_Pistol_Deagle')])
        result = analyze_suite(text, native, cases)
        self.assertTrue(result['passed'], result)
        self.assertEqual(2, result['completed_cases'])
        self.assertFalse(result['full_reload_accepted'])
        self.assertFalse(result['multiplayer_accepted'])
        self.assertFalse(analyze_suite(text.replace('weaponClass=KFWeap_Pistol_Deagle',
                            'weaponClass=KFWeap_Pistol_9mm'), native, cases)['passed'])

    def test_geometry_and_hold_use_independent_observation_contracts(self):
        jobs = plan_batch(['9mm'], ['hold', 'geometry'], ['normal', 'dual'])
        cases = [jobs[i] for i in group_cases(jobs)[0]]
        text, native = transcript(cases, [hold_log(), geometry_log()])
        result = analyze_suite(text, native, cases)
        self.assertTrue(result['passed'], result)
        self.assertEqual(['PASS-BOUNDED-HOLD', 'OBSERVED-BOUNDED'], [r['status'] for r in result['cases']])

    def test_option_profiles_batch_distinct_guns_without_reusing_paid_actors(self):
        jobs = plan_batch(['9mm,deagle'], ['magazine-hip'], ['normal'],
                          keep_chamber='both', lose_ammo='both')
        groups = group_cases(jobs)
        self.assertEqual([2, 2, 2, 2], [len(g) for g in groups])
        self.assertEqual(8, len({j['lifecycle_case'] for j in jobs}))
        for group in groups:
            self.assertEqual(2, len({jobs[i]['weapon'] for i in group}))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'KFGame.ini'; path.write_text('', encoding='utf-16')
            configure_suite(directory, [jobs[i] for i in groups[-1]])
            self.assertIn('|magazine-hip|9mm_normal_k0l0r1|0|0|1', read_ini(path))
        unsupported = plan_batch(['9mm'], ['magazine-hip'], ['normal'], recover_mags='off')
        self.assertEqual('SKIPPED-UNSUPPORTED', unsupported[0]['status'])

    def test_missing_duplicate_misordered_and_stuck_cases_cannot_pass(self):
        cases = plan_batch(['9mm,deagle'], ['hold'], ['normal'])
        text, native = transcript(cases, [hold_log(), hold_log('KFWeap_Pistol_Deagle')])
        variants = [text.replace('phase=end index=1', 'phase=end index=2'),
                    text.replace('phase=begin index=2', 'phase=begin index=1'),
                    text.replace('count=2', 'count=1'),
                    text.replace('phase=complete', 'phase=unknown'),
                    text.replace('passed=True reason=completed', 'passed=False reason=reload-stuck', 1),
                    text+'\nKF2VR_REPLAY_SUITE phase=complete count=2 passed=True',
                    text+'\nKF2VR_REPLAY_SUITE phase=watchdog index=2 reason=reload-stuck stage=await-removal',
                    text+'\nScriptWarning: Accessed None',
                    text.replace(hold_log(), '')]
        for broken in variants:
            with self.subTest(broken=broken[-100:]):
                self.assertFalse(analyze_suite(broken, native, cases)['passed'])
        for broken in (native.replace('index=2', 'index=3'), native.replace('accepted=1', 'accepted=0'),
                       native+'\nReplayInputCase index=2 accepted=1', ''):
            self.assertFalse(analyze_suite(text, broken, cases)['passed'])


if __name__ == '__main__':
    unittest.main()
