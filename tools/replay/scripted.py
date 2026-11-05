"""Run a .kfs replay script against an unselected candidate, unattended.

One launch per weapon (the script sees it as $weapon). Each run gets its own
directory with the compiled ops, game/native logs, captures/index.html and a
summary. The live watchdog stops the game on a crash, a hung window, runaway
memory, a stalled log, a forbidden log line or the script deadline.
See tools/replay/SCRIPTS.md.
"""
import argparse
import contextlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fixture
from run import ROOT, digest, disable_script_inputs, fixture_gate, launch_slot, log_text, preflight_configs, steam_preflight
from native_fixture import NativeDeployment
from prepare_reload import configure_reload
from session import config_hashes, read_ini, role_config, set_ini
from release_state import verify_release
from captures import collect_captures
import kfs

BRIDGES = ('KF2VR.VRHandsBridge', 'KF2VRNetClient.KF2VRNetHandsBridge')
TAPE_HEADER = 'KF2VR_INPUT 1 8333 0'
NEUTRAL = ('0 0 1 1 1 0 0 0 0 0 0 1 2047 0 0 0 0 0 -0.25 -0.18 -0.55 0 0 0 1 -0.25 -0.18 -0.55 0 0 0 1 '
           '2047 0 0 0 0 0 0.25 -0.18 -0.55 0 0 0 1 0.25 -0.18 -0.55 0 0 0 1')
FATAL = re.compile(r'Critical:|Assertion failed|Fatal error|appError|General protection fault|Unhandled Exception')


def user_config_root(explicit):
    if explicit:
        return explicit.resolve()
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') as key:
        return Path(os.path.expandvars(winreg.QueryValueEx(key, 'Personal')[0]))/'My Games/KillingFloor2/KFGame/Config'


def resolve_weapon(name):
    from weapons import weapon_path
    return weapon_path(name)


def neutral_tape(path, seconds):
    # The tape only carries boot/readiness and head position; the script owns
    # hands, buttons, sticks and head rotation through the v3 goal ingress.
    ticks = min(360000, int(seconds*120)+1200)
    path.write_text(f'{TAPE_HEADER}\n# Scripted replay carrier; ScriptRunner supplies all controls.\n{ticks} {NEUTRAL}\n',
                    encoding='ascii')


def prepare(run, candidate, compiled, user, game):
    # The candidate is tested exactly as built: its own manifest verifies its
    # packages and native files. Other agents' edits to the shared tree since
    # the build do not invalidate it.
    release = candidate
    if release.parent != (ROOT/'build/multiplayer/releases').resolve():
        raise RuntimeError('Candidate must be a generated repository release')
    verify_release(release)
    run.mkdir(parents=True)
    packages = run/'Packages'
    # Hard links: every run sees the candidate's exact packages without
    # duplicating ~0.8 GB on D:. The observer package is copied in separately.
    shutil.copytree(release/'Packages', packages, copy_function=os.link)
    # One engine cache shared by all scripted runs (it grows to ~11 GB cold);
    # sharing it also keeps later launches warm.
    cache = ROOT/'build/scripted-replay/Cache'
    cache.mkdir(parents=True, exist_ok=True)
    role = role_config(run, 'driver', user, packages, game, 7777, 27015, cache, False)
    configs = Path(role['config_root'])
    configure_reload(configs, 'normal')
    if compiled.setup.get('res'):
        # A larger window for visual checks: glow colours and small parts.
        width, height = compiled.setup['res'].split('x')
        settings = configs/'KFSystemSettings.ini'
        settings.write_text(set_ini(read_ini(settings), 'SystemSettings', {'ResX': width, 'ResY': height}),
                            encoding='utf-16')
    path = configs/'KFGame.ini'
    text = read_ini(path)
    for section in BRIDGES:
        text = set_ini(text, section, compiled.settings)
    prefix = 'KF2VR_Replay_'+datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S%f')
    text = set_ini(text, 'KF2VRReplay.ScriptRunner', {'Ops': compiled.ops, 'CapturePrefix': prefix,
        'bAutoShot': str(compiled.setup['autoshot'] == 'on'), 'SetupTimeoutSeconds': '240',
        'StartSpot': compiled.setup.get('start', 'keep')})
    path.write_text(text, encoding='utf-16')
    path.write_bytes(disable_script_inputs(path.read_bytes()))
    # Voice chat logs several lines a frame in an offline run; mute it here only.
    engine = configs/'KFEngine.ini'
    engine.write_text(set_ini(read_ini(engine), 'VoIP', {'bHasVoiceEnabled': 'False'}), encoding='utf-16')
    args = [a for a in role['args'] if not a.startswith(('-MULTIHOME=', '-Port=', '-QueryPort='))]
    if compiled.setup.get('res'):
        # The role's -ResX/-ResY switches override the ini: follow setup res.
        width, height = compiled.setup['res'].split('x')
        args = [f'-ResX={width}' if a.startswith('-ResX=') else f'-ResY={height}' if a.startswith('-ResY=') else a
                for a in args]
        if not any(a.startswith('-ResX=') for a in args):
            args += [f'-ResX={width}', f'-ResY={height}']
    args[0] = (compiled.setup['map']+'?Game=KFGameContent.KFGameInfo_Survival?Difficulty=0?GameLength=0'
               '?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo,KF2VRReplay.ScriptRunner')
    args += ['-kf2vr-hand-replay', '-onethread', '-kf2vr-probe', '-nohomedir',
             '-kf2vr-input-replay', '-kf2vr-reload-geometry', '-kf2vr-input-isolation-probe']
    preflight_configs(args, run)
    return release, packages, configs, args


