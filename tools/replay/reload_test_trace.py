"""Observed-log analyzer and disposable config checks; no production substitutes."""
from pathlib import Path
import tempfile
import unittest

from ammo_prepare import configure_case
from reload_trace_analyze import analyze, analyze_geometry
from session import read_ini
from vr_config import values
import json
from reload_coverage import audit_runs
from run import plan_batch, stage_environment, runtime_job_result
from unittest.mock import patch
import os


def trace():
    return '\n'.join([
        'KF2VR_RELOAD_TRACE phase=input case=mosin-owed-grips seq=1 buttons=0 grips=0 triggers=0 valid=3',
        'KF2VR_RELOAD_TRACE phase=state case=mosin-owed-grips seq=2 weapon=World.Mosin pawn=World.Pawn world=World ownership=1 loaded=4 reserve=20',
        'KF2VR_RELOAD_TRACE phase=complete case=mosin-owed-grips seq=3 status=UNTESTED acceptance=False'])


class TraceLogTests(unittest.TestCase):
    def test_complete_collection_cannot_accept_reload(self):
        result = analyze(trace(), 'mosin-owed-grips')
        self.assertTrue(result['collection_complete'])
        self.assertFalse(result['passed'])
        self.assertFalse(result['full_reload_accepted'])
        self.assertEqual('UNTESTED', result['status'])

    def test_empty_duplicate_malformed_wrong_case_and_warning_fail_collection(self):
        for text in ('', trace()+trace(), trace().replace('seq=2', 'seq=9'),
                     trace().replace('ownership=1', 'ownership=NaN'),
                     trace().replace('seq=2', 'seq=2 seq=2'),
                     trace().replace('acceptance=False', 'acceptance=True'),
                     trace()+'\nScriptWarning: Accessed None'):
            with self.subTest(text=text):
                self.assertFalse(analyze(text, 'mosin-owed-grips')['collection_complete'])
        self.assertFalse(analyze(trace(), 'other')['collection_complete'])


def geometry_log():
    """Parser fixture only; these rows are never gameplay evidence."""
    rows = ['KF2VR_INPUT_ISOLATION phase=installed abort=F10 gamepad=authored',
            'KF2VR_RELOAD_GEOMETRY phase=initial case=dual-removal-backend-busy left=World.Left right=World.Right pawn=World.Pawn loadedLeft=15 loadedRight=15 reserve=90 loseAmmo=True authoredInput=True measuredHumanInput=False',
            'KF2VR_RELOAD_GEOMETRY phase=ledger case=dual-removal-backend-busy step=1 loaded=30 reserve=90 escrow=0 tokens=0 shots=0 mismatch=0']
    invocation = 0
    def callback(function, weapon, action, receipt, detail=''):
        nonlocal invocation
        invocation += 1
        for phase, offset in (('before', 1), ('after', 0)):
            rows.append(f'KF2VR_RELOAD_CALLBACK case=dual-removal-backend-busy seq={invocation*2-offset} '
                        f'call={invocation} phase={phase} function=KF2VR.{function} source=production '
                        f'weapon=World.{weapon} action={action} accepted={"Unknown" if phase == "before" else "True"} '
                        f'receipt={receipt} {detail}'.rstrip())
    callback('VRCylinderSession.BeginMagazine', 'Right', 'recover', 0, 'boundary=admission-wait hand=1')
    for hand, weapon, token in ((0, 'Left', 101), (1, 'Right', 102)):
        callback('VRMagazineAuthority.Remove', weapon, 'eject', token, 'actual=14 remaining=14')
        callback('VRMagazineAuthority.Read', weapon, 'recover', token, 'kind=0 actual=14 remaining=14')
    rows.append('KF2VR_RELOAD_GEOMETRY phase=ledger case=dual-removal-backend-busy step=4 loaded=2 reserve=90 escrow=28 tokens=2 shots=0 mismatch=0')
    for hand, weapon, receipt in ((0, 'Left', 201), (1, 'Right', 202)):
        callback('VRCylinderSession.Tick', weapon, 'recover', 0, f'boundary=seat-contact hand={hand} hip=True')
        callback('VRCylinderSession.Complete', weapon, 'reload', receipt, 'loaded=16')
    rows.extend([
        'KF2VR_RELOAD_GEOMETRY phase=ledger case=dual-removal-backend-busy step=5 loaded=32 reserve=60 escrow=28 tokens=2 shots=0 mismatch=0',
        'KF2VR_RELOAD_GEOMETRY phase=ledger case=dual-removal-backend-busy step=7 loaded=32 reserve=60 escrow=28 tokens=2 shots=0 mismatch=0',
        'KF2VR_RELOAD_GEOMETRY phase=complete case=dual-removal-backend-busy passed=True reason=authored-contact-path-completed busyObserved=True leftContact=True rightContact=True leftRemoval=101 rightRemoval=102 multiplayerAccepted=False headsetAccepted=False',
        trace().replace('mosin-owed-grips', 'dual-removal-backend-busy')])
    return '\n'.join(rows)


