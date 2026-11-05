"""Log analyzer regression checks; no source assertions or simulated gameplay."""
import unittest

from sharing_replay import CHECKS, analyze


class SharingReplayAnalysisTests(unittest.TestCase):
    def logs(self):
        server = '\n'.join('KF2VRNet sharing_case phase=check case=' + case
                           + ' passed=True netmode=NM_DedicatedServer' for case in CHECKS)
        server += '\nKF2VRNet sharing_case phase=complete passed=True netmode=NM_DedicatedServer'
        client = 'KF2VRNet sharing_client id=1 op=1 passed=True netmode=NM_Client'
        observer = client + '\nKF2VRNet sharing_observer shared=True hidden=False motion=0 netmode=NM_Client'
        return server, client, observer

    def test_complete_independent_streams(self):
        self.assertTrue(analyze(*self.logs())['passed'])

    def test_missing_denial_is_incomplete(self):
        server, owner, recipient = self.logs()
        server = '\n'.join(line for line in server.splitlines() if 'case=gun_denied_off ' not in line)
        self.assertFalse(analyze(server, owner, recipient)['passed'])

    def test_hidden_mesh_or_warning_fails(self):
        server, owner, recipient = self.logs()
        self.assertFalse(analyze(server, owner, recipient.replace('hidden=False', 'hidden=True'))['passed'])
        self.assertFalse(analyze(server, owner + '\nScriptWarning: Accessed None', recipient)['passed'])

    def test_stock_startup_warning_is_reported_but_runtime_is_not_ignored(self):
        server, owner, recipient = self.logs()
        warning = "ScriptWarning: Accessed None 'CurrentPerk'\n\tController_0\n\tFunction KFGame.KFPlayerController:InitPerkLoadout:000A\n"
        result = analyze(server, warning + owner, recipient)
        self.assertTrue(result['passed'])
        self.assertEqual(len(result['warnings']['owner']['known_stock_startup']), 1)
        self.assertFalse(analyze(server, owner + '\n' + warning, recipient)['passed'])


if __name__ == '__main__':
    unittest.main()