@contextlib.contextmanager
def queued_gate(wait_seconds):
    """The fixture lease, waiting for another run or game to finish instead of failing."""
    if fixture.lane() is not None:
        # A lane's own copy: one blocking wait on its own lock.
        with fixture_gate(wait_seconds):
            yield
        return
    deadline = time.monotonic() + wait_seconds
    while True:
        gate = fixture_gate()
        try:
            gate.__enter__()
        except RuntimeError as error:
            if time.monotonic() > deadline or not re.search(r'busy|Existing game', str(error)):
                raise
            print(f'KF2VR_SCRIPTED waiting for the game slot: {error}', flush=True)
            time.sleep(30)
            continue
        try:
            yield
        finally:
            gate.__exit__(None, None, None)
        return


def compile_observer(packages, output, wait_seconds=0):
    """Compiles the replay observer; waits for a busy fixture when asked."""
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            return _compile_observer(packages, output)
        except RuntimeError:
            log = (output.parent/'observer-compile.log')
            text = log.read_text(encoding='utf-8', errors='replace') if log.exists() else ''
            # Busy fixture, a running game/editor/server, or another lane editing
            # replay sources mid-compile: try again until --wait runs out.
            if time.monotonic() > deadline or not any(
                    reason in text for reason in ('busy', 'deferred', 'changed during compile')):
                raise
            print(f'KF2VR_SCRIPTED waiting observer-compile reason={text.strip().splitlines()[0][:80]!r}',
                  flush=True)
            time.sleep(30)


def _compile_observer(packages, output):
    # Windows PowerShell 5.1 child: a PowerShell 7 PSModulePath would hide Get-FileHash.
    env = {k: v for k, v in os.environ.items() if k.upper() != 'PSMODULEPATH'}
    result = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                             str(HERE/'build-observer.ps1'), '-ProductionScriptRoot', str(packages),
                             '-OutputRoot', str(output)], cwd=ROOT, capture_output=True, text=True, env=env)
    (output.parent/'observer-compile.log').write_text(result.stdout+result.stderr, encoding='utf-8')
    package = output/'Script/KF2VRReplay.u'
    if result.returncode or not package.exists():
        raise RuntimeError('Observer compile failed; see '+str(output/'compiler.log'))
    return package


def window_hung(pid):
    """True when every top-level window of pid stopped pumping messages."""
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.WinDLL('user32')
    found, hung = [], []
    proc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    def visit(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid:
            found.append(hwnd)
            hung.append(bool(user32.IsHungAppWindow(hwnd)))
        return True
    user32.EnumWindows(proc(visit), 0)
    return bool(found) and all(hung)


def working_set_mb(handle):
    import ctypes
    from ctypes import wintypes

    class Counters(ctypes.Structure):
        _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD)] + \
                   [(n, ctypes.c_size_t) for n in ('PeakWorkingSetSize', 'WorkingSetSize', 'QuotaPeakPagedPoolUsage',
                    'QuotaPagedPoolUsage', 'QuotaPeakNonPagedPoolUsage', 'QuotaNonPagedPoolUsage',
                    'PagefileUsage', 'PeakPagefileUsage')]
    counters = Counters(cb=ctypes.sizeof(Counters))
    if not ctypes.WinDLL('psapi').GetProcessMemoryInfo(int(handle), ctypes.byref(counters), counters.cb):
        return None
    return counters.WorkingSetSize/2**20, counters.PagefileUsage/2**20


