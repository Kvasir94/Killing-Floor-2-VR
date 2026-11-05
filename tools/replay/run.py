"""Run a prepared, isolated bootstrap session with a verified native input tape.
Only initial setup/observations belong in the optional observer package.
"""
import argparse, hashlib, json, math, os, re, shutil, subprocess, time
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
import sys
sys.path.insert(0, str(ROOT / 'tools/multiplayer'))
from native_fixture import NativeDeployment
from session import config_hashes
sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixture


def plan_batch(weapons, tests, cases, scope='solo', catalog=None, keep_chamber='on', lose_ammo='on', recover_mags='on'):
    """Select existing executable routes; unsupported combinations stay explicit."""
    from ammo_prepare import FAMILIES
    def selected(items, known, aliases=None):
        tokens = [v for item in items for v in item.split(',') if v]
        expanded = []
        for value in tokens:
            expanded.extend(known if value == 'all' else (aliases or {}).get(value, [value]))
        unknown = set(expanded) - set(known)
        if unknown:
            raise ValueError('Unknown selection: '+', '.join(sorted(unknown)))
        return list(dict.fromkeys(expanded))
    from weapons import select_weapons, hold_candidate
    weapons = select_weapons(weapons, catalog)
    known_tests = (['hold', 'tactical-hip', 'dual-contention', 'magazine-hip', 'revolver-hip'] if scope == 'solo' else
                   ['replication', 'network-reload'] if scope == 'network' else
                   ['hold', 'tactical-hip', 'dual-contention', 'magazine-hip', 'revolver-hip', 'replication', 'network-reload'])
    tests = selected(tests, known_tests,
                     {'geometry': ['tactical-hip', 'dual-contention']})
    cases = selected(cases, ['normal', 'dual'])
    if not weapons or not tests or not cases:
        raise ValueError('Choose at least one weapon, test and case')
    jobs = []
    def values(selection):
        if selection not in ('on', 'off', 'both'):
            raise ValueError('Option profiles require on, off or both')
        return (True, False) if selection == 'both' else (selection == 'on',)
    profiles = [(k, l, r) for k in values(keep_chamber) for l in values(lose_ammo) for r in values(recover_mags)]
    for weapon in weapons if scope != 'network' else []:
        if 'hold' in tests:
            for case in cases:
                reason = ('Hold uses the fixed all-ON baseline; option profiles require magazine-hip' if any(p != 'on' for p in (keep_chamber, lose_ammo, recover_mags)) else
                          'Dual setup supports paired 9mm only' if case == 'dual' and weapon != '9mm' else
                          'Legacy dual hold tape assumes stock-full forbids realistic top-up; use geometry for the current paired contract'
                          if case == 'dual' else
                          'No executable hold contract for this family; lifecycle plans remain untested'
                          if not hold_candidate(weapon, catalog) else None)
                jobs.append(dict(weapon=weapon, case=case, tests=['hold'], geometry_input=False,
                                 lifecycle_case=None, status='SKIPPED-UNSUPPORTED' if reason else 'PLANNED', reason=reason))
        geometry = [t for t in tests if t in ('tactical-hip', 'dual-contention')]
        if geometry:
            reason = ('Legacy geometry uses the fixed all-ON baseline; option profiles require magazine-hip'
                      if any(p != 'on' for p in (keep_chamber, lose_ammo, recover_mags)) else
                      None if weapon == '9mm' and 'dual' in cases else 'Geometry contacts currently support paired 9mm in dual mode only')
            jobs.append(dict(weapon=weapon, case='dual', tests=geometry, geometry_input=True,
                lifecycle_case='dual-removal-backend-busy' if 'dual-contention' in geometry else 'hip-tactical-at-capacity',
                status='SKIPPED-UNSUPPORTED' if reason else 'PLANNED', reason=reason))
        if 'magazine-hip' in tests:
            from weapons import weapon_path
            row = next((r for r in catalog or [] if r['weapon'].lower() == weapon_path(weapon).lower()), None)
            for case in cases:
                for keep, lose, recover in profiles:
                    reason = ('Recovery OFF discard accounting is not implemented' if not recover else
                              'No detachable magazine contract for this weapon family' if not hold_candidate(weapon, catalog) else
                              'Registry profile does not support occupied-hand hip reload' if row is not None and row.get('magazineHip') not in (True, 'True') else
                              'Registry class has no paired weapon family' if case == 'dual' and row is not None and not row['dual'] else None)
                    identity = re.sub(r'[^A-Za-z0-9_]', '_', weapon)+'_'+case+f'_k{int(keep)}l{int(lose)}r{int(recover)}'
                    jobs.append(dict(weapon=weapon, case=case, tests=['magazine-hip'], module='magazine-hip',
                        geometry_input=True, lifecycle_case=identity, keep_chamber=keep, lose_ammo=lose,
                        recover_mags=recover, status='SKIPPED-UNSUPPORTED' if reason else 'PLANNED', reason=reason))
        if 'revolver-hip' in tests:
            from weapons import weapon_path
            row = next((r for r in catalog or [] if r['weapon'].lower() == weapon_path(weapon).lower()), None)
            for case in cases:
                reason = ('No revolver hip profile in the production catalog' if row is not None and row.get('family') != 'revolver' else
                          'Registry class has no paired weapon family' if case == 'dual' and row is not None and not row['dual'] else
                          'No known revolver hip alias; provide its registered canonical class' if row is None and '.' not in weapon and weapon not in ('1858', 'sw500', 'rhino') else None)
                jobs.append(dict(weapon=weapon, case=case, tests=['revolver-hip'], module='revolver-hip',
                    geometry_input=True, lifecycle_case=re.sub(r'[^A-Za-z0-9_]', '_', weapon)+'_'+case+'_cylinder',
                    keep_chamber=profiles[0][0], lose_ammo=profiles[0][1], recover_mags=profiles[0][2],
                    option_effect='ammo-loss-and-recovery', status='SKIPPED-UNSUPPORTED' if reason else 'PLANNED', reason=reason))
    for job in jobs: job['scope'] = 'solo'
    network_tests = [t for t in tests if t in ('replication', 'network-reload')]
    if scope != 'solo' and network_tests:
        from network_suite import plan_network
        jobs.extend(plan_network(weapons, network_tests))
    return jobs


