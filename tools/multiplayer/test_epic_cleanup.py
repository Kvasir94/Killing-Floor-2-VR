"""Epic process ownership and native-file restoration, without launching a game."""
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, call, patch

from epic_broker import EpicBroker
import epic_manual
from native_fixture import NativeDeployment
from session import digest


def observed_broker(states):
    broker = EpicBroker.__new__(EpicBroker)
    broker.ticket = SimpleNamespace(owner=object())
    broker.owner_handle = 41
    broker._observed = list(range(41, 41 + len(states)))
    broker.kernel = SimpleNamespace(WaitForSingleObject=Mock(side_effect=states))
    return broker


class EpicOwnershipTests(unittest.TestCase):
    def test_wait_distinguishes_running_and_exited_on_the_held_handle(self):
        broker = observed_broker([258, 0])
        self.assertTrue(epic_manual.owner_running(broker, 250))
        self.assertFalse(epic_manual.owner_running(broker, 250))
        self.assertEqual([call(41, 250), call(41, 250)],
                         broker.kernel.WaitForSingleObject.call_args_list)

    def test_unknown_wait_results_do_not_establish_exit(self):
        for state in (0xffffffff, 128, 1):
            with self.subTest(state=state):
                with self.assertRaisesRegex(OSError, 'native files retained'):
                    epic_manual.owner_running(observed_broker([state]))

    def test_unclaimed_or_missing_handle_cannot_establish_exit(self):
        for missing in ('owner', 'handle'):
            broker = observed_broker([0])
            if missing == 'owner':
                broker.ticket.owner = None
            else:
                broker.owner_handle = None
            with self.assertRaisesRegex(RuntimeError, 'No authenticated'):
                epic_manual.owner_running(broker)
            broker.kernel.WaitForSingleObject.assert_not_called()

    def test_diagnostic_options_remain_unavailable(self):
        for option in ('duration', 'local_test_control'):
            args = SimpleNamespace(recover_epic=False, solo=True, vr=True,
                host=False, address=None, single_pass=False, record_motion=False,
                promo_events=False, local_test_control=False, replay_teammate=False,
                avatar_preview=False, locomotion_preview=False, duration=None)
            setattr(args, option, 30 if option == 'duration' else True)
            with self.assertRaisesRegex(RuntimeError, 'diagnostic sessions are unavailable'):
                epic_manual.validate_options(args)


class EpicNativeCleanupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        source, self.destination = root/'source', root/'game'
        source.mkdir()
        self.destination.mkdir()
        for name in ('dinput8.dll', 'openxr_loader.dll'):
            (source/name).write_bytes(('owned '+name).encode())
        (self.destination/'openxr_loader.dll').write_bytes(b'original loader')
        receipt = {'artifacts_sha256': {p.name: digest(p) for p in source.iterdir()}}
        self.deployment = NativeDeployment(source, self.destination, root/'backup', receipt, digest)
        self.deployment.install()
        self.installed = {p.name: p.read_bytes() for p in self.destination.iterdir()}

    def assert_installed_files_retained(self):
        self.assertEqual(self.installed,
                         {p.name: p.read_bytes() for p in self.destination.iterdir()})

    def test_live_broker_blocks_restore_even_without_observed_peers(self):
        broker = observed_broker([])
        with patch.object(epic_manual, 'no_game') as no_game:
            with self.assertRaisesRegex(RuntimeError, 'handoff is still active'):
                epic_manual.restore_native_files(self.deployment, broker,
                    SimpleNamespace(is_alive=lambda: True))
        no_game.assert_not_called()
        self.assert_installed_files_retained()

    def test_live_or_unverifiable_observed_peer_preserves_installed_files(self):
        for state in (258, 0xffffffff, 128):
            broker = observed_broker([0, state])
            # A failed authentication still leaves an OS-observed peer to fence.
            broker.ticket.owner = None
            with self.subTest(state=state), patch.object(epic_manual, 'no_game') as no_game:
                with self.assertRaisesRegex(RuntimeError, 'observed Epic peers'):
                    epic_manual.restore_native_files(self.deployment, broker,
                        SimpleNamespace(is_alive=lambda: False))
                no_game.assert_not_called()
                self.assert_installed_files_retained()

    def test_unobserved_game_still_blocks_restore_after_peer_exit(self):
        with patch.object(epic_manual, 'no_game', side_effect=RuntimeError('another game')):
            with self.assertRaisesRegex(RuntimeError, 'another game'):
                epic_manual.restore_native_files(self.deployment, observed_broker([0]))
        self.assert_installed_files_retained()

    def test_verified_exit_restores_original_files_and_removes_only_owned_proxy(self):
        with patch.object(epic_manual, 'no_game') as no_game:
            epic_manual.restore_native_files(self.deployment, observed_broker([0, 0]),
                SimpleNamespace(is_alive=lambda: False))
        no_game.assert_called_once_with()
        self.assertFalse((self.destination/'dinput8.dll').exists())
        self.assertEqual(b'original loader',
                         (self.destination/'openxr_loader.dll').read_bytes())

    def test_partial_install_before_broker_creation_can_restore(self):
        with patch.object(epic_manual, 'no_game'):
            epic_manual.restore_native_files(self.deployment)
        self.assertFalse((self.destination/'dinput8.dll').exists())

    def test_restore_error_is_not_reported_as_success(self):
        deployment = SimpleNamespace(restore=Mock(return_value=['owned file changed']))
        with patch.object(epic_manual, 'no_game'):
            with self.assertRaisesRegex(RuntimeError, 'owned file changed'):
                epic_manual.restore_native_files(deployment, observed_broker([0]))


if __name__ == '__main__':
    unittest.main()
