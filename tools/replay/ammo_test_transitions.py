"""Callback/parser fixtures only; these strings are never runtime evidence."""
import unittest

from ammo_transition_analyze import audit


def trace(body='', finish=True):
    # Match the emitted ReloadObserver shape; callback bodies occur before its
    # final observation-only row. These remain parser fixtures, not game logs.
    start = ('KF2VR_RELOAD_TRACE case=case seq=1 phase=input elapsed=0 buttons=0 grips=0 '
             'triggers=0 valid=3 roomEpoch=0 left=0,0,0 right=0,0,0 '
             'leftRotation=0,0,0 rightRotation=0,0,0 leftHand=0,0,0 rightHand=0,0,0 '
             'leftRoom=0,0,0 rightRoom=0,0,0\n'
             'KF2VR_RELOAD_TRACE case=case seq=2 phase=state elapsed=0 slot=1 weapon=World.Gun '
             'pawn=World.Pawn world=World.WorldInfo owner=World.Pawn primary=1 support=-1 '
             'carryPrimary=-1 ownership=1 current=True loaded=1 reserve=75 stockState=Active '
             'feed=7 chamberLoaded=True magOut=True mechanismPending=0 mesh=World.Gun.Mesh '
             'attached=True physical=True awaitAmmo=True awaitRack=False guide=0 rackPull=0\n')
    end = ('KF2VR_RELOAD_TRACE case=case seq=3 phase=complete '
           'status=UNTESTED reason=observation-ended acceptance=False\n')
    return start + body + (end if finish else '')


def callback(seq, call, phase, **overrides):
    values = dict(case='case', seq=seq, call=call, phase=phase,
                  function='VRInteractiveReload.Seat', source='production', weapon='World.Gun',
                  action='insert', accepted='False', loaded=1, reserve=75, escrow=13,
                  shots=1, grants=0, discarded=0, commits=0, owed='False', progress=0,
                  primary=1, support=-1, chamberLoaded='True', magOut='True', feed=7,
                  solicited='True', occupied='False', receipt=0)
    values.update(overrides)
    return 'KF2VR_RELOAD_CALLBACK '+' '.join(f'{k}={v}' for k, v in values.items())+'\n'


def pair(**after):
    return callback(1, 1, 'before') + callback(2, 1, 'after', **after)


