"""Offline player launch, settings and repository context checks; no game, server or window."""
import json
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import MagicMock

import friends
import launcher_app as app
import launcher_settings as model
import workshop_loadout


def no_install():
    return (patch.object(app.game_install, 'select_for_launch', side_effect=ValueError('no install')),
            patch.object(app.game_install, 'discover', return_value=[]))


class PlayerLauncherTests(unittest.TestCase):
    def setUp(self):
        # A KF2-VR session someone is playing on this PC must not make settings read-only;
        # the read-only test patches its own state.
        running = patch.object(app.LauncherState, '_other_session_running', return_value=False)
        running.start()
        self.addCleanup(running.stop)

    def profile(self, root):
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(workshop_loadout, 'profile_root', return_value=root))
        stack.enter_context(patch('vr_config.profile_root', return_value=root))
        stack.enter_context(patch.object(app, 'LOGS', root / 'logs'))
        return stack

    def test_join_preserves_or_explicitly_replaces_personal_graphics(self):
        for vr, initial in ((True, []), (True, ['--vr-quality', 'quality']), (False, [])):
            with self.subTest(vr=vr, initial=initial), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                profile = root / 'profile'
                profile.mkdir()
                (profile / 'launcher.json').write_text(json.dumps({'vr_quality': 'quality'}))
                context = app.parse_context(['--workspace', str(root), '--initial-arguments',
                                             json.dumps(['--vr' if vr else '--desktop'] + initial)])
                missing, empty = no_install()
                with patch.object(app, 'ROOT', root), self.profile(profile), missing, empty:
                    state = app.LauncherState(context)
                    self.assertIsNone(state.join_arguments(root / 'game', 'code', code='not a code'))
                    args = friends.parse_options(state.join_arguments(root / 'game', 'code', code=' KF2VR1:test '))
                    self.assertIsNone(args.vr_quality_requested)
                    self.assertEqual(args.vr, vr)
                    self.assertEqual(args.address, 'KF2VR1:test')
                    address = friends.parse_options(state.join_arguments(root / 'game', 'address', address='192.168.1.20',
                                                                         password='secret'))
                    self.assertEqual((address.address, address.password, address.port), ('192.168.1.20', 'secret', 7777))
                    # host:port works for IP addresses and names, with any port the game accepts (1-65535).
                    for typed, host, port in (('203.0.113.7:7790', '203.0.113.7', 7790), ('kf.example.net:8000', 'kf.example.net', 8000),
                                              ('203.0.113.7:80', '203.0.113.7', 80), ('203.0.113.7:65535', '203.0.113.7', 65535)):
                        joined = friends.parse_options(state.join_arguments(root / 'game', 'address', address=typed))
                        self.assertEqual((joined.address, joined.port), (host, port))
                    for bad in ('203.0.113.7:0', '203.0.113.7:65536'):
                        self.assertIsNone(state.join_arguments(root / 'game', 'address', address=bad), bad)
                    self.assertEqual({'address'}, set(state.address_problems('bad host', '')))
                    for bad in ('192.168.1', '192.168.1.300', '10.0.0.1.', 'host..example', '-host', 'host:', 'host:x7'):
                        self.assertEqual({'address'}, set(state.address_problems(bad, '')), bad)
                    for good in ('203.0.113.7', '203.0.113.7:7790', 'my-pc', 'host.example.com:7777'):
                        self.assertEqual({}, state.address_problems(good, ''), good)
                    self.assertEqual({'password'}, set(state.address_problems('host', 'not ok!')))
                    self.assertIsNone(state.join_arguments(root / 'game', 'address', address='bad host!'))
                self.assertEqual(json.loads((profile / 'launcher.json').read_text()), {'vr_quality': 'quality'})

    def test_host_form_uses_explicit_identity_and_public_override(self):
        for initial, expected in ((['--server-name', 'CLI host', '--password', 'cli-secret'], ('CLI host', 'cli-secret')),
                                  (['--server-name', 'Public host', '--open-server'], ('Public host', ''))):
            with self.subTest(initial=initial), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                settings = root / 'settings.json'
                settings.write_text(json.dumps({'server_name': 'Saved host', 'host_password': 'saved-secret'}))
                before = settings.read_bytes()
                context = app.parse_context(['--workspace', str(root), '--initial-arguments',
                                             json.dumps(['--host', '--desktop'] + initial)])
                with patch.object(app, 'ROOT', root), self.profile(root / 'profile'):
                    state = app.LauncherState(context)
                    form = state.match_defaults('host', ['KF-Outpost'])
                    self.assertEqual((form['server_name'], form['password']), expected)
                    parsed = friends.parse_options(state.match_arguments('host', root / 'game', form))
                self.assertEqual(parsed.server_name, expected[0])
                self.assertEqual(parsed.open_server, not bool(expected[1]))
                self.assertEqual(parsed.password, expected[1] or None)
                self.assertEqual(settings.read_bytes(), before)

    def test_host_form_preserves_saved_password_and_blank_requests_public_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'settings.json').write_text(json.dumps({'server_name': 'Saved server', 'host_password': 'saved-secret'}))
            with patch.object(app, 'ROOT', root), self.profile(root / 'profile'):
                state = app.LauncherState()
                for vr in (False, True):
                    state.vr = vr
                    form = state.match_defaults('host', ['KF-Outpost'])
                    self.assertEqual((form['server_name'], form['password']), ('Saved server', 'saved-secret'))
                    args = friends.parse_options(state.match_arguments('host', root / 'game', form))
                    self.assertEqual((args.server_name, args.password, args.open_server), ('Saved server', 'saved-secret', False))
                    form.update(server_name='Our game', password='')
                    args = friends.parse_options(state.match_arguments('host', root / 'game', form))
                    self.assertEqual((args.server_name, args.password, args.open_server), ('Our game', None, True))
                    self.assertTrue(args.workshop_desktop)
                    self.assertIs(False, args.inventory_focus)
                    for field, value in (('server_name', ''), ('password', 'has space')):
                        with self.assertRaises(ValueError) as problems:
                            state.match_arguments('host', root / 'game', dict(form, **{field: value}))
                        self.assertTrue(problems.exception.args[0][field])
            self.assertFalse((root / 'profile/launcher.json').exists())

    def test_host_loads_the_patch_whenever_mods_or_spawn_changes_need_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(app, 'ROOT', root), self.profile(root / 'profile'):
                state = app.LauncherState()
                form = state.match_defaults('host', ['KF-Outpost'])
                self.assertEqual([], friends.parse_options(state.match_arguments('host', root / 'game', form)).mods)
                for change in ({'mods': ['yas']}, {'max_zeds': 32}):
                    parsed = friends.parse_options(state.match_arguments('host', root / 'game', dict(form, **change)))
                    self.assertIn('ukfp', parsed.mods)
                    self.assertTrue(state.patch_needed(dict(form, **change)))
                solo = state.match_defaults('solo', ['KF-Outpost'])
                parsed = friends.parse_options(state.match_arguments('solo', root / 'game', dict(solo, max_zeds=32)))
                self.assertEqual(32, parsed.max_zeds)

    def test_epic_solo_uses_single_pass_without_writing_preferences(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            missing, empty = no_install()
            with self.profile(root / 'profile'), missing, empty:
                state = app.LauncherState()
                state.store = 'epic'
                state.epic_rules()
                # Render modes are fixed, not settings (Kvasir94, 11-05, #200).
                self.assertFalse({'single_pass', 'threaded_render'} & set(model.BY_KEY))
                launched = state.match_arguments('solo', root / 'game', state.match_defaults('solo', ['KF-Outpost']))
                parsed = friends.parse_options(launched + ['--store', 'epic'])
                parsed.profile_root = root / 'profile'
                workshop_loadout.load_preferences(parsed)
                self.assertTrue(parsed.single_pass)
            self.assertFalse((root / 'profile/launcher.json').exists())

    def test_console_warning_precedes_steam_preflight_and_epic_session(self):
        for store in ('steam', 'epic'):
            with self.subTest(store=store), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                manifest = {'files_sha256': {}, 'game_sha256': 'fixture'}
                (root / 'release.json').write_text(json.dumps(manifest))
                install = app.game_install.Installation(store, root / 'game')
                output = io.StringIO()
                with patch.object(friends, 'ROOT', root), \
                        patch.object(friends.sys, 'argv', ['friends.py', '--solo', '--vr', '--store', store, '--dlss', 'off']), \
                        patch.object(friends.game_install, 'select_for_launch', return_value=install), \
                        patch.object(friends.game_install, 'validate_native'), \
                        patch.object(friends, 'load_preferences'), \
                        patch.object(friends, 'installed_solo_maps', return_value=['KF-BurningParis']), \
                        patch.object(friends, 'preflight', side_effect=RuntimeError('preflight boundary')), \
                        patch('epic_manual.run_session', return_value=0) as epic, \
                        contextlib.redirect_stdout(output):
                    if store == 'epic':
                        self.assertEqual(0, friends.main())
                        epic.assert_called_once()
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'preflight boundary'):
                            friends.main()
                        epic.assert_not_called()
                self.assertEqual(list(friends.launch_notices(store)), output.getvalue().splitlines())
                # Epic has no VAC to mention; both say the same XP rule.
                self.assertEqual(() if store == 'epic' else (friends.LAUNCH_NOTE,),
                                 friends.launch_notices(store))
                self.assertFalse((root / 'settings.json').exists())

    def test_settings_auto_save_and_running_session_is_read_only(self):
        from session import read_ini
        import vr_config
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile = root / 'profile'
            with self.profile(profile):
                state = app.LauncherState()
                self.assertEqual((True, None), state.persist({'eye_render_percent': '75'}))
                self.assertEqual('75', vr_config.values(read_ini(profile / 'KFGame.ini'), model.SESSION)['EyeRenderPercent'])
                before = (profile / 'KFGame.ini').read_bytes()
                with patch.object(state, 'session_running', return_value=True):
                    self.assertEqual((False, 'running'), state.persist(model.RELOAD_PRESETS['Realistic']))
                    self.assertEqual((False, 'running'), state.reset('Hands & Weapons'))
                    self.assertEqual((False, 'running'), state.apply_preset('graphics_preset', 'Performance'))
                self.assertEqual(before, (profile / 'KFGame.ini').read_bytes())

    def test_reload_preset_saves_all_owned_rules_and_preserves_fit(self):
        import vr_config
        from session import read_ini
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile = root / 'profile'
            profile.mkdir()
            (profile / 'KFGame.ini').write_text('[KF2VR.VRHandsBridge]\nFirearmAimPitchDegrees=-13.25\nFirearmAimYawDegrees=4.5\n',
                                               encoding='utf-16')
            with self.profile(profile):
                state = app.LauncherState()
                self.assertTrue(state.apply_preset('reload_mode', 'Realistic')[0])
                self.assertEqual('Realistic', model.preset_name('reload_mode', model.load(state.saved)))
                hands = vr_config.values(read_ini(profile / 'KFGame.ini'), model.HANDS)
                self.assertEqual(('-13.25', '4.5'), (hands['FirearmAimPitchDegrees'], hands['FirearmAimYawDegrees']))
                self.assertTrue(state.persist({'bReloadHints': False})[0])
                self.assertEqual('Realistic', model.preset_name('reload_mode', state.settings_values))
                self.assertTrue(state.persist({'bEmptyTriggerReloads': True})[0])
                self.assertEqual('Custom', model.preset_name('reload_mode', state.settings_values))
                self.assertTrue(state.preset_change_lines('reload_mode', 'Realistic'))

    def test_graphics_preset_also_becomes_the_saved_launch_quality(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.profile(root):
                state = app.LauncherState()
                self.assertTrue(state.apply_preset('graphics_preset', 'Performance')[0])
                self.assertEqual('performance', json.loads((root / 'launcher.json').read_text())['vr_quality'])
                self.assertEqual('Graphics: Performance', state.graphics_summary())
                state.vr = False
                self.assertEqual("Graphics: the game's own options", state.graphics_summary())

    def test_dominant_hand_mirrors_a_standard_layout_and_keeps_fit(self):
        # A standard layout (move with the other hand, point with the gun hand) follows the new
        # dominant hand; hands the player arranged themselves are left alone.
        for layout, expected in (({}, ('0', '1', '0', '7')), ({'MenuHand': '0'}, ('0', '0', '0', '7'))):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                with self.profile(root):
                    model.save({'FirearmAimYawDegrees': '7', **layout})
                    state = app.LauncherState()
                    self.assertTrue(state.persist(state.with_mirroring({'PreferredWeaponHand': '0'}))[0])
                    actual = model.load(state.saved)
                    self.assertEqual(expected, tuple(actual[k] for k in
                                                     ('PreferredWeaponHand', 'MovementHand', 'MenuHand', 'FirearmAimYawDegrees')))

    def test_first_time_setup_never_discards_answered_choices(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.profile(root):
                state = app.LauncherState()
                # A fresh profile already holds every recommended choice.
                self.assertEqual([], state.unanswered_differing())
                model.save({'bSeatedPlay': 'True', **model.RELOAD_PRESETS['Manual']})
                state = app.LauncherState()
                # Hand and seated mode are the player's own, never "recommended" or reset by Use recommended.
                self.assertEqual({'reload_mode'}, {card['id'] for card in state.unanswered_differing()})
                self.assertTrue(state.choose_card_preset('reload_mode', 'reload_mode', 'Realistic')[0])
                self.assertTrue(state.choose_card_preset('ammo_rules', 'ammo_rules', 'Realistic')[0])
                self.assertTrue(state.use_recommended()[0])
                values = model.load(state.saved)
                self.assertEqual(('Realistic', 'Realistic', 'True'),
                                 (model.preset_name('reload_mode', values), model.preset_name('ammo_rules', values),
                                  str(values['bSeatedPlay'])))
                # Button reloads skip Ammo rules and keep Standard (R52).
                self.assertTrue(state.choose_card_preset('reload_mode', 'reload_mode', 'Button')[0])
                self.assertEqual('Standard', model.preset_name('ammo_rules', state.settings_values))
                card = next(c for c in model.FIRST_TIME_SETUP['cards'] if c['id'] == 'ammo_rules')
                self.assertFalse(model.card_applies(card, state.settings_values))
                self.assertTrue(model.first_time_setup_pending())
                state.complete_setup()
                self.assertFalse(model.first_time_setup_pending())

    def test_first_launch_onboarding_and_upgrade_note(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.profile(root):
                state = app.LauncherState()
                self.assertTrue(state.first_launch())
                state.onboarding = True
                state.finish_onboarding()
                self.assertFalse(state.first_launch())
                self.assertFalse(state.upgrade_note_pending())
            with tempfile.TemporaryDirectory() as older:
                # A returning player from an older release: no onboarding, setup marked done, one note.
                older = Path(older)
                (older / 'launcher.json').write_text(json.dumps({'last_session': 'host'}))
                with self.profile(older):
                    state = app.LauncherState()
                    self.assertFalse(state.first_launch())
                    self.assertEqual('host', state.last_kind())
                    self.assertTrue(state.upgrade_note_pending())
                    self.assertFalse(model.first_time_setup_pending())
                    state.dismiss_upgrade_note()
                    self.assertFalse(state.upgrade_note_pending())

    def test_search_finds_dormant_controls_without_changing_preferences(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.profile(root):
                state = app.LauncherState()
                before = model.load(state.saved)
                found = model.search('perk insertion')
                setting = next(s for s in found if s.label == 'Perk reload assist')
                self.assertEqual('Only with Manual or Realistic reloads', model.requirement_text(setting, before))
                elsewhere = model.search_elsewhere('snap')
                self.assertTrue(elsewhere and all(app.where_text(s).startswith('In ') for s in elsewhere))
                self.assertEqual(before, model.load(state.saved))

    def test_gui_rejects_parked_initial_overrides_before_creating_a_window(self):
        for initial in (["--solo", "--breacher-level", "25"], ["--solo", "--zed-defense"]):
            context = app.parse_context(["--workspace", "checkout", "--initial-arguments", json.dumps(initial)])
            with self.subTest(initial=initial), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                app.LauncherState(context)

    def test_single_store_detection_and_saved_package_choice(self):
        import game_install
        for store in ('steam', 'epic'):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                install = game_install.Installation(store, root / 'game')
                (root / 'settings.json').write_text(json.dumps({'game_root': str(install.root)}))
                with self.profile(root / 'profile'), patch.object(app, 'ROOT', root), \
                        patch.object(game_install, 'discover', return_value=[install]):
                    state = app.LauncherState()
                    self.assertEqual(store, state.store)
                    self.assertEqual(install.root, state.game())
                    self.assertEqual(install.root, state.saved.game_root)
                    if store == 'epic':
                        self.assertTrue(state.vr and state.last_kind() == 'solo')

    def test_malformed_saved_package_settings_fall_back_to_discovery(self):
        import game_install
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'settings.json').write_text('{')
            install = game_install.Installation('epic', root / 'game')
            with patch.object(app, 'ROOT', root), patch.object(game_install, 'discover', return_value=[install]), \
                    patch.object(workshop_loadout, 'profile_root', return_value=root / 'profile'):
                self.assertEqual(install.root, app.game_folder())

    def test_epic_window_forwards_store_and_disables_recording_choices(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            context = app.parse_context(['--workspace', 'checkout', '--initial-arguments', json.dumps([
                '--store', 'epic', '--solo', '--vr'])])
            with self.profile(root):
                state = app.LauncherState(context)
                self.assertEqual('epic', state.store)
                self.assertTrue(state.vr)
                self.assertFalse(state.record_motion or state.highlight_events)
                with patch.object(app.subprocess, 'Popen', return_value=MagicMock()) as popen:
                    session = state.launch(['--solo', '--vr'], 'Epic Solo')
                    parsed = friends.parse_options(popen.call_args.args[0][3:])
                self.assertEqual('epic', parsed.store)
                self.assertEqual('epic', session.kind)
                self.assertFalse(parsed.record_motion or parsed.promo_events)

    def test_real_recording_controls_forward_independently_and_off_clears_both(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.profile(root):
                state = app.LauncherState()
                self.assertFalse(state.record_motion or state.highlight_events)
                state.vr = True
                for motion, highlights in ((False, False), (True, False), (False, True), (True, True)):
                    state.record_motion, state.highlight_events = motion, highlights
                    with patch.object(app.subprocess, 'Popen', return_value=MagicMock()) as popen:
                        state.launch(['--host', '--vr'], 'Hosting')
                        parsed = friends.parse_options(popen.call_args.args[0][3:])
                    self.assertEqual((motion, highlights), (parsed.record_motion, parsed.promo_events))
                    self.assertFalse(parsed.replay_teammate or parsed.avatar_preview)
                state.vr = False
                with patch.object(app.subprocess, 'Popen', return_value=MagicMock()) as popen:
                    state.launch(['--host', '--desktop'], 'Hosting')
                    parsed = friends.parse_options(popen.call_args.args[0][3:])
                self.assertFalse(parsed.record_motion or parsed.promo_events)

    def test_repository_context_preserves_explicit_off_and_dependency_locations(self):
        context = app.parse_context(['--workspace', 'checkout', '--initial-arguments', json.dumps([
            '--host', '--desktop', '--no-inventory-focus', '--server-root', 'server', '--cache-root', 'cache', '--prepare-only'])])
        saved = friends.parse_options(context.initial_arguments)
        args = app.contextual_arguments(['--host', '--desktop', '--no-inventory-focus'], saved, context)
        parsed = friends.parse_options(args)
        self.assertIs(False, parsed.inventory_focus)
        self.assertEqual((Path('server'), Path('cache'), True),
                         (parsed.server_root, parsed.cache_root, parsed.prepare_only))
        join = app.contextual_arguments(['--desktop', '--address', 'host.example'], saved, context)
        self.assertNotIn('--server-root', join)
        portable = app.parse_context([])
        self.assertEqual(['--host', '--no-inventory-focus'],
                         app.contextual_arguments(['--host', '--no-inventory-focus'], saved, portable))

    def test_parked_optional_controls_are_absent_with_old_enabled_profiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "launcher.json").write_text(json.dumps({"breacher": True, "zed_defense": True}))
            with self.profile(root):
                state = app.LauncherState()
                for kind in ('host', 'solo'):
                    for vr in (False, True):
                        state.vr = vr
                        launched = state.match_arguments(kind, root / 'game', state.match_defaults(kind, ['KF-Outpost']))
                        args = friends.parse_options(launched)
                        self.assertFalse(hasattr(args, 'breacher') or hasattr(args, 'zed_defense'))
                        self.assertNotIn('--breacher', launched)
                        self.assertNotIn('--zed-defense', launched)

    def test_workspace_stale_consent_and_changed_selection_block_launch(self):
        state = object.__new__(app.LauncherState)
        state.context = app.parse_context(['--workspace', 'checkout'])
        ask, alert = MagicMock(return_value=False), MagicMock()
        with patch('release_state.selected_release', return_value=(app.ROOT.resolve(), {})), \
                patch('release_state.verify_workspace', side_effect=RuntimeError('source changed')):
            self.assertFalse(state.allow_workspace_launch(ask, alert))
            ask.assert_called_once()
        with patch('release_state.selected_release', return_value=(Path('other'), {})):
            self.assertFalse(state.allow_workspace_launch(ask, alert))
            alert.assert_called_once()

    def test_map_lists_group_stock_and_workshop_and_hide_nothing(self):
        maps = ['KF-Outpost', 'KF-BurningParis', 'KF-TF2_Upward', 'KF-VRRange', 'KF-SomeTestMap_v2', 'KF-Remilly_Test_Map']
        choices = app.map_choices(maps, stock={'KF-Outpost', 'KF-BurningParis'})
        # The list opens on a map: only the groups after the game's own maps have a heading.
        self.assertEqual(['Burning Paris', 'Outpost', 'KF2-VR maps', 'VR Range (practice)',
                          'Workshop maps', "Remilly's Test Map", 'Some Test Map (v2)', 'TF2 Upward'],
                         [text for _, text in choices])
        self.assertFalse(isinstance(choices[0][0], app.Heading))
        self.assertTrue(isinstance(choices[2][0], app.Heading))

    def test_match_picks_are_saved_as_chosen_and_quick_start_uses_them(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.profile(root):
                state = app.LauncherState()
                form = state.match_defaults('solo', ['KF-Outpost', 'KF-BurningParis'])
                state.remember_match('solo', dict(form, map='KF-Outpost', difficulty='hard', game_length='short', max_zeds=32))
                self.assertEqual('Outpost  ·  Hard  ·  Short length', state.match_summary('solo'))
                again = state.match_defaults('solo', ['KF-Outpost', 'KF-BurningParis'])
                self.assertEqual(('KF-Outpost', 'hard', 'short', 32),
                                 (again['map'], again['difficulty'], again['game_length'], again['max_zeds']))
                # Quick start passes only --solo; friends.py fills the match from the saved picks.
                arguments, _ = state.quick_play_arguments(root / 'game')
                parsed = friends.parse_options(arguments)
                parsed.profile_root = root
                workshop_loadout.load_preferences(parsed)
                self.assertEqual(('KF-Outpost', 'hard', 'short', 32),
                                 (parsed.map, parsed.difficulty, parsed.game_length, parsed.max_zeds))

    def test_join_code_states_name_what_to_do(self):
        self.assertEqual('empty', app.LauncherState.join_code_state('  ', 'build')[0])
        kind, text = app.LauncherState.join_code_state('KF2VR1:garbage', 'build')
        self.assertEqual('bad', kind)
        self.assertIn('Copy it again', text)

    def test_a_chosen_server_folder_is_used_before_the_server_is_installed(self):
        # Host > Change folder saves machine.json server_root; the first Host downloads into that folder.
        with tempfile.TemporaryDirectory() as temp:
            chosen = Path(temp) / 'E' / 'KF2VR-Server'
            with patch('machine_settings.load', return_value={'server_root': str(chosen), 'game_root': temp}):
                self.assertNotEqual(chosen, friends.default_data_roots()['server_root'])
                chosen.mkdir(parents=True)
                self.assertEqual(chosen, friends.default_data_roots()['server_root'])


if __name__ == '__main__':
    unittest.main()
