import unittest
from epic_launch_options import prepare,prepare_session,tokens
from types import SimpleNamespace
class OptionsTests(unittest.TestCase):
 def test_blank(self):
  p=prepare('', ['KF-BurningParis','-kf2vr-probe','-ENGINEINI=C:\\Session Folder\\KFEngine.ini'])
  self.assertIn('-ENGINEINI="C:\\Session Folder\\KFEngine.ini"',p.prepared)
  self.assertEqual(p.restore_text(p.prepared),'')
 def test_preserves_exact_text(self):
  original='  -windowed  -ResX=1920 '
  p=prepare(original,['-windowed','-kf2vr-probe'])
  self.assertTrue(p.prepared.startswith(original));self.assertEqual(p.restore_text(p.prepared),original)
  self.assertEqual(tokens(p.prepared),['-windowed','-ResX=1920','-kf2vr-probe'])
 def test_conflicts(self):
  with self.assertRaises(ValueError):prepare('-ENGINEINI=old.ini',['-ENGINEINI=new.ini'])
 def test_user_edits_not_overwritten(self):
  p=prepare('-windowed',['-kf2vr-probe'])
  with self.assertRaises(ValueError):p.restore_text(p.prepared+' -ResX=1280')
 def test_auth_never_copied(self):
  for old,args in [('-AUTH_PASSWORD=do-not-copy',[]),('', ['-AUTH_LOGIN=do-not-copy'])]:
   with self.assertRaises(ValueError):prepare(old,args)
 def test_malformed_or_positional_preserved_for_review(self):
  for old in ['-foo="unfinished','KF-Other','-foo\nbar']:
   with self.assertRaises(ValueError):prepare(old,['-kf2vr-probe'])
 def test_session_requires_early_proxy_activation_and_isolated_configs(self):
  broker=SimpleNamespace(argument='-kf2vr-epic-session=public-session-marker')
  args=['KF-BurningParis','-kf2vr-probe','-kf2vr-stereo','-onethread']
  args += ['-'+name+'INI=C:\\Session\\KF'+name+'.ini' for name in ['ENGINE','GAME','INPUT','SYSTEMSETTINGS']]
  plan=prepare_session('-windowed',args,broker)
  self.assertIn('-kf2vr-probe',plan.prepared)
  self.assertIn(broker.argument,plan.prepared)
  for required in ['-kf2vr-probe','-kf2vr-stereo','-onethread']:
   with self.assertRaises(ValueError):prepare_session('',[arg for arg in args if arg!=required],broker)
  with self.assertRaises(ValueError):prepare_session('',args+['-kf2vr-hand-replay'],broker)

if __name__=='__main__':unittest.main()