class GeometryLogTests(unittest.TestCase):
    def test_bounded_parser_outcome_never_claims_general_acceptance(self):
        result = analyze_geometry(geometry_log(), 'ReplayInputIsolationProbe passed=1', 'dual-removal-backend-busy')
        self.assertEqual([], result['errors'])
        self.assertTrue(result['bounded_case_passed'])
        self.assertFalse(result['headset_accepted'])
        self.assertFalse(result['multiplayer_accepted'])
        self.assertFalse(result['full_reload_accepted'])

    def test_missing_or_contradictory_observations_cannot_pass(self):
        original = geometry_log()
        samples = ['', original.replace('passed=True', 'passed=False'),
                   original.replace('busyObserved=True', 'busyObserved=False'),
                   original.replace('hip=True', 'hip=False'),
                   original.replace('actual=14', 'actual=13'),
                   original.replace('reserve=60', 'reserve=61'),
                   original.replace('seq=2 ', 'seq=99 '),
                   original.replace('leftRemoval=101', 'leftRemoval=102'),
                   original.replace('headsetAccepted=False', 'headsetAccepted=True'),
                   original.replace('phase=after', 'phase=before'),
                   original+'\nScriptWarning: Accessed None']
        for sample in samples:
            with self.subTest(sample=sample):
                self.assertFalse(analyze_geometry(sample, 'ReplayInputIsolationProbe passed=1',
                                                'dual-removal-backend-busy')['bounded_case_passed'])
        self.assertFalse(analyze_geometry(original, '', 'dual-removal-backend-busy')['bounded_case_passed'])

    def test_coverage_reanalyzes_geometry_logs_without_claiming_hold_or_full_acceptance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); run = root/'batch'/'case'; run.mkdir(parents=True)
            game = run/'game.log'; native = run/'native.log'
            game.write_text(geometry_log()); native.write_text('ReplayInputIsolationProbe passed=1')
            (run/'run.json').write_text(json.dumps(dict(reload_case='dual', geometry_input=True,
                lifecycle_case='dual-removal-backend-busy', environment={'KF2VR_LOG_PATH': str(native)})))
            (run/'input-replay-run.json').write_text(json.dumps(dict(arguments=['-ABSLOG='+str(game)],
                observer_complete=False)))
            row = audit_runs(root)[0]
            self.assertEqual('geometry', row['coverage_kind'])
            self.assertEqual('OBSERVED-BOUNDED', row['status'])
            self.assertTrue(row['bounded_case_passed'])
            self.assertFalse(row['reanalyzed_passed'])
            self.assertFalse(row['full_reload_accepted'])
            # A saved success flag cannot replace actual game observations.
            game.write_text('')
            row = audit_runs(root)[0]
            self.assertEqual('UNTESTED', row['status'])
            self.assertFalse(row['bounded_case_passed'])


