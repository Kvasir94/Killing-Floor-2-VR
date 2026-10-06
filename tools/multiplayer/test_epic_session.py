from pathlib import Path
import unittest
from dataclasses import replace
from epic_session import PendingEpicLaunch, ProcessIdentity

class SessionOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.path=Path('KFGame.exe').resolve()
        self.sha='A'*64
        self.ticket=PendingEpicLaunch(self.path,self.sha,100,1000)
        self.peer=ProcessIdentity(42,200,self.path,self.sha)
        self.session=self.ticket.session_id;self.nonce=self.ticket.nonce

    def claim(self,peer=None,**overrides):
        args=dict(session_id=self.session,nonce=self.nonce,now=300);args.update(overrides)
        return self.ticket.claim(peer or self.peer,**args)

    def test_correct_ephemeral_binding_accepts_once_and_journal_omits_nonce(self):
        journal=self.claim()
        self.assertEqual(journal['pid'],42)
        self.assertNotIn('nonce',journal)
        self.assertNotIn(self.nonce,repr(self.ticket))
        self.assertEqual(self.ticket.nonce,'')
        with self.assertRaises(ValueError):self.claim()

    def test_game_path_time_alone_never_grants_ownership(self):
        self.assertIsNone(self.ticket.recovery_identity())
        self.assertFalse(self.ticket.owns(self.peer))
        with self.assertRaises(ValueError):self.claim(nonce='B'*64)
        self.assertFalse(self.ticket.owns(self.peer))

    def test_other_session_refused(self):
        with self.assertRaises(ValueError):self.claim(session_id='other')

    def test_preexisting_or_future_process_refused(self):
        for created in (99,301):
            with self.assertRaises(ValueError):self.claim(replace(self.peer,creation_time=created))

    def test_expired_and_backwards_clock_refused(self):
        for now in (99,1001):
            with self.assertRaises(ValueError):self.claim(now=now)

    def test_wrong_binary_or_installation_refused(self):
        for peer in (replace(self.peer,sha256='B'*64),replace(self.peer,executable=self.path.parent/'other.exe')):
            with self.assertRaises(ValueError):self.claim(peer)

    def test_pid_reuse_never_owned(self):
        self.claim()
        self.assertTrue(self.ticket.owns(self.peer))
        self.assertFalse(self.ticket.owns(replace(self.peer,creation_time=201)))
        self.assertFalse(self.ticket.owns(replace(self.peer,pid=43)))

    def test_cancel_prevents_late_game_adoption(self):
        self.ticket.cancel()
        with self.assertRaises(ValueError):self.claim()
        self.assertIsNone(self.ticket.recovery_identity())

    def test_malformed_identity_refused(self):
        for peer in (replace(self.peer,pid=True),replace(self.peer,pid=0),replace(self.peer,sha256='bad')):
            with self.assertRaises(ValueError):self.claim(peer)

    def test_timeout_is_bounded(self):
        for timeout in (0,301,True):
            with self.assertRaises(ValueError):PendingEpicLaunch.create(self.path,self.sha,timeout_seconds=timeout)

if __name__=='__main__':unittest.main()
