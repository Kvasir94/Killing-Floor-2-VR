"""Parse the stock LAN startup separately from Steam server-query evidence."""
import unittest
import tempfile
from pathlib import Path
from evidence import local_lan_readiness
from session import role_config, read_ini
from vr_config import values


LOG = """Log: [FSocketWin::Bind] Binding to 127.0.0.1:18777
ScriptLog: Disabling all authentication, due to bIsLanMatch being set to true
DevOnline: Listening for lan beacon requests on 14001
DevOnline: Advertising: bIsLanMatch=True
DevOnline: Advertising: bAntiCheatProtected=False
DevOnline: Advertising: bRequiresPassword=True
DevOnline: Advertising: MapName=KF-BURNINGPARIS
"""


class LanReadinessTests(unittest.TestCase):
    def test_client_lobby_keeps_voice_interface_initialized(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            user = root / 'user'
            user.mkdir()
            (user / 'KFEngine.ini').write_text('[Core.System]\nPaths=Stock\n[VoIP]\nbHasVoiceEnabled=false\n')
            for role, expected in (('server','false'),('driver','true'),('observer','true')):
                result = role_config(root/'run',role,user,root/'packages',root/'game',18777,38015,root/'cache',False)
                self.assertEqual(expected, values(read_ini(Path(result['config_root'])/'KFEngine.ini'),'VoIP')['bHasVoiceEnabled'])

    def test_diagnostic_clients_disable_home_directory_fallback_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            user = root / 'user'
            user.mkdir()
            original = b'[Core.System]\nPaths=Stock\n'
            profile = user / 'KFEngine.ini'
            profile.write_bytes(original)
            for diagnostic in (False, True):
                for role in ('server', 'driver', 'observer'):
                    result = role_config(root / str(diagnostic), role, user,
                        root / 'packages', root / 'game', 18777, 38015,
                        root / 'cache', False, native_replay=diagnostic)
                    self.assertEqual(diagnostic and role != 'server',
                        '-nohomedir' in result['args'])
                    self.assertIn('-ENGINEINI=' + str(Path(result['config_root']) / 'KFEngine.ini'), result['args'])
                    self.assertEqual(original, profile.read_bytes())

    def test_complete_loopback_lan(self):
        self.assertTrue(local_lan_readiness(LOG, 18777, 'kf-burningparis')['passed'])

    def test_every_observation_is_required(self):
        for line in LOG.splitlines(keepends=True):
            with self.subTest(line=line):
                self.assertFalse(local_lan_readiness(LOG.replace(line, ''), 18777, 'kf-burningparis')['passed'])

    def test_different_endpoint_or_map_rejected(self):
        for log, port, map_name in ((LOG.replace('127.0.0.1', '0.0.0.0'),18777,'kf-burningparis'),
                                    (LOG,1877,'kf-burningparis'), (LOG,18777,'kf-outpost')):
            self.assertFalse(local_lan_readiness(log, port, map_name)['passed'])

    def test_latest_settings_win(self):
        for key, value in (('bIsLanMatch','False'),('bAntiCheatProtected','True'),('bRequiresPassword','False')):
            self.assertFalse(local_lan_readiness(LOG + f'Advertising: {key}={value}\n',18777,'kf-burningparis')['passed'])


if __name__ == '__main__':
    unittest.main()