class CallbackParserTests(unittest.TestCase):
    def test_no_samples_and_missing_callbacks_are_untested(self):
        for text in ('', trace()):
            result = audit(text, 'case')
            self.assertEqual('UNTESTED', result['status'])
            self.assertFalse(result['observed_invariants'])

    def test_known_observed_accounting_is_finite_not_headset_acceptance(self):
        result = audit(trace(pair(accepted='True', loaded=14, escrow=0, commits=1, receipt=99)),
                       'case', ['VRInteractiveReload.Seat'])
        self.assertEqual('OBSERVED', result['status'], result)
        for key in ('full_reload_accepted', 'headset_accepted', 'multiplayer_accepted'):
            self.assertFalse(result[key])

    def test_unknown_never_becomes_zero_or_success(self):
        result = audit(trace(pair(escrow='Unknown')), 'case')
        self.assertEqual('UNTESTED', result['status'], result)
        self.assertIn('counter:escrow', result['missing'])

    def test_duplication_loss_invalid_order_and_unbound_identity_fail(self):
        initial = callback(1, 1, 'before')
        cases = [pair(loaded=2), pair(reserve=74),
                 pair(weapon='World.Other'), pair().replace('phase=after', 'phase=other'),
                 callback(1, 1, 'after'),
                 initial+callback(2, 2, 'before')+callback(3, 1, 'after'),
                 pair(commits=2, accepted='True', receipt=1),
                 pair(commits=1), pair(loaded='NaN'),
                 pair(progress='nan'), pair(support=5)]
        for text in cases:
            with self.subTest(text=text):
                self.assertEqual('FAILED', audit(trace(text), 'case')['status'])

    def test_pending_return_and_required_order_are_not_acceptance(self):
        for text, required in ((trace(callback(1, 1, 'before')), ()),
                               (trace(pair()), ['Missing.Callback']),
                               (trace(pair(), finish=False), ()),
                               (pair(), ())):
            result = audit(text, 'case', required)
            self.assertEqual('UNTESTED', result['status'], result)

    def test_unsolicited_reload_and_occupied_feed_reject(self):
        for action, field in (('reload', 'solicited'), ('insert', 'occupied')):
            values = {field: 'False' if field == 'solicited' else 'True', 'action': action}
            text = trace(callback(1, 1, 'before', **values)
                         +callback(2, 1, 'after', **values, accepted='True', receipt=4))
            self.assertEqual('FAILED', audit(text, 'case')['status'])

    def test_duplicate_accepted_receipt_and_role_loss_fail(self):
        duplicate = trace(pair(accepted='True', receipt=4)
                          +callback(3, 2, 'before')+callback(4, 2, 'after', accepted='True', receipt=4))
        self.assertEqual('FAILED', audit(duplicate, 'case')['status'])
        for after in ({'owed':'False', 'progress':0.4}, {'owed':'True', 'progress':0}):
            text = trace(callback(1, 1, 'before', action='role', owed='True', progress=0.4)
                         +callback(2, 1, 'after', action='role', **after))
            self.assertEqual('FAILED', audit(text, 'case')['status'])

    def test_explicit_grants_discards_and_nesting_reconcile(self):
        text = trace(callback(1, 1, 'before', action='grant')
                +callback(2, 2, 'before', action='role')
                +callback(3, 2, 'after', action='role')
                +callback(4, 1, 'after', action='grant', reserve=80, grants=5)
                +callback(5, 3, 'before', action='discard', reserve=80, grants=5)
                +callback(6, 3, 'after', action='discard', reserve=80, grants=5,
                          escrow=12, discarded=1))
        self.assertEqual('OBSERVED', audit(text, 'case')['status'])

    def test_runtime_warnings_and_duplicate_fields_fail(self):
        for text in (trace(pair())+'ScriptWarning: Accessed None',
                     trace(pair().replace('loaded=1', 'loaded=1 loaded=1')),
                     trace(pair().replace('seq=2 call', 'seq=1 call'))):
            self.assertEqual('FAILED', audit(text, 'case')['status'])

    def test_reviewer_failed_complete_then_callbacks_cannot_be_observed(self):
        text = trace().replace('status=UNTESTED', 'status=FAILED').replace('acceptance=False', 'acceptance=True') + pair()
        result = audit(text, 'case')
        self.assertEqual('FAILED', result['status'], result)
        self.assertFalse(result['observed_invariants'])
        self.assertIn('Production callback after terminal completion', result['errors'])

    def test_exactly_one_observation_only_terminal_row_is_required(self):
        good = trace(pair())
        terminal = good.splitlines(keepends=True)[-1]
        cases = [good.replace('status=UNTESTED', 'status=FAILED'),
                 good.replace('acceptance=False', 'acceptance=True'),
                 good.replace('status=UNTESTED ', ''),
                 good.replace('acceptance=False', ''),
                 good+terminal, terminal+good, trace()+pair(),
                 good+good.splitlines(keepends=True)[0]]
        for text in cases:
            with self.subTest(text=text):
                result = audit(text, 'case')
                self.assertEqual('FAILED', result['status'], result)
                self.assertFalse(result['observed_invariants'])

    def test_trace_schema_case_and_exact_identity_are_validated(self):
        good = trace(pair())
        cases = [good.replace('phase=input ', ''),
                 good.replace('phase=input', 'phase=bogus'),
                 good.replace('case=case', 'case=other', 1),
                 good.replace('case=case ', '', 1),
                 good.replace('buttons=0 ', ''),
                 good.replace('attached=True', 'attached=Unknown'),
                 good.replace('ownership=1 ', ''),
                 good.replace('weapon=World.Gun', 'weapon=None'),
                 good.replace('weapon=World.Gun', 'weapon=Gun'),
                 good.replace('weapon=World.Gun', 'weapon=.'),
                 good.replace('pawn=World.Pawn ', ''),
                 good.replace('left=0,0,0', 'left=0,NaN,0'),
                 good.replace('guide=0', 'guide=NaN'),
                 good.replace('phase=state', 'owed=NaN phase=state')]
        for text in cases:
            with self.subTest(text=text):
                self.assertEqual('FAILED', audit(text, 'case')['status'])

    def test_trace_and_callback_orders_are_both_monotonic(self):
        good = trace(pair())
        cases = [good.replace('seq=2 phase=state', 'seq=1 phase=state'),
                 good.replace('seq=3 phase=complete', 'seq=4 phase=complete'),
                 good.replace('elapsed=0 slot=1', 'elapsed=-1 slot=1'),
                 good.replace('seq=1 call=1', 'seq=2 call=1'),
                 good.replace('call=1', 'call=3')]
        for text in cases:
            with self.subTest(text=text):
                self.assertEqual('FAILED', audit(text, 'case')['status'])

    def test_matching_callback_identity_requires_preceding_state(self):
        wrong = trace(pair().replace('weapon=World.Gun', 'weapon=World.Other'))
        self.assertEqual('FAILED', audit(wrong, 'case')['status'])
        late = pair() + trace()
        self.assertEqual('UNTESTED', audit(late, 'case')['status'])

    def test_recovery_and_geometry_wire_shapes_are_checked(self):
        recovery = ('KF2VR_RELOAD_TRACE case=case seq=3 phase=recovery hand=0 active=False '
                    'claimed=False request=0 token=0 guide=False requireFresh=False queuedAction=0 '
                    'remaining=0 source=None target=None origin=0,0,0 handBusy=False hipBusy=False\n')
        geometry = ('KF2VR_RELOAD_TRACE case=case seq=4 phase=geometry weapon=World.Gun '
                    'entry=0,0,0 seat=0,0,0 entryLocal=0,0,0 seatLocal=0,0,0 '
                    'insertTime=0.5 insertEnd=1 carryTime=0.4 cylinderFrame=None\n')
        good = trace(pair()+recovery+geometry).replace('seq=3 phase=complete', 'seq=5 phase=complete')
        self.assertEqual('OBSERVED', audit(good, 'case')['status'])
        for text in (good.replace('request=0 ', ''),
                     good.replace('origin=0,0,0', 'origin=0,0'),
                     good.replace('insertTime=0.5', 'insertTime=nan'),
                     good.replace('phase=geometry weapon=World.Gun', 'phase=geometry weapon=World.Other')):
            with self.subTest(text=text):
                self.assertEqual('FAILED', audit(text, 'case')['status'])


if __name__ == '__main__':
    unittest.main()
