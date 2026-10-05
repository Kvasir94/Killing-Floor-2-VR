"""Prepare by default; --run needs the exclusive compiler/runtime gate.

Use freshly compiled isolated melee packages and the immutable native backend
from a specified release. No current-release pointer or player INI is written.
"""
from __future__ import annotations
import argparse
import ctypes
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/multiplayer'))
from session import (digest, role_config, config_hashes, read_ini, set_ini,
                     unreal_command, verify_server, log_text, check_port,
                     await_client_startup)
from release_state import verify_release
from native_fixture import NativeDeployment
from evidence import verify_transport, local_lan_readiness, events
from melee_fixture_evidence import analyze, read

PACKAGES = ('KF2VR', 'KF2VRNet', 'KF2VRNetClient', 'MeleeTestTools', 'MeleeRuntimeTools')
EXPECTATIONS = (
    ('BoneCrusher mace', 'KFDT_Bludgeon_MaceAndShield_MaceHeavy', 165),
    ('BoneCrusher shield', 'KFDT_Bludgeon_MaceAndShield_ShieldHeavy', 165),
    ('Katana', 'KFDT_Slashing_KatanaHeavy', 79),
    ('Zweihander rejected gap', 'KFDT_Slashing_ZweihanderHeavy', 174),
)

def fixture_rows(log, marker='KF2VR_MELEE_FIXTURE'):
    result = []
    for line in log.splitlines():
        match = re.search(re.escape(marker) + r' (.*)', line)
        if match:
            result.append(dict(re.findall(r'([a-z_]+)=([^\s]+)', match[1])))
    return result

def numeric(row, key):
    try: return float(row[key])
    except (KeyError,ValueError): return float('nan')

def bmp_to_png(source, target):
    """Lossless conversion of UE3's uncompressed BGR screenshot; preserve BMP."""
    b = Path(source).read_bytes()
    if b[:2] != b'BM' or len(b) < 54:
        raise ValueError('Not a BMP screenshot')
    offset, header = struct.unpack_from('<II', b, 10)
    w, signed_h, planes, bits, compression = struct.unpack_from('<iiHHI', b, 18)
    if header < 40 or planes != 1 or bits not in (24, 32) or compression != 0:
        raise ValueError('Unsupported BMP screenshot encoding')
    h = abs(signed_h)
    if not (0 < w <= 8192 and 0 < h <= 8192):
        raise ValueError('Invalid BMP dimensions')
    stride = ((w * bits + 31) // 32) * 4
    if offset + h * stride > len(b):
        raise ValueError('Truncated BMP screenshot')
    scan = bytearray()
    for y in range(h):
        row = y if signed_h < 0 else h - y - 1
        scan.append(0)
        for x in range(w):
            p = offset + row * stride + x * (bits // 8)
            scan.extend((b[p+2], b[p+1], b[p]))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind+data))
    Path(target).write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w,h,8,2,0,0,0))
                            + chunk(b'IDAT', zlib.compress(scan)) + chunk(b'IEND', b''))

