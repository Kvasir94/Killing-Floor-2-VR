import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('zones',Path(__file__).parents[1]/'reload_zone_report.py')
zones=importlib.util.module_from_spec(spec);spec.loader.exec_module(zones)

GOOD=('[0015.80] ScriptLog: KF2VR_RELOAD_ZONE weapon=KFWeap_Pistol_9mm start=empty mesh=Wep_1stP_9mm_Rig '
      'anim=Reload_Empty status=sampled magazine=True action_kind=0 root=RW_Weapon loaded=RW_Magazine1 '
      'spare=RW_Magazine2 ammo=RW_Magazine1 rack=RW_Bolt follow=None frame=None track=RW_Magazine1 '
      'entry=-4.8082,0.0470,-10.6391 seat=-1.6199,0.0000,-1.8309 path=17 entry_time=1.1807 end_time=1.3007 '
      'axial=False axis=0.0000,0.0000,0.0000 capture_dot=0.8434 swept=False rack_sampled=True '
      'rack_stroke=4.5535 rack_axis=-1.0000,0.0000,0.0000 rack_rest=5.0104,0.0000,3.7529 rack_hand=6.7688 '
      'follow_sampled=False follow_stroke=0.0000 fail= rack_fail= glow_mag=RW_Magazine1 glow_well=RW_Weapon '
      'glow_slide=RW_Bolt')

class ZoneReportTest(unittest.TestCase):
    def test_parses_vectors_numbers_and_flags(self):
        zone=zones.parse(GOOD)['KFWeap_Pistol_9mm/empty']
        self.assertEqual(zone['seat'],[-1.6199,0.0,-1.8309])
        self.assertEqual(zone['path'],17.0)
        self.assertTrue(zone['rack_sampled'])
        self.assertEqual(zone['fail'],'')
        self.assertEqual(zones.problems(zone),[])

    def test_flags_unusable_samples(self):
        zone=zones.parse(GOOD.replace('rack_sampled=True','rack_sampled=False')
                         .replace('rack_fail=','rack_fail=action-travel-out-of-range')
                         .replace('glow_slide=RW_Bolt','glow_slide=RW_Bolt!missing-bone')
                         .replace('entry=-4.8082,0.0470,-10.6391','entry=-1.6199,0.0000,-1.8309'))['KFWeap_Pistol_9mm/empty']
        found=' '.join(zones.problems(zone))
        self.assertIn('no insertion stroke',found)
        self.assertIn('rack RW_Bolt not sampled',found)
        self.assertIn('slide shell bone missing',found)
        self.assertEqual(zones.problems({'status':'reload-barrel'}),['not sampled: reload-barrel'])

    def test_reports_moves_beyond_noise_only(self):
        old=zones.parse(GOOD)['KFWeap_Pistol_9mm/empty']
        noise=zones.parse(GOOD.replace('seat=-1.6199','seat=-1.6299'))['KFWeap_Pistol_9mm/empty']
        moved=zones.parse(GOOD.replace('seat=-1.6199','seat=-2.6199').replace('glow_well=RW_Weapon','glow_well=none'))['KFWeap_Pistol_9mm/empty']
        self.assertEqual(zones.changes(old,noise),[])
        diff=' '.join(zones.changes(old,moved))
        self.assertIn('seat',diff)
        self.assertIn('glow_well RW_Weapon -> none',diff)

if __name__=='__main__':
    unittest.main()
