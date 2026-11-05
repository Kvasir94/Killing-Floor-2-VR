"""Modular access to existing bounded LAN diagnostics; no new network scenario."""
from contextlib import contextmanager
from copy import deepcopy
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/multiplayer'))
from release_state import digest, verify_release, verify_workspace
from session import config_hashes, verify_server


def plan_network(weapons, tests):
    """Do not silently widen a requested weapon subset to a fixed fixture."""
    weapons = list(dict.fromkeys(v for item in weapons for v in item.split(',') if v))
    aliases = {'network-smoke': 'replication', 'physical-reload': 'network-reload'}
    selected = []
    for item in tests:
        for value in item.split(','):
            values = ['replication', 'network-reload'] if value == 'all' else [aliases.get(value, value)]
            for value in values:
                if value not in ('replication', 'network-reload'):
                    raise ValueError('Unknown network test: '+value)
                if value not in selected:
                    selected.append(value)
    if not weapons or not selected:
        raise ValueError('Choose at least one weapon and network test')
    jobs = []

    def add(test, actual, route, reason=None):
        jobs.append(dict(weapon=','.join(actual), case='network', tests=[test], scope='network',
                         actual_weapons=actual, route=route,
                         status='SKIPPED-UNSUPPORTED' if reason else 'PLANNED', reason=reason))

    for test in selected:
        if test == 'replication':
            required = ['1858', '9mm']
            if all(w in weapons for w in required):
                add(test, required, 'paired-weapons')
            elif any(w in weapons for w in required):
                add(test, [w for w in weapons if w in required], 'paired-weapons',
                    'Existing network smoke runs 1858 then 9mm in one client launch; select both families')
            unsupported = [w for w in weapons if w not in required]
        else:
            if '9mm' in weapons:
                add(test, ['9mm'], 'physical-reload-9mm')
            unsupported = [w for w in weapons if w != '9mm']
        if unsupported:
            add(test, unsupported, None, 'No existing '+test+' route for these weapon families')
    return jobs


def network_command(candidate, job, output, game_root, server_root, user_config, run=False):
    command = [sys.executable, str(ROOT/'tools/multiplayer/session.py'), '--release', str(candidate),
               '--game-root', str(game_root), '--server-root', str(server_root),
               '--user-config', str(user_config), '--output-root', str(output),
               '--cache-root', str(ROOT/'build/workshop-cache'), '--duration', '30',
               '--startup-timeout', '120', '--client-startup-timeout', '240', '--lan-no-voice']
    if job['route'] == 'paired-weapons':
        command += ['--native-replay', '--server-adapter', '--paired-weapons', '--clients', '1']
    elif job['route'] == 'physical-reload-9mm':
        # Existing session route enables native replay, server adapter and two clients.
        command += ['--physical-reload-9mm']
    else:
        raise ValueError('No executable network route')
    return command + (['--run'] if run else [])


def network_result(receipt, job, candidate_name, manifest_hash, code, run, logs):
    errors = []
    if code:
        errors.append(receipt.get('error') or 'Existing network runner failed; inspect runner log')
    if receipt.get('release') != candidate_name or receipt.get('release_manifest_sha256') != manifest_hash:
        errors.append('Network receipt candidate identity mismatch')
    if run:
        if receipt.get('runtime_pass') is not True:
            errors.append('Network runtime checks did not pass')
        if receipt.get('user_config_preserved') is not True or receipt.get('cleanup_errors') != []:
            errors.append('Network user config or native deployment cleanup failed')
        if not receipt.get('finished_utc'):
            errors.append('Network receipt has no final completion')
        if receipt.get('input_isolation_pass') is not True or receipt.get('native_replay_pass') is not True:
            errors.append('Native input/isolation evidence missing')
        key = 'paired_smoke' if job['route'] == 'paired-weapons' else 'physical_reload_9mm'
        if receipt.get(key, {}).get('passed') is not True:
            errors.append('Required '+key+' observations did not pass')
        if any(re.search(r'ScriptWarning:|ScriptError:|Critical:|Fatal error', text, re.I) for text in logs):
            errors.append('Runtime script warning or critical error in network role logs')
    elif receipt.get('status') != 'prepared':
        errors.append('Existing network runner did not prepare a session')
    return dict(status='FAILED' if errors else 'PASS-BOUNDED-NETWORK' if run else 'PREPARED',
                errors=errors, pids=[r['pid'] for r in receipt.get('roles', []) if r.get('pid')],
                cleanup_errors=receipt.get('cleanup_errors', []),
                physical_reload=receipt.get('physical_reload_9mm'), paired_smoke=receipt.get('paired_smoke'),
                headset_accepted=False, remote_network_accepted=False)


