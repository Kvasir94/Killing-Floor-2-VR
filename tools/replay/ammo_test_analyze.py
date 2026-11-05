"""Adversarial log-parser tests; fixtures are parser inputs, never game evidence."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'multiplayer'))
from test_reload_replay import rows as driver_rows
from ammo_analyze import analyze


def sample(seq, loaded, reserve, escrow, shots, tokens, case='normal'):
    return (f'KF2VR_AMMO_OBSERVER phase=sample case={case} seq={seq} baseline=105 '
            f'loaded={loaded} reserve={reserve} escrow={escrow} shots={shots} tokens={tokens} '
            'mismatch=0 source=authority nativeCapability=9 worldWeapons=False')


def good():
    return '\n'.join([sample(1,15,90,0,0,0), sample(2,14,90,0,1,0),
                      sample(3,1,90,13,1,1), driver_rows()])


class AmmoParserTests(unittest.TestCase):
    def test_pre_ready_setup_identity_is_not_a_post_ready_weapon_switch(self):
        setup = ('KF2VR_RELOAD_OBSERVER phase=setup case=normal reason=waiting '
                 'hand=1 identity=None weaponClass=None stage=empty\n')
        result = analyze(setup+good(), 'normal')
        self.assertTrue(result['passed'],result)

    def test_post_ready_weapon_switch_still_fails(self):
        self.assertFalse(analyze(good().replace('identity=Weapon_1 weaponClass',
                                               'identity=Other weaponClass'), 'normal')['passed'])

    def test_paid_escrow_conserves_and_keeps_acceptance_bounded(self):
        result = analyze(good(), 'normal')
        self.assertTrue(result['passed'], result)
        for k in ('full_reload_accepted', 'recovery_accepted', 'rendered_ejection_accepted',
                  'multiplayer_accepted', 'headset_accepted'):
            self.assertFalse(result[k])

    def test_escrow_cannot_be_copied_destroyed_or_double_counted(self):
        for amount in (0,12,14,26):
            with self.subTest(amount=amount):
                self.assertFalse(analyze(good().replace('escrow=13', f'escrow={amount}'), 'normal')['passed'])

    def test_missing_malformed_duplicate_or_inconsistent_samples_fail(self):
        for text in ('', driver_rows(), good().replace('seq=2','seq=1'),
                     good().replace('loaded=1 reserve','loaded=-1 reserve'),
                     good().replace('escrow=13','escrow=NaN'),
                     good().replace('mismatch=0','mismatch=1'),
                     good().replace('source=authority','source=mock'),
                     good().replace('baseline=105 loaded=1','baseline=106 loaded=1'),
                     good().replace('worldWeapons=False','worldWeapons=True'),
                     good().replace('nativeCapability=9','nativeCapability=7'),
                     good().replace('seq=3','seq=3 seq=3'),
                     good().replace('passed=True','passed=False')):
            with self.subTest(text=text):
                self.assertFalse(analyze(text, 'normal')['passed'])

    def test_dual_requires_real_driver_both_hands_and_two_payloads(self):
        text = '\n'.join([sample(1,30,75,0,0,0,'dual'), sample(2,2,75,26,2,2,'dual'),
                          driver_rows('dual',(0,1))])
        self.assertTrue(analyze(text,'dual')['passed'])
        self.assertFalse(analyze(text.replace('tokens=2','tokens=1'),'dual')['passed'])
        self.assertFalse(analyze(text,'normal')['passed'])


if __name__ == '__main__':
    unittest.main()
