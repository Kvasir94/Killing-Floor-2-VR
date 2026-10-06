import json
from pathlib import Path
import tempfile
import unittest
import game_install
import epic_launch


class EpicLaunchTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.game=self.root/'Epic KF2'
        self.install=game_install.Installation('epic',self.game)
        self.install.executable.parent.mkdir(parents=True)
        self.install.executable.write_bytes(b'test')
        self.manifests=self.root/'manifests';self.manifests.mkdir()
        self.item=dict(AppName='Finch',bIsIncompleteInstall=False,InstallLocation=str(self.game),
                       LaunchExecutable='Binaries/Win64/KFGame.exe',CatalogNamespace='namespace',CatalogItemId='item')
        self.write()

    def write(self, **changes):
        (self.manifests/'game.item').write_text(json.dumps({**self.item,**changes}))

    def test_documented_uri_contains_identity_and_only_documented_parameters(self):
        target=epic_launch.resolve_target(self.install,self.manifests)
        self.assertEqual(target.uri(),'com.epicgames.launcher://apps/namespace%3Aitem%3AFinch?action=launch&silent=true')

    def test_activation_does_not_claim_handler_is_owned_game(self):
        calls=[]
        result=epic_launch.activate_vanilla(self.install,self.manifests,opener=calls.append)
        self.assertEqual(len(calls),1)
        self.assertIsNone(result['game_pid'])
        self.assertFalse(result['owns_game_process'])

    def test_manifest_root_binding(self):
        self.write(InstallLocation=str(self.root/'other'))
        with self.assertRaises(ValueError):epic_launch.resolve_target(self.install,self.manifests)

    def test_incomplete_install(self):
        self.write(bIsIncompleteInstall=True)
        with self.assertRaises(ValueError):epic_launch.resolve_target(self.install,self.manifests)

    def test_conflicting_manifest_identity(self):
        (self.manifests/'duplicate.item').write_text(json.dumps({**self.item,'CatalogItemId':'other'}))
        with self.assertRaisesRegex(ValueError,'ambiguous'):epic_launch.resolve_target(self.install,self.manifests)

    def test_identical_duplicate_is_harmless(self):
        (self.manifests/'duplicate.item').write_text(json.dumps(self.item))
        self.assertEqual(epic_launch.resolve_target(self.install,self.manifests).artifact,'Finch')

    def test_uri_injection_rejected(self):
        for value in ('item?action=other','item/other','item:other','',None):
            self.write(CatalogItemId=value)
            with self.assertRaises(ValueError):epic_launch.resolve_target(self.install,self.manifests)

    def test_stale_native_proxy_blocks_vanilla_before_activation(self):
        (self.install.executable.parent/'dinput8.dll').write_bytes(b'owned by another session')
        calls=[]
        with self.assertRaises(RuntimeError):epic_launch.activate_vanilla(self.install,self.manifests,opener=calls.append)
        self.assertEqual(calls,[])

    def test_no_silent_loss_of_vr_arguments_or_environment(self):
        for options in ({'arguments':['-kf2vr-probe']},{'environment':{'KF2VR_LOG_PATH':'session/native.log'}}):
            with self.assertRaises(epic_launch.EpicHandoffUnavailable):epic_launch.require_session_handoff(**options)
        epic_launch.require_session_handoff()

if __name__=='__main__':unittest.main()