def stage_environment(command):
    env = os.environ.copy()
    if Path(command[0]).name.lower() == 'powershell.exe':
        # Match the normal launcher: PowerShell 7's inherited module path can
        # hide Windows PowerShell built-ins such as Get-FileHash.
        env = {k: v for k, v in env.items() if k.upper() != 'PSMODULEPATH'}
    return env


def parse_steam_processes(text):
    """Read tasklist's CSV fields without depending on localized headings."""
    import csv
    processes = []
    for row in csv.reader(text.splitlines()):
        if len(row) >= 4 and row[0].lower() == 'steam.exe':
            try:
                processes.append(dict(pid=int(row[1]), session_id=int(row[3])))
            except ValueError:
                raise RuntimeError('Could not read the Steam process/session prerequisite') from None
    return processes


def validate_steam_prerequisite(processes, session_id, active_pid, client_dll64, *, dll_exists=None):
    """Process readiness only; the game's Steam API result checks authentication."""
    same_session = [p for p in processes if p['session_id'] == session_id]
    other_session = {p['pid'] for p in processes if p['session_id'] != session_id}
    # Steam can leave a stale ActiveProcess pid after a self-update restart while
    # one signed-in client runs here. Accept that single client; the game's own
    # Steam API result still decides authentication.
    stale = active_pid not in {p['pid'] for p in same_session}
    if not same_session:
        reason = 'Steam is not running in this Windows session'
    elif stale and (len(same_session) != 1 or active_pid in other_session):
        reason = 'Steam ActiveProcess does not match a live Steam process in this Windows session'
    elif not client_dll64 or not (dll_exists or Path.is_file)(Path(client_dll64)):
        reason = 'Steam ActiveProcess has no existing SteamClientDll64'
    else:
        return dict(process_ready=True, authentication_verified=False, stale_active_process=stale)
    raise RuntimeError(reason + '; open Steam, sign in, wait for startup to finish, then retry the replay. '
                       'The harness does not launch or restart Steam.')


def steam_preflight():
    """Bounded read-only check before costly work and before native deployment."""
    import ctypes
    from ctypes import wintypes
    import winreg
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.ProcessIdToSessionId.argtypes = (wintypes.DWORD, ctypes.POINTER(wintypes.DWORD))
    kernel.ProcessIdToSessionId.restype = wintypes.BOOL
    session_id = wintypes.DWORD()
    if not kernel.ProcessIdToSessionId(os.getpid(), ctypes.byref(session_id)):
        raise RuntimeError('Cannot inspect this Windows session for the Steam prerequisite')
    try:
        output = subprocess.check_output(['tasklist', '/FI', 'IMAGENAME eq steam.exe', '/FO', 'CSV', '/NH'],
            creationflags=subprocess.CREATE_NO_WINDOW, text=True, errors='replace', timeout=10)
        processes = parse_steam_processes(output)
        active_pid, client_dll64 = None, None
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam\ActiveProcess') as key:
                active_pid = winreg.QueryValueEx(key, 'pid')[0]
                client_dll64 = winreg.QueryValueEx(key, 'SteamClientDll64')[0]
        except OSError:
            pass
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError('Cannot inspect the Steam prerequisite: '+str(error)) from error
    return validate_steam_prerequisite(processes, session_id.value, active_pid, client_dll64)


def runtime_job_result(receipt, code, geometry, game_log):
    from collections import Counter
    diagnostic = receipt.get('geometry_observations', receipt.get('observations', {}))
    status = ('OBSERVED-BOUNDED' if geometry else 'PASS-BOUNDED-HOLD') if code == 0 and receipt.get('observer_complete') else (
        'UNTESTED' if diagnostic.get('status') == 'UNTESTED' else 'FAILED')
    errors = list(diagnostic.get('errors', []))
    if receipt.get('preflight_error'):
        status = 'FAILED-STARTUP'
        errors.append(receipt['preflight_error'])
    exit_code = receipt.get('exit_code')
    if code and exit_code not in (None, 0):
        status = 'FAILED-RUNTIME' if receipt.get('playable') else 'FAILED-STARTUP'
        errors.append(f'Game process exited 0x{exit_code & 0xffffffff:08X}')
    fatal = list(dict.fromkeys(re.findall(r'(?m)^.*?Critical:\s*(.+)$', game_log)))
    errors.extend('Critical: '+line for line in fatal[:3])
    if receipt.get('timeout'):
        status = 'FAILED-RUNTIME' if receipt.get('playable') else 'FAILED-STARTUP'
        errors.append('Timed out during '+str(receipt.get('timeout_phase', 'unknown phase')))
    startup = receipt.get('startup_diagnostics', {})
    if startup.get('steam_client_initialized') is False and startup.get('steam_required_error'):
        errors.append('Steam Client API initialized 0; the game requires a signed-in Steam session')
    if 'KF2VR_INPUT_ISOLATION phase=abort key=F10' in game_log:
        status = 'ABORTED'
        errors.append('F10 aborted the diagnostic; remaining batch cases must not launch')
    messages = Counter(message.strip() for message in
                       re.findall(r'(?m)^.*?\b(?:Error|Warning):\s*(.+)$', game_log))
    return dict(status=status, errors=errors, process_exit=exit_code,
        sample_counts=receipt.get('observations', {}).get('samples'),
        callback_rows=diagnostic.get('callback_rows'), geometry_rows=diagnostic.get('geometry_rows'),
        startup_phase=receipt.get('startup_diagnostics', {}).get('phase'),
        isolation_verified=receipt.get('physical_input_isolation_verified'),
        log_notices=[dict(message=message, count=count) for message, count in messages.items()],
        cleanup_errors=receipt.get('cleanup_errors', []))


@contextmanager
def compiler_gate():
    """Serialize genuinely shared SDK/commandlet work across projects."""
    import ctypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
    kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    kernel.ReleaseMutex.argtypes = (ctypes.c_void_p,)
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    mutex = kernel.CreateMutexW(None, False, r'Local\KF2VR_NativeBuild')
    locked = bool(mutex) and kernel.WaitForSingleObject(mutex, 0) in (0, 0x80)
    try:
        if not locked:
            raise RuntimeError('Shared compiler lease busy; defer this batch')
        yield
    finally:
        if locked:
            kernel.ReleaseMutex(mutex)
        if mutex:
            kernel.CloseHandle(mutex)


