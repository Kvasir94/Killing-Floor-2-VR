"""Run a .kfs replay script on network clients that play on a dedicated server.

One owned loopback LAN dedicated server (KFServer.exe with the candidate's
packages and server adapter, the production KF2VRNet game) and one or more
VR network clients. Each client runs its share of the cases through
NetScriptRunner, the client-side ScriptRunner: the same .kfs language, the
same v3 goal ingress and production tracking path, so the owner's reload,
grab, drop and throw code talks to the real authority. Weapons are granted by
the server (KF2VRReplay.NetScriptServer). Hand probes srv_ammo, srv_reserve,
srv_weapon and ammo_agree read the authority's counts for the held gun.

Several clients share one server (--clients N, like scripted.py --parallel):
the cases are split between them and they play at once. The runner holds the
fixture lease (its lane's own with --fixture, see fixture.py) and queues for
it with --wait.
See tools/replay/SCRIPTS.md ("Multiplayer").
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fixture
import scripted
from scripted import (BRIDGES, FATAL, case_results, compile_case, compile_observer, merge_cases, neutral_tape,
                      queued_gate, resolve_weapon, settings_cases, user_config_root, watch)
from run import ROOT, digest, disable_script_inputs, launch_slot, log_text, steam_preflight
from native_fixture import NativeDeployment
from session import config_hashes, read_ini, role_config, set_ini, unreal_command
from release_state import verify_release
from captures import collect_captures
import kfs

PASSWORD = 'kf2vr-local-diagnostic'
# Production host settings (friends.py host_settings). The URL adds only the
# diagnostic option that keeps Zeds from walking into the script.
HOST_SETTINGS = {'bServerAdapter': 'true', 'bIndependentWeapons': 'true', 'bInventoryFocusEnabled': 'false',
                 'bMultiplayerZedGrabAllowed': 'false'}


def server_url(map_name, clients, zeds, grabs=True):
    return (f'{map_name}?Game=KF2VRNet.KF2VRNetGame?Difficulty=0?GameLength=0?bIsLanMatch=true'
            # No VRNetAutoReady: it also runs the held-inventory probe, which
            # destroys a third weapon (the perk knife or a just-given gun).
            # NetScriptServer readies the players instead.
            # Quiet Zeds need the diagnostics; with --zeds the server runs without
            # them, as a player's host does (the diagnostics also defer every
            # ambient wave squad while independent weapons are on).
            f'?VRInventoryFocus=0?VRMultiplayerGrabs={1 if grabs else 0}?VRNetClients={clients}'
            + ('' if zeds else '?VRNetDiagnostics=1?VRNetQuietZeds=1') + '?Mutator=KF2VRReplay.NetScriptServer')


def server_exe(root):
    exe = root/'Binaries/Win64/KFServer.exe'
    if not exe.exists():
        raise RuntimeError(f'No dedicated server at {root}; run tools/install-multiplayer-server.ps1')
    return exe


def prepare_server(net, user, packages, game, opts, clients):
    role = role_config(net, 'server', user, packages, game, opts.port, opts.query_port,
                       (ROOT/'build/scripted-replay/Cache'), False)
    configs = Path(role['config_root'])
    path = configs/'KFGame.ini'
    path.write_text(set_ini(read_ini(path), 'KF2VRNet.KF2VRNetGame', HOST_SETTINGS), encoding='utf-16')
    role['args'][0] = server_url(opts.map, clients, opts.zeds, getattr(opts, 'hostgrabs', 'on') != 'off')
    role['args'] += ['-kf2vr-server-adapter']
    return role


def refresh_ini_versions(configs, game):
    """Restamp [IniVersion] in session ini copies so -NOAUTOINIUPDATE starts
    without the modal "Your ini is outdated" dialog. KF2 stamps each source
    Base/Default ini as its UTC mtime shifted by the difference between the
    current local offset and the offset on the file's date, so every daylight
    saving change makes copied inis look outdated (2026-11-01: all launches
    stalled behind a hidden dialog from 07:00 UTC). A stamp is matched to its
    source by true mtime, allowing for the hour either way."""
    sources = {int(p.stat().st_mtime) for d in (game/'KFGame/Config', game/'KFGame/Config/Eos', game/'Engine/Config') if d.is_dir()
               for p in d.glob('*.ini')}
    now = time.localtime().tm_gmtoff

    def expected(stamp):
        for true in (stamp, stamp + 3600, stamp - 3600):
            if true in sources:
                return true + now - time.localtime(true).tm_gmtoff
        return stamp

    for path in Path(configs).glob('*.ini'):
        text = read_ini(path)
        section = re.search(r'(?ims)^\[IniVersion\][^\n]*\n(.*?)(?=^\[|\Z)', text)
        if not section:
            continue
        body = re.sub(r'(?m)^(\w+)=(\d+)(\.\d+)?', lambda m: f'{m[1]}={expected(int(m[2]))}{m[3] or ""}', section[1])
        if body != section[1]:
            raw = path.read_bytes()
            encoding = 'utf-16' if raw.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8'
            path.write_text(text[:section.start(1)] + body + text[section.end(1):], encoding=encoding)


def prepare_client(net, k, user, packages, game, opts, compiled):
    run = net/f'client{k}'
    role = role_config(run, 'driver', user, packages, game, opts.port, opts.query_port,
                       (ROOT/'build/scripted-replay/Cache'), False, native_replay=True)
    role['run'] = run
    configs = Path(role['config_root'])
    path = configs/'KFGame.ini'
    text = read_ini(path)
    for section in BRIDGES:
        text = set_ini(text, section, compiled.settings)
    # captures.py wants KF2VR_Replay_<20 digits>; the last digit tells clients apart.
    prefix = 'KF2VR_Replay_'+datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S%f')[:-1]+str(k % 10)
    text = set_ini(text, 'KF2VRReplay.NetScriptRunner', {'Ops': compiled.ops, 'CapturePrefix': prefix,
        'bAutoShot': str(compiled.setup['autoshot'] == 'on'), 'SetupTimeoutSeconds': '300'})
    path.write_text(text, encoding='utf-16')
    path.write_bytes(disable_script_inputs(path.read_bytes()))
    # Loopback LAN only (session.py --lan-no-voice): voice logs every frame.
    engine = configs/'KFEngine.ini'
    engine.write_text(set_ini(read_ini(engine), 'VoIP', {'bHasVoiceEnabled': 'False'}), encoding='utf-16')
    refresh_ini_versions(configs, game)
    args = [a for a in role['args'] if not a.startswith(('-Port=', '-QueryPort='))]
    res = re.fullmatch(r'(\d+)x(\d+)', compiled.setup.get('res') or '')
    if res:   # setup res= sets the window and so the capture size, as in scripted.py
        args = [a for a in args if not a.startswith(('-ResX=', '-ResY='))] + [f'-ResX={res[1]}', f'-ResY={res[2]}']
    args[0] = f'127.0.0.1:{opts.port}?Password={PASSWORD}?Name=Script_{k}'
    args += [f'-Port={opts.port + 10 + 10*k}', f'-QueryPort={opts.query_port + 10 + 10*k}',
             '-kf2vr-input-replay', '-kf2vr-reload-geometry', '-kf2vr-input-isolation-probe']
    role['args'] = args
    return role


def start(executable, args, cwd, env, console):
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    with console.open('wb') as out:
        return subprocess.Popen(unreal_command(executable, args), cwd=cwd, env=env, startupinfo=startup,
                                stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT)


def server_ready(log):
    return ('Listening for lan beacon requests on ' in log
            and re.search(r'KF2VRNet session .*netmode=(1|NM_DedicatedServer)', log) is not None)


def stop(process, timeout=20):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=10)


def restore_all(*deployments, attempts=20):
    """Restore every native install. A just-killed game can hold its DLLs for a
    few seconds (WinError 5); retry instead of leaving the proxy installed,
    which blocks every other lane's run."""
    left, errors = list(deployments), []
    for attempt in range(attempts):
        errors = []
        for deploy in list(left):
            try:
                problems = deploy.restore()
            except OSError as error:
                problems = [str(error)]
            if problems:
                errors += problems
            else:
                left.remove(deploy)
        if not left:
            return []
        time.sleep(1.5)
    return errors + ['Native restore incomplete; journal kept for a manual NativeDeployment.restore']