@contextmanager
def game_test_gate():
    """The existing child session owns DevelopmentFixture; hold only the global game lease here."""
    import ctypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
    kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    kernel.ReleaseMutex.argtypes = (ctypes.c_void_p,)
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    mutex = kernel.CreateMutexW(None, False, r'Local\KFVR_GameTest')
    locked = bool(mutex) and kernel.WaitForSingleObject(mutex, 0) in (0, 0x80)
    try:
        if not locked:
            raise RuntimeError('Shared game-test lease busy; network suite deferred')
        yield
    finally:
        if locked:
            kernel.ReleaseMutex(mutex)
        if mutex:
            kernel.CloseHandle(mutex)


def execute_network(candidate, jobs, output, *, game_root=None, server_root=None, user_config=None, run=False):
    """Reuse existing session.py, its finite phase deadlines, cleanup and strict observations."""
    candidate, output = Path(candidate).resolve(), Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT/'build').resolve()):
        raise RuntimeError('Network suite needs a fresh output directory inside checkout build/')
    if candidate.parent != (ROOT/'build/multiplayer/releases').resolve():
        raise RuntimeError('Network suite candidate must be a generated repository release')
    output.mkdir(parents=True)
    pointer = ROOT/'build/multiplayer/current-release.json'
    pointer_hash = digest(pointer)
    result = dict(jobs=deepcopy(jobs), errors=[], runtime_invoked=False, output=str(output),
                  receipt=str(output/'network.json'), headset_accepted=False, remote_network_accepted=False)

    def save():
        result['selection_preserved'] = digest(pointer) == pointer_hash
        Path(result['receipt']).write_text(json.dumps(result, indent=2), encoding='utf-8')

    try:
        manifest = verify_release(candidate)
        verify_workspace(ROOT, manifest)
        manifest_hash = digest(candidate/'release.json')
        result.update(candidate=str(candidate), candidate_manifest_sha256=manifest_hash)
        game_root = Path(game_root) if game_root else Path(json.loads(
            (ROOT/'docs/intake/install_manifest.json').read_text(encoding='utf-8-sig'))['game_root'])
        server_root = Path(server_root) if server_root else ROOT/'build/multiplayer/server'
        verify_server(server_root)
        if user_config is None:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                                r'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') as key:
                user_config = Path(os.path.expandvars(winreg.QueryValueEx(key, 'Personal')[0]))/'My Games/KillingFloor2/KFGame/Config'
        user_config = Path(user_config)
        profile = Path.home()/'AppData/Local/KF2VR/Profile'
        profile_before = config_hashes(profile)
        for index, job in enumerate(result['jobs']):
            if job['status'] != 'PLANNED':
                continue
            verify_workspace(ROOT, manifest)
            if digest(pointer) != pointer_hash:
                raise RuntimeError('Player selection changed; network suite stopped')
            case_output = output/f'{index+1:02d}-{job["tests"][0]}'
            case_output.mkdir()
            runner_log = case_output/'runner.log'
            job['logs'] = dict(runner=str(runner_log))
            command = network_command(candidate, job, case_output, game_root, server_root, user_config, run)
            job['command'] = command
            save()

            def invoke():
                with runner_log.open('w', encoding='utf-8') as handle:
                    return subprocess.run(command, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT,
                        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0)).returncode

            if run:
                from run import steam_preflight
                with game_test_gate():
                    result['steam_prerequisite'] = steam_preflight()
                    result['runtime_invoked'] = True
                    code = invoke()
            else:
                code = invoke()
            receipts = list(case_output.glob('*/run.json'))
            if len(receipts) != 1:
                job.update(status='FAILED', errors=['Expected one existing network session receipt; inspect runner log'])
                save()
                raise RuntimeError(job['errors'][0])
            receipt_path = receipts[0]
            receipt = json.loads(receipt_path.read_text(encoding='utf-8-sig'))
            job['logs']['receipt'] = str(receipt_path)
            texts = []
            from run import log_text
            for role in receipt.get('roles', []):
                job['logs'][role['role']] = role['log']
                texts.append(log_text(Path(role['log'])))
                if role.get('native_log'):
                    job['logs'][role['role']+'_native'] = role['native_log']
            job.update(network_result(receipt, job, candidate.name, manifest_hash, code, run, texts))
            if config_hashes(profile) != profile_before:
                job['status'] = 'FAILED'
                job['errors'].append('Saved launcher profile changed during network suite')
            save()
            if job['status'] == 'FAILED':
                raise RuntimeError('Network case failed; remaining cases were not launched')
    except Exception as error:
        result['errors'].append(str(error))
    finally:
        for job in result['jobs']:
            if job['status'] == 'PLANNED':
                job.update(status='NOT-RUN', reason='Network suite stopped before this case')
        save()
    return result
