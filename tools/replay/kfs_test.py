"""Parser tests for the .kfs replay script compiler (python -m unittest tools/replay/kfs_test.py)."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kfs


def ops(text, **variables):
    return kfs.Compiler(variables).compile_text(text, 'case.kfs').ops


class CompileTest(unittest.TestCase):
    def test_press_expands_to_edges_and_wait(self):
        self.assertEqual(ops('press right trigger 80ms'), [
            '1|button|hand=R|b=trigger|down=1', '1|wait|t=0.08', '1|button|hand=R|b=trigger|down=0'])

    def test_both_hands_run_together(self):
        result = ops('pose both body offset (30, -10, -20) over 0.3s')
        self.assertIn('par=1', result[0])
        self.assertNotIn('par=1', result[1])
        self.assertIn('ox=30|oy=-10|oz=-20', result[1])

    def test_anchors_and_carried_point(self):
        self.assertEqual(ops('move left R.mag to R.well speed 40 tol 1'),
            ['1|move|hand=L|a=R.part.well|p=R.part.mag|frame=body|speed=40|tol=1'])
        self.assertIn('a=pouch.L', ops('move left to pouch')[0])
        self.assertIn('a=R.bone.RW_Bolt', ops('pose right R.bone(RW_Bolt)')[0])
        self.assertIn('a=nearest.KFDroppedPickup', ops('move right to nearest(KFDroppedPickup)')[0])

    def test_blocks_macros_repeat_and_variables(self):
        result = ops('define fire { press right trigger ; wait 0.1s }\nrepeat 3 {\n do fire\n}\ndraw right $weapon',
                     weapon='KFGameContent.KFWeap_Pistol_9mm')
        self.assertEqual(sum('down=1' in op for op in result), 3)
        self.assertTrue(result[-1].endswith('weapon=KFGameContent.KFWeap_Pistol_9mm|timeout=10'))

    def test_probes_conditions_and_options(self):
        self.assertEqual(ops('expect left.ammo >= 1 within 2s'), ['1|expect|probe=L.ammo|op=>=|v=1|within=2'])
        self.assertIn('probes=count.KFDroppedPickup,nearest.KFDroppedPickup.z,dist.L:part:well.wrist:L',
                      ops('log count(KFDroppedPickup) nearest(KFDroppedPickup).z dist(L.well, wrist.left)')[0])
        self.assertIn('ry=45', ops('look yaw=45 over 1s')[0])

    def test_movement_shorthands(self):
        self.assertEqual(ops('wait 1s\nwalk forward 2s speed 0.5')[1:], [
            '2|stick|hand=L|x=0|y=0.5', '2|wait|t=2', '2|stick|hand=L|x=0|y=0'])
        self.assertEqual(ops('turn left')[0], '1|stick|hand=R|x=-1|y=0')

    def test_belt_progress_and_regrab_compile_as_input_ops(self):
        result = ops('release left grip\nmove left to reload.target speed 60 tol 1 timeout 6 track\n'
                     'hold left grip\nwait until R.belt_engaged == true timeout 1.5s\n'
                     'stroke left R to 0.7 speed 20 tol 0.03 timeout 6\n'
                     'expect R.belt_progress >= 0.5\nrelease left grip\n'
                     'wait until R.belt_seated == true timeout 2s')
        self.assertEqual(result[0], '1|button|hand=L|b=grip|down=0')
        self.assertIn('a=reload.target', result[1])
        self.assertIn('probe=R.belt_engaged', result[3])
        self.assertIn('|stroke|hand=L|gun=R|s=0.7', result[4])
        self.assertIn('probe=R.belt_progress', result[5])
        self.assertEqual(result[6], '7|button|hand=L|b=grip|down=0')
        self.assertIn('probe=R.belt_seated', result[7])

    def test_log_checks_need_marks(self):
        compiled = kfs.Compiler().compile_text('mark seated\nexpect log /seated/ since seated\nforbid log /Critical/', 'x')
        self.assertEqual([c['kind'] for c in compiled.log_checks], ['expect', 'forbid'])
        with self.assertRaises(kfs.ScriptError):
            ops('expect log /x/ since nowhere')

    def test_errors_name_file_and_line(self):
        for text in ('jump left', 'press left nose', 'pose left nowhere', 'repeat 2 { wait 1s', 'wait 99999s',
                     'console quit', 'expect left.ammo ~ 3', 'stick left 2 0', 'shot bad|name'):
            with self.subTest(text=text), self.assertRaises(kfs.ScriptError) as caught:
                ops('wait 1s\n'+text)
            self.assertIn('case.kfs:2', str(caught.exception))

    def test_origins_keep_include_lines_apart(self):
        compiled = kfs.Compiler().compile_text('wait 1s\nwait 2s', 'case.kfs')
        self.assertEqual([op.split('|')[0] for op in compiled.ops], ['1', '2'])
        self.assertEqual(compiled.where(2), 'case.kfs:2')

    def test_include_resolves_beside_script(self):
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, 'lib.kfs').write_text('define ready { pose both body offset (30,0,-20) }\n', encoding='utf-8')
            Path(folder, 'main.kfs').write_text('include lib.kfs\ndo ready\n', encoding='utf-8')
            self.assertEqual(len(kfs.compile_script(Path(folder, 'main.kfs')).ops), 2)

    def test_examples_compile(self):
        for path in sorted((Path(__file__).parent/'scripts').glob('*.kfs')):
            with self.subTest(script=path.name):
                kfs.compile_script(path, {'weapon': 'KFGameContent.KFWeap_Pistol_9mm'})


class LogTest(unittest.TestCase):
    LOG = '\n'.join([
        'KF2VR_SCRIPT line=4 t=1.2 check=expect probe=R.ammo value=13 op=== expected=13 passed=true',
        'KF2VR_SCRIPT line=9 t=5.0 mark=seated',
        'KF2VR_RELOAD_GEOMETRY seated hand=1',
        'KF2VR_SCRIPT line=12 t=6.0 check=reach probe=R.part.well value=4.2 op=<= expected=1.5 passed=false',
        'KF2VR_SCRIPT phase=complete passed=false reason=end checks=2 failures=1 captures=3'])

    def test_runner_verdicts(self):
        verdicts = kfs.runner_verdicts(self.LOG)
        self.assertTrue(verdicts['complete'])
        self.assertFalse(verdicts['passed'])
        self.assertEqual([c['passed'] for c in verdicts['checks']], [True, False])
        self.assertEqual(verdicts['checks'][1]['value'], '4.2')

    def test_log_windows(self):
        compiled = kfs.Compiler().compile_text(
            'mark seated\nexpect log /GEOMETRY seated/ since seated\nforbid log /Critical/\nexpect log /never/', 'x')
        self.assertEqual([r['passed'] for r in kfs.check_log(self.LOG, compiled)], [True, True, False])



class NewStatementTest(unittest.TestCase):
    def test_spawn_names_the_exact_class_and_hostile(self):
        self.assertEqual(ops('spawn clot hostile dist 400'),
                         ['1|spawn|zed=ClotA|cls=KFPawn_ZedClot_Alpha|hostile=1|dist=400|yaw=0'])
        self.assertEqual(ops('spawn GF2 yaw 30'), ['1|spawn|zed=GF2|dist=300|yaw=30'])
        self.assertIn('cls=KFPawn_ZedHusk', ops('spawn KFPawn_ZedHusk')[0])

    def test_damage(self):
        self.assertEqual(ops('damage on; damage off'), ['1|damage|on=1', '1|damage|on=0'])
        with self.assertRaises(kfs.ScriptError):
            ops('damage maybe')

    def test_select_and_wheel(self):
        self.assertEqual(ops('select left W.Gun refused timeout 5'),
                         ['1|select|hand=L|act=pick|pick=W.Gun|refused=1|timeout=5'])
        self.assertIn('pick=hand', ops('select right empty')[0])
        self.assertEqual(ops('wheel right open'), ['1|select|hand=R|act=open'])
        self.assertEqual(ops('wheel left close'), ['1|select|hand=L|act=close'])
        with self.assertRaises(kfs.ScriptError):
            ops('wheel left spin')

    def test_camera(self):
        self.assertEqual(ops('camera side dist 140 body'), ['1|camera|mode=side|dist=140|body=1'])
        self.assertEqual(ops('camera eye'), ['1|camera|mode=eye'])
        for bad in ('camera eye dist 100', 'camera nowhere', 'camera front dist 5000'):
            with self.assertRaises(kfs.ScriptError, msg=bad):
                ops(bad)

    def test_new_probes(self):
        self.assertIn('probe=god', ops('expect god == false')[0])
        self.assertIn('probe=nearest.VRWorldDropGun.pull', ops('expect nearest(VRWorldDropGun).pull == 0')[0])
        self.assertEqual(ops('log left.wheel_items'), ['1|log|probes=L.wheel_items'])

if __name__ == '__main__':
    unittest.main()