def batch_main():
    """Prepare, compile, run and summarize existing cases sequentially."""
    from collections import Counter
    from datetime import datetime, timezone
    from release_state import verify_release, verify_workspace
    p = argparse.ArgumentParser(description='End-to-end batch mode for the existing replay harness')
    p.add_argument('--batch', action='store_true')
    p.add_argument('--weapons', nargs='+', default=['9mm'], help='Names or all; spaces and commas supported')
    p.add_argument('--tests', '--test-types', nargs='+', default=['all'], help='hold, tactical-hip, dual-contention, geometry, replication, network-reload, or all')
    p.add_argument('--scope', choices=('solo', 'network', 'both'), default='solo')
    p.add_argument('--catalog', type=Path, help='Actual runtime registry catalog for full-gun selection')
    p.add_argument('--keep-chamber', choices=('on', 'off', 'both'), default='on')
    p.add_argument('--lose-ammo', choices=('on', 'off', 'both'), default='on')
    p.add_argument('--recover-mags', choices=('on', 'off', 'both'), default='on')
    p.add_argument('--cases', nargs='+', default=['normal', 'dual'])
    p.add_argument('--plan', action='store_true', help='Print supported/unsupported selections without creating files')
    p.add_argument('--candidate', type=Path)
    p.add_argument('--build', action='store_true', help='Build one fresh DLSS candidate without selecting it')
    p.add_argument('--run', action='store_true', help='Execute each prepared case; otherwise compile and prepare only')
    p.add_argument('--output', type=Path)
    p.add_argument('--game-root', type=Path)
    p.add_argument('--server-root', type=Path)
    p.add_argument('--user-config', type=Path)
    p.add_argument('--timeout', type=int, default=600)
    p.add_argument('--startup-timeout', type=int, default=240)
    p.add_argument('--fail-fast', action='store_true')
    p.add_argument('--cases-per-launch', type=int, default=8, help='Group 2..16 supported cases per game process')
    opts = p.parse_args()
    try:
        from weapons import read_catalog
        jobs = plan_batch(opts.weapons, opts.tests, opts.cases, opts.scope,
                          read_catalog(opts.catalog) if opts.catalog else None,
                          opts.keep_chamber, opts.lose_ammo, opts.recover_mags)
    except ValueError as error:
        p.error(str(error))
    if opts.plan:
        from suite import group_cases
        try:
            groups = group_cases(jobs, opts.cases_per_launch)
        except ValueError as error:
            p.error(str(error))
        print(json.dumps(dict(jobs=jobs, launches=groups, runtime_invoked=False, full_reload_accepted=False), indent=2))
        return
    if not opts.build and opts.candidate is None:
        p.error('Pass --candidate or --build; the player selection is never changed')
    if opts.build and opts.candidate:
        p.error('Choose --build or --candidate')
    if not (30 <= opts.timeout <= 600 and 30 <= opts.startup_timeout <= 600):
        p.error('Timeouts must be 30..600 seconds')
    if not any(j['status'] == 'PLANNED' for j in jobs):
        p.error('No executable combinations; use --plan to inspect unsupported selections')
    from suite import group_cases, prepare as prepare_suite
    try:
        groups = group_cases(jobs, opts.cases_per_launch)
    except ValueError as error:
        p.error(str(error))
    output = (opts.output or ROOT/'build/reload-replay'/('batch-'+datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-%f'))).resolve()
    if not output.is_relative_to((ROOT/'build').resolve()) or output.exists():
        p.error('Use a fresh output directory under this checkout build/')
    output.mkdir(parents=True)
    pointer = ROOT/'build/multiplayer/current-release.json'
    selection_hash = digest(pointer)
    result = dict(schema='kf2vr/replay-batch/1', jobs=jobs, requested_run=opts.run,
                  runtime_invoked=False, full_reload_accepted=False, headset_accepted=False,
                  multiplayer_accepted=False, errors=[], source_head=subprocess.check_output(
                      ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip())
    result['launches'] = []
    def save():
        result['counts'] = dict(Counter(j['status'] for j in jobs))
        result['selection_preserved'] = digest(pointer) == selection_hash
        (output/'batch.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        lines = ['# Replay batch', '', 'Bounded offline checks only; headset, network and general reload acceptance remain false.', '',
                 '| Weapon | Mode | Tests | Result | Detail |', '| --- | --- | --- | --- | --- |']
        for job in jobs:
            detail = job.get('reason') or ', '.join(job.get('errors', [])) or ''
            lines.append('| '+ ' | '.join([job['weapon'], job['case'], ', '.join(job['tests']), job['status'], detail.replace('|', '/')])+' |')
        for launch in result['launches']:
            lines += ['', f'Launch {launch["index"]}: {launch["cases"]} cases; PID {launch.get("pid", "pending")}; {launch["status"]}.']
        for job in jobs:
            if job.get('logs'):
                lines += ['', '## '+job['weapon']+' / '+job['case']+' / '+', '.join(job['tests']), '']
                lines += [f'- [{name}](<{path}>)' for name, path in job['logs'].items()]
                if job.get('sample_counts'):
                    lines += ['', 'Observed samples: '+json.dumps(job['sample_counts'])]
                if job.get('geometry_rows') is not None:
                    lines += ['', f'Geometry rows: {job["geometry_rows"]}; production callback rows: {job.get("callback_rows", 0)}.']
                if job.get('startup_phase'):
                    lines += ['', 'Startup: '+job['startup_phase']]
                if job.get('captures'):
                    lines += ['', f'Images: [{job["captures"]["count"]} timestamped captures](<{job["captures"]["index"]}>).']
                if job.get('log_notices'):
                    lines += ['', 'Game log notices (inspect the linked game log for context):', '']
                    lines += [f'- {item["count"]}× {item["message"]}' for item in job['log_notices']]
        if result['errors']:
            lines += ['', 'Batch errors: '+ '; '.join(result['errors'])]
        (output/'summary.md').write_text('\n'.join(lines)+'\n', encoding='utf-8')
    def stage(command, log):
        with log.open('w', encoding='utf-8') as handle:
            return subprocess.run(command, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT,
                env=stage_environment(command),
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0)).returncode
    save()
    try:
        if opts.run:
            result['steam_prerequisite'] = steam_preflight()
        candidate = opts.candidate.resolve() if opts.candidate else None
        if opts.build:
            releases = ROOT/'build/multiplayer/releases'
            before = set(releases.glob('KF2VR-Multiplayer-*'))
            print('KF2VR_REPLAY_BATCH phase=build output='+str(output/'build.log'), flush=True)
            with compiler_gate():
                code = stage(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                              str(ROOT/'tools/build-kf2vr.ps1'), '-NoSelect', '-Parallel', '2'], output/'build.log')
            if code:
                raise RuntimeError('Build failed; see '+str(output/'build.log'))
            created = [path for path in set(releases.glob('KF2VR-Multiplayer-*'))-before if path.is_dir() and (path/'release.json').exists()]
            if len(created) != 1:
                raise RuntimeError('Could not identify one fresh build candidate')
            candidate = created[0]
        manifest = verify_release(candidate)
        verify_workspace(ROOT, manifest)
        result.update(candidate=str(candidate), candidate_manifest_sha256=digest(candidate/'release.json'))
        for launch_index, indices in enumerate(groups):
            cases = [jobs[i] for i in indices]
            run = output/f'launch-{launch_index+1:02d}'
            logs = dict(prepare=str(output/f'{launch_index+1:02d}-prepare.log'),
                        compiler=str(output/f'{launch_index+1:02d}-compiler.log'))
            launch = dict(index=launch_index+1, job_indices=indices, cases=len(cases), logs=logs, status='PREPARING')
            result['launches'].append(launch)
            for job in cases:
                job.update(logs=logs, launch=launch_index+1, phase='preparing')
            save()
            print(f'KF2VR_REPLAY_BATCH phase=prepare launch={launch_index+1} cases={len(cases)}', flush=True)
            with Path(logs['prepare']).open('w', encoding='utf-8') as handle:
                # Preserve setup diagnostics in their own log without hiding errors.
                from contextlib import redirect_stdout
                with redirect_stdout(handle):
                    record = prepare_suite(candidate, cases, run, game_root=opts.game_root, user_config=opts.user_config)
            game = Path(record['native_probe']['destination']).parents[2]
            print(f'KF2VR_REPLAY_BATCH phase=compile launch={launch_index+1}', flush=True)
            with compiler_gate():
                code = stage(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                    str(ROOT/'tools/replay/build-observer.ps1'), '-ProductionScriptRoot', record['package_root'],
                    '-GameRoot', str(game), '-OutputRoot', record['observer_root']], Path(logs['compiler']))
            if code:
                launch['status'] = 'FAILED'
                for job in cases: job.update(status='FAILED', reason='Observer compile failed; see compiler log')
                save()
                if opts.fail_fast: break
                continue
            if not opts.run:
                launch['status'] = 'PREPARED'
                for job in cases: job.update(status='PREPARED', reason='Compiled and prepared; runtime was not requested')
                save()
                continue
            logs.update(runner=str(run/'runner.log'), game=str(run/'driver/game.log'),
                        native=str(run/'native.log'), receipt=str(run/'input-replay-run.json'))
            print(f'KF2VR_REPLAY_BATCH phase=run launch={launch_index+1} cases={len(cases)} log='+logs['runner'], flush=True)
            result['runtime_invoked'] = True
            launch['status'] = 'RUNNING'
            for job in cases: job['phase'] = 'running'
            save()
            code = stage([sys.executable, str(ROOT/'tools/replay/run.py'), '--record', str(run/'run.json'),
                '--source-root', str(ROOT), '--input', record['input_file'], '--reload-case', record['reload_case'],
                '--timeout', str(opts.timeout), '--startup-timeout', str(opts.startup_timeout)], Path(logs['runner']))
            receipt = json.loads(Path(logs['receipt']).read_text()) if Path(logs['receipt']).exists() else {}
            common = runtime_job_result(receipt, code, False, log_text(Path(logs['game'])))
            suite_result = receipt.get('suite_observations', {})
            launch.update(status='COMPLETED' if code == 0 and suite_result.get('passed') else 'FAILED',
                          pid=receipt.get('pid'), errors=common['errors']+suite_result.get('errors', []))
            observed = suite_result.get('cases', [])
            for case_index, job in enumerate(cases):
                job.update(common, phase='complete')
                if case_index < len(observed):
                    detail = observed[case_index]
                    job.update(status=detail['status'], errors=detail['errors'], observations=detail)
                    diagnostic = detail.get('diagnostic', {})
                    job.update(geometry_rows=diagnostic.get('geometry_rows'), callback_rows=diagnostic.get('callback_rows'))
                else:
                    job.update(status='NOT-RUN', reason='Case did not complete; inspect shared launch logs')
                if common['status'] in ('FAILED-STARTUP', 'ABORTED'):
                    job.update(status=common['status'], errors=common['errors'])
                elif code and job['status'] in ('OBSERVED-BOUNDED', 'PASS-BOUNDED-HOLD'):
                    job.update(status='FAILED-SESSION', reason='Case observations completed but shared session failed',
                               errors=common['errors']+suite_result.get('errors', []))
                if not receipt:
                    job.update(status='FAILED-STARTUP', reason='No runtime receipt; inspect runner preflight/lease log')
                if receipt.get('captures'):
                    capture = receipt['captures']
                    job['captures'] = dict(count=sum(e.get('case_index') == case_index+1 for e in capture.get('entries', [])),
                                           index=capture.get('index_html', str(run/'captures/index.html')))
            save()
            if common['status'] in ('ABORTED', 'FAILED-STARTUP') or not receipt:
                raise RuntimeError('Batch stopped after startup failure or abort; inspect shared launch logs')
            if receipt.get('cleanup_errors') or any(receipt.get(key) is False for key in
                ('user_config_preserved', 'selection_preserved', 'saved_profile_preserved')):
                raise RuntimeError('Cleanup/preservation failed; remaining launches were not started')
            if code:
                raise RuntimeError('Suite failed or a reload watchdog fired; inspect cases before another launch')
        network_jobs = [j for j in jobs if j.get('scope') == 'network']
        if network_jobs:
            from network_suite import execute_network
            network = execute_network(candidate, network_jobs, output/'network', game_root=opts.game_root,
                server_root=opts.server_root, user_config=opts.user_config, run=opts.run)
            result['network'] = network
            for original, updated in zip(network_jobs, network['jobs']): original.update(updated)
            result['runtime_invoked'] |= network.get('runtime_invoked', False)
            result['errors'].extend(network.get('errors', []))
            save()
    except Exception as error:
        result['errors'].append(str(error))
    finally:
        for job in jobs:
            if job['status'] == 'PLANNED':
                job.update(status='NOT-RUN', reason='Batch stopped before this case')
        save()
    print('KF2VR_REPLAY_BATCH summary='+str(output/'summary.md')+' counts='+json.dumps(result['counts']), flush=True)
    if result['errors'] or not result['selection_preserved'] or any(j['status'].startswith('FAILED') or j['status'] in ('UNTESTED', 'NOT-RUN', 'ABORTED') for j in jobs):
        raise SystemExit(1)


