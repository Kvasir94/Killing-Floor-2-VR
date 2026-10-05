import struct
import tempfile
from pathlib import Path
import unittest
from melee_fixture_evidence import analyze

class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.capture=Path(self.temp.name)/"observer.png"
        self.capture.write_bytes(b"\x89PNG\r\n\x1a\n"+struct.pack(">I",13)+b"IHDR"+struct.pack(">II",640,480))
        self.cases=[{"target":"case1","damage_type":"KFGameContent.KFDT_Bludgeon_MaceAndShield_MaceHeavy",
                     "expected_deltas":[157,157],"input":"authored synthetic","observer_captures":[str(self.capture)]}]
        self.server="\n".join(f"KF2VRNet target_damage target=case1 receipt={i} before={before} after={after} damage=175 damage_type=KFGameContent.KFDT_Bludgeon_MaceAndShield_MaceHeavy netmode=1"
                              for i,before,after in ((1,1000,843),(2,843,686)))
        self.observer="\n".join(f"KF2VRNet target_state target=case1 receipt={i} health={health} netmode=3" for i,health in ((1,843),(2,686)))
    def test_authority_and_observer_agree(self):
        self.assertTrue(analyze(self.server,self.observer,self.cases)["passed"])
    def test_requested_damage_is_not_health_loss(self):
        result=analyze(self.server.replace("after=843","after=1000"),self.observer,self.cases)
        self.assertFalse(result["passed"])
        self.assertEqual(result["cases"][0]["actual_deltas"][0],0)
    def test_client_prediction_cannot_replace_authority(self):
        self.assertFalse(analyze(self.server.replace("netmode=1","netmode=3"),self.observer,self.cases)["passed"])
    def test_stale_observer_and_missing_capture_fail(self):
        self.assertFalse(analyze(self.server,self.observer.replace("health=686","health=843"),self.cases)["passed"])
        self.capture.unlink()
        self.assertFalse(analyze(self.server,self.observer,self.cases)["passed"])
    def test_duplicate_receipt_and_wrong_type_fail(self):
        self.assertFalse(analyze(self.server+self.server,self.observer,self.cases)["passed"])
        self.assertFalse(analyze(self.server.replace("MaceHeavy","ShieldHeavy"),self.observer,self.cases)["passed"])
    def test_empty_cases_are_not_a_pass(self):
        self.assertFalse(analyze(self.server,self.observer,[])["passed"])
if __name__=="__main__":unittest.main()