class BatchSelectionTests(unittest.TestCase):
    def test_startup_crash_remains_unexercised_and_surfaces_exact_fatal_detail(self):
        receipt = dict(exit_code=0xc0000409, playable=False, observer_complete=False,
                       geometry_observations=dict(status='UNTESTED', errors=['No geometry samples']),
                       observations=dict(samples={'input': 0, 'state': 0}), cleanup_errors=[])
        result = runtime_job_result(receipt, 1, True,
            '[0069.68] Critical: appError called: Can\'t bind to native class Engine.AnimSet')
        self.assertEqual('FAILED-STARTUP', result['status'])
        self.assertIn('No geometry samples', result['errors'])
        self.assertTrue(any('Engine.AnimSet' in line for line in result['errors']))
        self.assertEqual(0, result['sample_counts']['input'])

    def test_successful_bounded_and_preflight_refusal_have_distinct_outcomes(self):
        success = dict(exit_code=0, observer_complete=True,
                       geometry_observations=dict(status='OBSERVED-BOUNDED', errors=[], callback_rows=18))
        result = runtime_job_result(success, 0, True, '')
        self.assertEqual('OBSERVED-BOUNDED', result['status'])
        self.assertEqual(18, result['callback_rows'])
        self.assertEqual('FAILED', runtime_job_result({}, 1, True, '')['status'])

    def test_f10_abort_is_not_success_even_if_the_process_exits_cleanly(self):
        receipt = dict(exit_code=0, observer_complete=False,
                       geometry_observations=dict(status='UNTESTED', errors=['No geometry samples']))
        result = runtime_job_result(receipt, 1, True, 'KF2VR_INPUT_ISOLATION phase=abort key=F10')
        self.assertEqual('ABORTED', result['status'])
        self.assertTrue(any('remaining batch cases must not launch' in e for e in result['errors']))

    def test_startup_timeout_and_unavailable_steam_are_actionable_failures(self):
        timeout = runtime_job_result(dict(timeout=True, timeout_phase='startup', playable=False), 1, True, '')
        self.assertEqual('FAILED-STARTUP', timeout['status'])
        steam = runtime_job_result(dict(exit_code=1, playable=False, startup_diagnostics=dict(
            steam_client_initialized=False, steam_required_error=True)), 1, True, '')
        self.assertEqual('FAILED-STARTUP', steam['status'])
        self.assertTrue(any('Steam Client API initialized 0' in e for e in steam['errors']))

    def test_windows_powershell_child_uses_its_own_builtin_modules(self):
        with patch.dict(os.environ, {'PSModulePath': 'example-pwsh7-modules', 'REPLAY_TEST_VALUE': 'keep'}):
            env = stage_environment(['powershell.exe', '-NoProfile'])
            self.assertFalse(any(k.upper() == 'PSMODULEPATH' for k in env))
            self.assertEqual('keep', env['REPLAY_TEST_VALUE'])
            python_env = {k.upper(): v for k, v in stage_environment(['python', 'run.py']).items()}
            self.assertEqual('example-pwsh7-modules', python_env['PSMODULEPATH'])
            self.assertEqual('example-pwsh7-modules', os.environ['PSModulePath'])

    def test_weapon_and_test_filters_select_only_existing_executable_routes(self):
        jobs = plan_batch(['9mm,deagle'], ['hold'], ['normal'])
        self.assertEqual([('9mm', 'normal', ['hold']), ('deagle', 'normal', ['hold'])],
                         [(j['weapon'], j['case'], j['tests']) for j in jobs])
        self.assertTrue(all(j['status'] == 'PLANNED' for j in jobs))

    def test_geometry_alias_combines_duplicate_input_sequences_into_one_case(self):
        jobs = plan_batch(['9mm', '9mm'], ['geometry'], ['normal', 'dual'])
        self.assertEqual(1, len(jobs))
        self.assertEqual(['tactical-hip', 'dual-contention'], jobs[0]['tests'])
        self.assertEqual('dual-removal-backend-busy', jobs[0]['lifecycle_case'])
        self.assertTrue(jobs[0]['geometry_input'])
        hip = plan_batch(['9mm'], ['tactical-hip'], ['dual'])[0]
        self.assertEqual('hip-tactical-at-capacity', hip['lifecycle_case'])

    def test_unsupported_families_and_modes_are_explicit_skips(self):
        jobs = plan_batch(['mosin', 'deagle'], ['hold', 'geometry'], ['normal', 'dual'])
        self.assertEqual(1, sum(j['status'] == 'PLANNED' for j in jobs))
        self.assertTrue(all(j['reason'] for j in jobs if j['status'] == 'SKIPPED-UNSUPPORTED'))
        self.assertEqual('SKIPPED-UNSUPPORTED', plan_batch(['9mm'], ['geometry'], ['normal'])[0]['status'])
        dual_hold = plan_batch(['9mm'], ['hold'], ['dual'])[0]
        self.assertEqual('SKIPPED-UNSUPPORTED', dual_hold['status'])
        self.assertIn('realistic top-up', dual_hold['reason'])

    def test_unknown_and_empty_selections_fail_before_launch(self):
        for weapons, tests, cases in ((['typo'], ['hold'], ['normal']),
                                      (['9mm'], ['unknown'], ['normal']),
                                      (['9mm'], ['hold'], ['bogus']), ([], ['hold'], ['normal'])):
            with self.subTest(weapons=weapons, tests=tests, cases=cases):
                with self.assertRaises(ValueError):
                    plan_batch(weapons, tests, cases)


