"""Cylinder log identity, receipt ordering and conservation regressions."""
import unittest
from revolver_analyze import analyze
from run import plan_batch


def observed(replacement=True):
    case=plan_batch(['1858'],['revolver-hip'],['normal'])[0]
    case['lose_ammo']=replacement
    policy='paid-replacement' if replacement else 'stock-deficit-top-up'
    final_reserve=24 if replacement else 29
    remaining=0 if replacement else 5
    identity=case['lifecycle_case']; rows=[]; seq=0; call=0
    cls='KFGameContent.KFWeap_Revolver_Rem1858'; weapon='World.KFWeap_Revolver_Rem1858_0'
    def path(phase,loaded,reserve,extra=''):
        nonlocal seq
        seq+=1
        shots=int(phase!='initial')
        escrow=5 if replacement and phase in ('opened','contact','closing','paid','settled','retry') else 0
        rows.append(f'KF2VR_REVOLVER_PATH case={identity} seq={seq} phase={phase} hand=1 weapon={weapon} '
                    f'weaponClass={cls} selectedClass={cls} selectedFamilyClass={cls} pairSingleClass={cls} '
                    f'memberClass={cls} pawn=World.Player_0 world=World ownership=2 keep=True lose={replacement} recover=True '
                    f'optionEffect=ammo-loss reloadPolicy={policy} loaded={loaded} reserve={reserve} '
                    f'capacity=6 firedRounds={shots} paymentRequest=0 paymentSession=0 physicalActive=False '
                    f'bridgeRequestSerial=0 nativeRetrySeen=True '+extra)
        rows.append(f'KF2VR_REVOLVER_LEDGER case={identity} seq={seq} phase={phase} '
                    f'loaded={loaded} reserve={reserve} shots={shots} escrow={escrow} tokens={int(escrow>0)} mismatch=0')
    def callback(function,phase,number,loaded=remaining,reserve=30,extra=''):
        sequence=sum('KF2VR_RELOAD_CALLBACK ' in r for r in rows)+1
        rows.append(f'KF2VR_RELOAD_CALLBACK case={identity} seq={sequence} call={number} phase={phase} '
                    f'function=KF2VR.{function} weapon={weapon} action=reload source=production '
                    f'accepted={"True" if phase=="after" else "Unknown"} receipt=0 loaded={loaded} reserve={reserve} '+extra)
    path('initial',6,30)
    path('shot',5,30,'rounds=1')
    path('admitted',5,30); path('opened',remaining,30)
    callback('VRCylinderSession.Tick','before',1)
    callback('VRCylinderSession.Tick','after',1,extra='boundary=seat-contact hip=True hand=1')
    path('contact',remaining,30,'call=1')
    callback('VRCylinderSession.Complete','before',2)
    path('closing',remaining,30)
    callback('VRCylinderSession.Complete','after',2,6,final_reserve,'boundary=single-payment synchronous=True')
    path('paid',6,final_reserve,'call=2'); path('settled',6,final_reserve); path('retry',6,final_reserve,'stable=True rejected=True')
    seq+=1
    rows.extend((f'KF2VR_REVOLVER_PATH case={identity} seq={seq} phase=complete hand=-1 keep=True lose={replacement} recover=True '
                 f'optionEffect=ammo-loss reloadPolicy={policy} passed=True reason=real-revolver-hip-completed',
                 f'KF2VR_REVOLVER_LEDGER case={identity} seq={seq} phase=complete loaded=6 reserve={final_reserve} shots=1 escrow={5 if replacement else 0} tokens={int(replacement)} mismatch=0'))
    return case,'\n'.join(rows)


class RevolverLogTests(unittest.TestCase):
    def test_real_path_has_finite_scope(self):
        case,text=observed(); result=analyze(text,case)
        self.assertTrue(result['bounded_case_passed'],result)
        self.assertFalse(result['multiplayer_accepted'])

    def test_retained_rounds_use_deficit_payment(self):
        case,text=observed(False)
        self.assertTrue(analyze(text,case)['bounded_case_passed'])

    def test_missing_paid_payload_or_wrong_debit_fails(self):
        case,text=observed()
        for bad in (text.replace('escrow=5','escrow=0'), text.replace('tokens=1','tokens=0'),
                    text.replace('reserve=24','reserve=29'), text.replace('mismatch=0','mismatch=1'),
                    text.replace('reloadPolicy=paid-replacement','reloadPolicy=stock-deficit-top-up')):
            self.assertFalse(analyze(bad,case)['bounded_case_passed'])

    def test_wrong_family_payment_duplicate_and_stuck_fail(self):
        case,text=observed()
        for broken in ('',text.replace('pairSingleClass=KFGameContent.KFWeap_Revolver_Rem1858','pairSingleClass=Wrong'),
                       text.replace('ownership=2','ownership=3',1),text.replace('receipt=0','receipt=1',1),
                       text.replace('shots=1','shots=0'),text.replace('hip=True','hip=False'),
                       text.replace('synchronous=True','synchronous=False'),text.replace('rejected=True','rejected=False'),
                       text.replace('passed=True','passed=False'),text+'\n'+next(r for r in text.splitlines() if 'phase=after' in r)):
            with self.subTest(tail=broken[-100:]): self.assertFalse(analyze(broken,case)['bounded_case_passed'])


if __name__=='__main__': unittest.main()