def running_games(root=None):
    """KF2 game/editor/server processes: those run from root, or (no root) all
    but the replay lanes' fixture copies."""
    paths = subprocess.check_output(['powershell','-NoProfile','-Command',
        '(Get-Process KFGame,KFEditor,KFServer -ErrorAction SilentlyContinue).Path'],
        creationflags=subprocess.CREATE_NO_WINDOW, text=True, errors='replace').splitlines()
    paths = [path.strip() for path in paths if path.strip()]
    if root is None:
        # The shared install: every game except the replay lanes' own copies.
        return [path for path in paths if not fixture.owns(Path(path), fixture.FIXTURES)]
    return [path for path in paths if fixture.owns(Path(path), root)]


@contextmanager
def launch_slot(log, settle=8.0, timeout=90.0):
    """One KF2 cold start at a time across every lane and runner. Three engines
    starting together stalled Steam's main loop past its 15 s watchdog
    (assert_steam: 'CSteamEngine::BMainLoop appears to have stalled'); Steam
    crashed and every later launch failed 'Steam Client API initialized 0'.
    Hold the slot from launch until this game's log shows Steam initialized
    (or it fails), plus a short settle; running games stay parallel."""
    import ctypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
    kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    kernel.ReleaseMutex.argtypes = (ctypes.c_void_p,)
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    mutex = kernel.CreateMutexW(None, False, r'Local\KF2VR_GameLaunch')
    locked = bool(mutex) and kernel.WaitForSingleObject(mutex, int(timeout*4*1000)) in (0, 0x80)
    try:
        yield
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            raw = Path(log).read_bytes() if Path(log).exists() else b''
            # KF2's -ABSLOG is ANSI; accept a UTF-16 log (BOM or NUL-padded) too.
            wide = raw[:2] in (b'\xff\xfe', b'\xfe\xff') or b'\x00' in raw[:200]
            text = raw.decode('utf-16' if wide else 'utf-8', errors='replace')
            if 'Steam Client API initialized' in text or 'Exit: Exiting.' in text:
                break
            time.sleep(1)
        time.sleep(settle)
    finally:
        if locked:
            kernel.ReleaseMutex(mutex)
        if mutex:
            kernel.CloseHandle(mutex)


