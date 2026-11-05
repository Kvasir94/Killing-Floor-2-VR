"""Adversarial payload parser fixtures, never engine or gameplay evidence."""
import unittest
from ammo_payload_analyze import audit


def sample(seq, escrow, tokens):
    return (f'KF2VR_AMMO_OBSERVER phase=sample case=normal seq={seq} escrow={escrow} '
            f'tokens={tokens} source=authority worldWeapons=False\n')


def payload(seq=1, token=7, remaining=13, retired=False, present=True, weapon='Gun_1'):
    return (f'KF2VR_AMMO_PAYLOAD seq={seq} registry=Registry_0 token={token} weapon={weapon} '
            f'remaining={remaining} retired={retired} carrier=None hand=-1 '
            f'propPresent={present} propRounds={remaining if present else -1} meshBound={present}\n')


class PayloadParserTests(unittest.TestCase):
    def test_real_remaining_is_reconciled_without_broad_acceptance(self):
        result = audit(sample(1,13,1)+payload(),'normal')
        self.assertTrue(result['counts_consistent'],result)
        self.assertEqual(13,result['reconciled'][0]['ledger_remaining'])
        for key in ('full_reload_accepted','recovery_accepted','lifecycle_accepted',
                    'rendered_ejection_accepted','headset_accepted'):
            self.assertFalse(result[key])

    def test_missing_cosmetic_prop_does_not_destroy_paid_ammo(self):
        result = audit(sample(1,13,1)+payload(present=False),'normal')
        self.assertTrue(result['counts_consistent'],result)
        self.assertEqual([['Registry_0',7]],result['missing_prop_identities'])

    def test_carrier_release_preserves_budget_and_retirement_is_explicit(self):
        text = (sample(1,13,1)+payload().replace('carrier=None hand=-1','carrier=Pawn_0 hand=0')
                +sample(2,13,1)+payload(seq=2)
                +sample(3,0,0)+payload(seq=3,remaining=0,retired=True,present=False))
        self.assertTrue(audit(text,'normal')['counts_consistent'])

    def test_double_count_refill_retarget_and_resurrection_refuse(self):
        initial = sample(1,13,1)+payload()
        cases = [initial+payload(), initial.replace('escrow=13','escrow=26'),
                 initial+sample(2,14,1)+payload(seq=2,remaining=14),
                 initial+sample(2,13,1)+payload(seq=2,weapon='Different_1'),
                 initial+sample(2,0,0)+payload(seq=2,remaining=0,retired=True,present=False)
                 +sample(3,0,1)+payload(seq=3,remaining=0)]
        for text in cases:
            with self.subTest(text=text): self.assertFalse(audit(text,'normal')['counts_consistent'])

    def test_lost_token_mismatched_prop_and_unanchored_rows_refuse(self):
        initial = sample(1,13,1)+payload()
        for text in ('',payload(),initial+sample(2,0,0),
                     initial.replace('propRounds=13','propRounds=12'),
                     initial.replace('carrier=None hand=-1','carrier=Pawn_0 hand=-1'),
                     initial.replace('retired=False','retired=True'),
                     initial.replace('remaining=13','remaining=NaN'),
                     initial.replace('token=7','token=7 token=7')):
            with self.subTest(text=text): self.assertFalse(audit(text,'normal')['counts_consistent'])

    def test_registry_identity_and_exclusive_carrier_hands(self):
        text = sample(1,26,2)+payload()+payload().replace('Registry_0','Registry_1')
        self.assertTrue(audit(text,'normal')['counts_consistent'])
        duplicate_hand = text.replace('carrier=None hand=-1','carrier=Pawn_0 hand=0')
        self.assertFalse(audit(duplicate_hand,'normal')['counts_consistent'])


if __name__ == '__main__':
    unittest.main()
