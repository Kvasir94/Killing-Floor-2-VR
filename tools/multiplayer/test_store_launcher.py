"""Offline store selection, generated Epic config and recovery; no game launch."""
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import epic_manual
import epic_recovery
import diagnostics
import friends
import game_install
from native_fixture import NativeDeployment
from session import digest, read_ini
from vr_config import values
import workshop_loadout


class StoreLauncherTests(unittest.TestCase):
    def test_auto_single_install_no_install_and_stale_saved_folder(self):
        steam = game_install.Installation('steam', Path('C:/games/SteamKF2'))
        epic = game_install.Installation('epic', Path('C:/games/EpicKF2'))
        for install in (steam, epic):
            self.assertEqual(install, game_install.select_for_launch(installs=[install]))
            self.assertEqual(install, game_install.select_for_launch(installs=[install], saved_root='C:/missing/KF2'))
        with self.assertRaisesRegex(ValueError, 'No completed'):
            game_install.select_for_launch(installs=[])
        with self.assertRaisesRegex(ValueError, 'Choose a Killing Floor'):
            game_install.select_for_launch(installs=[steam, epic], saved_root='C:/missing/KF2')
        with self.assertRaisesRegex(ValueError, 'No completed'):
            game_install.select_for_launch(installs=[epic], store='steam')

    def test_manual_saved_folder_survives_without_manifest_but_never_changes_explicit_store(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exe = root/game_install.EXECUTABLE
            exe.parent.mkdir(parents=True)
            exe.write_bytes(b'unknown')
            with self.assertRaisesRegex(ValueError, 'No completed'):
                game_install.select_for_launch(installs=[], saved_root=root)
            identity = dict(binary_store='epic', file_version='1.0.8767.0')
            with patch.object(game_install, 'fingerprint', return_value=identity):
                self.assertEqual(root, game_install.select_for_launch(installs=[], saved_root=root).root)
                with self.assertRaisesRegex(ValueError, 'No completed'):
                    game_install.select_for_launch(installs=[], saved_root=root, store='steam')

    def test_epic_bug_report_collects_owned_logs_with_existing_redaction(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)/'app'
            run = root/'sessions/one'
            run.mkdir(parents=True)
            (root/'release.json').write_text('{}')
            log = run/'game.log'
            log.write_text('AUTH_PASSWORD=fake-private-credential\nKF2VR gameplay started\n')
            (run/'native.log').write_text('adapter started\n')
            (run/'Launch Options.txt').write_text('must stay local')
            (run/'epic-session.json').write_text(json.dumps({'schema': 'kf2vr/epic-manual/1', 'store': 'epic',
                'role': {'role': 'driver', 'log': str(log)}, 'cleanup_complete': True}))
            with patch.object(diagnostics, 'hardware_context', return_value={}):
                target = diagnostics.collect_logs(root, Path(temporary))
            with zipfile.ZipFile(target) as archive:
                self.assertTrue(any(name.endswith('game.log') for name in archive.namelist()))
                self.assertFalse(any('Launch Options' in name for name in archive.namelist()))
                text = '\n'.join(archive.read(name).decode() for name in archive.namelist())
                self.assertIn('gameplay started', text)
                self.assertNotIn('fake-private-credential', text)

    def test_auto_requires_choice_with_both_stores_and_remembers_valid_folder(self):
        steam = game_install.Installation('steam', Path('C:/games/SteamKF2'))
        epic = game_install.Installation('epic', Path('C:/games/EpicKF2'))
        installs = [steam, epic]
        with self.assertRaisesRegex(ValueError, 'Choose a Killing Floor'):
            game_install.select_for_launch(installs=installs)
        self.assertEqual(epic, game_install.select_for_launch(installs=installs, saved_root=epic.root))
        self.assertEqual(steam, game_install.select_for_launch(installs=installs, store='steam', saved_root=epic.root))

    def test_explicit_root_checks_actual_store_and_unknown_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exe = root/game_install.EXECUTABLE
            exe.parent.mkdir(parents=True)
            exe.write_bytes(b'unknown build')
            with self.assertRaisesRegex(ValueError, 'version differs'):
                game_install.select_for_launch(root=root)
            identity = dict(binary_store='epic', file_version='1.0.8767.0')
            with patch.object(game_install, 'fingerprint', return_value=identity):
                self.assertEqual('epic', game_install.select_for_launch(root=root).store)
                with self.assertRaisesRegex(ValueError, 'another store'):
                    game_install.select_for_launch(root=root, store='steam')

    def test_epic_rejects_unverified_modes_and_recording_before_deployment(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = Path(temporary)
            for flags, error in ((['--host', '--vr'], 'Solo VR only'),
                                 (['--solo', '--desktop'], 'Solo VR only'),
                                 (['--vr', '--address', 'host.example'], 'Solo VR only'),
                                 (['--solo', '--vr', '--record-motion'], 'unavailable'),
                                 (['--solo', '--vr', '--promo-events'], 'unavailable'),
                                 (['--solo', '--vr', '--local-test-control'], 'ordinary manual')):
                args = friends.parse_options(['--store', 'epic', *flags])
                args.profile_root = profile
                workshop_loadout.load_preferences(args)
                with self.assertRaisesRegex(RuntimeError, error):
                    epic_manual.validate_options(args)

    def test_generated_solo_config_keeps_stock_frontend_and_carried_vr_options(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            user = root/'user'
            user.mkdir()
            (user/'KFEngine.ini').write_text('[Core.System]\nPaths=stock\nScriptPaths=stock\nSeekFreePCPaths=stock\n'
                                            'BrewedPCPaths=stock\n[URL]\nLocalMap=KFMainMenu\nLocalOptions=\n')
            (user/'KFGame.ini').write_text('[Stock]\nPreserve=true\n')
            before = {p.name: p.read_bytes() for p in user.iterdir()}
            args = friends.parse_options(['--store', 'epic', '--solo', '--vr', '--map', 'KF-Outpost',
                                         '--difficulty', 'hard', '--game-length', 'long', '--no-breacher'])
            args.profile_root = root/'profile'
            workshop_loadout.load_preferences(args)
            args.address, args.password, args.mods, args.workshop_content = '127.0.0.1', 'solo-unused', [], []
            with patch.object(friends, 'ROOT', root), patch.object(friends, 'configure_mod_settings'):
                role = friends.configure_role(root/'session', 'driver', user, root/'game', args)
            epic_manual.configure_menu_first(role, args)
            config = Path(role['config_root'])
            url = values(read_ini(config/'KFEngine.ini'), 'URL')
            self.assertEqual('KFMainMenu', url['LocalMap'])
            self.assertIn('?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo', url['LocalOptions'])
            self.assertIn('?VRNormalGame=1', url['LocalOptions'])
            self.assertIn('?Difficulty=1?GameLength=2', url['LocalOptions'])
            self.assertEqual('KF-Outpost', values(read_ini(config/'KFGame.ini'), 'KF2VR.VRSessionUI')['LocalMap'])
            self.assertTrue(all(arg.startswith('-') for arg in role['args']))
            self.assertEqual(before, {p.name: p.read_bytes() for p in user.iterdir()})

    def test_unified_package_recovery_restores_original_loader_and_preserves_unknown_proxy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)/'KF2VR-Multiplayer-test'
            source, destination = root/'Native', Path(temporary)/'game'
            source.mkdir(parents=True)
            destination.mkdir()
            for name in ('dinput8.dll', 'openxr_loader.dll'):
                (source/name).write_bytes(('owned '+name).encode())
            (destination/'openxr_loader.dll').write_bytes(b'original loader')
            receipt = {'artifacts_sha256': {p.name: digest(p) for p in source.iterdir()}}
            (root/'release.json').write_text(json.dumps({'store_launcher_protocol': 1, 'native_build': receipt}))
            NativeDeployment(source, destination, root/'sessions/one/native-backup', receipt, digest).install()
            self.assertIsNotNone(epic_recovery.recover_candidates(root, destination, digest))
            self.assertFalse((destination/'dinput8.dll').exists())
            self.assertEqual(b'original loader', (destination/'openxr_loader.dll').read_bytes())
            self.assertIsNone(epic_recovery.recover_candidates(root, destination, digest))
            (destination/'dinput8.dll').write_bytes(b'unknown proxy')
            with self.assertRaisesRegex(RuntimeError, 'preserve'):
                epic_recovery.recover_candidates(root, destination, digest)
            self.assertEqual(b'unknown proxy', (destination/'dinput8.dll').read_bytes())


if __name__ == '__main__':
    unittest.main()
