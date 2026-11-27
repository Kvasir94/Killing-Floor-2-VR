"""Tests for live.py's pure parts and its broker (python -m unittest tools/replay/live_test.py)."""
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kfs
import live


class CompileTest(unittest.TestCase):
    def test_statements_use_the_shared_macros_and_session_variables(self):
        ops, origins, new = live.compile_statements('draw right $weapon\ndo ready', {'weapon': 'W.Gun'})
        self.assertTrue(ops[0].endswith('|draw|hand=R|weapon=W.Gun|timeout=10'))
        self.assertTrue(any('|pose|' in op for op in ops))
        self.assertEqual(origins[0], '<live>:1')
        self.assertEqual(new, {})

    def test_launch_only_statements_are_refused(self):
        for text in ('setup map=KF-Burning', 'set bLoseReloadAmmo=True', 'preset classic',
                     'forbid log /x/', 'live'):
            with self.assertRaises(kfs.ScriptError, msg=text):
                live.compile_statements(text)

    def test_new_macros_are_returned_and_reusable(self):
        _, _, new = live.compile_statements('define tap(h) { press $h trigger 50ms }')
        self.assertEqual(list(new), ['tap'])
        params, block = new['tap']
        ops, _, _ = live.compile_statements('do tap(right)', macros={'tap': (params, block)})
        self.assertEqual(ops[0], '1|button|hand=R|b=trigger|down=1')



class LaunchSettingsTest(unittest.TestCase):
    def test_preset_then_sets_like_script_lines(self):
        settings = live.launch_settings('advanced', ['bToggleGrip=True', 'bWorldWeaponDrops=False'])
        self.assertEqual(settings['ReloadPreset'], '2')
        self.assertEqual(settings['bToggleGrip'], 'True')
        self.assertEqual(settings['bWorldWeaponDrops'], 'False')
        self.assertEqual(live.launch_settings(), {})
        for bad in (('nope', []), (None, ['NoEquals']), (None, ['Key=a|b'])):
            with self.assertRaises(kfs.ScriptError, msg=str(bad)):
                live.launch_settings(*bad)

    def test_start_settings_reach_the_launch_config(self):
        start = dict(script=None, minutes=5, settings=live.launch_settings('classic', ['bWorldWeaponDrops=True']))
        compiled = live.build_compiled(start, None, 1, 4321)
        self.assertEqual(compiled.settings['ReloadPreset'], '0')
        self.assertEqual(compiled.settings['bWorldWeaponDrops'], 'True')
        self.assertTrue(compiled.ops[-1].endswith('|live|port=4321|client=1'))

class RelocateTest(unittest.TestCase):
    def test_lines_shift_and_loops_jump_back_relatively(self):
        ops, _, _ = live.compile_statements('wait 1s\nrepeat until R.ammo == 0 max 5 {\n press right trigger\n}')
        moved = live.relocate(ops, 100)
        self.assertTrue(all(int(op.split('|')[0]) > 100 for op in moved))
        loop = next(op for op in moved if '|loop|' in op)
        index = moved.index(loop)
        self.assertNotIn('|to=', loop)
        # back= lands on the loop body's first op wherever the batch is appended.
        self.assertEqual(index - int(live.fields(loop.replace('|', ' '))['back']), 1)

    def test_if_skips_are_untouched(self):
        ops, _, _ = live.compile_statements('if R.ammo == 0 { wait 1s } else { wait 2s }')
        self.assertEqual([op.split('|', 1)[1] for op in live.relocate(ops, 7)], [op.split('|', 1)[1] for op in ops])

    def test_bind_live_sets_port_and_client(self):
        self.assertEqual(live.bind_live(['3|live', '4|wait|t=1', '5|live|port=1|client=9'], 4321, 2),
                         ['3|live|port=4321|client=2', '4|wait|t=1', '5|live|port=4321|client=2'])
        self.assertTrue(live.has_live(['1|live']))
        self.assertFalse(live.has_live(['1|wait|t=1']))


class ReplyTest(unittest.TestCase):
    def test_fields_and_notes(self):
        self.assertEqual(live.fields('id=ab\tR.ammo=14\tR.anim=Idle:0.5:1:true', '\t'),
                         {'id': 'ab', 'R.ammo': '14', 'R.anim': 'Idle:0.5:1:true'})
        self.assertEqual(live.note_text('line=2 t=12.345 check=expect passed=true', ['a', 'live1 <live>:1']),
                         't=12.35 [live1 <live>:1] check=expect passed=true')
        self.assertEqual(live.note_text('case n=1 label=live', []), 'case n=1 label=live')


class SessionFileTest(unittest.TestCase):
    def test_line_allocation_and_macro_store(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(live.allocate_lines(folder, ['s:1', 's:2'], ''), 0)
            self.assertEqual(live.allocate_lines(folder, ['<live>:1'], 'live1'), 2)
            self.assertEqual(live.read_json(Path(folder)/'origins.json'), ['s:1', 's:2', 'live1 <live>:1'])
            _, _, new = live.compile_statements('define two { wait 1s ; wait 2s }')
            live.save_macros(folder, new)
            ops, _, _ = live.compile_statements('do two', macros=live.load_macros(folder))
            self.assertEqual(len(ops), 2)

    def test_update_session_merges(self):
        with tempfile.TemporaryDirectory() as folder:
            live.update_session(folder, state='starting', port=5)
            self.assertEqual(live.update_session(folder, state='live'), {'state': 'live', 'port': 5})


class BrokerTest(unittest.TestCase):
    def test_commands_reach_the_game_and_replies_come_back(self):
        with tempfile.TemporaryDirectory() as folder:
            broker = live.Broker(folder, [1])
            game = socket.create_connection(('127.0.0.1', broker.port))
            game.sendall(b'HELLO game client=1\n')

            def fake_game():
                for line in live.socket_lines(game):
                    kind, _, rest = line.partition(' ')
                    if kind == 'PROBE':
                        game.sendall(f'PROBE id={rest.split()[0]}\tR.ammo=15\n'.encode())
                    elif kind == 'COMMIT':
                        game.sendall(f'QUEUED id={rest} at=3 ops=1\nNOTE line=1 t=1 log R.ammo=15\nDONE id={rest}\n'.encode())
                        game.sendall(b'READY client=1\n')
            threading.Thread(target=fake_game, daemon=True).start()
            time.sleep(0.2)
            session = dict(root=folder, port=broker.port, clients=[1], state='live', variables={})
            self.assertEqual(live.control(session, 'PROBE', 1, 'R.ammo')['R.ammo'], '15')
            out = Out()
            self.assertEqual(live.send_statements(session, 'log R.ammo', out=out), live.OK)
            self.assertIn('log R.ammo=15', out.text)
            time.sleep(0.2)
            self.assertEqual(live.read_json(Path(folder)/'session.json')['state'], 'live')
            game.close()
            time.sleep(0.2)
            with self.assertRaises(live.LiveError):
                live.control(session, 'STATUS', 1)
            broker.close()


class Out:
    def __init__(self):
        self.text = ''

    def write(self, text):
        self.text += text

    def flush(self):
        pass


if __name__ == '__main__':
    unittest.main()
