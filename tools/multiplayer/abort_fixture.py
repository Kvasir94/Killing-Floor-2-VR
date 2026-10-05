"""Verify F10 abort in one owned fixture window; no global input blocking."""
import argparse, ctypes, json, re, subprocess, time
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('release','server-root','cache-root','user-config','output-root'):
        p.add_argument('--'+name,type=Path,required=True)
    p.add_argument("--during-motion",action="store_true",help="Abort only after saved-file motion reaches the separate observer")
    a=p.parse_args()
    a.output_root.mkdir(parents=True,exist_ok=True)
    previous=set(a.output_root.glob('*/run.json'))
    command=[str(a.release/'runtime/python.exe'),'-B',str(a.release/'tools/multiplayer/session.py'),
             '--run','--release',str(a.release),'--server-root',str(a.server_root),
             '--cache-root',str(a.cache_root),'--user-config',str(a.user_config),
             '--output-root',str(a.output_root),'--clients','1','--native-replay','--server-adapter','--lan-no-voice',
             '--duration','5','--client-startup-timeout','120','--startup-timeout','90',
             '--port','18777','--query-port','38015']
    if a.during_motion:
        command[command.index('--clients')+1]='2'
        command += ['--motion-fixture']
    result={'schema':'kf2vr/owned-fixture-abort/1','passed':False,'input':'targeted F10 window message; no physical XR','command':command}
    user32=ctypes.WinDLL('user32',use_last_error=True)
    user32.IsWindow.argtypes=[ctypes.c_void_p];user32.IsWindow.restype=ctypes.c_int
    user32.GetWindowThreadProcessId.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_ulong)]
    user32.PostMessageW.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_size_t,ctypes.c_ssize_t]
    user32.PostMessageW.restype=ctypes.c_int
    def read_log(path):
        if not path.exists():return ''
        data=path.read_bytes()
        return data.decode('utf-16' if data.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig',errors='replace')
    with (a.output_root/'abort-console.log').open('w',encoding='utf-8') as output:
        child=subprocess.Popen(command,stdout=output,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL)
        began=time.monotonic();receipt=None;sent=False
        while child.poll() is None:
            found=set(a.output_root.glob('*/run.json'))-previous
            if len(found)>1:raise RuntimeError('Ambiguous owned fixture receipt')
            if found:
                receipt=next(iter(found));r=json.loads(receipt.read_text())
                role=next(x for x in r['roles'] if x['role']=='driver')
                game=read_log(Path(role['log']))
                native=read_log(Path(role.get('native_log','missing-native-log')))
                matches=re.findall(r'hwnd=(?:0x)?([0-9A-Fa-f]+) owner_pid=(\d+)',native)
                observer=next((x for x in r['roles'] if x['role']=='observer'),None)
                motion_ready=not a.during_motion or (observer and 'KF2VRNet motion_received ' in read_log(Path(observer['log'])))
                if not sent and motion_ready and 'KF2VR_INPUT_ISOLATION phase=installed' in game and matches:
                    handle=int(matches[-1][0],16);pid=ctypes.c_ulong()
                    user32.GetWindowThreadProcessId(handle,ctypes.byref(pid))
                    if pid.value!=role.get('pid') or pid.value!=int(matches[-1][1]) or not user32.IsWindow(handle):
                        raise RuntimeError('Refusing to send F10: window does not belong to this fixture')
                    if not user32.PostMessageW(handle,0x100,0x79,0x00440001):raise OSError(ctypes.get_last_error(),'F10 delivery failed')
                    user32.PostMessageW(handle,0x101,0x79,0xC0440001)
                    sent=True;result['during_saved_file_network_replay']=bool(a.during_motion and motion_ready);result.update(target_pid=pid.value,target_hwnd=hex(handle),f10_sent=True)
                    print('Sent F10 only to owned fixture window pid='+str(pid.value),flush=True)
            if time.monotonic()-began>360:
                raise RuntimeError('Owned harness exceeded its finite phase budgets; inspect without terminating unowned processes')
            time.sleep(.5)
        result['harness_exit_code']=child.returncode
    if receipt:
        r=json.loads(receipt.read_text());role=next(x for x in r['roles'] if x['role']=='driver')
        result.update(receipt=str(receipt),game_exit_code=role.get('exit_code'),user_config_preserved=r.get('user_config_preserved'),cleanup_errors=r.get('cleanup_errors'))
        result['abort_logged']='KF2VR_INPUT_ISOLATION phase=abort key=F10' in read_log(Path(role['log']))
        result['passed']=bool(sent and result['abort_logged'] and role.get('exit_code')==0 and not role.get('bounded_fixture_stop') and r.get('user_config_preserved') and r.get('cleanup_errors')==[])
    (a.output_root/'abort-result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2),flush=True)
    return 0 if result['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
