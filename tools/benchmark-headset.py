"""Attach a read-only SteamVR observer and mark real-play phases; never drives the game."""
import argparse
import ctypes
from datetime import datetime, timezone
import json
import hashlib
import os
from pathlib import Path
import subprocess
import time


def tick():
    clock = ctypes.windll.kernel32.GetTickCount64
    clock.restype = ctypes.c_ulonglong
    return clock()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    start = commands.add_parser('start')
    start.add_argument('--pid', type=int, required=True)
    for field in ('headset', 'connection', 'map', 'preset'):
        start.add_argument('--'+field, required=True)
    start.add_argument('--notes', default='', help='PC, refresh, streaming resolution/bitrate and overlay settings')
    mark = commands.add_parser('mark')
    mark.add_argument('root', type=Path)
    mark.add_argument('label', choices=('warmup','noncombat','combat','pause'))
    mark.add_argument('--headset-worn', action='store_true')
    mark.add_argument('--active-play', action='store_true')
    mark.add_argument('--note', default='')
    finish = commands.add_parser('finish')
    finish.add_argument('root', type=Path)
    args = parser.parse_args()
    workspace = Path(__file__).resolve().parents[1]
    if args.command == 'start':
        if args.pid <= 0:
            parser.error('Game PID must be positive')
        identity = json.loads(subprocess.check_output(['powershell.exe','-NoProfile','-Command',
            f"$p=Get-Process -Id {args.pid} -ErrorAction Stop; [ordered]@{{name=$p.ProcessName;path=$p.Path;start_utc=$p.StartTime.ToUniversalTime().ToString('o');cpu=(Get-CimInstance Win32_Processor).Name;gpu=@((Get-CimInstance Win32_VideoController).Name)}} | ConvertTo-Json -Compress"],text=True))
        if identity['name'].lower() != 'kfgame' or not identity['path']:
            parser.error('--pid must identify a live KFGame process with a readable executable path')
        paths = json.loads((Path(os.environ['LOCALAPPDATA'])/'openvr/openvrpaths.vrpath').read_text())
        dll = Path(paths['runtime'][0])/'bin/win64/openvr_api.dll'
        monitor = workspace/'build/portal-native/native/tools/vrmonitor/Release/kf2vr_runtime_monitor.exe'
        if not dll.is_file() or not monitor.is_file():
            parser.error('SteamVR loader or built monitor missing; build first')
        root = workspace/'build/headset-benchmarks'/datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-%f')
        root.mkdir(parents=True)
        with (root/'monitor.stdout.log').open('wb') as stdout, (root/'monitor.stderr.log').open('wb') as stderr:
            process = subprocess.Popen([str(monitor),str(dll),str(root/'runtime.csv'),'600',str(root/'monitor.stop')],
                                       stdout=stdout, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
        time.sleep(.7)
        if process.poll() is not None:
            raise RuntimeError('Collector failed; see '+str(root/'monitor.stderr.log'))
        session = dict(game_pid=args.pid, monitor_pid=process.pid, collector_clean_exit=False,
                       started_utc=datetime.now(timezone.utc).isoformat(), phases=[],
                       context={field:getattr(args,field) for field in ('headset','connection','map','preset','notes')})
        session['context']['host_and_process'] = identity
        session['context']['game_sha256'] = hashlib.sha256(Path(identity['path']).read_bytes()).hexdigest()
        release = workspace/'build/multiplayer/current-release.json'
        session['context']['selected_release'] = json.loads(release.read_text(encoding='utf-8-sig'))
        session['context']['release_note'] = 'Selected package metadata; attached process may have been launched with another package.'
        controls = subprocess.run([os.sys.executable,str(workspace/'tools/vr-benchmark-controls.py'),
                                   '--output',str(root/'controls-before.json')],capture_output=True,text=True)
        session['context']['controls_snapshot_available'] = controls.returncode == 0
        if controls.returncode:
            session['context']['controls_snapshot_error'] = controls.stderr[-1500:]
        (root/'session.json').write_text(json.dumps(session,indent=2)+'\n')
        print(root)
        return
    root = args.root.resolve()
    session = json.loads((root/'session.json').read_text())
    if session.get('finished_utc'):
        parser.error('Capture is already finished')
    if args.command == 'mark':
        current_start = subprocess.check_output(['powershell.exe','-NoProfile','-Command',
            f"(Get-Process -Id {int(session['game_pid'])} -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')"],text=True).strip()
        if current_start != session['context']['host_and_process']['start_utc']:
            parser.error('Game process exited or PID was reused; finish and start a new capture')
    now = tick()
    if session['phases'] and 'end_tick_ms' not in session['phases'][-1]:
        session['phases'][-1]['end_tick_ms'] = now
    if args.command == 'mark':
        session['phases'].append(dict(label=args.label,start_tick_ms=now,
                                     headset_worn=args.headset_worn,active_play=args.active_play,note=args.note))
    else:
        (root/'monitor.stop').write_text('Finished real play capture')
        # Existing collector writes its final CSV on normal shutdown. Wait for process exit,
        # without terminating or touching the game.
        kernel = ctypes.windll.kernel32
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        kernel.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.OpenProcess(0x100000 | 0x1000, False, session['monitor_pid'])
        if handle:
            try:
                waited = ctypes.windll.kernel32.WaitForSingleObject(handle, 5000)
                code = ctypes.c_ulong()
                ok = ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
                session['collector_clean_exit'] = waited == 0 and bool(ok) and code.value == 0
            finally:
                ctypes.windll.kernel32.CloseHandle(handle)
        session['finished_utc'] = datetime.now(timezone.utc).isoformat()
        controls = subprocess.run([os.sys.executable,str(workspace/'tools/vr-benchmark-controls.py'),
                                   '--output',str(root/'controls-after.json')],capture_output=True,text=True)
        session['controls_unchanged'] = False
        if controls.returncode == 0 and (root/'controls-before.json').exists():
            before = json.loads((root/'controls-before.json').read_text())
            after = json.loads((root/'controls-after.json').read_text())
            session['controls_unchanged'] = before['effective_controls_sha256'] == after['effective_controls_sha256']
    (root/'session.json').write_text(json.dumps(session,indent=2)+'\n')
    if args.command == 'finish':
        subprocess.run([os.sys.executable,str(workspace/'tools/analyze-headset-benchmark.py'),str(root)],check=True)
    else:
        print('Phase marked:',args.label,'(at least 30 seconds recommended).')


if __name__ == '__main__':
    main()
