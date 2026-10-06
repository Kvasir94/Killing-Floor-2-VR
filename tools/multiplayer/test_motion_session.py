"""Offline capture launch contracts; never starts runtime or writes motion clips."""
from pathlib import Path
import tempfile
import unittest

import friends
import motion_session
import promo_session


class MotionSessionTests(unittest.TestCase):
    def roles(self, root):
        return [dict(role='driver', native_adapter=True, args=['-kf2vr-stereo'], log=str(root/'driver/game.log')),
                dict(role='server', native_adapter=False, server_adapter=True, args=[], log=str(root/'server/game.log'))]

    def test_independent_switches_share_promo_identity_and_only_record_player(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for motion in (False, True):
                for highlights in (False, True):
                    with self.subTest(motion=motion, highlights=highlights):
                        roles = self.roles(root)
                        promo = promo_session.configure(roles, highlights)
                        capture = motion_session.configure(roles, motion)
                        driver, server = [friends.role_environment({}, role) for role in roles]
                        self.assertEqual('KF2VR_RECORD_MOTION' in driver, motion)
                        self.assertNotIn('KF2VR_RECORD_MOTION', server)
                        self.assertEqual('KF2VR_PROMO_SESSION' in driver, highlights)
                        self.assertEqual('KF2VR_PROMO_SESSION' in server, highlights)
                        if capture:
                            self.assertEqual(capture['capture_session_id'], driver['KF2VR_CAPTURE_SESSION_ID'])
                            self.assertEqual(capture['capture_session_started_utc'], driver['KF2VR_CAPTURE_SESSION_STARTED_UTC'])
                            if highlights:
                                self.assertEqual(promo, capture['capture_session_id'])
                                self.assertEqual(promo, server['KF2VR_CAPTURE_SESSION_ID'])
                        else:
                            self.assertFalse(driver.get('KF2VR_CAPTURE_SESSION_ID'))
            self.assertEqual([], list(root.iterdir()), 'Preparing capture must not create output files')

    def test_off_clears_previous_role_state_and_inherited_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            roles = self.roles(Path(temporary))
            motion_session.configure(roles, True)
            self.assertIsNone(motion_session.configure(roles, False))
            for role in roles:
                env = friends.role_environment({'PATH': 'preserved', 'kf2vr_record_motion': '1',
                    'KF2VR_MOTION_SESSION_DIR': 'old', 'KF2VR_CAPTURE_SESSION_ID': 'old'}, role)
                self.assertFalse(any('MOTION' in key.upper() or 'CAPTURE' in key.upper() for key in env))
                self.assertEqual('preserved', env['PATH'])

    def test_invalid_output_and_nonlive_role_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            roles = self.roles(Path(temporary))
            motion_session.configure(roles, True)
            for changes in ({'motion_session_dir': 'elsewhere'}, {'capture_session_id': 'bad'},
                            {'capture_session_started_utc': 'bad'}, {'args': ['-kf2vr-hand-replay']}):
                with self.subTest(changes=changes), self.assertRaises(ValueError):
                    motion_session.environment({**roles[0], **changes})
            with self.assertRaises(ValueError):
                motion_session.configure([roles[1]], True)

    def test_cli_defaults_explicit_off_and_live_vr_validation(self):
        args = friends.parse_options(['--solo', '--vr'])
        self.assertFalse(args.record_motion or args.promo_events)
        for feature in ('record-motion', 'promo-events'):
            args = friends.parse_options(['--solo', '--vr', '--' + feature, '--no-' + feature])
            self.assertFalse(getattr(args, feature.replace('-', '_')))
            for mode in (['--solo', '--desktop'], ['--host', '--vr', '--replay-teammate']):
                with self.subTest(feature=feature, mode=mode), self.assertRaises(RuntimeError):
                    friends.validate_play_mode(friends.parse_options([*mode, '--' + feature]))


if __name__ == '__main__':
    unittest.main()
