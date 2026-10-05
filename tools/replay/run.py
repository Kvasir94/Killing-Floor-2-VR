"""Run a prepared, isolated bootstrap session with a verified native input tape.
Only initial setup/observations belong in the optional observer package.
"""
import argparse, hashlib, json, math, os, re, shutil, subprocess, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
import sys
sys.path.insert(0, str(ROOT / 'tools/multiplayer'))
from native_fixture import NativeDeployment

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
                 'bMeleeReplay','bGrabReplay','bBashLegReplay','bReloadHintCapture','bPortalReplay'):
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
    parser.add_argument('--observer', action='store_true')
    opts = parser.parse_args()
    if not 30 <= opts.timeout <= 600:
        raise RuntimeError('Timeout must be 30..600 seconds')
    record = json.loads(opts.record.read_text(encoding='utf-8-sig'))
    run = opts.record.resolve().parent
    if (run/'input-replay-run.json').exists() or (run/'ReplayNativeBackup').exists():
        raise RuntimeError('Run already attempted; prepare a fresh isolated session')
    if record['status'] != 'prepared' or record.get('process_started'):
        raise RuntimeError('Require a fresh prepared-only record')
    selection = json.loads((opts.source_root/'build/multiplayer/current-release.json').read_text(encoding='utf-8-sig'))
    if selection['release'] != record['selected_release']:
        raise RuntimeError('Prepared selection changed')
    release = opts.source_root/'build/multiplayer/releases'/selection['release']
    if digest(release/'release.json') != selection['manifest_sha256'].upper():
        raise RuntimeError('Manifest hash mismatch')
    manifest = json.loads((release/'release.json').read_text(encoding='utf-8-sig'))
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
    if not all(x in args for x in ('-kf2vr-hand-replay','-onethread')):
        raise RuntimeError('Prepared session must be offline hand replay')
    preflight_configs(args, run)
    # Disable all retired script-driven input paths in the isolated game config.
    config_arg = next(a for a in args if a.upper().startswith('-GAMEINI='))
    config = Path(config_arg.split('=',1)[1]).resolve()
    if not config.is_relative_to(run):
        raise RuntimeError('Config must be inside prepared run')
    config.write_bytes(disable_script_inputs(config.read_bytes()))
    if opts.observer:
        observer = ROOT/'build/input-replay/Script/KF2VRReplay.u'
        if not observer.exists():
            raise RuntimeError('Build observer first')
        built = json.loads((ROOT/'build/input-replay/observer.json').read_text(encoding='utf-8-sig'))
        if (digest(observer) != built['package_sha256'] or
            digest(ROOT/'tools/replay/script/KF2VRReplay/Classes/ReplayObserver.uc') != built['source_sha256'] or
            digest(package/'KF2VR.u') != built['production_sha256']):
            raise RuntimeError('Observer build is stale or targets a different production package')
        shutil.copy2(observer, package/observer.name)
        args[0] = args[0].replace('KF2VR.VRDemo', 'KF2VR.VRDemo,KF2VRReplay.ReplayObserver')
    replay_copy = run/'input-replay.txt'
    shutil.copy2(opts.input.resolve(), replay_copy)
    env = os.environ.copy()
    env.update(record['environment'])
    env['KF2VR_INPUT_REPLAY'] = str(replay_copy)
    destination = Path(record['native_probe']['destination']).parent
    game = destination/'KFGame.exe'
    if digest(game) != record['game_sha256'].upper():
        raise RuntimeError('Game executable changed')
    deploy = NativeDeployment(native/'native/adapter/Release', destination, run/'ReplayNativeBackup', receipt, digest)
    result = {'schema':'kf2vr/input-replay-run/1', 'input_sha256':digest(replay_copy),
              'release':selection['release'], 'native_sha256':receipt['artifacts_sha256'],
              'arguments':args, 'headset_accepted':False}
    owned = None
    try:
        deploy.install()
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        owned = subprocess.Popen([str(game),*args],cwd=destination,env=env,startupinfo=startup,
                                 stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        result['pid'] = owned.pid
        started = time.monotonic()
        log = Path(next(a.split('=',1)[1] for a in args if a.upper().startswith('-ABSLOG=')))
        playable = False
        while owned.poll() is None:
            elapsed = time.monotonic()-started
            if not playable and log.exists():
                playable = 'phase=playable' in log.read_text(encoding='utf-8',errors='replace')
            if elapsed >= opts.timeout or (not playable and elapsed >= min(120,opts.timeout)):
                result['timeout'] = True
                result['timeout_phase'] = 'session' if playable else 'startup'
                break
            time.sleep(.25)
        result['playable'] = playable
        result['exit_code'] = owned.poll()
        if opts.observer:
            observed = log.read_text(encoding='utf-8',errors='replace') if log.exists() else ''
            # Reuse the log parser; completion also requires actual observed
            # unavailable -> held/disarmed -> release/rearm -> fire per hand.
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            from analyze import analyze
            result['observations'] = analyze(observed)
            result['observer_complete'] = (result['observations']['complete']
                and all(result['observations']['unavailable_held_release_fire']))
    finally:
        try:
            if owned and owned.poll() is None:
                owned.terminate()
                owned.wait(timeout=20)
        finally:
            # A live child may still be using the proxy: preserve journal/files
            # for recovery rather than restoring underneath a running process.
            result['cleanup_errors'] = (['Owned child still running; deployment preserved']
                if owned and owned.poll() is None else deploy.restore())
            (run/'input-replay-run.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))
    if result.get('timeout') or result.get('exit_code') != 0 or result['cleanup_errors'] or result.get('observer_complete') is False:
        raise RuntimeError('Replay process or cleanup failed; inspect input-replay-run.json')

if __name__ == '__main__':
    main()