def watch(owned, log, native_log, compiled, deadline, limits, live=False):
    """Live watchdog. Returns the reason the run ended."""
    started, ready_at, last_size, last_growth, hung_since = time.monotonic(), None, 0, time.monotonic(), None
    baseline, offset = None, 0
    forbids = [re.compile(c['pattern'], re.M) for c in compiled.log_checks if c['kind'] == 'forbid' and not c['since']]
    while owned.poll() is None:
        now = time.monotonic()
        text = log_text(log)
        new, offset = text[offset:], len(text)
        for line in new.splitlines():
            if live and ('KF2VR_SCRIPT' in line or 'KF2VR_REPLAY_CAPTURE' in line):
                print(line.split('KF2VR_', 1)[-1][:240], flush=True)
        if ready_at is None and ('KF2VR_SCRIPT phase=ready' in text or 'KF2VR_SCRIPT phase=complete' in text):
            ready_at = now
        if FATAL.search(new):
            return 'fatal-log-line'
        if any(p.search(new) for p in forbids):
            return 'forbidden-log-line'
        if len(text) != last_size:
            last_size, last_growth = len(text), now
        elif ready_at and now-last_growth > limits['stall']:
            return 'log-stalled'
        # Engine startup and map loads block the message pump; judge hangs only once the script runs.
        if ready_at and window_hung(owned.pid):
            hung_since = hung_since or now
            if now-hung_since > limits['hang']:
                return 'window-hung'
        else:
            hung_since = None
        memory = working_set_mb(owned._handle)
        if memory and ready_at and baseline is None and now-ready_at > 5:
            baseline = memory
        if memory and baseline and memory[1]-baseline[1] > limits['growth']:
            return f'memory-growth-{memory[1]-baseline[1]:.0f}MB'
        if ready_at is None and now-started > limits['startup']:
            return 'startup-timeout'
        if now-started > deadline:
            return 'deadline'
        time.sleep(.25)
    return 'exited' if 'KF2VR_SCRIPT phase=complete' in log_text(log) else f'exited-early-code-{owned.returncode}'


def write_summary(run, result):
    (run/'summary.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    lines = [f"# {result['script']} — {'PASS' if result['passed'] else 'FAIL'}", '',
             f"Weapon: {result.get('weapon') or '-'}  ·  ended: {result['ended']}  ·  runner: {result['verdicts']['reason']}  ·  "
             f"exit: {result.get('exit_code')}", '']
    if result.get('errors'):
        lines += ['## Errors', ''] + [f'- {e}' for e in result['errors']] + ['']
    lines += ['## Checks', '', '| where | kind | probe | value | expected | result |', '| --- | --- | --- | --- | --- | --- |']
    for c in result['verdicts']['checks']:
        lines.append(f"| {c['where']} | {c['kind']} | {c['probe']} | {c['value']} | {c['op']} {c['expected']} | {'pass' if c['passed'] else '**FAIL**'} |")
    for c in result['log_checks']:
        lines.append(f"| {c['where']} | {c['kind']} log | /{c['pattern']}/ | {c['detail'][:60]} | since {c['since'] or 'start'} | {'pass' if c['passed'] else '**FAIL**'} |")
    caps = result.get('captures') or {}
    lines += ['', f"Captures: {len(caps.get('entries', []))} — captures/index.html" if caps else 'Captures: none', '',
              'Logs: game.log (KF2VR_SCRIPT lines), native.log. A scripted pass is not headset or online acceptance.']
    (run/'summary.md').write_text('\n'.join(lines)+'\n', encoding='utf-8')


def run_name(weapon, label=''):
    name = re.sub(r'[^A-Za-z0-9_.-]', '_', weapon) if weapon else 'run'
    return name+('__'+label if label else '')


def settings_cases(matrix):
    """--matrix Key=a,b entries -> list of (label, overrides); `preset` expands kfs presets
    and a `var.` key sets a script variable instead ($name in the script), e.g. var.start=empty,full."""
    import itertools
    axes = []
    for entry in matrix:
        key, _, values = entry.partition('=')
        if not re.fullmatch(r'(?:var\.)?[A-Za-z_][A-Za-z0-9_]*', key) or not values:
            raise ValueError(f'--matrix wants Key=value1,value2; got {entry!r}')
        for value in values.split(','):
            if key == 'preset' and value not in kfs.PRESETS:
                raise ValueError(f'Unknown preset {value!r}; known: {", ".join(kfs.PRESETS)}')
            if not re.fullmatch(r'[A-Za-z0-9_.\-]+', value):
                raise ValueError(f'Bad setting value {value!r}')
        axes.append([(key, v) for v in values.split(',')])
    cases = []
    for combo in itertools.product(*axes) if axes else [()]:
        overrides = {}
        for key, value in combo:
            overrides.update(kfs.PRESETS[value] if key == 'preset' else {key: value})
        cases.append(('_'.join(f'{k}-{v}' for k, v in combo), overrides))
    return cases


