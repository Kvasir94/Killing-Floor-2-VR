"""Prepare the explicitly requested standalone acceptance; --run is gate-only.

Desktop and non-XR VR bridge rehearsal are separate cases. Neither establishes
tracked-input or mixed-client parity. No installed files or release selection.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import time
from types import SimpleNamespace

import breacher
from session import role_config, read_ini, set_ini, config_hashes, digest, unreal_command
from friends import role_environment

ON = ('bridge_mode', 'perk_registered', 'trader_registered', 'perk_menu_label',
      'perk_selected', 'spawn_starter', 'starter_sold', 'trader_filter_label',
      'purchase_available', 'purchase_inventory', 'purchase_charged')
OFF = ('bridge_mode', 'perk_absent', 'trader_entry_absent', 'stock_menu_label',
       'stock_perk_selected', 'spawn_absence', 'trader_open_absence')


def evidence(log, enabled, bridge):
    rows = re.findall(r'(?m)\bBREACHER_ACCEPT[^\r\n]*', log)
    cases = ON if enabled else OFF
    expected = [f'BREACHER_ACCEPT rev=1 phase=begin enabled={enabled} bridge={bridge}']
    expected += [f'BREACHER_ACCEPT rev=1 phase=check index={i} name={name} passed=True'
                 for i, name in enumerate(cases)]
    expected += [f'BREACHER_ACCEPT rev=1 phase=complete checks={len(cases)} passed=True']
    return rows == expected and not re.search(
        r'(?i)(ScriptWarning:|Accessed None|Critical error|Fatal error|Assertion failed|Infinite loop|script recursion)', log)


def prepare(root, game, user, run, enabled, bridge):
    fixture = root / 'build/breacher-acceptance'
    build = json.loads((fixture / 'build.json').read_text(encoding='utf-8-sig'))
    source = root / 'script/KF2BreacherAcceptance'
    hashes = {p.relative_to(source).as_posix(): digest(p) for p in sorted(source.rglob('*.uc'))}
    if not build.get('success') or build['sources_sha256'] != hashes or build['package_sha256'] != digest(fixture / 'KF2BreacherAcceptance.u'):
        raise RuntimeError('Compile current acceptance fixture before preparation')
    stage = root / 'build/breacher-content-stage'
    for name in ('KF2VR.u', 'KF2VRNet.u', 'KF2VRNetClient.u'):
        if digest(stage / 'Packages' / name) != digest(root / 'build/multiplayer/script' / name):
            raise RuntimeError('Refresh compiled core content stage before preparation')
    if bridge:
        for name in ('KF2VRHands.upk', 'KF2VRPortal.upk'):
            if not (root / 'build/multiplayer/script' / name).is_file():
                raise RuntimeError('Missing owned bridge asset ' + name)
    args = SimpleNamespace(breacher=enabled, solo=True)
    breacher.prepare(args, stage, {'breacher_protocol': 1})
    role = role_config(run, 'driver', user, root / 'build/multiplayer/script', game, 19077, 29077,
                       run / 'Cache', False)
    configs = Path(role['config_root'])
    breacher.configure_content(configs, args)
    path = configs / 'KFEngine.ini'
    text = read_ini(path)
    section = re.search(r'(?ims)^\[Core\.System\][^\n]*\n(.*?)(?=^\[|\Z)', text)[1]
    text = set_ini(text, 'Core.System', {key: [str(fixture)] + re.findall(r'(?im)^' + key + r'=([^\r\n]*)', section)
        for key in ('Paths', 'ScriptPaths', 'SeekFreePCPaths', 'BrewedPCPaths')})
    text = set_ini(text, 'VoIP', {'bHasVoiceEnabled': 'false'})
    path.write_text(text, encoding='utf-16')
    path = configs / 'KFGame.ini'
    path.write_text(set_ini(read_ini(path), 'KF2VRNet.KF2VRNetPlayerController', {
        'bDiagnosticSyntheticAutoStart': 'false', 'bDiagnosticObserverDebug': 'false'}), encoding='utf-16')
    mutators = ['KF2BreacherAcceptance.BreacherAcceptance']
    if bridge:
        mutators += ['KF2VR.VRBootstrap', 'KF2VR.VRDemo']
    url = 'KF-BurningParis?Game=KF2VRNet.KF2VRNetGame?Difficulty=0?GameLength=0?Mutator=' + ','.join(mutators)
    url += f'?BreacherAcceptEnabled={int(enabled)}?BreacherAcceptBridge={int(bridge)}'
    if bridge:
        url += '?VRNormalGame=1'
    role['args'][0] = breacher.add_mutator(url + breacher.options(args), args)
    role['args'] += ['-windowed', '-ResX=960', '-ResY=540']
    role['config_hashes'] = config_hashes(configs)
    role['exe'] = str(game / 'Binaries/Win64/KFGame.exe')
    role['enabled'], role['bridge'] = enabled, bridge
    (run / 'launch.json').write_text(json.dumps(role, indent=2))
    return role


def child_launch(role, environment):
    """Reuse the network harness launch contract; no process or config mutation."""
    child_environment = role_environment(environment, role)
    child_environment.update(SteamAppId="232090", SteamGameId="232090")
    return unreal_command(Path(role['exe']), role['args']), child_environment


def run_owned(role, user):
    # Gate owner must also confirm SteamVR/headset inactivity before --run.
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
    kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    kernel.ReleaseMutex.argtypes = kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    mutex = kernel.CreateMutexW(None, False, 'Local\\KF2VR_DevelopmentFixture')
    if not mutex:
        raise ctypes.WinError(ctypes.get_last_error())
    locked, child = False, None
    before = config_hashes(user)
    try:
        locked = kernel.WaitForSingleObject(mutex, 0) in (0, 128)
        if not locked:
            raise RuntimeError('Development gate is occupied')
        check = subprocess.run(['powershell', '-NoProfile', '-Command',
            'if (Get-Process KFGame,KFServer,KFEditor,vrserver,vrcompositor -ErrorAction SilentlyContinue) { exit 1 }'],
            creationflags=subprocess.CREATE_NO_WINDOW)
        if check.returncode:
            raise RuntimeError('Game/editor/server/SteamVR active; refusing runtime')
        exe = Path(role['exe'])
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        command, environment = child_launch(role, os.environ)
        # Match session.py: capture pre-engine failures without inheriting the
        # tool host's pipes. This is a startup comparison, not a proven fix.
        with Path(role['log']).with_name('console.log').open('wb') as console:
            child = subprocess.Popen(command, cwd=exe.parent, startupinfo=startup,
                env=environment, stdin=subprocess.DEVNULL, stdout=console, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 120
        log = Path(role['log'])
        while child.poll() is None and time.monotonic() < deadline:
            text = log.read_text(errors='replace') if log.exists() else ''
            if 'BREACHER_ACCEPT rev=1 phase=complete' in text:
                break
            time.sleep(0.5)
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(5)
        if locked:
            kernel.ReleaseMutex(mutex)
        kernel.CloseHandle(mutex)
    if before != config_hashes(user):
        raise RuntimeError('Base user config changed')
    text = Path(role['log']).read_text(errors='replace')
    if not evidence(text, role['enabled'], role['bridge']):
        raise RuntimeError('Acceptance did not pass; inspect ' + role['log'])
    print('PASS standalone callbacks only: ' + role['log'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-root', type=Path, default=Path('D:/SteamLibrary/steamapps/common/killingfloor2'))
    parser.add_argument('--user-config', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--enabled', action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument('--bridge', action='store_true', help='Non-XR VR bridge rehearsal, not tracked parity')
    parser.add_argument('--run', action='store_true', help='Only after exclusive runtime gate is granted')
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    role = prepare(root, options.game_root.resolve(), options.user_config.resolve(), options.output.resolve(), options.enabled, options.bridge)
    print('Prepared ' + str(options.output / 'launch.json'))
    if options.run:
        run_owned(role, options.user_config)