def runtime_evidence(server, driver, observer, captures):
    """Fail closed on missing conditions, skipped gap, or misleading client damage."""
    sr, dr = fixture_rows(server), fixture_rows(driver)
    obs = fixture_rows(observer, 'KF2VR_MELEE_OBSERVER')
    problems, cases = [], []
    if len(obs) != len(captures):
        problems.append('screenshot count does not match independent observer capture events')
    if len(obs) != 12:
        problems.append('expected all three observer stages for each of four cases')
    for i, (name, damage_type, delta) in enumerate(EXPECTATIONS):
        starts = [e for e in sr if e.get('phase') == 'case' and e.get('case') == str(i)]
        if len(starts) != 1:
            problems.append(f'case {i}: unique stock target missing'); continue
        target = starts[0].get('target')
        def phase(rows, kind):
            return [e for e in rows if e.get('case') == str(i) and e.get('phase') == kind]
        health = phase(sr, 'health')
        placements = phase(sr, 'placed')
        if len(placements) != 1 or placements[0].get('success','').lower() != 'true':
            problems.append(f'case {i}: confirmed target placement missing')
        expected_health = {1:1000-delta, 2:1000-delta, 3:1000-2*delta}
        for stage in (1,2,3):
            matching = [e for e in health if e.get('stage') == str(stage) and e.get('target') == target
                        and e.get('health') == str(expected_health[stage])
                        and e.get('receipts') == str(1 if stage < 3 else 2)]
            if len(matching) != 1:
                problems.append(f'case {i}: authority stage {stage} health/receipts differ')
            seen = [e for e in obs if e.get('case') == str(i) and e.get('target') == target
                    and e.get('marker') == str(i*10+stage) and e.get('netmode') == '3'
                    and e.get('health') == str(expected_health[stage])
                    and e.get('receipts') == str(1 if stage < 3 else 2)]
            if len(seen) != 1:
                problems.append(f'case {i}: independent observer stage {stage} differs')
        authored = phase(dr, 'authored')
        if len(authored) != 1 or authored[0].get('speed') != '600':
            problems.append(f'case {i}: authored movement start missing')
        impacts = [e for e in sr if e.get('phase') == 'impact' and e.get('target') == target]
        if len(impacts) != 2 or any(e.get('type') != damage_type or e.get('upgrade') != '0'
                                 or numeric(e, 'volume_scale') != 1
                                 or 'head' in e.get('bone', '').lower() for e in impacts):
            problems.append(f'case {i}: stock body damage conditions differ')
        sample = phase(dr, 'sampling')
        if not sample or any(e.get('supported','').lower() != 'false' for e in sample):
            problems.append(f'case {i}: unsupported weapon threshold context missing')
        if not phase(sr, 'complete') or not phase(dr, 'finished'):
            problems.append(f'case {i}: completion missing')
        images = [str(captures[j]) for j,e in enumerate(obs) if j < len(captures) and e.get('case') == str(i)]
        cases.append(dict(name=name, target=target, damage_type=damage_type,
                          expected_deltas=[delta,delta], input='authored synthetic', observer_captures=images))
    gaps = [e for e in dr if e.get('phase') == 'gap' and e.get('case') == '3']
    try:
        if len(gaps) != 1 or gaps[0].get('gap_authored','').lower() != 'true' or int(gaps[0]['rejected_after']) <= int(gaps[0]['rejected_before']):
            problems.append('long melee rejected gap was not sampled')
    except (KeyError, ValueError):
        problems.append('malformed rejected-gap diagnostics')
    if len([e for e in sr if e.get('phase') == 'precondition']) != 4 or any(e.get('phase') == 'blocked' for e in sr):
        problems.append('neutral perk preconditions missing or blocked')
    health = analyze(server, observer, cases)
    transport = verify_transport(server, driver, observer)
    return dict(passed=not problems and health['passed'] and transport['passed'], problems=problems,
                damage=health, transport=transport, scope='Four authored synthetic cases; one-fist report remains open')

def source_hashes():
    return {n:{p.relative_to(ROOT/'script'/n).as_posix():digest(p)
               for p in sorted((ROOT/'script'/n).rglob('*.uc'))} for n in PACKAGES}

def prepare(a):
    release = verify_release(a.release)
    server_exe, _ = verify_server(a.server_root)
    game_exe = a.game_root/'Binaries/Win64/KFGame.exe'
    if digest(game_exe) != release['game_sha256']:
        raise RuntimeError('Game differs from audited immutable release')
    compiled = json.loads((a.compiled_run/'run.json').read_text(encoding='utf-8-sig'))
    hashes = source_hashes()
    ready = compiled.get('passed') and compiled.get('sources_sha256') == hashes
    if a.run and not ready:
        raise RuntimeError('Compile fresh runtime packages and production state tests first; no processes launched')
    run = ROOT/'build/melee-runtime-sessions'/datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-%f')
    packages = run/'Packages'; packages.mkdir(parents=True)
    for name in tuple(n+'.u' for n in PACKAGES) + ('KF2VRHands.upk','KF2VRPortal.upk'):
        shutil.copy2(a.compiled_run/'Script'/name, packages/name)
    before = config_hashes(a.user_config)
    if not before:
        raise RuntimeError('Initialized player config is required')
    roles = [role_config(run, name, a.user_config, packages, a.game_root, a.port, a.query_port,
                       a.cache_root.resolve(), combat=False, native_replay=True,
                       vr_controls=True, expected_clients=2) for name in ('server','driver','observer')]
    roles[0]['args'][0] += '?Mutator=MeleeRuntimeTools.VRMeleeFixtureMutator?VRNetQuietZeds=1?VRNetDualWeapons=1?VRNetServerAdapter=1'
    roles[0]['args'].append('-kf2vr-server-adapter')
    roles[1]['args'].append('-kf2vr-input-isolation-probe')
    for role in roles:
        config = Path(role['config_root'])/'KFGame.ini'
        if role['role'] == 'server':
            config.write_text(set_ini(read_ini(config), 'KF2VRNet.KF2VRNetGame',
                            {'bServerAdapter':'true','bIndependentWeapons':'true'}), encoding='utf-16')
        engine = Path(role['config_root'])/'KFEngine.ini'
        text = read_ini(engine)
        section = re.search(r'(?ims)^\[Engine.GameEngine\].*?(?=^\[|\Z)', text)
        existing = re.findall(r'(?im)^[+]?ServerPackages\s*=\s*([^\r\n]+)',section[0]) if section else []
        text = set_ini(text, 'Engine.GameEngine', {'ServerPackages':list(dict.fromkeys(existing+list(PACKAGES)))})
        if role['role'] != 'server':
            text = set_ini(text, 'VoIP', {'bHasVoiceEnabled':'false'})
        engine.write_text(text, encoding='utf-16')
        role['config_hashes'] = config_hashes(Path(role['config_root']))
    pointers = [Path('D:/KF2-VR-integration-20261003/build/multiplayer/current-release.json'),
                Path('D:/KF2-VR/build/multiplayer/current-release.json')]
    record = dict(schema='kf2vr/melee-runtime/1', status='prepared', passed=False, roles=roles,
                  ready_for_runtime=bool(ready), compiled_run=str(a.compiled_run), sources_sha256=hashes,
                  packages_sha256={p.name:digest(p) for p in packages.iterdir()},
                  native_backend_release=str(a.release), native_backend_commit=release['git_head'],
                  release_manifest_sha256=digest(a.release/'release.json'),
                  native_backend_scope='Pinned native backend; current isolated melee scripts, no native rebuild claimed',
                  user_config_before=before, selected_release_before={str(p):digest(p) for p in pointers if p.exists()},
                  game_sha256=digest(game_exe), server_sha256=digest(server_exe))
    return run, record, release, game_exe, server_exe

