"""Adversarial receipt/ledger log analysis, independent of game implementation."""
import unittest
from magazine_analyze import analyze
from run import plan_batch


def observed():
    case = plan_batch(['9mm'], ['magazine-hip'], ['normal'])[0]
    identity = case['lifecycle_case']; rows=[]; seq=0; call=0
    weapon='World.KFWeap_Pistol_9mm_0'
    def path(phase, loaded, reserve, escrow=0, shots=0, extra=''):
        nonlocal seq
        seq+=1
        rows.append(f'KF2VR_MAGAZINE_PATH case={identity} seq={seq} phase={phase} hand=1 weapon={weapon} '
                    f'pawn=World.Player_0 world=World ownership=2 keep=True lose=True recover=True time={seq}.0 '
                    f'loaded={loaded} reserve={reserve} request={1 if seq>=3 else 0} '
                    f'capacity=15 tracksFeed=True hasChamber=True chamberRounds=1 chamberKept={int(seq>=3)} '
                    f'fullExpected=16 firedRounds={int(seq>=2)} '+extra)
        rows.append(f'KF2VR_MAGAZINE_LEDGER case={identity} seq={seq} phase={phase} '
                    f'loaded={loaded} reserve={reserve} escrow={escrow} shots={shots} tokens={int(escrow>0)} mismatch=0')
    def callback(function, extra='', receipt='1', loaded=1, reserve=75):
        nonlocal call
        call+=1
        for phase in ('before','after'):
            number=sum('KF2VR_RELOAD_CALLBACK ' in r for r in rows)+1
            rows.append(f'KF2VR_RELOAD_CALLBACK case={identity} seq={number} call={call} phase={phase} '
                        f'function=KF2VR.{function} weapon={weapon} action=reload source=production '
                        f'accepted={"True" if phase=="after" else "Unknown"} receipt={receipt} '
                        f'loaded={loaded} reserve={reserve} '+extra)
    path('initial',15,75,extra='authoredInput=True measuredHumanInput=False')
    path('shot',14,75,shots=1,extra='rounds=1')
    callback('VRMagazineAuthority.Remove','actual=13 remaining=13')
    path('removal',1,75,13,1,'payload=13')
    callback('VRCylinderSession.Tick','boundary=seat-contact hand=1 hip=True')
    path('contact',1,75,13,1)
    callback('VRCylinderSession.Complete','boundary=single-payment synchronous=True',receipt='0',loaded=16,reserve=60)
    path('seated',16,60,13,1)
    path('retry',16,60,13,1,'stable=True rejected=True')
    seq+=1
    rows += [f'KF2VR_MAGAZINE_PATH case={identity} seq={seq} phase=complete hand=-1 '
             f'keep=True lose=True recover=True time={seq}.0 passed=True reason=real-magazine-hip-completed',
             f'KF2VR_MAGAZINE_LEDGER case={identity} seq={seq} phase=complete loaded=16 reserve=60 escrow=13 shots=1 tokens=1 mismatch=0']
    return case, '\n'.join(rows)


class MagazineLogTests(unittest.TestCase):
    def test_actual_ordered_receipts_and_conservation(self):
        case,text=observed()
        result=analyze(text,case)
        self.assertTrue(result['bounded_case_passed'],result)
        self.assertFalse(result['full_reload_accepted'])

    def test_wrong_identity_duplicate_credit_stuck_and_missing_samples_fail(self):
        case,text=observed()
        for broken in ('', text.replace('ownership=2','ownership=3',1),
                       text.replace('receipt=1','receipt=2',1),
                       text.replace('phase=after','phase=before',1),
                       text.replace('synchronous=True','synchronous=False'),
                       text.replace('escrow=13','escrow=14'),
                       text.replace('payload=13','payload=12'),
                       text.replace('chamberRounds=1','chamberRounds=0'),
                       text.replace('firedRounds=1','firedRounds=2'),
                       text.replace('hip=True','hip=False'),
                       text.replace('keep=True','keep=False',1),
                       text.replace('passed=True','passed=False'),
                       text.replace('stable=True','stable=False'),
                       text+'\n'+next(r for r in text.splitlines() if 'phase=after' in r)):
            with self.subTest(tail=broken[-100:]):
                self.assertFalse(analyze(broken,case)['bounded_case_passed'])


if __name__ == '__main__':
    unittest.main()