@contextmanager
def fixture_gate(wait_seconds=0):
    """Own the engine/deployment slot for CLI and PowerShell entrypoints: the
    shared install's, or a lane's own (fixture.py, KF2VR_FIXTURE), waiting up
    to wait_seconds for it in one blocking wait."""
    import ctypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
    kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    kernel.ReleaseMutex.argtypes = (ctypes.c_void_p,)
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    leases = []
    lane = fixture.lane()
    names = ((r'Local\KFVR_GameTest', r'Local\KF2VR_DevelopmentFixture') if lane is None
             else (fixture.lock_name(lane),))
    try:
        for name in names:
            mutex = kernel.CreateMutexW(None, False, name)
            locked = bool(mutex) and kernel.WaitForSingleObject(mutex, int(max(0, wait_seconds)*1000)) in (0, 0x80)
            leases.append((mutex, locked))
            if not locked:
                raise RuntimeError('Runtime lease is busy: '+name)
        # A lane owns only its own copy: other lanes' games don't block it.
        if running_games(None if lane is None else fixture.game_root(lane)):
            raise RuntimeError('Existing game/editor/server; deferred')
        yield
    finally:
        for mutex, locked in reversed(leases):
            if locked:
                kernel.ReleaseMutex(mutex)
            if mutex:
                kernel.CloseHandle(mutex)


def observer_inputs(package):
    paths = list((ROOT/'tools/replay/script').rglob('*.uc')) + list(package.glob('*.u'))
    return {str(p.resolve()):digest(p) for p in sorted(paths)}