def run_fixture(a, run, record, release, game_exe, server_exe):
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
    kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p,ctypes.c_uint)
    kernel.ReleaseMutex.argtypes = kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    mutex = kernel.CreateMutexW(None,False,'Local\\KF2VR_DevelopmentFixture')
    locked = False; processes=[]; deployments=[]
    def save():
        (run/'session.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
    def wait_for(test, timeout, phase):
        deadline=time.monotonic()+timeout
        record['status']=phase; save(); print('PHASE '+phase,flush=True)
        while time.monotonic()<deadline:
            if test(): return
            if any(p.poll() is not None for p in processes):
                raise RuntimeError('Owned process exited before '+phase)
            time.sleep(.5)
        raise RuntimeError('Timed out: '+phase)
    try:
        if not mutex: raise RuntimeError('Cannot open fixture mutex')
        locked=kernel.WaitForSingleObject(mutex,0) in (0,0x80)
        if not locked: raise RuntimeError('Heavy gate is occupied; no processes launched')
        existing=subprocess.check_output(['tasklist','/FO','CSV','/NH'],text=True)
        if re.search(r'"KF(?:Game|Editor|Server)\.exe"',existing,re.I):
            raise RuntimeError('Existing game/server/editor preserved; no processes launched')
        for port in (a.port,a.port+10,a.port+20,a.query_port,a.query_port+10,a.query_port+20): check_port(port)
        if source_hashes()!=record['sources_sha256']: raise RuntimeError('Sources changed after preparation')
        for name,expected in record['packages_sha256'].items():
            if digest(run/'Packages'/name)!=expected: raise RuntimeError('Prepared package changed')
        native=release['native_build']
        deployments.append(NativeDeployment(a.release/'ServerNative',server_exe.parent,run/'server-native-backup',
                            {'artifacts_sha256':native['server_artifacts_sha256']},digest,server=True))
        deployments.append(NativeDeployment(a.release/'Native',game_exe.parent,run/'client-native-backup',native,digest))
        for deployment in deployments: deployment.install()
        environment={k:v for k,v in os.environ.items() if not k.startswith('KF2VR_')}
        environment.update(SteamAppId='232090',SteamGameId='232090')
        roles=record['roles']
        def start(role, exe):
            startup=subprocess.STARTUPINFO();startup.dwFlags=subprocess.STARTF_USESHOWWINDOW;startup.wShowWindow=0
            env=environment.copy()
            if role['role'] in ('server','driver'):
                key='KF2VR_SERVER_LOG_PATH' if role['role']=='server' else 'KF2VR_LOG_PATH'
                role['native_log']=str(Path(role['log']).with_name('native.log'));env[key]=role['native_log']
            with Path(role['log']).with_name('console.log').open('wb') as stream:
                proc=subprocess.Popen(unreal_command(exe,role['args']),cwd=a.server_root if role['role']=='server' else exe.parent,
                                      env=env,startupinfo=startup,stdin=subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT)
            processes.append(proc);role['pid']=proc.pid;save();return proc
        server=start(roles[0],server_exe)
        def server_ready():
            log=log_text(roles[0]);native_path=Path(roles[0]['native_log'])
            return local_lan_readiness(log,a.port,'kf-burningparis')['passed'] and native_path.exists() and 'server_adapter ready=1' in native_path.read_text(errors='replace')
        wait_for(server_ready,120,'server_ready')
        driver=start(roles[1],game_exe)
        await_client_startup(roles[1],server,driver,120)
        wait_for(lambda:any(e.get('hello','').lower()=='true' and e.get('perk_ready','').lower()=='true'
                            for e in events(log_text(roles[1]),'status')),120,'driver_lobby')
        observer=start(roles[2],game_exe)
        await_client_startup(roles[2],server,observer,120)
        def cases_complete():
            rows=fixture_rows(log_text(roles[0]))
            blocked=[e for e in rows if e.get('phase')=='blocked']
            if blocked:
                raise RuntimeError('Fixture setup blocked: '+blocked[-1].get('reason','unknown'))
            return len([e for e in rows if e.get('phase')=='complete'])==4 and len(fixture_rows(log_text(roles[2]),'KF2VR_MELEE_OBSERVER'))==12
        wait_for(cases_complete,180,'four_melee_cases')
        # Let the last screenshot render and the authored auto-quit finish.
        for proc in processes:
            try: proc.wait(timeout=12)
            except subprocess.TimeoutExpired: pass
        capture_root=run/'observer'/'Screenshots'
        # role_config's explicit Core.System.ScreenShotPath is the source of truth.
        engine=read_ini(Path(roles[2]['config_root'])/'KFEngine.ini')
        match=re.search(r'(?im)^ScreenShotPath=(.*)$',engine)
        if match: capture_root=Path(match[1].strip())
        originals=sorted(p for p in capture_root.rglob('*') if p.suffix.lower() in ('.bmp','.png'))
        captures=[]
        for i,p in enumerate(originals):
            if p.suffix.lower()=='.bmp':
                out=run/'observer'/f'capture-{i:02}.png';bmp_to_png(p,out);captures.append(out)
            else: captures.append(p)
        result=runtime_evidence(*(log_text(r) for r in roles),captures)
        native_log=Path(roles[1]['native_log']).read_text(errors='replace')
        if 'local hand replay; stock renderer; no XR session' not in native_log:
            result['problems'].append('native authored backend evidence missing');result['passed']=False
        record['evidence']=result;record['passed']=result['passed'];record['status']='passed' if record['passed'] else 'failed'
    except Exception as error:
        record['status']='failed';record['error']=str(error);record['passed']=False
    finally:
        cleanup=[]
        # Only handles returned by this runner are eligible; no name/PID sweeping.
        for proc in reversed(processes):
            if proc.poll() is None:
                proc.terminate()
                try: proc.wait(timeout=15)
                except subprocess.TimeoutExpired: cleanup.append(f'Owned process still running: {proc.pid}')
        if not cleanup:
            for deployment in reversed(deployments): cleanup.extend(deployment.restore())
        record['cleanup_errors']=cleanup
        record['user_config_preserved']=config_hashes(a.user_config)==record['user_config_before']
        record['selection_preserved']=all(Path(p).exists() and digest(Path(p))==h for p,h in record['selected_release_before'].items())
        record['all_owned_processes_exited']=all(p.poll() is not None for p in processes)
        if cleanup or not record['user_config_preserved'] or not record['selection_preserved']: record['passed']=False
        save()
        if locked: kernel.ReleaseMutex(mutex)
        if mutex: kernel.CloseHandle(mutex)
    return 0 if record['passed'] else 1

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--compiled-run',required=True,type=Path)
    p.add_argument('--release',type=Path,default=Path('D:/KF2-VR-integration-20261003/build/multiplayer/releases/KF2VR-Multiplayer-20261003-040423'))
    p.add_argument('--game-root',type=Path,default=Path('D:/SteamLibrary/steamapps/common/killingfloor2'))
    p.add_argument('--server-root',type=Path,default=Path('D:/KF2-VR/build/multiplayer/server'))
    p.add_argument('--user-config',type=Path,default=Path.home()/'Documents/My Games/KillingFloor2/KFGame/Config')
    p.add_argument('--cache-root',type=Path,default=Path('D:/KF2-VR/build/workshop-cache'))
    p.add_argument('--port',type=int,default=19777);p.add_argument('--query-port',type=int,default=39015)
    p.add_argument('--run',action='store_true')
    a=p.parse_args()
    ports=(a.port,a.port+10,a.port+20,a.query_port,a.query_port+10,a.query_port+20)
    if len(set(ports))!=6 or any(x<1024 or x>65000 for x in ports):p.error('six distinct valid UDP ports required')
    run,record,release,game,server=prepare(a)
    (run/'session.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
    print('Session receipt: '+str(run/'session.json'),flush=True)
    print('Runtime source compile current: '+str(record['ready_for_runtime']),flush=True)
    return run_fixture(a,run,record,release,game,server) if a.run else 0

if __name__=='__main__':raise SystemExit(main())