def server_findings(text, compiled):
    """Server-side facts worth a line in the summary, and live forbids that matched there."""
    refusals = re.findall(r'KF2VRNet \w+ phase=refused[^\r\n]*', text)
    forbids = [c for c in compiled.log_checks if c['kind'] == 'forbid' and re.search(c['pattern'], text, re.M)]
    return dict(fatal=bool(FATAL.search(text)), refusals=refusals[:40], refusal_count=len(refusals),
                forbidden=[f"{c['where']} /{c['pattern']}/" for c in forbids],
                gives=len(re.findall(r'KF2VR_SCRIPT_SERVER give .*granted=True', text)),
                refused_gives=len(re.findall(r'KF2VR_SCRIPT_SERVER give .*granted=False', text)))


def run_net_session(opts, script, batches, observer, net):
    """One server and one client per batch. batches: [[(n, weapon, label, Compiled)]]."""
    user = user_config_root(opts.user_config)
    game = (opts.game_root or fixture.game_root()).resolve()
    release = opts.candidate.resolve()
    if release.parent != (ROOT/'build/multiplayer/releases').resolve():
        raise RuntimeError('Candidate must be a generated repository release')
    verify_release(release)
    exe = server_exe(opts.server_root)
    net.mkdir(parents=True)
    packages = net/'Packages'
    shutil.copytree(release/'Packages', packages, copy_function=os.link)
    shutil.copy2(observer, packages/observer.name)   # server and clients load the same observer build
    user_before = config_hashes(user)
    merged = [merge_cases(batch) for batch in batches]
    server = prepare_server(net, user, packages, game, opts, len(batches))
    clients = [prepare_client(net, k+1, user, packages, game, opts, m) for k, m in enumerate(merged)]
    manifest = json.loads((release/'release.json').read_text(encoding='utf-8-sig'))
    sha = manifest['files_sha256']
    client_deploy = NativeDeployment(release/'Native', game/'Binaries/Win64', net/'ClientNativeBackup',
        {'artifacts_sha256': {n: sha['Native/'+n].upper() for n in ('dinput8.dll', 'openxr_loader.dll')}}, digest)
    server_deploy = NativeDeployment(release/'ServerNative', exe.parent, net/'ServerNativeBackup',
        {'artifacts_sha256': {'dinput8.dll': sha['ServerNative/dinput8.dll'].upper()}}, digest, server=True)
    base_env = {k: v for k, v in os.environ.items() if not k.upper().startswith('KF2VR_')}
    base_env.update(SteamAppId='232090', SteamGameId='232090')
    errors, processes, results = [], [], [None]*len(clients)
    server_log = Path(server['log'])
    srv = None
    try:
        steam_preflight()
        # The dedicated server install is shared by every lane that runs MP
        # replays; wait for another lane's server proxy like the client's.
        scripted.install_when_free(server_deploy, opts.wait)
        # Another lane's proxy can still be in the game folder: wait it out.
        scripted.install_when_free(client_deploy, opts.wait)
        # The server initializes only the Steam game server API; hold the launch
        # slot through its start-up all the same, briefly.
        with launch_slot(server['log'], timeout=20):
            srv = start(exe, server['args'], opts.server_root, dict(base_env, KF2VR_SERVER_LOG_PATH=str(net/'server/native.log')),
                        net/'server/console.log')
        processes.append(srv)
        deadline = time.monotonic() + 240
        while not server_ready(log_text(server_log)):
            if srv.poll() is not None:
                raise RuntimeError(f'Dedicated server exited during startup ({srv.returncode}); see {server_log}')
            if time.monotonic() > deadline:
                raise RuntimeError(f'Dedicated server not ready in 240 s; see {server_log}')
            time.sleep(1)
        print(f'KF2VR_SCRIPTED_MP server ready map={opts.map}', flush=True)

        def client(k, role, compiled):
            run = role['run']
            tape = run/'input-replay.txt'
            timeout = compiled.timeout + 60
            neutral_tape(tape, timeout)
            native_log = run/'native.log'
            env = dict(base_env, KF2VR_LOG_PATH=str(native_log), KF2VR_INPUT_REPLAY=str(tape),
                       KF2VR_INPUT_REPLAY_WAIT_READY='1', KF2VR_INPUT_REPLAY_REALTIME='1')
            time.sleep(20 * k)   # stagger the cold engine starts
            result = dict(started_unix=time.time(), errors=[])
            # One KF2 cold start at a time machine-wide (Steam crashes on several).
            with launch_slot(role['log']):
                owned = start(game/'Binaries/Win64/KFGame.exe', role['args'], game/'Binaries/Win64', env, run/'console.log')
            processes.append(owned)
            try:
                # A launch that never opens its log is stalled before the
                # engine starts (seen with a wedged Steam client); fail it in
                # minutes rather than at the full startup timeout.
                opened = time.monotonic() + 180
                while not Path(role['log']).exists() and owned.poll() is None and time.monotonic() < opened:
                    time.sleep(1)
                if not Path(role['log']).exists():
                    result['ended'] = 'no-game-log-in-180s'
                    return
                result['ended'] = watch(owned, Path(role['log']), native_log, compiled, timeout + 240,
                                        dict(stall=opts.stall, hang=opts.hang, growth=opts.memory_growth, startup=480),
                                        live=opts.live)
            finally:
                stop(owned)
                result['exit_code'] = owned.poll()
                result['finished_unix'] = time.time()
                results[k] = result

        threads = [threading.Thread(target=client, args=(k, role, merged[k])) for k, role in enumerate(clients)]
        for thread in threads: thread.start()
        while any(t.is_alive() for t in threads):
            if srv.poll() is not None:
                errors.append(f'Dedicated server exited mid-run ({srv.returncode})')
                for p in processes[1:]: stop(p)
                break
            time.sleep(1)
        for thread in threads: thread.join()
    finally:
        for p in reversed(processes): stop(p)
        if any(p.poll() is None for p in processes):
            errors.append('An owned process is still running; native deployments preserved')
        else:
            errors += restore_all(client_deploy, server_deploy)
        if config_hashes(user) != user_before:
            errors.append('User config changed during the run')
    server_text = log_text(server_log)
    rows = []
    for k, (role, batch, compiled) in enumerate(zip(clients, batches, merged)):
        result = results[k] or dict(ended='never-launched', errors=[])
        run, text = role['run'], log_text(Path(role['log']))
        findings = server_findings(server_text, compiled)
        got, pending = case_results(text, batch, {n: c for n, _, _, c in batch}, compiled, result.get('ended'))
        session_errors = errors + result['errors'] + (['Dedicated server logged a fatal line'] if findings['fatal'] else []) \
            + [f'server log matched forbid {f}' for f in findings['forbidden']]
        caps = 0
        if 'KF2VR_REPLAY_CAPTURE' in text:
            try:
                caps = len(collect_captures(run, text, started_unix=result['started_unix'], finished_unix=result['finished_unix'],
                    source_roots=[Path(role['config_root']).parent/'ScreenShotPath', game/'KFGame/Screenshots'],
                    max_captures=1024, max_cases=64, max_bytes=2 * 1024**3).get('entries', []))
            except Exception as error:   # captures are evidence, not the verdict
                session_errors.append('Capture collection failed: '+str(error))
        for row in got:
            row.update(client=k+1, summary=str(run/'summary.md'), server=findings)
            if session_errors:
                row['passed'] = False
                row['errors'] = session_errors
        rows += got
        rows += [dict(n=n, weapon=w, settings=l, passed=False, ended=f'pending-{result.get("ended")}', failed=[],
                      errors=session_errors, captures=0, client=k+1, summary=str(run/'summary.md'), server=findings)
                 for n, w, l, _ in batch if n in pending]
        verdicts = kfs.runner_verdicts(text)
        (run/'summary.json').write_text(json.dumps(dict(client=k+1, ended=result.get('ended'), errors=session_errors,
            server=findings, checks=verdicts['checks'], captures=caps), indent=2), encoding='utf-8')
        lines = [f'# client {k+1}: ended {result.get("ended")}', '', f'Server: {findings["gives"]} gives, '
                 f'{findings["refused_gives"]} refused, {findings["refusal_count"]} KF2VRNet refusals', '']
        lines += [f'- {e}' for e in session_errors] + [f'- server: {r}' for r in findings['refusals']]
        (run/'summary.md').write_text('\n'.join(lines)+'\n', encoding='utf-8')
    if server_log.exists():
        shutil.copy2(server_log, net/'server-game.log')
    return rows


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--script', type=Path, required=True)
    p.add_argument('--candidate', type=Path, help='Absolute unselected release directory from build-kf2vr.ps1 -NoSelect')
    p.add_argument('--weapons', nargs='*', default=[], help='Run once per weapon as $weapon (aliases or class paths, commas ok)')
    p.add_argument('--matrix', action='append', default=[], help='Key=v1,v2 VR setting axis, as in scripted.py')
    p.add_argument('--var', action='append', default=[], help='name=value for $name in the script')
    p.add_argument('--clients', type=int, default=1, choices=range(1, 4),
                   help='VR clients playing on the one server at once; cases are split between them')
    p.add_argument('--map', help='Server map (default: the script setup map)')
    p.add_argument('--zeds', action='store_true', help='Let the wave spawn Zeds (default: quiet)')
    p.add_argument('--server-root', type=Path, default=ROOT/'build/multiplayer/server',
                   help='Dedicated server install (the Host launcher\'s; another SteamCMD install works too)')
    p.add_argument('--port', type=int, default=18777)
    p.add_argument('--query-port', type=int, default=38015)
    p.add_argument('--plan', action='store_true', help='Compile and print ops only')
    p.add_argument('--output', type=Path)
    p.add_argument('--stall', type=int, default=90)
    p.add_argument('--hang', type=int, default=20)
    p.add_argument('--memory-growth', type=int, default=1500)
    p.add_argument('--wait', type=int, default=0, help='Seconds to wait for a busy game slot instead of failing')
    p.add_argument('--live', action='store_true')
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
    cases, n = [], 0
    try:
        for label, overrides in settings_cases(opts.matrix):
            for weapon in weapons:
                n += 1
                cases.append((n, weapon, label, compile_case(opts, opts.script, weapon, overrides)))
    except (ValueError, kfs.ScriptError) as error:
        p.error(str(error))
    opts.map = opts.map or cases[0][3].setup['map']
    # setup hostgrabs=off: the host's "Zed grabs" permission for the whole server.
    opts.hostgrabs = cases[0][3].setup.get('hostgrabs', 'on')
    if opts.plan:
        for n, weapon, label, compiled in cases:
            print(f'# case {n} weapon={weapon} settings={label} ops={len(compiled.ops)} {compiled.settings}')
            print('\n'.join(compiled.ops))
        return
    if not opts.candidate or not opts.candidate.is_absolute():
        p.error('--candidate <absolute release directory> is required to run')
    # A session shares one settings set per client; group by settings, then split.
    groups = {}
    for case in cases:
        groups.setdefault(json.dumps(case[3].settings, sort_keys=True), []).append(case)
    root = (opts.output or ROOT/'build/scripted-replay'/(datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')
            + '-mp-'+opts.script.stem)).resolve()
    if root.exists():
        p.error('Output exists; choose a fresh directory')
    root.mkdir(parents=True)
    steam_preflight()
    observer = compile_observer(opts.candidate/'Packages', root/'Observer', opts.wait)
    rows = []
    for g, group in enumerate(groups.values()):
        batches = [b for b in (group[k::opts.clients] for k in range(opts.clients)) if b]
        with queued_gate(opts.wait):
            try:
                rows += run_net_session(opts, opts.script, batches, observer, root/f'session{g+1}')
            except Exception as error:
                rows += [dict(n=n, weapon=w, settings=l, passed=False, ended='runner-error', failed=[], errors=[str(error)],
                              captures=0, client=0, summary=str(root)) for batch in batches for n, w, l, _ in batch]
                print(f'KF2VR_SCRIPTED_MP FAIL session={g+1} error={error}', flush=True)
    # The observer folder holds a full copy of the candidate's packages
    # (~0.75 GB); the sessions copied the one package they used, so drop it.
    shutil.rmtree(root/'Observer'/'Script', ignore_errors=True)
    rows.sort(key=lambda r: r['n'])
    (root/'batch.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
    report = [f"# {opts.script.name} (dedicated): {sum(r['passed'] for r in rows)}/{len(rows)} passed", '']
    for r in rows:
        report.append(f"- {'PASS' if r['passed'] else 'FAIL'} client {r.get('client')} {r['weapon'] or '-'} {r['settings'] or ''}: "
                      f"ended {r['ended']}, {r.get('captures', 0)} captures, {r['summary']}")
        report += [f'  - {line}' for line in r.get('errors', []) + r.get('failed', [])]
        if r.get('server', {}).get('refusal_count'):
            report.append(f"  - server refusals: {r['server']['refusal_count']} (first: {r['server']['refusals'][0][:160]})")
    (root/'batch.md').write_text('\n'.join(report)+'\n', encoding='utf-8')
    print('\n'.join(report), flush=True)
    print(f"KF2VR_SCRIPTED_MP batch passed={sum(r['passed'] for r in rows)}/{len(rows)} output={root}", flush=True)
    sys.exit(0 if rows and all(r['passed'] for r in rows) else 1)


if __name__ == '__main__':
    main()
