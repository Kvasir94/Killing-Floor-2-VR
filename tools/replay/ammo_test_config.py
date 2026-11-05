"""Disposable family/VoIP config behavior; no game or source assertions."""
from pathlib import Path
import tempfile
import unittest

from ammo_prepare import configure_case
from session import read_ini
from vr_config import values


class FamilyConfigTests(unittest.TestCase):
    def test_family_and_voice_override_stay_in_disposable_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);user=root/'user.ini'
            user.write_bytes(b'[VoIP]\r\nbHasVoiceEnabled=True\r\n[Other]\r\nKeep=Yes\r\n')
            before=user.read_bytes();config=root/'copy';config.mkdir()
            (config/'KFGame.ini').write_text('[KF2VR.VRHandsBridge]\n',encoding='utf-16')
            (config/'KFEngine.ini').write_bytes(before)
            (config/'KFSystemSettings.ini').write_text('[SystemSettings]\nResX=1\n',encoding='utf-16')
            configure_case(config,'normal','thompson',True)
            self.assertEqual(before,user.read_bytes())
            engine=read_ini(config/'KFEngine.ini')
            self.assertEqual('False',values(engine,'VoIP')['bHasVoiceEnabled'])
            self.assertEqual('Yes',values(engine,'Other')['Keep'])
            game=read_ini(config/'KFGame.ini')
            self.assertEqual('KFGameContent.KFWeap_AssaultRifle_Thompson',values(game,'KF2VRReplay.ReloadObserver')['SingleWeaponPath'])
            self.assertEqual('True',values(game,'KF2VR.VRHandsBridge')['bKeepChamberedRound'])

    def test_unsupported_dual_family_refuses_before_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with self.assertRaisesRegex(ValueError,'paired 9mm'):
                configure_case(root,'dual','ar15',False)
            self.assertEqual([],list(root.iterdir()))


if __name__ == '__main__':
    unittest.main()
