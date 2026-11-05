"""Offline launch configuration and log parser checks. No runtime is launched."""
from pathlib import Path
import tempfile
import unittest

from physical_reload import analyze, configure
from session import read_ini, config_hashes
from vr_config import values


def logs():
    identity = 'world=10 connection=20 pawn=30 item=4 hand=1 capacity=15 target=w10-c20-p30-reload9mm'
    states = [('ready', 15, 90, 0), ('shot_before', 14, 90, 1), ('physical', 1, 90, 1),
              ('held', 1, 90, 1), ('carried', 1, 90, 1), ('reloaded', 16, 75, 1),
              ('shot_after', 15, 75, 2), ('complete', 15, 75, 2)]
    server = '\n'.join(f'KF2VRNet reload_case role=server phase={phase} {identity} ammo={ammo} '
        f'reserve={reserve} damage={damage} held_seconds=4 netmode=1'
        for phase, ammo, reserve, damage in states if phase != 'carried')
    owner = '\n'.join(f'KF2VRNet reload_case role=owner phase={phase} {identity} ammo={ammo} '
        f'reserve={reserve} damage={damage} netmode=3' for phase, ammo, reserve, damage in states)
    owner += '\nKF2VR_INTERACTIVE_RELOAD phase=complete weapon=KFGameContent.KFWeap_Pistol_9mm ammo=16 paused=4'
    observer = []
    for receipt in (1, 2):
        server += (f'\nKF2VRNet target_damage target=w10-c20-p30-reload9mm receipt={receipt} '
                   f'before={1020 - 20 * receipt} after={1000 - 20 * receipt} damage=20 netmode=1')
        observer.append(f'KF2VRNet target_state target=w10-c20-p30-reload9mm receipt={receipt} health={1000 - 20 * receipt} netmode=3')
    for ammo, shots, reloads in ((15, 0, 0), (14, 1, 0), (1, 2, 1), (16, 2, 1), (15, 3, 1)):
        observer.append(f'KF2VRNet remote_weapon {identity} weapon=KFGameContent.KFWeap_Pistol_9mm '
            f'netmode=3 ready=True muzzle_error=0.1 bore_error=0.2 ammo={ammo} shots={shots} reloads={reloads}')
    return server, owner, '\n'.join(observer)


class PhysicalReloadLogTests(unittest.TestCase):
    def test_complete_independent_observations_pass(self):
        self.assertTrue(analyze(*logs())['passed'])

    def test_missing_duplicate_wrong_role_and_mixed_identity_fail(self):
        good = logs()
        for role in range(3):
            for bad in ('', good[role] + '\n' + good[role], good[role].replace('pawn=30', 'pawn=31'),
                        good[role].replace('netmode=' + ('1' if role == 0 else '3'), 'netmode=0')):
                value = list(good); value[role] = bad
                with self.subTest(role=role, bad=bad[:70]):
                    # Extra remote snapshots may repeat normally; duplicated
                    # owner/authority completion records may never do so.
                    if role == 2 and bad == good[role] + '\n' + good[role]:
                        continue
                    self.assertFalse(analyze(*value)['passed'])

    def test_timer_payment_wrong_reserve_and_missing_physical_finish_fail(self):
        server, owner, observer = logs()
        for changed in (owner.replace('phase=held', 'phase=missing'), owner.replace('ammo=1 reserve=90', 'ammo=16 reserve=75'),
                        owner.replace('reserve=75', 'reserve=76'), owner.replace('INTERACTIVE_RELOAD phase=complete', 'INTERACTIVE_RELOAD phase=ended')):
            self.assertFalse(analyze(server, changed, observer)['passed'])
        self.assertFalse(analyze(server.replace('held_seconds=4', 'held_seconds=3.9'), owner, observer)['passed'])

    def test_server_damage_and_observer_actions_are_required(self):
        server, owner, observer = logs()
        for changed in (observer.replace('target_state', 'missing'), observer.replace('shots=3', 'shots=2'),
                        observer.replace('health=980', 'health=1000'),
                        observer.replace('reloads=1', 'reloads=0'), observer.replace('muzzle_error=0.1', 'muzzle_error=nan'),
                        observer.replace('ready=True', 'ready=False')):
            self.assertFalse(analyze(server, owner, changed)['passed'])
        self.assertFalse(analyze(server.replace('target_damage', 'missing'), owner, observer)['passed'])
        self.assertFalse(analyze(server, owner + '\nScriptWarning: Accessed None', observer)['passed'])


class PhysicalReloadConfigTests(unittest.TestCase):
    def test_isolated_roles_enable_only_owner_input_and_authority_permission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            user = root / 'user.ini'
            user.write_text('[Unrelated]\nKeep=Yes\n', encoding='utf-16')
            before = user.read_bytes()
            roles = []
            for name in ('server', 'driver', 'observer'):
                config = root / name; config.mkdir()
                (config / 'KFGame.ini').write_bytes(before)
                (config / 'KFEngine.ini').write_text('[Engine.Engine]\nbSmoothFrameRate=True\n', encoding='utf-16')
                roles.append(dict(role=name, config_root=str(config), args=['map?VRNet9mm=1']))
            configure(roles)
            for role in roles:
                config = Path(role['config_root'])
                text = read_ini(config / 'KFGame.ini')
                settings = values(text, 'KF2VRNetClient.KF2VRNetHandsBridge')
                self.assertEqual(str(role['role'] == 'driver'), settings['bDiagnostic9mmReload'])
                self.assertEqual('True', settings['bInteractiveReloads'])
                self.assertEqual('False', settings['bWorldWeaponDrops'])
                self.assertEqual('False', values(text, 'KF2VRNet.KF2VRNetPlayerController')['bDiagnosticAutoFire9mm'])
                self.assertEqual('Yes', values(text, 'Unrelated')['Keep'])
                self.assertEqual(config_hashes(config), role['config_hashes'])
            self.assertIn('?VRNet9mmReload=1', roles[0]['args'][0])
            self.assertIn('?VRNet9mm=0', roles[0]['args'][0])
            self.assertIn('-kf2vr-reload-9mm', roles[1]['args'])
            self.assertNotIn('-kf2vr-reload-9mm', roles[2]['args'])
            self.assertEqual(before, user.read_bytes())


if __name__ == '__main__':
    unittest.main()
