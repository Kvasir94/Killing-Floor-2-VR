"""Focused replay config isolation and observed-log parser behavior."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

import reload_analyze
import vr_config
from session import read_ini

REPLAY = Path(__file__).resolve().parents[1]/'replay'
sys.path.insert(0, str(REPLAY))
spec = importlib.util.spec_from_file_location('reload_prepare_test', REPLAY/'prepare_reload.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)

def rows(case='normal', hands=(1,)):
    values = [f'KF2VR_RELOAD_OBSERVER phase=ready case={case} preset=Advanced nativeCapability=9 worldWeapons=False coverage=physical-entry-hold-only']
    for h in hands:
        values += [f'KF2VR_RELOAD_OBSERVER phase=shot case={case} hand={h} identity=Weapon_{h} ammo=14 otherHandShot=True',
            f'KF2VR_RELOAD_OBSERVER phase=physical-accepted case={case} hand={h} identity=Weapon_{h} ammo=1',
            f'KF2VR_RELOAD_OBSERVER phase=state case={case} hand={h} identity=Weapon_{h} weaponClass=9mm ammo=1 reserve=90 stage=held worldWeapons=False nativeCapability=9 physicalActive=True authorityHeld=True pairedStatus=1 stockRequest=0']
    values += [f'KF2VR_RELOAD_OBSERVER phase=complete case={case} passed=True coverage=physical-entry-hold-only fullInsertion=False multiplayerAccepted=False otherHandShot=True']
    return '\n'.join(values)

class ReloadLogTests(unittest.TestCase):
    def test_bounded_result_does_not_claim_complete_reload(self):
        result = reload_analyze.analyze(rows(), 'normal')
        self.assertTrue(result['passed'])
        self.assertFalse(result['full_reload_accepted'])
        self.assertFalse(result['multiplayer_accepted'])

    def test_dual_requires_both_hands(self):
        self.assertFalse(reload_analyze.analyze(rows('dual'), 'dual')['passed'])
        self.assertTrue(reload_analyze.analyze(rows('dual',(0,1)), 'dual')['passed'])

    def test_missing_duplicate_contradictory_and_runtime_errors_fail(self):
        good = rows()
        broken = [good.split('\n',1)[1], good.rsplit('\n',1)[0], good+'\n'+good,
            good.replace('passed=True','passed=False'), good.replace('fullInsertion=False','fullInsertion=True'),
            good.replace('worldWeapons=False','worldWeapons=True'), good+'\nScriptWarning: Accessed None',
            good.replace('ammo=1','ammo=NaN'), good.replace('hand=1','hand=3'),
            good.replace('case=normal','case=dual'), good.replace('stage=held','stage=held stage=stock'),
            good.replace('physicalActive=True','physicalActive=False'),
            good.replace('phase=physical-accepted','phase=missing'),
            good.replace('identity=Weapon_1 weaponClass','identity=Changed weaponClass')]
        for value in broken:
            with self.subTest(value=value):
                self.assertFalse(reload_analyze.analyze(value,'normal')['passed'])

class ReloadConfigTests(unittest.TestCase):
    def test_only_disposable_config_is_changed(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            original = base/'user.ini'
            original.write_bytes(b'[KF2VR.VRHandsBridge]\r\nbWorldWeaponDrops=True\r\nbDualHandReplay=True\r\n'
                b'[Unrelated.Custom]\r\nKeepThis=Unchanged\r\n')
            configs = base/'copied'
            configs.mkdir()
            (configs/'KFGame.ini').write_bytes(original.read_bytes())
            (configs/'KFEngine.ini').write_text('[Engine.Engine]\n',encoding='utf-16')
            (configs/'KFSystemSettings.ini').write_text('[SystemSettings]\nResX=1\n',encoding='utf-16')
            before = original.read_bytes()
            prepare.configure_reload(configs,'dual')
            self.assertEqual(before,original.read_bytes())
            text = read_ini(configs/'KFGame.ini')
            for section in ('KF2VR.VRHandsBridge','KF2VRNetClient.KF2VRNetHandsBridge'):
                values = vr_config.values(text,section)
                for key,value in prepare.ADVANCED.items():
                    self.assertEqual(value,values[key])
                for key in ('WristwatchScale','TopHudScale','TopHudDistance','WeaponAmmoReadoutScale'):
                    self.assertGreater(float(values[key]),0)
                    self.assertEqual(vr_config.DEFAULTS['KF2VR.VRHandsBridge'][key], values[key])
            session = vr_config.values(text,'KF2VR.VRSessionUI')
            self.assertGreater(float(session['SpatialMenuScale']),0)
            self.assertEqual('Unchanged',vr_config.values(text,'Unrelated.Custom')['KeepThis'])
            self.assertEqual('False',vr_config.values(text,'KF2VRNet.KF2VRNetPlayerController')['bDiagnosticSyntheticAutoStart'])
            engine = read_ini(configs/'KFEngine.ini')
            self.assertEqual('KF2VRNetClient.KF2VRNetViewportClient',vr_config.values(engine,'Engine.Engine')['GameViewportClientClassName'])
            self.assertEqual('True',vr_config.values(engine,'KF2VRNetClient.KF2VRNetViewportClient')['bDiagnosticInputIsolation'])
            self.assertEqual('False',vr_config.values(text,'KF2VR.VRHandsBridge')['bDualHandReplay'])
            self.assertEqual('dual',vr_config.values(text,'KF2VRReplay.ReloadObserver')['Scenario'])

if __name__ == '__main__':
    unittest.main()