def log_text(path):
    if not path.exists():
        return ''
    data = path.read_bytes()
    return data.decode('utf-16' if data[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8-sig', errors='replace')


def changed_log_lines(text, previous):
    """Stream only diagnostic changes; identical polling rows stay quiet."""
    result = []
    for line in text.splitlines():
        marker = re.search(r'(KF2VR_REPLAY_SUITE\b.*|KF2VR_RELOAD_(?:OBSERVER|GEOMETRY|CALLBACK)\b.*|KF2VR_AMMO_(?:OBSERVER|SETUP|PAYLOAD)\b.*|KF2VR_INTERACTIVE_RELOAD\b.*|KF2VR_INPUT_REPLAY\b.*)', line)
        if not marker:
            continue
        value = re.sub(r'\belapsed=[^\s]+\s*', '', marker[1])
        key = ('state', re.search(r'\bhand=([01])', value)[1]) if 'phase=state' in value and re.search(r'\bhand=([01])', value) else ('event', value)
        if previous.get(key) != value:
            previous[key] = value
            result.append(marker[1])
    return result

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()

def disable_script_inputs(data):
    prefix = next((bom for bom in (b'\xff\xfe', b'\xfe\xff', b'\xef\xbb\xbf') if data.startswith(bom)), b'')
    # Single-byte mapping preserves every unrelated ANSI byte; only ASCII
    # flag names/values are interpreted. UTF-16 keeps its original byte order.
    encoding = {b'\xff\xfe':'utf-16-le', b'\xfe\xff':'utf-16-be'}.get(prefix, 'latin1')
    text = data[len(prefix):].decode(encoding)
    for name in ('bPresentationProbe','bDualWieldProbe','bDualHandReplay','bUsabilityCapture',
                 'bBreakActionCapture','bDiagnosticMagazineReloadCapture','bPairedHandReplay',
                 'bMeleeReplay','bGrabReplay','bBashLegReplay','bReloadHintCapture'):
        text = re.sub(r'(?im)^'+name+r'=[^\r\n]*', name+'=False', text)
    return prefix + text.encode(encoding)

def validate_capture_config(data):
    # UE3 accepts ANSI or BOM-marked UTF-16. A UTF-8 BOM makes the first
    # section unreadable; SystemSettings then initializes with zero values.
    if data.startswith(b'\xef\xbb\xbf'):
        raise RuntimeError('UTF-8 BOM is unsafe for UE3 configs; prepare from original bytes or UTF-16')
    text = data.decode('utf-16' if data[:2] in (b'\xff\xfe', b'\xfe\xff') else 'latin1')
    section = re.search(r'(?ims)^\[SystemSettings\][ \t]*\r?\n(.*?)(?=^\[|\Z)', text)
    if not section:
        raise RuntimeError('Capture requires the complete SystemSettings section')
    for key in ('ResX', 'ResY', 'ScreenPercentage', 'MaxDrawDistanceScale'):
        values = re.findall(r'(?im)^'+key+r'[ \t]*=[ \t]*([^\r\n;]+)', section[1])
        try:
            value = float(values[-1])
        except (ValueError, IndexError):
            raise RuntimeError(f'Missing or invalid capture setting: {key}') from None
        if not math.isfinite(value) or value <= 0:
            raise RuntimeError(f'Capture setting must be positive: {key}={value}')

def preflight_configs(args, run):
    for name in ('ENGINE', 'GAME', 'INPUT', 'UI', 'WEB', 'SYSTEMSETTINGS', 'LIGHTMASS', 'BENCHMARKING'):
        matches = [a.split('=', 1)[1] for a in args if a.upper().startswith('-'+name+'INI=')]
        if len(matches) != 1:
            raise RuntimeError(f'Require one isolated {name}INI override')
        path = Path(matches[0]).resolve()
        if not path.is_relative_to(run):
            raise RuntimeError(f'Config must be inside prepared run: {name}')
        data = path.read_bytes()
        if data.startswith(b'\xef\xbb\xbf'):
            raise RuntimeError(f'UTF-8 BOM is unsafe for UE3 configs: {path.name}')
        if name == 'SYSTEMSETTINGS':
            validate_capture_config(data)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--record', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=180)
    parser.add_argument('--startup-timeout', type=int,
                        help='Bounded readiness deadline; reload default 240s, other tapes 120s; total timeout still applies')
    parser.add_argument('--observer', action='store_true')
    parser.add_argument('--reload-case', choices=('normal','dual'))
    opts = parser.parse_args()
    if not 30 <= opts.timeout <= 600:
        raise RuntimeError('Timeout must be 30..600 seconds')
    from ammo_timing import readiness_seen, startup_budget, startup_milestones, timeout_phase
    startup_limit = startup_budget(opts.timeout, opts.startup_timeout, reload_case=bool(opts.reload_case))
    record = json.loads(opts.record.read_text(encoding='utf-8-sig'))
    run = opts.record.resolve().parent
    if opts.reload_case and record.get('reload_case') != opts.reload_case:
        raise RuntimeError('Prepared reload case does not match requested case')
    if (run/'input-replay-run.json').exists() or (run/'ReplayNativeBackup').exists():
        raise RuntimeError('Run already attempted; prepare a fresh isolated session')
    if record['status'] != 'prepared' or record.get('process_started'):
        raise RuntimeError('Require a fresh prepared-only record')
    selection = json.loads((opts.source_root/'build/multiplayer/current-release.json').read_text(encoding='utf-8-sig'))
    if opts.reload_case:
        from release_state import verify_workspace
        if opts.source_root.resolve() != ROOT.resolve():
            raise RuntimeError('Reload replay must use this checkout')
        if digest(ROOT/'build/multiplayer/current-release.json') != record['selected_pointer_sha256']:
            raise RuntimeError('Prepared selection pointer changed')
    if record.get('candidate_root'):
        if not opts.reload_case or opts.source_root.resolve() != ROOT.resolve():
            raise RuntimeError('Explicit ammo candidate requires this checkout and a reload case')
        from ammo_candidate import verify_candidate
        release, manifest = verify_candidate(ROOT, record)
    else:
        release = opts.source_root/'build/multiplayer/releases'/selection['release']
        manifest = json.loads((release/'release.json').read_text(encoding='utf-8-sig'))
    if selection['release'] != record['selected_release']:
        raise RuntimeError('Prepared selection changed')
    expected_manifest = record.get('candidate_manifest_sha256', selection['manifest_sha256'])
    if digest(release/'release.json') != expected_manifest.upper():
        raise RuntimeError('Manifest hash mismatch')
    if opts.reload_case:
        verify_workspace(ROOT, manifest)
    for name, expected in manifest['files_sha256'].items():
        if digest(release/name) != expected.upper():
            raise RuntimeError(f'Release changed: {name}')
    native = ROOT/'build/multiplayer/native'
    receipt = json.loads((native/'build.json').read_text(encoding='utf-8-sig'))
    if not receipt.get('success'):
        raise RuntimeError('Native build unsuccessful')
    for name, expected in receipt['sources_sha256'].items():
        if digest(ROOT/name) != expected.upper():
            raise RuntimeError(f'Stale native build: {name}')
    package = Path(record['package_root']).resolve()
    if not package.is_relative_to(run):
        raise RuntimeError('Package directory must be inside prepared run')
    for item in (release/'Packages').iterdir():
        if item.is_file():
            shutil.copy2(item, package/item.name)
    args = [a.replace('"','') for a in record['arguments']]
    args += ['-kf2vr-input-replay']
    if record.get('replay_suite'):
        from suite import validate_cases
        validate_cases(record['suite_cases'])
        args += ['-kf2vr-replay-suite', '-kf2vr-input-isolation-probe']
        if any(c['geometry_input'] for c in record['suite_cases']):
            args += ['-kf2vr-reload-geometry']
    elif record.get('geometry_input'):
        if (opts.reload_case != 'dual' or record.get('weapon_family') != '9mm' or
            record.get('lifecycle_case') not in ('hip-tactical-at-capacity', 'dual-removal-backend-busy')):
            raise RuntimeError('Geometry input requires the explicit paired 9mm hip audit case')
        args += ['-kf2vr-reload-geometry', '-kf2vr-input-isolation-probe']
    if not all(x in args for x in ('-kf2vr-hand-replay','-onethread')):
        raise RuntimeError('Prepared session must be offline hand replay')
    preflight_configs(args, run)
    # Disable all retired script-driven input paths in the isolated game config.
    config_arg = next(a for a in args if a.upper().startswith('-GAMEINI='))
    config = Path(config_arg.split('=',1)[1]).resolve()
    if not config.is_relative_to(run):
        raise RuntimeError('Config must be inside prepared run')
    config.write_bytes(disable_script_inputs(config.read_bytes()))
    use_observer = opts.observer or opts.reload_case
    if use_observer:
        observer_root = Path(record['observer_root']) if opts.reload_case else ROOT/'build/input-replay'
        if opts.reload_case and not observer_root.resolve().is_relative_to(run):
            raise RuntimeError('Observer must be inside isolated reload run')
        observer = observer_root/'Script/KF2VRReplay.u'
        if not observer.exists():
            raise RuntimeError('Build observer first')
        built = json.loads((observer_root/'observer.json').read_text(encoding='utf-8-sig'))
        if (digest(observer) != built['package_sha256'] or
            digest(ROOT/'tools/replay/script/KF2VRReplay/Classes/ReplayObserver.uc') != built['source_sha256'] or
            digest(package/'KF2VR.u') != built['production_sha256']):
            raise RuntimeError('Observer build is stale or targets a different production package')
        if opts.reload_case and built.get('inputs_sha256') != observer_inputs(package):
            raise RuntimeError('Observer sources or production dependencies differ from compile')
        shutil.copy2(observer, package/observer.name)
        observer_class = 'BatchObserver' if record.get('replay_suite') else 'ReloadObserver' if opts.reload_case else 'ReplayObserver'
        args[0] = args[0].replace('KF2VR.VRDemo', 'KF2VR.VRDemo,KF2VRReplay.'+observer_class)
    replay_copy = run/'input-replay.txt'
    if opts.reload_case and digest(opts.input) != record['input_sha256']:
        raise RuntimeError('Prepared input tape changed')
    shutil.copy2(opts.input.resolve(), replay_copy)
    env = {k:v for k,v in os.environ.items() if not k.upper().startswith('KF2VR_')}
    env.update(record['environment'])
    env['KF2VR_INPUT_REPLAY'] = str(replay_copy)
    if opts.reload_case:
        env.update(KF2VR_INPUT_REPLAY_WAIT_READY='1', KF2VR_INPUT_REPLAY_REALTIME='1')
    destination = Path(record['native_probe']['destination']).parent
    game = destination/'KFGame.exe'
    if digest(game) != record['game_sha256'].upper():
        raise RuntimeError('Game executable changed')
    deploy = NativeDeployment(native/'native/adapter/Release', destination, run/'ReplayNativeBackup', receipt, digest)
    result = {'schema':'kf2vr/input-replay-run/1', 'input_sha256':digest(replay_copy),
              'release':selection['release'], 'native_sha256':receipt['artifacts_sha256'],
              'arguments':args, 'headset_accepted':False}
    if record.get('geometry_input') or record.get('replay_suite'):
        result.update(geometry_input=True, full_reload_accepted=False, multiplayer_accepted=False)
    if record.get('candidate_root'):
        result.update(release=release.name, player_selected_release=selection['release'],
                      candidate=release.name, candidate_manifest_sha256=expected_manifest)
    result.update(startup_timeout_seconds=startup_limit, total_timeout_seconds=opts.timeout)
    if record.get('ammo_observer'):
        result.update(weapon_family=record.get('weapon_family','9mm'),
                      voice_disabled=bool(record.get('voice_disabled',False)))
    owned = None
    user = Path(record['user_config_root']) if opts.reload_case else None
    if user and config_hashes(user) != record['user_config_before']:
        raise RuntimeError('User config changed since preparation')
    profile = Path(record['saved_profile_root']) if record.get('saved_profile_root') else None
    if profile and config_hashes(profile) != record['saved_profile_before']:
        raise RuntimeError('Saved launcher profile changed since preparation')
    if opts.reload_case:
        configs = Path(next(a.split('=',1)[1] for a in args if a.upper().startswith('-GAMEINI='))).parent
        if config_hashes(configs) != record['prepared_config_sha256']:
            raise RuntimeError('Prepared reload config changed')
        from native_fixture import verify_native
        script_receipt = json.loads((ROOT/'build/multiplayer/script/build.json').read_text(encoding='utf-8-sig'))
        verify_native(ROOT, script_receipt, digest)
        if receipt['artifacts_sha256'] != record['native_artifacts_sha256']:
            raise RuntimeError('Native artifacts changed since preparation')
    try:
        try:
            result['steam_prerequisite'] = steam_preflight()
        except RuntimeError as error:
            result['preflight_error'] = str(error)
            result['startup_diagnostics'] = dict(phase='steam-prerequisite-unavailable')
            raise
        deploy.install()
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        owned = subprocess.Popen([str(game),*args],cwd=destination,env=env,startupinfo=startup,
                                 stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        result['pid'] = owned.pid
        result['started_unix'] = time.time()
        started = time.monotonic()
        log = Path(next(a.split('=',1)[1] for a in args if a.upper().startswith('-ABSLOG=')))
        playable = False
        offsets = {}
        streamed = {}
        if opts.reload_case:
            from ammo_startup import StartupProgress, process_counters
            startup_progress = StartupProgress(opts.reload_case)
            last_startup_phase = None
            last_startup_report = 0.0
        while owned.poll() is None:
            elapsed = time.monotonic()-started
            if not playable and log.exists() and not opts.reload_case:
                playable = 'phase=playable' in log_text(log)
            if opts.reload_case:
                for live in (log, Path(env['KF2VR_LOG_PATH'])):
                    content = log_text(live)
                    offset = offsets.get(str(live), 0)
                    # Flush only complete lines so split writes cannot be misreported.
                    tail = content[offset:]
                    end = tail.rfind('\n') + 1
                    for line in changed_log_lines(tail[:end], streamed):
                        print(line, flush=True)
                    offsets[str(live)] = offset + end
                playable = playable or readiness_seen(log_text(log), opts.reload_case)
                progress = startup_progress.observe(elapsed, log_text(log),
                    log_text(Path(env['KF2VR_LOG_PATH'])), process_counters(owned._handle))
                if not playable and (progress['phase'] != last_startup_phase
                                     or elapsed - last_startup_report >= 30):
                    print('KF2VR_STARTUP '+json.dumps(progress, sort_keys=True), flush=True)
                    last_startup_phase = progress['phase']
                    last_startup_report = elapsed
            expired_phase = timeout_phase(elapsed, opts.timeout, startup_limit, playable)
            if expired_phase:
                result['timeout'] = True
                result['timeout_phase'] = expired_phase
                break
            time.sleep(.25)
        result['playable'] = playable
        result['exit_code'] = owned.poll()
        if opts.reload_case:
            result['startup_diagnostics'] = startup_progress.observe(time.monotonic()-started,
                log_text(log), log_text(Path(env['KF2VR_LOG_PATH'])), process_counters(owned._handle))
        if use_observer:
            observed = log_text(log)
            if record.get('geometry_input') or record.get('replay_suite'):
                native_observed = log_text(Path(env['KF2VR_LOG_PATH']))
                result['physical_input_isolation_verified'] = (
                    'KF2VR_INPUT_ISOLATION phase=installed' in observed and
                    'ReplayInputIsolationProbe passed=1' in native_observed)
                result['geometry_outcomes'] = [line for line in observed.splitlines()
                    if 'KF2VR_RELOAD_GEOMETRY ' in line]
                # These outcomes are bounded diagnostic observations. They do
                # not turn missing receipts or human acceptance into a pass.
            result['startup_milestones_log_seconds'] = startup_milestones(observed)
            if opts.reload_case:
                offset = offsets.get(str(log), 0)
                for line in changed_log_lines(observed[offset:], streamed):
                    print(line, flush=True)
            # Reuse the log parser; completion also requires actual observed
            # unavailable -> held/disarmed -> release/rearm -> fire per hand.
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            if opts.reload_case:
                if record.get('replay_suite'):
                    from suite import analyze_suite
                    result['suite_observations'] = analyze_suite(observed,
                        log_text(Path(env['KF2VR_LOG_PATH'])), record['suite_cases'])
                    result['observations'] = dict(errors=result['suite_observations']['errors'])
                    result['observer_complete'] = result['suite_observations']['passed']
                elif record.get('lifecycle_case'):
                    from reload_trace_analyze import analyze
                    result['observations'] = analyze(observed, record['lifecycle_case'])
                    result['lifecycle_missing_requirements'] = record.get('lifecycle_missing_requirements', [])
                    result['status'] = 'UNTESTED'
                else:
                    from reload_analyze import analyze
                    result['observations'] = analyze(observed+'\n'+log_text(Path(env['KF2VR_LOG_PATH'])), opts.reload_case)
                if not record.get('replay_suite'):
                    result['observer_complete'] = result['observations']['passed']
                if record.get('geometry_input'):
                    from reload_trace_analyze import analyze_geometry
                    result['geometry_observations'] = analyze_geometry(observed,
                        log_text(Path(env['KF2VR_LOG_PATH'])), record['lifecycle_case'])
                    result['observer_complete'] = result['geometry_observations']['bounded_case_passed']
                if record.get('ammo_observer'):
                    from ammo_analyze import analyze as analyze_ammo
                    result['ammo_observations'] = analyze_ammo(observed, opts.reload_case)
                    result['observer_complete'] &= result['ammo_observations']['passed']
                    from ammo_payload_analyze import audit as audit_payloads
                    result['payload_observations'] = audit_payloads(observed, opts.reload_case)
                    result['observer_complete'] &= result['payload_observations']['counts_consistent']
            else:
                from analyze import analyze
                result['observations'] = analyze(observed)
                result['observer_complete'] = (result['observations']['complete']
                    and all(result['observations']['unavailable_held_release_fire']))
    finally:
        try:
            if owned and owned.poll() is None:
                owned.terminate()
                try:
                    owned.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    owned.kill()
                    owned.wait(timeout=10)
        finally:
            # A live child may still be using the proxy: preserve journal/files
            # for recovery rather than restoring underneath a running process.
            result['cleanup_errors'] = (['Owned child still running; deployment preserved']
                if owned and owned.poll() is None else deploy.restore())
            if user:
                result['user_config_preserved'] = config_hashes(user) == record['user_config_before']
                result['selection_preserved'] = digest(ROOT/'build/multiplayer/current-release.json') == record['selected_pointer_sha256']
                if not result['user_config_preserved'] or not result['selection_preserved']:
                    result['cleanup_errors'].append('User config or selected release changed during replay')
            if profile:
                result['saved_profile_preserved'] = config_hashes(profile) == record['saved_profile_before']
                if not result['saved_profile_preserved']:
                    result['cleanup_errors'].append('Saved launcher profile changed during replay')
            result['finished_unix'] = time.time()
            if record.get('replay_suite') and result.get('started_unix'):
                try:
                    from weapons import catalog_from_log
                    result['weapon_catalog'] = catalog_from_log(log_text(log))
                    (run/'weapon-catalog.json').write_text(json.dumps(result['weapon_catalog'], indent=2), encoding='utf-8')
                    from captures import collect_captures
                    result['captures'] = collect_captures(run, log_text(log),
                        started_unix=result['started_unix'], finished_unix=result['finished_unix'],
                        source_roots=[game.parents[2]/'KFGame/Screenshots']+
                                     ([user.parent/'Screenshots'] if user else []))
                    if not result['captures']['passed']:
                        result['observer_complete'] = False
                        result.setdefault('suite_observations', {}).setdefault('errors', []).append('Required timestamped captures incomplete or unusable')
                except Exception as error:
                    result['captures'] = dict(passed=False, errors=[str(error)])
                    result['observer_complete'] = False
            (run/'input-replay-run.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))
    if result.get('timeout') or result.get('exit_code') != 0 or result['cleanup_errors'] or result.get('observer_complete') is False:
        raise RuntimeError('Replay process or cleanup failed; inspect input-replay-run.json')

if __name__ == '__main__':
    if '--batch' in sys.argv:
        batch_main()
    else:
        with fixture_gate():
            main()
