"""Offline host identity, admission and Workshop package compatibility checks."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import friends
import game_install
import workshop_loadout as loadout
from session import read_ini
from vr_config import apply_preferences, values


class HostOptionsTests(unittest.TestCase):
    def test_grab_zone_preference_defaults_and_saved_choices_survive_merge(self):
        section = 'KF2VR.VRHandsBridge'
        for saved, expected in (('', 'False'), ('True', 'True'), ('False', 'False'), ('invalid', 'False')):
            profile = '[KF2VR.Profile]\nRevision=2\n['+section+']\nbWideGrabZones='+saved+'\n' if saved else ''
            text = apply_preferences('['+section+']\nbWideGrabZones=True\n' if saved else '', profile)
            self.assertEqual(values(text, section)['bWideGrabZones'], expected)

    def test_steam_main_checks_effective_saved_dlss_before_preflight(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'release.json').write_text(json.dumps({'files_sha256': {}, 'game_sha256': 'fixture'}))
            install = game_install.Installation('steam', root/'game')
            with patch.object(friends, 'ROOT', root), patch.object(loadout, 'profile_root', return_value=root), \
                    patch.object(friends.game_install, 'select_for_launch', return_value=install), \
                    patch.object(friends.game_install, 'validate_native'), \
                    patch.object(friends, 'installed_solo_maps', return_value=['KF-BurningParis']), \
                    patch.object(friends, 'preflight', side_effect=RuntimeError('preflight boundary')) as preflight:
                for mode in ('off', 'quality'):
                    (root/'launcher.json').write_text(json.dumps({'dlss': mode}))
                    preflight.reset_mock()
                    with patch.object(friends.sys, 'argv', ['friends.py', '--solo', '--vr']), contextlib.redirect_stdout(io.StringIO()):
                        if mode == 'off':
                            with self.assertRaisesRegex(RuntimeError, 'preflight boundary'):
                                friends.main()
                            preflight.assert_called_once()
                        else:
                            with self.assertRaisesRegex(ValueError, 'no DLSS runtime'):
                                friends.main()
                            preflight.assert_not_called()

    def test_epic_saved_dlss_requires_runtime_before_deployment(self):
        import epic_manual
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'launcher.json').write_text(json.dumps({'dlss': 'quality'}))
            args = friends.parse_options(['--solo', '--vr', '--store', 'epic'])
            args.profile_root = root
            install = game_install.Installation('epic', root/'game')
            with patch.object(epic_manual, 'resolve_target') as resolve, self.assertRaisesRegex(ValueError, 'no DLSS runtime'):
                epic_manual.run_session(args, {}, install)
            resolve.assert_not_called()

    def test_open_host_retains_password_for_later_protected_host(self):
        saved = {'server_name': 'Our server', 'host_password': 'private-123'}
        args = friends.parse_options(['--host', '--open-server'])
        friends.resolve_host_identity(args, saved)
        self.assertEqual((args.server_name, args.password), ('Our server', ''))
        self.assertEqual(saved['host_password'], 'private-123')
        args = friends.parse_options(['--host', '--no-open-server', '--server-name', 'New server'])
        friends.resolve_host_identity(args, saved)
        self.assertEqual((args.server_name, args.password), ('New server', 'private-123'))
        self.assertEqual(saved['server_name'], 'New server')

    def test_new_protected_host_generates_password_and_bad_identity_never_saves(self):
        saved = {}
        args = friends.parse_options(['--host'])
        friends.resolve_host_identity(args, saved)
        self.assertRegex(args.password, r'^[A-Za-z0-9_-]{1,64}$')
        self.assertEqual(saved['host_password'], args.password)
        before = dict(saved)
        for flags in (['--server-name', 'bad?name'], ['--server-name', ' '], ['--password', 'bad?secret']):
            with self.subTest(flags=flags), self.assertRaises(RuntimeError):
                friends.resolve_host_identity(friends.parse_options(['--host', *flags]), saved)
            self.assertEqual(saved, before)

    def test_host_only_options_reject_solo_and_join(self):
        for prefix in ([], ['--solo']):
            for flags in (['--server-name', 'Name'], ['--open-server'], ['--no-open-server'], ['--workshop-desktop']):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    friends.parse_options([*prefix, *flags])

    def test_query_requires_matching_password_state_and_vac_off(self):
        for protected in (False, True):
            info = dict(secure=False, folder='kf2', password=protected)
            friends.validate_server_query(info, 'secret' if protected else '')
            with self.assertRaises(ValueError):
                friends.validate_server_query(info, '' if protected else 'secret')
            with self.assertRaises(RuntimeError):
                friends.validate_server_query({**info, 'secure': True}, 'secret' if protected else '')
        with self.assertRaises(ValueError):
            friends.validate_server_query(dict(secure=False, folder='other', password=False), '')

    def test_host_preferences_survive_solo_and_explicit_off_wins(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile = root/'profile'
            host = friends.parse_options(['--host', '--vr', '--open-server', '--workshop-desktop'])
            host.profile_root = profile
            loadout.load_preferences(host)
            loadout.save_preferences(host)
            solo = friends.parse_options(['--solo', '--vr'])
            solo.profile_root = profile
            loadout.load_preferences(solo)
            self.assertFalse(solo.open_server or solo.workshop_desktop)
            loadout.save_preferences(solo)
            self.assertTrue(json.loads((profile/'launcher.json').read_text())['open_server'])
            host = friends.parse_options(['--host', '--no-open-server', '--no-workshop-desktop'])
            host.profile_root = profile
            loadout.load_preferences(host)
            self.assertFalse(host.open_server or host.workshop_desktop)

    def test_workshop_matching_packages_are_offered_without_mounting_foreign_scripts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package, published, configs = root/'release/Packages', root/'workshop/BrewedPC', root/'config'
            for folder in (package, published, configs):
                folder.mkdir(parents=True)
            for name in ('KF2VR.u', 'KF2VRNet.u', 'KF2VRNetClient.u', 'KF2VRHands.upk'):
                content = b'\xc1\x83\x2a\x9e' + name.encode()
                (package/name).write_bytes(content)
                (published/name).write_bytes(content)
            args = friends.parse_options(['--host', '--workshop-desktop', '--prepare-only'])
            with patch.object(loadout, 'ensure_item', return_value=published.parent) as ensure:
                loadout.verify_desktop_workshop(args, root/'game', root/'steam', package.parent)
                self.assertFalse(ensure.call_args.kwargs['download'])
                original = '[Core.System]\nPaths=local-script-path\n[IpDrv.TcpNetDriver]\nDownloadManagers=OtherManager\n'
                engine = configs/'KFEngine.ini'
                engine.write_text(original)
                loadout.configure_content(configs, args, server=True)
                configured = read_ini(engine)
                self.assertIn('ServerSubscribedWorkshopItems='+loadout.KF2VR_WORKSHOP_ID, configured)
                self.assertIn('Paths=local-script-path', configured)
                self.assertNotIn(str(published), configured)
                self.assertIn('DownloadManagers=OtherManager', configured)
                (published/'KF2VR.u').write_bytes(b'\xc1\x83\x2a\x9echanged')
                with self.assertRaisesRegex(RuntimeError, 'differ'):
                    loadout.verify_desktop_workshop(args, root/'game', root/'steam', package.parent)
                self.assertFalse(args.workshop_desktop_verified)
                with self.assertRaisesRegex(RuntimeError, 'not been verified'):
                    loadout.configure_content(configs, args, server=True)
                args.breacher = True
                with self.assertRaisesRegex(RuntimeError, 'Breacher'):
                    loadout.verify_desktop_workshop(args, root/'game', root/'steam', package.parent)

    def test_saved_dlss_is_checked_after_resolution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for mode in ('off', 'quality'):
                (root/'launcher.json').write_text(json.dumps({'dlss': mode}))
                for flags in ([], ['--dlss', 'off'], ['--dlss', 'quality']):
                    args = friends.parse_options(['--solo', '--vr', *flags])
                    args.profile_root = root
                    loadout.load_preferences(args)
                    effective = flags[1] if flags else mode
                    self.assertEqual(args.dlss, effective)
                    if effective == 'off':
                        friends.validate_dlss_package(args, {})
                    else:
                        with self.assertRaisesRegex(ValueError, 'no DLSS runtime'):
                            friends.validate_dlss_package(args, {})
                    friends.validate_dlss_package(args, {'native_build': {'dlss_enabled': True}})


if __name__ == '__main__':
    unittest.main()
