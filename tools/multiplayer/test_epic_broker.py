"""Offline integration: a tiny native test client, never KF2 or the SDK."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from epic_session import PendingEpicLaunch
from epic_broker import EpicBroker

CLIENT=Path(__file__).resolve().parents[2]/'build/multiplayer/native/native/adapter/Release/kf2vr_epic_session_client.exe'

@unittest.skipUnless(os.name=='nt' and CLIENT.is_file(),'Build the offline native Epic client first')
class BrokerTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
  self.root=Path(self.temp.name)
  self.sha=hashlib.sha256(CLIENT.read_bytes()).hexdigest().upper()
 def run_client(self,*,expected_sha=None,stale=False,alter_marker=False,on_claim=None):
  ticket=PendingEpicLaunch.create(CLIENT,expected_sha or self.sha,timeout_seconds=5)
  broker=EpicBroker(ticket,self.root,on_claim=on_claim or (lambda journal: None));self.addCleanup(broker.close)
  thread=threading.Thread(target=broker.serve,daemon=True);thread.start()
  self.assertTrue(broker.ready.wait(3));self.assertIsNone(broker.error)
  if stale:(self.root/'native.log').write_text('preserve me')
  argument=broker.argument
  if alter_marker:argument=argument.rsplit(':',1)[0]+':1'
  client=subprocess.run([str(CLIENT),argument],capture_output=True,text=True,encoding="utf-8",timeout=12)
  thread.join(8);self.assertFalse(thread.is_alive())
  return ticket,broker,client
 def test_native_pipe_handoff_with_os_peer_identity(self):
  records=[];ticket,broker,client=self.run_client(on_claim=records.append)
  self.assertEqual(client.returncode,0,repr(broker.error))
  self.assertIsNone(broker.error)
  self.assertEqual(Path(client.stdout.strip()),self.root/'native.log')
  self.assertEqual(len(records),1);self.assertIsNotNone(ticket.owner)
  self.assertNotIn('nonce',records[0]);self.assertFalse((self.root/'native.log').exists())
 def test_wrong_hash_cannot_claim_session(self):
  ticket,broker,client=self.run_client(expected_sha='F'*64)
  self.assertNotEqual(client.returncode,0);self.assertIsNotNone(broker.error);self.assertIsNone(ticket.owner)
 def test_output_appearing_after_prepare_is_preserved(self):
  ticket,broker,client=self.run_client(stale=True)
  self.assertNotEqual(client.returncode,0);self.assertIsNotNone(broker.error);self.assertIsNone(ticket.owner)
  self.assertEqual((self.root/'native.log').read_text(),'preserve me')
 def test_native_rejects_reused_broker_pid_birth_stamp(self):
  ticket,broker,client=self.run_client(alter_marker=True)
  self.assertNotEqual(client.returncode,0);self.assertIsNone(ticket.owner)
 def test_failed_journal_does_not_authorize_native_start(self):
  def refuse(_):raise OSError('simulated journal failure')
  ticket,broker,client=self.run_client(on_claim=refuse)
  self.assertNotEqual(client.returncode,0);self.assertIsNotNone(broker.error)
 def test_existing_output_blocks_before_listening(self):
  (self.root/'native.log').write_text('existing')
  ticket=PendingEpicLaunch.create(CLIENT,self.sha)
  with self.assertRaises(ValueError):EpicBroker(ticket,self.root,on_claim=lambda journal: None)

 def test_unicode_and_spaces_session_directory(self):
  self.root=self.root/'Session café folder';self.root.mkdir()
  ticket,broker,client=self.run_client()
  self.assertEqual(client.returncode,0,repr(broker.error))
  self.assertEqual(Path(client.stdout.strip()),self.root/'native.log')
 def test_durable_journal_callback_is_required(self):
  ticket=PendingEpicLaunch.create(CLIENT,self.sha)
  with self.assertRaises(ValueError):EpicBroker(ticket,self.root,on_claim=None)

 def test_pending_pipe_can_be_cancelled_without_game(self):
  ticket=PendingEpicLaunch.create(CLIENT,self.sha,timeout_seconds=30)
  broker=EpicBroker(ticket,self.root,on_claim=lambda journal: None);self.addCleanup(broker.close)
  thread=threading.Thread(target=broker.serve,daemon=True);thread.start()
  self.assertTrue(broker.ready.wait(3));broker.cancel();thread.join(2)
  self.assertFalse(thread.is_alive());self.assertIsNone(ticket.owner)

 def test_cancel_during_connect_issuance_cannot_miss_pending_operation(self):
  ticket=PendingEpicLaunch.create(CLIENT,self.sha,timeout_seconds=5)
  broker=EpicBroker(ticket,self.root,on_claim=lambda journal:None);self.addCleanup(broker.close)
  entering=threading.Event();resume=threading.Event();cancelled=threading.Event()
  connect=broker.kernel.ConnectNamedPipe;cancel=ticket.cancel
  def delayed_connect(pipe,operation):
   entering.set()
   if not resume.wait(3):raise TimeoutError('Offline connect barrier expired')
   return connect(pipe,operation)
  def signal_cancel():
   cancel();cancelled.set()
  broker.kernel.ConnectNamedPipe=delayed_connect;ticket.cancel=signal_cancel
  thread=threading.Thread(target=broker.serve,daemon=True);thread.start()
  self.assertTrue(entering.wait(2))
  canceller=threading.Thread(target=broker.cancel,daemon=True);canceller.start()
  try:self.assertTrue(cancelled.wait(2))
  finally:resume.set()
  thread.join(2);canceller.join(2)
  self.assertFalse(thread.is_alive());self.assertFalse(canceller.is_alive());self.assertIsNone(ticket.owner)
  self.assertTrue(broker.observed_peers_exited())

if __name__=='__main__':unittest.main()