class LifecycleConfigTests(unittest.TestCase):
    def test_paid_finish_case_selects_existing_helios_class(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('KFGame.ini', 'KFEngine.ini', 'KFSystemSettings.ini'):
                (root/name).write_text('[SystemSettings]\nResX=1\n', encoding='utf-16')
            configure_case(root, 'normal', 'helios', lifecycle_case='paid-finish-action-switch')
            observer = values(read_ini(root/'KFGame.ini'), 'KF2VRReplay.ReloadObserver')
            self.assertEqual('KFGameContent.KFWeap_AssaultRifle_Microwave', observer['SingleWeaponPath'])
            self.assertEqual('paid-finish-action-switch', observer['LifecycleCase'])
            self.assertEqual('True', observer['bTraceLifecycle'])

    def test_diagnostic_family_and_recovery_are_isolated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('KFGame.ini', 'KFEngine.ini', 'KFSystemSettings.ini'):
                (root/name).write_text('[SystemSettings]\nResX=1\n', encoding='utf-16')
            configure_case(root, 'normal', 'mosin', lifecycle_case='mosin-owed-grips')
            text = read_ini(root/'KFGame.ini')
            observer = values(text, 'KF2VRReplay.ReloadObserver')
            self.assertEqual('True', observer['bTraceLifecycle'])
            self.assertEqual('mosin-owed-grips', observer['LifecycleCase'])
            self.assertEqual('KFGameContent.KFWeap_Rifle_MosinNagant', observer['SingleWeaponPath'])
            self.assertEqual('False', values(text, 'KF2VR.VRHandsBridge')['bDisableGravityPull'])

    def test_geometry_input_is_explicit_and_confined_to_paired_hip_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('KFGame.ini', 'KFEngine.ini', 'KFSystemSettings.ini'):
                (root/name).write_text('[SystemSettings]\nResX=1\n', encoding='utf-16')
            configure_case(root, 'dual', '9mm', lifecycle_case='dual-removal-backend-busy', geometry_input=True)
            observer = values(read_ini(root/'KFGame.ini'), 'KF2VRReplay.ReloadObserver')
            self.assertEqual('True', observer['bGeometryInput'])
            self.assertEqual('True', observer['bTraceLifecycle'])
            viewport = values(read_ini(root/'KFEngine.ini'), 'KF2VRNetClient.KF2VRNetViewportClient')
            self.assertEqual('True', viewport['bDiagnosticInputIsolation'])

    def test_geometry_input_rejects_other_routes_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for case, weapon, scenario in (('normal', '9mm', 'dual-removal-backend-busy'),
                                          ('dual', 'deagle', 'dual-removal-backend-busy'),
                                          ('dual', '9mm', 'recovered-insert-receipt-after-cancel')):
                with self.subTest(case=case, weapon=weapon, scenario=scenario):
                    with self.assertRaisesRegex(ValueError, 'explicit paired 9mm'):
                        configure_case(root, case, weapon, lifecycle_case=scenario, geometry_input=True)
                    self.assertEqual([], list(root.iterdir()))

    def test_nonmagazine_requires_explicit_observation_before_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'observation-only'):
                configure_case(root, 'normal', 'mosin')
            self.assertEqual([], list(root.iterdir()))


if __name__ == '__main__':
    unittest.main()
