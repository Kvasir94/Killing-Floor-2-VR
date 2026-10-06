"""Offline real player form and repository context checks; no game or server."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import MagicMock

import friends
import launcher_gui as gui
import workshop_loadout


class PlayerLauncherTests(unittest.TestCase):
    def test_single_store_detection_limits_home_options_and_survives_saved_package_choice(self):
        import game_install
        for store in ('steam', 'epic'):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                install = game_install.Installation(store, root/'game')
                (root/'settings.json').write_text(json.dumps({'game_root': str(install.root)}))
                with patch.object(workshop_loadout, 'profile_root', return_value=root/'profile'), \
                        patch.object(gui, 'ROOT', root), patch.object(gui, 'LOGS', root/'logs'), \
                        patch.object(game_install, 'discover', return_value=[install]):
                    window = gui.Launcher(art=False)
                    window.withdraw()
                    try:
                        self.assertEqual(store, window.store.get())
                        self.assertEqual(install.root, window.need_game())
                        self.assertEqual(install.root, window.saved.game_root)
                        labels = []
                        def visit(widget):
                            for child in widget.winfo_children():
                                if isinstance(child, (gui.tk.Label, gui.tk.Button)):
                                    labels.append(child.cget('text'))
                                visit(child)
                        visit(window.body)
                        self.assertIn('PLAY SOLO', labels)
                        self.assertEqual(store == 'steam', 'HOST A GAME' in labels)
                        self.assertEqual(store == 'steam', 'JOIN A FRIEND' in labels)
                    finally:
                        window.destroy()

    def test_malformed_saved_package_settings_fall_back_to_discovery(self):
        import game_install
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'settings.json').write_text('{')
            install = game_install.Installation('epic', root/'game')
            with patch.object(gui, 'ROOT', root), patch.object(game_install, 'discover', return_value=[install]):
                self.assertEqual(install.root, gui.game_folder())

    def test_epic_window_forwards_store_and_disables_recording_choices(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            context = gui.parse_context(['--workspace', 'checkout', '--initial-arguments', json.dumps([
                '--store', 'epic', '--solo', '--vr'])])
            with patch.object(workshop_loadout, 'profile_root', return_value=root), patch.object(gui, 'LOGS', root/'logs'):
                window = gui.Launcher(art=False, context=context)
                window.withdraw()
                try:
                    self.assertEqual('epic', window.store.get())
                    self.assertTrue(window.vr.get())
                    self.assertFalse(window.record_motion.get() or window.highlight_events.get())
                    with patch.object(window, 'allow_workspace_launch', return_value=True), \
                            patch.object(gui.subprocess, 'Popen', return_value=MagicMock()), patch.object(window, 'poll'):
                        window.run(['--solo', '--vr'], 'Epic Solo')
                        parsed = friends.parse_options(gui.subprocess.Popen.call_args.args[0][3:])
                    self.assertEqual('epic', parsed.store)
                    self.assertFalse(parsed.record_motion or parsed.promo_events)
                    window.progress.stop()
                    window.epic_options = '-example=session'
                    window.show_epic_options()
                    text = next(child for child in window.code_box.winfo_children() if isinstance(child, gui.tk.Text))
                    self.assertEqual('-example=session', text.get('1.0', 'end').strip())
                finally:
                    window.destroy()

    def test_real_recording_controls_forward_independently_and_off_clears_both(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(workshop_loadout, 'profile_root', return_value=root), patch.object(gui, 'LOGS', root/'logs'):
                window = gui.Launcher(art=False)
                window.withdraw()
                try:
                    self.assertFalse(window.record_motion.get() or window.highlight_events.get())
                    window.vr.set(True)
                    for motion, highlights in ((False, False), (True, False), (False, True), (True, True)):
                        window.record_motion.set(motion)
                        window.highlight_events.set(highlights)
                        with patch.object(gui.subprocess, 'Popen', return_value=MagicMock()), patch.object(window, 'poll'):
                            window.run(['--host', '--vr', '--no-breacher'], 'Hosting')
                            command = gui.subprocess.Popen.call_args.args[0]
                        parsed = friends.parse_options(command[3:])
                        self.assertEqual((motion, highlights), (parsed.record_motion, parsed.promo_events))
                        self.assertFalse(parsed.replay_teammate or parsed.avatar_preview)
                        window.progress.stop()
                    window.vr.set(False)
                    with patch.object(gui.subprocess, 'Popen', return_value=MagicMock()), patch.object(window, 'poll'):
                        window.run(['--host', '--desktop'], 'Hosting')
                        parsed = friends.parse_options(gui.subprocess.Popen.call_args.args[0][3:])
                    self.assertFalse(parsed.record_motion or parsed.promo_events)
                    window.progress.stop()
                finally:
                    window.destroy()

    def test_repository_context_preserves_explicit_off_and_dependency_locations(self):
        context = gui.parse_context(['--workspace', 'checkout', '--initial-arguments', json.dumps([
            '--host', '--desktop', '--no-breacher', '--server-root', 'server', '--cache-root', 'cache', '--prepare-only'])])
        saved = friends.parse_options(context.initial_arguments)
        args = gui.contextual_arguments(['--host', '--desktop', '--no-breacher'], saved, context)
        parsed = friends.parse_options(args)
        self.assertFalse(parsed.breacher)
        self.assertEqual((Path('server'), Path('cache'), True),
                         (parsed.server_root, parsed.cache_root, parsed.prepare_only))
        join = gui.contextual_arguments(['--desktop', '--address', 'host.example'], saved, context)
        self.assertNotIn('--server-root', join)
        portable = gui.parse_context([])
        self.assertEqual(['--host', '--no-breacher'],
                         gui.contextual_arguments(['--host', '--no-breacher'], saved, portable))

    def test_real_host_checkbox_clears_saved_on_in_both_modes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'launcher.json').write_text(json.dumps({'breacher': True}))
            game = root / 'game'
            maps = game / 'KFGame/BrewedPC/Maps/test'
            maps.mkdir(parents=True)
            (maps / 'KF-Outpost.kfm').write_bytes(b'parser fixture')
            with patch.object(workshop_loadout, 'profile_root', return_value=root):
                window = gui.Launcher(art=False)
                window.withdraw()
                try:
                    for vr in (False, True):
                        window.vr.set(vr)
                        launched = []
                        start = []
                        with patch.object(window, 'need_game', return_value=game), \
                                patch.object(window, 'footer', side_effect=lambda frame, **kw: start.append(kw['start'])), \
                                patch.object(window, 'run', side_effect=lambda args, title: launched.append(args)):
                            window.options('host')
                            def descendants(widget):
                                for child in widget.winfo_children():
                                    yield child
                                    yield from descendants(child)
                            checkbox = next(child for child in descendants(window.body)
                                if isinstance(child, gui.ttk.Checkbutton) and child.cget('text').startswith('Breacher'))
                            self.assertTrue(checkbox.instate(['selected']))
                            checkbox.invoke()
                            start[0]()
                        self.assertEqual(len(launched), 1)
                        args = friends.parse_options(launched[0])
                        self.assertFalse(args.breacher)
                        self.assertTrue(args.breacher_requested_off)
                        self.assertEqual(args.vr, vr)
                        self.assertNotIn('--breacher', launched[0])
                finally:
                    window.destroy()

    def test_workspace_stale_consent_and_changed_selection_block_launch(self):
        window = object.__new__(gui.Launcher)
        window.context = gui.parse_context(['--workspace', 'checkout'])
        with patch('release_state.selected_release', return_value=(gui.ROOT.resolve(), {})), \
                patch('release_state.verify_workspace', side_effect=RuntimeError('source changed')), \
                patch.object(gui.messagebox, 'askyesno', return_value=False) as consent:
            self.assertFalse(window.allow_workspace_launch())
            consent.assert_called_once()
        with patch('release_state.selected_release', return_value=(Path('other'), {})), \
                patch.object(gui.messagebox, 'showerror') as error:
            self.assertFalse(window.allow_workspace_launch())
            error.assert_called_once()


if __name__ == '__main__':
    unittest.main()
