"""Map metadata checks for saved-file replay evidence; no engine/source assertions."""
import unittest
from motion_timeline import map_identity,ordered_resets

class MapIdentityTest(unittest.TestCase):
    def test_capture_uses_recorded_sample_map(self):
        samples=[{'map':'KF-BurningParis'},{'map':'KF-Outpost'}]
        self.assertTrue(map_identity(samples,[{'input_sample_index':1,'map':'kf-outpost'}]))
        self.assertFalse(map_identity(samples,[{'input_sample_index':1,'map':'KF-BurningParis'}]))

    def test_unknown_legacy_identity_does_not_pass(self):
        for name in ('','None','none'):
            self.assertFalse(map_identity([{'map':name}],[{'input_sample_index':0,'map':name}]))

    def test_missing_or_out_of_range_capture_does_not_pass(self):
        samples=[{'map':'KF-BurningParis'}]
        self.assertFalse(map_identity(samples,[]))
        self.assertFalse(map_identity([],[]))
        for index in (-1,1):
            self.assertFalse(map_identity(samples,[{'input_sample_index':index,'map':'KF-BurningParis'}]))

class OrderedResetTest(unittest.TestCase):
    def setUp(self):
        self.server="\n".join((
            'KF2VRNet motion_begin replay=1 time=10',
            'KF2VRNet motion_end replay=1 time=20',
            'KF2VRNet motion_reset replay=1 passed=True time=20.1',
            'KF2VRNet motion_begin replay=2 time=21',
            'KF2VRNet motion_end replay=2 time=23',
            'KF2VRNet motion_reset replay=2 passed=True time=23.1'))
        self.driver='KF2VRNet motion_batch_reset replay=1 passed=True time=8\nKF2VRNet motion_batch_reset replay=2 passed=True time=11'

    def test_both_ordered_resets_required(self):
        result=ordered_resets(self.server,self.driver,2)
        self.assertTrue(result['passed'])
        self.assertEqual([c['replay_id'] for c in result['cases']],[1,2])
        self.assertEqual(result['cases'][0]['server_reset_seconds'],20.1)

    def test_missing_or_failed_second_reset_rejected(self):
        self.assertFalse(ordered_resets(self.server.rsplit('\n',1)[0],self.driver,2)['passed'])
        self.assertFalse(ordered_resets(self.server.replace('passed=True time=23.1','passed=False time=23.1'),self.driver,2)['passed'])

    def test_start_before_verified_reset_rejected(self):
        rows=self.server.splitlines();rows[2],rows[3]=rows[3],rows[2]
        self.assertFalse(ordered_resets('\n'.join(rows),self.driver,2)['passed'])
        self.assertFalse(ordered_resets(self.server.replace('time=21','time=19'),self.driver,2)['passed'])

    def test_wrong_ids_and_missing_client_ack_rejected(self):
        self.assertFalse(ordered_resets(self.server.replace('replay=2','replay=1'),self.driver,2)['passed'])
        self.assertFalse(ordered_resets(self.server,self.driver.splitlines()[0],2)['passed'])

    def test_client_reset_timestamps_must_be_valid_and_ordered(self):
        for value in ('nan','-1','7'):
            self.assertFalse(ordered_resets(self.server,self.driver.replace('time=11','time='+value),2)['passed'])

    def test_single_file_review_requires_matching_successful_reset_ack(self):
        server='\n'.join(self.server.splitlines()[:3]);ack=self.driver.splitlines()[0]
        self.assertTrue(ordered_resets(server,ack,1)['passed'])
        for invalid in ('',ack.replace('replay=1','replay=2'),ack.replace('passed=True','passed=False'),ack+'\n'+ack):
            self.assertFalse(ordered_resets(server,invalid,1)['passed'])

    def test_failed_file_only_server_reset_cannot_pass_local_completion(self):
        server='\n'.join(self.server.splitlines()[:3]).replace('passed=True','passed=False')
        driver=self.driver.splitlines()[0]+'\nKF2VR_MOTION_FIXTURE phase=network_complete passed=True status=3'
        self.assertFalse(ordered_resets(server,driver,1)['passed'])

if __name__=='__main__':unittest.main()
