import unittest
import json
import tempfile
from pathlib import Path
from breacher_acceptance import evidence, ON, OFF, prepare, digest, config_hashes, read_ini, child_launch


def log(enabled=True, bridge=False):
    cases = ON if enabled else OFF
    return '\n'.join([f'BREACHER_ACCEPT rev=1 phase=begin enabled={enabled} bridge={bridge}'] +
        [f'BREACHER_ACCEPT rev=1 phase=check index={i} name={case} passed=True' for i, case in enumerate(cases)] +
        [f'BREACHER_ACCEPT rev=1 phase=complete checks={len(cases)} passed=True'])


class AcceptanceParserTests(unittest.TestCase):
    def test_child_launch_reuses_ue3_quoting_and_clears_inherited_fixture_controls(self):
        role = {'exe': 'D:/Game Folder/KFGame.exe', 'native_adapter': False,
                'args': ['KF-BurningParis', '-ENGINEINI=D:/Run Folder/KFEngine.ini']}
        environment = {'PATH': 'unchanged', 'KF2VR_CAPTURE_ROOT': 'old',
                       'kf2vr_test_control': 'old', 'SteamAppId': 'wrong'}
        original = dict(environment)
        command, child = child_launch(role, environment)
        self.assertIn('-ENGINEINI="D:/Run Folder/KFEngine.ini"', command)
        self.assertFalse(any(key.upper().startswith('KF2VR_') for key in child))
        self.assertEqual(child['SteamAppId'], '232090')
        self.assertEqual(child['SteamGameId'], '232090')
        self.assertEqual(child['PATH'], 'unchanged')
        self.assertEqual(environment, original)

    def test_four_modes_are_distinct(self):
        for enabled in (True, False):
            for bridge in (True, False):
                self.assertTrue(evidence(log(enabled, bridge), enabled, bridge))
                self.assertFalse(evidence(log(enabled, bridge), not enabled, bridge))
                self.assertFalse(evidence(log(enabled, bridge), enabled, not bridge))

    def test_incomplete_duplicate_out_of_order_and_failure_rejected(self):
        good = log()
        rows = good.splitlines()
        for bad in ('\n'.join(rows[:-1]), good + '\n' + good,
                    '\n'.join(rows[:2] + [rows[3], rows[2]] + rows[4:]),
                    good.replace('passed=True', 'passed=False', 1),
                    good + '\nScriptWarning: Accessed None',
                    good.replace('name=perk_selected', 'name=timeout')):
            self.assertFalse(evidence(bad, True, False))

    def test_prepare_isolated_on_off_bridge_configs_without_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'script/KF2BreacherAcceptance/Classes/Fixture.uc'
            source.parent.mkdir(parents=True)
            source.write_text('fixture hash input')
            built = root / 'build/breacher-acceptance'
            built.mkdir(parents=True)
            package = built / 'KF2BreacherAcceptance.u'
            package.write_bytes(b'fixture compiled bytes')
            (built / 'build.json').write_text(json.dumps({'success': True,
                'sources_sha256': {'Classes/Fixture.uc': digest(source)}, 'package_sha256': digest(package)}))
            stage = root / 'build/breacher-content-stage'
            for folder in (stage / 'Packages', root / 'build/multiplayer/script'):
                folder.mkdir(parents=True)
                for name in ('KF2VR.u', 'KF2VRNet.u', 'KF2VRNetClient.u'):
                    (folder / name).write_bytes(b'core compiled bytes')
            optional = stage / 'optional/breacher'
            for name in ('KF2VRHands.upk', 'KF2VRPortal.upk'):
                (root / 'build/multiplayer/script' / name).write_bytes(b'owned asset bytes')
            (optional / 'Localization/INT').mkdir(parents=True)
            (optional / 'KF2Breacher.u').write_bytes(b'\xc1\x83\x2a\x9eoptional')
            (optional / 'manifest.json').write_text(json.dumps({'protocol': 1, 'sha256': digest(optional / 'KF2Breacher.u')}))
            (optional / 'Localization/INT/KF2Breacher.int').write_text('labels')
            user = root / 'user'
            user.mkdir()
            (user / 'KFEngine.ini').write_text('[Core.System]\nPaths=stock\nScriptPaths=stock\nSeekFreePCPaths=stock\nBrewedPCPaths=stock\n', encoding='utf-16')
            (user / 'KFGame.ini').write_text('[Engine.AccessControl]\n', encoding='utf-16')
            before = config_hashes(user)
            for enabled in (True, False):
                for bridge in (True, False):
                    role = prepare(root, root / 'game', user, root / f'run{enabled}{bridge}', enabled, bridge)
                    self.assertEqual('KF2Breacher.BreacherMutator' in role['args'][0], enabled)
                    self.assertEqual('KF2VR.VRDemo' in role['args'][0], bridge)
                    engine = read_ini(Path(role['config_root']) / 'KFEngine.ini')
                    self.assertEqual(str(optional) in engine, enabled)
                    self.assertIn(str(Path(role['config_root']).parent / 'SaveData'), engine)
                    self.assertIn('bHasVoiceEnabled=false', engine)
                    self.assertIn('bDiagnosticSyntheticAutoStart=false', read_ini(Path(role['config_root']) / 'KFGame.ini'))
                    self.assertFalse(any(arg.startswith('-kf2vr-') for arg in role['args']))
            self.assertEqual(before, config_hashes(user))
            source.write_text('changed fixture')
            with self.assertRaisesRegex(RuntimeError, 'Compile current acceptance'):
                prepare(root, root / 'game', user, root / 'stale', True, False)


if __name__ == '__main__':
    unittest.main()
