import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import zlib
from melee_runtime_launcher import bmp_to_png, runtime_evidence, EXPECTATIONS

def bmp24():
    # Two rows: top red, bottom blue. BMP stores the bottom row first.
    pixels = b'\xff\0\0\0' + b'\0\0\xff\0'
    return (b'BM'+struct.pack('<IHHI',54+len(pixels),0,0,54)
            +struct.pack('<IiiHHIIiiII',40,1,2,1,24,0,len(pixels),0,0,0,0)+pixels)

class RuntimeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        root=Path(self.temp.name);raw=root/'shot.bmp';raw.write_bytes(bmp24())
        self.capture=root/'shot.png';bmp_to_png(raw,self.capture)
        server=[];driver=[];observer=[]
        for i,(_,kind,loss) in enumerate(EXPECTATIONS):
            target=f'target{i}'
            server.extend([f'KF2VR_MELEE_FIXTURE phase=precondition perk=KFGame.KFPerk_Commando level=25',
                           f'KF2VR_MELEE_FIXTURE phase=case case={i} target={target}',
                           f'KF2VR_MELEE_FIXTURE phase=placed case={i} target={target} success=True',
                           f'KF2VR_MELEE_FIXTURE phase=complete case={i} target={target}'])
            driver.extend([f'KF2VR_MELEE_FIXTURE phase=authored case={i} speed=600',
                           f'KF2VR_MELEE_FIXTURE phase=sampling case={i} supported=false',
                           f'KF2VR_MELEE_FIXTURE phase=finished case={i}',
                           f'KF2VR_MELEE_FIXTURE phase=gap case={i} rejected_before=0 rejected_after=2 gap_authored={str(i==3).lower()}'])
            for receipt in (1,2):
                before=1000-(receipt-1)*loss;after=before-loss
                server.extend([f'KF2VR_MELEE_FIXTURE phase=impact target={target} type={kind} upgrade=0 volume_scale=1 bone=Spine',
                               f'KF2VRNet target_damage target={target} receipt={receipt} before={before} after={after} damage=999 damage_type={kind} netmode=1'])
                observer.append(f'KF2VRNet target_state target={target} receipt={receipt} health={after} netmode=3')
            for stage,receipt in ((1,1),(2,1),(3,2)):
                h=1000-receipt*loss
                server.append(f'KF2VR_MELEE_FIXTURE phase=health case={i} stage={stage} target={target} health={h} receipts={receipt}')
                observer.append(f'KF2VR_MELEE_OBSERVER case={i} marker={i*10+stage} target={target} health={h} receipts={receipt} netmode=3')
        self.server='\n'.join(server);self.driver='\n'.join(driver);self.observer='\n'.join(observer)
        self.captures=[self.capture]*12
    def result(self,**changes):
        data=dict(server=self.server,driver=self.driver,observer=self.observer,captures=self.captures);data.update(changes)
        # Transport has its own existing tests; these exercise only this analyzer.
        with patch('melee_runtime_launcher.verify_transport',return_value={'passed':True}):
            return runtime_evidence(**data)
    def test_complete_health_and_sampled_gap(self):
        self.assertTrue(self.result()['passed'])
    def test_no_actual_gap_cannot_pass(self):
        self.assertFalse(self.result(driver=self.driver.replace('rejected_after=2','rejected_after=0'))['passed'])
    def test_unpositioned_target_cannot_pass(self):
        self.assertFalse(self.result(server=self.server.replace('success=True','success=False'))['passed'])
    def test_gap_must_not_deal_extra_damage(self):
        self.assertFalse(self.result(server=self.server.replace('stage=2 target=target3 health=826','stage=2 target=target3 health=652'))['passed'])
    def test_independent_capture_must_match_health(self):
        self.assertFalse(self.result(observer=self.observer.replace('marker=33 target=target3 health=652','marker=33 target=target3 health=826'))['passed'])
        self.assertFalse(self.result(captures=self.captures[:-1])['passed'])
    def test_non_neutral_and_upgraded_context_fails(self):
        self.assertFalse(self.result(server=self.server+'\nKF2VR_MELEE_FIXTURE phase=blocked reason=nonneutral_perk')['passed'])
        self.assertFalse(self.result(server=self.server.replace('upgrade=0','upgrade=1'))['passed'])
    def test_malformed_damage_conditions_fail_closed(self):
        self.assertFalse(self.result(server=self.server.replace('volume_scale=1','volume_scale=garbled'))['passed'])
    def test_lossless_bmp_row_order(self):
        data=self.capture.read_bytes();cursor=8;payload=b''
        while cursor<len(data):
            count=struct.unpack_from('>I',data,cursor)[0];kind=data[cursor+4:cursor+8]
            if kind==b'IDAT':payload+=data[cursor+8:cursor+8+count]
            cursor+=count+12
        self.assertEqual(zlib.decompress(payload),b'\0\xff\0\0\0\0\0\xff')
    def test_compressed_or_truncated_bmp_is_rejected(self):
        p=Path(self.temp.name)/'bad.bmp';b=bytearray(bmp24());struct.pack_into('<I',b,30,1);p.write_bytes(b)
        with self.assertRaises(ValueError):bmp_to_png(p,self.capture)
        p.write_bytes(bmp24()[:-5])
        with self.assertRaises(ValueError):bmp_to_png(p,self.capture)

if __name__=='__main__':unittest.main()