SHARED_DEPLOY = None   # set while a --parallel batch holds one proxy install


def install_when_free(deploy, wait_seconds):
    """Installs the native proxy, waiting (with --wait) while another run's proxy
    is still in the game folder instead of failing."""
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            return deploy.install()
        except RuntimeError as error:
            if 'Existing proxy' not in str(error) or time.monotonic() > deadline:
                raise
            # install() made its backup folder before refusing; start clean next try.
            shutil.rmtree(deploy.backup, ignore_errors=True)
            print(f'KF2VR_SCRIPTED waiting for the game folder: {error}', flush=True)
            time.sleep(30)


def run_parallel(opts, script, session, observer, where):
    """Runs a session's cases across --parallel game instances at once. The
    parent holds the fixture lease and one native proxy install for all of them."""
    import threading
    global SHARED_DEPLOY
    release = opts.candidate.resolve()
    manifest = json.loads((release/'release.json').read_text(encoding='utf-8-sig'))
    receipt = {'artifacts_sha256': {name: manifest['files_sha256']['Native/'+name].upper()
                                    for name in ('dinput8.dll', 'openxr_loader.dll')}}
    game = (opts.game_root or fixture.game_root()).resolve()
    shared = NativeDeployment(release/'Native', game/'Binaries/Win64', where/'SharedNativeBackup', receipt, digest)
    slots = [session[k::opts.parallel] for k in range(opts.parallel)]
    rows, errors = [], []
    steam_preflight()
    install_when_free(shared, opts.wait)
    SHARED_DEPLOY = shared
    try:
        def work(k, cases):
            try:
                time.sleep(20 * k)   # stagger the cold engine starts
                rows.extend(run_session(opts, script, cases, observer, where/f'slot{k+1}'))
            except Exception as error:
                errors.append(f'slot {k+1}: {error}')
        threads = [threading.Thread(target=work, args=(k, cases)) for k, cases in enumerate(slots) if cases]
        for thread in threads: thread.start()
        for thread in threads: thread.join()
    finally:
        SHARED_DEPLOY = None
        errors += shared.restore()
    for row in rows:
        row['errors'] = row.get('errors', []) + errors
    return sorted(rows, key=lambda row: row['n'])


def compile_case(opts, script, weapon, overrides=None):
    overrides = dict(overrides or {})
    variables = dict(v.split('=', 1) for v in opts.var)
    variables.update({k[4:]: overrides.pop(k) for k in list(overrides) if k.startswith('var.')})
    if weapon:
        variables['weapon'] = weapon
    compiled = kfs.compile_script(script, variables, resolve_weapon)
    compiled.settings.update(overrides)
    return compiled


def run_one(opts, script, weapon, observer_package, root, overrides=None, label=''):
    """One isolated launch. The caller holds the fixture lease. Overrides beat the script's settings."""
    return launch(opts, compile_case(opts, script, weapon, overrides), root/run_name(weapon, label),
                  observer_package, script, weapon)


