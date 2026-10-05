import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('input_replay_runner', Path(__file__).resolve().parents[1]/'replay/run.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

class ReplayConfigTests(unittest.TestCase):
    def test_utf16_crlf_and_unrelated_values_preserved(self):
        source = '[KF2VR.VRHandsBridge]\r\nbDualHandReplay=True\r\nbInteractiveReloads=True\r\nbUsabilityCapture=True\r\n[Other]\r\nName=caf\u00e9\r\n'
        result = runner.disable_script_inputs(source.encode('utf-16'))
        self.assertTrue(result.startswith(b'\xff\xfe'))
        expected = source.replace('bDualHandReplay=True','bDualHandReplay=False').replace('bUsabilityCapture=True','bUsabilityCapture=False')
        self.assertEqual(result.decode('utf-16'),expected)

    def test_no_replay_flags_no_change(self):
        source = b'\xef\xbb\xbf[Other]\r\nbNormalGame=False\r\n'
        self.assertEqual(runner.disable_script_inputs(source),source)

    def test_bom_free_config_stays_bom_free(self):
        source = b'[KF2VR.VRHandsBridge]\r\nbDualHandReplay=True\r\n[Other]\r\nValue=7\r\n'
        self.assertEqual(runner.disable_script_inputs(source), source.replace(b'=True', b'=False'))

    def test_big_endian_utf16_preserves_byte_order(self):
        source = b'\xfe\xff' + '[Other]\r\nbDualHandReplay=True\r\n'.encode('utf-16-be')
        self.assertEqual(runner.disable_script_inputs(source), source.replace('True'.encode('utf-16-be'), 'False'.encode('utf-16-be')))

    def test_ansi_player_values_preserved(self):
        source = '[Other]\r\nName=caf\u00e9\r\nbDualHandReplay=True\r\n'.encode('cp1252')
        self.assertEqual(runner.disable_script_inputs(source), source.replace(b'True', b'False'))

    def test_capture_requires_readable_nonzero_graphics_config(self):
        source = b'[SystemSettings]\r\nResX=1920\r\nResY=1080\r\nScreenPercentage=100\r\nMaxDrawDistanceScale=1\r\n[Bucket]\r\nScreenPercentage=0\r\n'
        runner.validate_capture_config(source)
        runner.validate_capture_config(source.decode().encode('utf-16'))
        for invalid in (b'\xef\xbb\xbf'+source,
                        source.replace(b'[SystemSettings]', b'[Bucket1]'),
                        source.replace(b'ScreenPercentage=100', b'ScreenPercentage=0'),
                        source.replace(b'ScreenPercentage=100', b'ScreenPercentage=nan'),
                        source.replace(b'MaxDrawDistanceScale=1', b'MaxDrawDistanceScale=0')):
            with self.subTest(invalid=invalid), self.assertRaises(RuntimeError):
                runner.validate_capture_config(invalid)

    def test_preflight_checks_every_config_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory).resolve()
            args = []
            for name in ('ENGINE', 'GAME', 'INPUT', 'UI', 'WEB', 'SYSTEMSETTINGS', 'LIGHTMASS', 'BENCHMARKING'):
                path = run/(name+'.ini')
                data = b'[Other]\r\nValue=1\r\n'
                if name == 'SYSTEMSETTINGS':
                    data = b'[SystemSettings]\r\nResX=1920\r\nResY=1080\r\nScreenPercentage=100\r\nMaxDrawDistanceScale=1\r\n'
                path.write_bytes(data)
                args.append('-'+name+'INI='+str(path))
            runner.preflight_configs(args, run)
            (run/'ENGINE.ini').write_bytes(b'\xef\xbb\xbf[Other]\r\nValue=1\r\n')
            with self.assertRaisesRegex(RuntimeError, 'UTF-8 BOM'):
                runner.preflight_configs(args, run)
            (run/'ENGINE.ini').write_bytes(b'[Other]\r\nValue=1\r\n')
            with self.assertRaisesRegex(RuntimeError, 'inside prepared run'):
                runner.preflight_configs(['-ENGINEINI='+str(run.parent/'user.ini')]+args[1:], run)

# Log parsing checks use observations, not production source text or duplicate
# gameplay math. Missing or contradictory evidence must not become acceptance.
spec2 = importlib.util.spec_from_file_location('input_replay_analyzer', Path(__file__).resolve().parents[1]/'replay/analyze.py')
analyzer = importlib.util.module_from_spec(spec2)
spec2.loader.exec_module(analyzer)

class ReplayLogTests(unittest.TestCase):
    def test_empty_log_is_not_acceptance(self):
        result=analyzer.analyze('')
        self.assertFalse(result['complete'])
        self.assertEqual(result['unavailable_held_release_fire'],[False,False])

    def test_failure_wins_over_complete_marker(self):
        result=analyzer.analyze('KF2VR_INPUT_OBSERVER complete=True stockFallback=True conserved=True\nKF2VR_INPUT_OBSERVER complete=False reason=timeout')
        self.assertFalse(result['complete'])

    def test_rearm_requires_observed_release(self):
        def row(armed,valid,trigger,active,shots):
            return f'KF2VR_INPUT_OBSERVER hand=0 ammo=1 reserve=20 armed={armed} valid={valid} trigger={trigger} active={active} shots={shots} reloads=0\n'
        start=row('False',0,0,0,0)+row('False',1,1,1,0)
        self.assertFalse(analyzer.analyze(start+row('True',1,1,1,1))['unavailable_held_release_fire'][0])
        result=analyzer.analyze(start+row('True',1,0,1,0)+row('True',1,1,1,1))
        self.assertEqual(result['unavailable_held_release_fire'],[True,False])

if __name__ == '__main__':
    unittest.main()