def launch(opts, compiled, run, observer_package, script, weapon=None, deadline=None):
    """Prepare, deploy, run and watch one game process for already-compiled ops."""
    deadline = deadline or opts.timeout or int(compiled.setup['timeout'])
    user = user_config_root(opts.user_config)
    game = (opts.game_root or fixture.game_root()).resolve()
    user_before = config_hashes(user)
    release, packages, configs, args = prepare(run, opts.candidate.resolve(), compiled, user, game)
    (run/'ops.txt').write_text(''.join(f'{op}    # {compiled.where(int(op.split("|")[0]))}\n' for op in compiled.ops),
                               encoding='utf-8')
    target = packages/observer_package.name
    if target.exists():
        target.unlink()   # never write through a hard link into the candidate
    shutil.copy2(observer_package, target)
    tape = run/'input-replay.txt'
    neutral_tape(tape, deadline)
    manifest = json.loads((release/'release.json').read_text(encoding='utf-8-sig'))
    receipt = {'artifacts_sha256': {name: manifest['files_sha256']['Native/'+name].upper()
                                    for name in ('dinput8.dll', 'openxr_loader.dll')}}
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith('KF2VR_')}
    env.update(SteamAppId='232090', SteamGameId='232090', KF2VR_LOG_PATH=str(run/'native.log'),
               KF2VR_INPUT_REPLAY=str(tape), KF2VR_INPUT_REPLAY_WAIT_READY='1', KF2VR_INPUT_REPLAY_REALTIME='1')
    destination = game/'Binaries/Win64'
    # A parallel batch installs the proxy once for all its game instances.
    deploy = SHARED_DEPLOY or NativeDeployment(release/'Native', destination, run/'ReplayNativeBackup', receipt, digest)
    log = Path(next(a.split('=', 1)[1] for a in args if a.upper().startswith('-ABSLOG=')))
    result = dict(schema='kf2vr/scripted-replay/1', script=str(script), weapon=weapon, candidate=release.name,
                  arguments=args, errors=[], headset_accepted=False, multiplayer_accepted=False)
    owned = None
    try:
        steam_preflight()
        if SHARED_DEPLOY is None:
            install_when_free(deploy, opts.wait)
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        result['started_unix'] = time.time()
        with launch_slot(log):
            owned = subprocess.Popen([str(destination/'KFGame.exe'), *args], cwd=destination, env=env,
                                     startupinfo=startup, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        result['ended'] = watch(owned, log, run/'native.log', compiled, deadline+240,
                                dict(stall=opts.stall, hang=opts.hang, growth=opts.memory_growth, startup=480),
                                live=opts.live)
    finally:
        if owned and owned.poll() is None:
            owned.terminate()
            try:
                owned.wait(timeout=20)
            except subprocess.TimeoutExpired:
                owned.kill(); owned.wait(timeout=10)
        result['exit_code'] = owned.poll() if owned else None
        result['errors'] += (['Owned game still running; native deployment preserved']
                             if owned and owned.poll() is None else ([] if SHARED_DEPLOY else deploy.restore()))
        if config_hashes(user) != user_before:
            result['errors'].append('User config changed during the run')
        result['finished_unix'] = time.time()
    text = log_text(log)
    if log.exists() and log.resolve() != (run/'game.log').resolve():
        shutil.copy2(log, run/'game.log')
    result['verdicts'] = kfs.runner_verdicts(text)
    for check in result['verdicts']['checks']:
        check['where'] = compiled.where(check['line'])
    result['log_checks'] = kfs.check_log(text, compiled)
    if 'KF2VR_REPLAY_CAPTURE' in text:
        try:
            result['captures'] = collect_captures(run, text, started_unix=result['started_unix'],
                finished_unix=result['finished_unix'], source_roots=[game/'KFGame/Screenshots', user.parent/'Screenshots'],
                max_captures=1024, max_cases=64, max_bytes=2 * 1024**3)
        except Exception as error:   # captures are evidence, not the verdict
            result['errors'].append('Capture collection failed: '+str(error))
    result['passed'] = (result['ended'] == 'exited' and result['verdicts']['passed'] and not result['errors']
                        and all(c['passed'] for c in result['log_checks']))
    result['log_text'] = text
    write_summary(run, result)
    print(f"KF2VR_SCRIPTED {'PASS' if result['passed'] else 'FAIL'} weapon={weapon or '-'} ended={result['ended']} "
          f"summary={run/'summary.md'}", flush=True)
    return result


def merge_cases(cases):
    """cases: [(n, weapon, label, Compiled)] -> one Compiled whose `case` ops reset
    state and apply that case's settings in game, so one launch runs them all."""
    merged = kfs.Compiled()
    merged.setup = dict(cases[0][3].setup)
    merged.settings = dict(cases[0][3].settings)
    merged.timeout = 0
    for n, weapon, label, compiled in cases:
        offset = len(merged.origins)
        merged.origins.append(f'case {n} {weapon or "-"} {label or "-"}')
        merged.origins += compiled.origins
        if compiled.settings != merged.settings:
            raise ValueError('A session shares one settings set; group cases by settings first')
        merged.ops.append(f'{offset+1}|case|n={n}|weapon={weapon or "-"}|label={label or "-"}'
                          f'|timeout={compiled.setup["timeout"]}|stall={compiled.setup.get("stall", "25")}')
        base = len(merged.ops)   # where this case's first op lands
        for op in compiled.ops:
            line, rest = op.split('|', 1)
            # repeat-until jumps hold absolute op indices: shift them with the case.
            rest = re.sub(r'(?<=\|to=)(\d+)', lambda m: str(int(m[1]) + base), rest)
            merged.ops.append(f'{int(line)+offset+1}|{rest}')
        merged.timeout += int(compiled.setup['timeout'])
        for check in compiled.log_checks:   # live forbids apply session-wide
            if check['kind'] == 'forbid' and not check['since'] and check['pattern'] not in [c['pattern'] for c in merged.log_checks]:
                merged.log_checks.append(check)
    return merged


def case_results(text, cases, compiled_by_n, merged, ended):
    """Split one session log into per-case verdicts. Cases that never started are returned as pending."""
    starts = [(int(m[1]), m.start()) for m in re.finditer(r'KF2VR_SCRIPT case n=(\d+)', text)]
    rows, pending = [], []
    for n, weapon, label, _ in cases:
        at = next((pos for case_n, pos in starts if case_n == n), None)
        if at is None:
            pending.append(n)
            continue
        following = [pos for case_n, pos in starts if pos > at]
        piece = text[at:following[0] if following else len(text)]
        end = re.search(r'KF2VR_SCRIPT case-end n=\d+ label=\S+ reason=(\S+) passed=(true|false)', piece)
        verdicts = kfs.runner_verdicts(piece)
        for check in verdicts['checks']:
            check['where'] = merged.where(check['line'])
        log_checks = kfs.check_log(piece, compiled_by_n[n])
        passed = bool(end) and end[2] == 'true' and all(c['passed'] for c in log_checks)
        failed = [f"{c['where']} {c['kind']} {c['probe']}={c['value']} (want {c['op']} {c['expected']})"
                  for c in verdicts['checks'] if not c['passed']]
        failed += [f"{c['where']} {c['kind']} log /{c['pattern']}/" for c in log_checks if not c['passed']]
        rows.append(dict(n=n, weapon=weapon, settings=label, passed=passed,
                         ended=end[1] if end else f'launch-{ended}', failed=failed, errors=[],
                         captures=len(re.findall(r'KF2VR_REPLAY_CAPTURE', piece))))
    # A case that left the game dirty (a stuck reload, carried ammo...) fails
    # with what it left; the runner relaunches fresh for the next case.
    for m in re.finditer(r'KF2VR_SCRIPT case-dirty after=(\d+) before=\d+ left=(\S+)', text):
        for row in rows:
            if row['n'] == int(m[1]):
                row['passed'] = False
                row['failed'].append('left the game dirty for the next case: '+m[2])
    return rows, pending


def run_session(opts, script, cases, observer_package, root, launches=0):
    """Run cases in as few launches as possible; relaunch after a crash with the rest."""
    rows, queue, attempt = [], list(cases), 0
    while queue and attempt < 1 + len(cases):
        attempt += 1
        batch = queue[:opts.per_launch]
        compiled_by_n = {n: c for n, _, _, c in batch}
        merged = merge_cases(batch)
        run = root/f'session{attempt}'
        result = launch(opts, merged, run, observer_package, script, deadline=merged.timeout + 60)
        got, pending = case_results(result.get('log_text', ''), batch, compiled_by_n, merged, result.get('ended'))
        for row in got:
            row['summary'] = str(run/'summary.md')
            if not row['passed'] and result.get('errors'):
                row['errors'] = result['errors']
        rows += got
        done = {row['n'] for row in got}
        queue = [c for c in batch if c[0] in pending] + queue[len(batch):]
        if not got:   # nothing even started: do not spin on a broken launch
            rows += [dict(n=n, weapon=w, settings=l, passed=False, ended=f'never-started-{result.get("ended")}',
                          failed=[], errors=result.get('errors', []), captures=0, summary=str(run/'summary.md'))
                     for n, w, l, _ in queue]
            break
    return rows


def prune_run(root):
    """At exit, drop a run's bulky copies and keep its logs, reports and
    captures: the observer build's package copy (about 0.75 GB), the
    sessions' package folders, and native backups whose journal says every
    file was restored. Every run used to keep them, and D: filled up."""
    root = Path(root)
    if not root.is_dir():
        return
    targets = [root/'Observer'/'Script', *root.glob('**/Packages')]
    for backup in root.glob('**/*NativeBackup'):
        journal = backup/'deployment.json'
        try:
            files = json.loads(journal.read_text(encoding='utf-8')).get('files', {}) if journal.exists() else {}
        except (OSError, ValueError):
            continue   # unreadable journal: keep it for recovery
        if all(entry.get('restored') for entry in files.values()):
            targets.append(backup)
    for target in targets:
        shutil.rmtree(target, ignore_errors=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--script', type=Path, required=True)
    p.add_argument('--candidate', type=Path, help='Absolute unselected release directory from build-kf2vr.ps1 -NoSelect')
    p.add_argument('--weapons', nargs='*', default=[],
                   help='Run once per weapon as $weapon (aliases or class paths, commas ok); all = every registered weapon')
    p.add_argument('--families', default='', help='With --weapons all: keep these catalog families (commas), e.g. detachable,pump')
    p.add_argument('--dual-only', action='store_true', help='With --weapons all: keep weapons that have a paired family')
    p.add_argument('--loops', type=int, default=1, help='Repeat the whole weapon list')
    p.add_argument('--matrix', action='append', default=[],
                   help='Key=v1,v2 VR setting axis (repeatable; preset=advanced,classic too); runs every combination per weapon')
    p.add_argument('--var', action='append', default=[], help='name=value for $name in the script')
    p.add_argument('--plan', action='store_true', help='Compile and print ops only')
    p.add_argument('--output', type=Path)
    p.add_argument('--timeout', type=int, help='Override the script setup timeout (seconds)')
    p.add_argument('--stall', type=int, default=90, help='Seconds without log output after ready')
    p.add_argument('--hang', type=int, default=20, help='Seconds of unresponsive window')
    p.add_argument('--memory-growth', type=int, default=1500, help='Commit growth limit in MB after ready')
    p.add_argument('--fail-fast', action='store_true')
    p.add_argument('--isolated', action='store_true', help='One game launch per case instead of one session for many cases')
    p.add_argument('--per-launch', type=int, default=12, help='Cases per game process (default 12)')
    p.add_argument('--yield-gap', type=int, default=90, help='Seconds the game slot is left free between chunks for builds and other lanes')
    p.add_argument('--parallel', type=int, default=1, choices=range(1, 5),
                   help='Game instances at once in session mode (they share one proxy install)')
    p.add_argument('--wait', type=int, default=0, help='Seconds to wait for a busy game slot (another run or game) instead of failing')
    p.add_argument('--live', action='store_true', help='Stream script lines while running (default: quiet until the end)')
    p.add_argument('--game-root', type=Path)
    p.add_argument('--fixture', help="Run in the lane's own game copy and lock (tools/replay/fixture.py; "
                   "the same as KF2VR_FIXTURE=<lane>)")
    p.add_argument('--user-config', type=Path)
    opts = p.parse_args()
    if opts.fixture:
        # Children (build-observer.ps1, the native fixture) read the lane from the environment.
        os.environ['KF2VR_FIXTURE'] = fixture.lane(opts.fixture)
    if fixture.lane() is not None and not fixture.game_root().is_dir():
        p.error(f'No fixture for lane {fixture.lane()}: python tools/replay/fixture.py create {fixture.lane()}')
    weapons = [w for item in opts.weapons for w in item.split(',') if w] or [None]
    if opts.plan:
        for weapon in weapons:
            variables = dict(v.split('=', 1) for v in opts.var)
            if weapon: variables['weapon'] = weapon
            compiled = kfs.compile_script(opts.script, variables, resolve_weapon)
            print(f'# weapon={weapon} ops={len(compiled.ops)} settings={compiled.settings} setup={compiled.setup}')
            print('\n'.join(compiled.ops))
        return
    if not opts.candidate or not opts.candidate.is_absolute():
        p.error('--candidate <absolute release directory> is required to run')
    try:
        settings_cases(opts.matrix)   # reject a bad matrix before launching anything
    except ValueError as error:
        p.error(str(error))
    everything = 'all' in weapons
    weapons = [w for w in weapons if w != 'all'] or ([] if everything else [None])
    for weapon in weapons or ['KFGameContent.KFWeap_Pistol_9mm']:   # fail on a script error before launching
        for _, overrides in settings_cases(opts.matrix):
            compile_case(opts, opts.script, weapon if weapon != 'all' else None, overrides)
        kfs.compile_script(opts.script, dict(v.split('=', 1) for v in opts.var) | ({'weapon': weapon} if weapon else {}), resolve_weapon)
    root = (opts.output or ROOT/'build/scripted-replay'/(datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')+'-'+opts.script.stem)).resolve()
    if root.exists():
        p.error('Output exists; choose a fresh directory')
    root.mkdir(parents=True)
    import atexit
    atexit.register(prune_run, root)
    steam_preflight()   # fail before the costly observer compile; rechecked per launch
    # Compile the observer once against the candidate; it takes the fixture lease itself.
    observer = compile_observer(opts.candidate/'Packages', root/'Observer', opts.wait)
    if everything:
        # The game's own registry decides the list: one short catalog launch.
        catalog_script = root/'catalog.kfs'
        catalog_script.write_text('setup timeout=60 autoshot=off\ncatalog\nend\n', encoding='utf-8')
        with queued_gate(opts.wait):
            run_one(opts, catalog_script, None, observer, root/'catalog')
        rows = kfs.catalog_rows(log_text(root/'catalog/run/game.log'))
        if not rows:
            raise RuntimeError('Catalog launch produced no registry rows; see '+str(root/'catalog/run/summary.md'))
        (root/'weapon-catalog.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
        families = {f for f in opts.families.split(',') if f}
        weapons += [r['weapon'] for r in rows
                    if (not families or r.get('family') in families) and (not opts.dual_only or r.get('dual') == 'True')]
        print(f'KF2VR_SCRIPTED catalog weapons={len(rows)} selected={len(weapons)}', flush=True)
    cases = settings_cases(opts.matrix)
    results = []
    for loop in range(opts.loops):
        where = root/f'loop{loop+1}' if opts.loops > 1 else root
        where.mkdir(exist_ok=True)
        if not opts.isolated:
            # One session per settings combination runs every weapon; settings
            # are read from the launch config, so they cannot change mid-session.
            n = 0
            for group, (label, overrides) in enumerate(cases):
                session = []
                for weapon in weapons:
                    n += 1
                    session.append((n, weapon, label, compile_case(opts, opts.script, weapon, overrides)))
                folder = where/(f'settings{group+1}' if len(cases) > 1 else '')
                # Hold the game slot one chunk at a time and leave a gap between
                # chunks, so a build or another lane waiting on the fixture lease
                # (they retry about once a minute) gets its turn.
                size = opts.per_launch * opts.parallel
                for start in range(0, len(session), size):
                    chunk = session[start:start+size]
                    sub = folder/f'chunk{start//size+1}' if len(session) > size else folder
                    with queued_gate(opts.wait):
                        rows = (run_parallel(opts, opts.script, chunk, observer, sub) if opts.parallel > 1
                                else run_session(opts, opts.script, chunk, observer, sub))
                    results += [dict(row, loop=loop+1) for row in rows]
                    if start + size < len(session) or group + 1 < len(cases):
                        time.sleep(opts.yield_gap)
            continue
        for weapon, (label, overrides) in ((w, c) for w in weapons for c in cases):
            try:
                with queued_gate(opts.wait):
                    result = run_one(opts, opts.script, weapon, observer, where, overrides, label)
            except Exception as error:
                result = dict(passed=False, ended='runner-error', errors=[str(error)])
                print(f'KF2VR_SCRIPTED FAIL weapon={weapon or "-"} settings={label or "-"} error={error}', flush=True)
            failed = [f"{c.get('where', c.get('line'))} {c['kind']} {c['probe']}={c['value']} (want {c['op']} {c['expected']})"
                      for c in result.get('verdicts', {}).get('checks', []) if not c['passed']]
            failed += [f"{c['where']} {c['kind']} log /{c['pattern']}/" for c in result.get('log_checks', []) if not c['passed']]
            results.append(dict(loop=loop+1, weapon=weapon, settings=label, passed=result['passed'], ended=result['ended'],
                                errors=result.get('errors', []), failed=failed,
                                captures=len((result.get('captures') or {}).get('entries', [])),
                                summary=str(where/run_name(weapon, label)/'summary.md')))
            if opts.fail_fast and not result['passed']:
                break
        if opts.fail_fast and not all(r['passed'] for r in results):
            break
    (root/'batch.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    # One compact report for whoever reads the run afterwards: no live log in between.
    report = [f"# {opts.script.name}: {sum(r['passed'] for r in results)}/{len(results)} passed", '']
    for r in results:
        report.append(f"- {'PASS' if r['passed'] else 'FAIL'} loop {r['loop']} {r['weapon'] or '-'} {r['settings'] or ''}: ended {r['ended']}, "
                      f"{r['captures']} captures, {r['summary']}")
        report += [f'  - {line}' for line in r['errors'] + r['failed']]
    (root/'batch.md').write_text('\n'.join(report)+'\n', encoding='utf-8')
    print('\n'.join(report), flush=True)
    print(f"KF2VR_SCRIPTED batch passed={sum(r['passed'] for r in results)}/{len(results)} output={root}", flush=True)
    sys.exit(0 if all(r['passed'] for r in results) else 1)


if __name__ == '__main__':
    main()
