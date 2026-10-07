"""Manual Epic VR candidate: prepare, paste Launch Options, then launch in Epic."""
import ctypes
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time

import friends
import game_install
from epic_launch import resolve_target
from epic_launch_options import prepare_session
from epic_session import PendingEpicLaunch
from epic_broker import EpicBroker
from native_fixture import NativeDeployment
from session import digest, read_ini, set_ini, config_hashes

ROOT = Path(__file__).resolve().parents[2]


def align_identical_defaults(configs, game):
    """Rebase copied INI timestamps only when the old defaults are identical."""
    steam = [i.root for i in game_install.discover() if i.store == 'steam']
    changed = 0
    for path in Path(configs).glob('KF*.ini'):
        text = read_ini(path)
        version = re.search(r'(?ims)^\[IniVersion\][ \t]*\r?\n(.*?)(?=^\[|\Z)', text)
        if not version:
            continue
        values = dict(re.findall(r'(?m)^(\d+)=(\d+(?:\.\d+)?)\s*$', version[1]))
        leaf = game/'KFGame/Config/Eos'/('Eos'+path.name[2:])
        chain = []
        while leaf.is_file() and leaf not in chain and len(chain) < 8:
            chain.insert(0, leaf)
            section = re.search(r'(?ims)^\[Configuration\][ \t]*\r?\n(.*?)(?=^\[|\Z)', read_ini(leaf))
            parent = re.search(r'(?im)^BasedOn=([^\r\n]+)', section[1]) if section else None
            if not parent:
                break
            leaf = (game/'KFGame'/parent[1].replace('%GAME%', 'KF').replace('\\', '/')).resolve()
            if not leaf.is_relative_to(game.resolve()):
                chain = []
                break
        if not chain or set(values) != {str(i) for i in range(len(chain))}:
            continue
        updates = {}
        for i, default in enumerate(chain):
            old, current = float(values[str(i)]), int(default.stat().st_mtime)
            if old == current:
                continue
            relative = default.relative_to(game)
            identical = any((root/relative).is_file() and int((root/relative).stat().st_mtime) == old
                            and digest(root/relative) == digest(default) for root in steam)
            if not identical:
                updates = {}
                break
            updates[str(i)] = f'{current:.6f}'
        if updates:
            path.write_text(set_ini(text, 'IniVersion', updates), encoding='utf-16')
            changed += 1
    return changed


def no_game():
    listing = subprocess.check_output(['tasklist', '/FO', 'CSV', '/NH'], text=True)
    if re.search(r'"KF(?:Game|Editor|Server)\.exe"', listing, re.I):
        raise RuntimeError('Close KF2, its server and SDK first. Native files have been preserved.')


def save(path, record):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(record, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def validate_options(args):
    if args.recover_epic:
        return
    if not args.solo or not args.vr or args.host or args.address:
        raise RuntimeError('Epic currently supports menu-first Solo VR only. Epic Host, Join and Desktop are unverified and unavailable.')
    if args.record_motion or args.promo_events:
        raise RuntimeError('Epic motion recording and highlight logging are unavailable in this alpha. Turn both OFF; Steam supports them.')
    if args.local_test_control or args.replay_teammate or args.avatar_preview or args.locomotion_preview or args.duration:
        raise RuntimeError('Epic supports ordinary manual Solo VR play only. Test control and diagnostic sessions are unavailable.')


def configure_menu_first(role, args):
    # Epic ignores an appended positional URL. Keep KFMainMenu as the frontend
    # identity and carry the SAME Solo gameplay options through stock travel.
    # Clearing LocalOptions (old D) loses VRBootstrap; replacing LocalMap (old C)
    # makes a gameplay map the frontend. Both defaults live only in session INIs.
    url = role['args'][0]
    _, separator, options = url.partition('?')
    if not separator or '?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo' not in url or '?VRNormalGame=1' not in url:
        raise RuntimeError('Solo VR gameplay bootstrap is missing; no native deployment.')
    engine = Path(role['config_root'])/'KFEngine.ini'
    engine.write_text(set_ini(read_ini(engine), 'URL', {
        'LocalMap': 'KFMainMenu', 'LocalOptions': '?'+options}), encoding='utf-16')
    role['startup_url'] = role['args'].pop(0)
    game_ini = Path(role['config_root'])/'KFGame.ini'
    game_ini.write_text(set_ini(read_ini(game_ini), 'KF2VR.VRSessionUI', {
        'LocalMap': args.map, 'LocalDifficulty': str(friends.DIFFICULTIES[args.difficulty]),
        'LocalLength': str(friends.LENGTHS[args.game_length])}), encoding='utf-16')


def run_session(args, manifest, install):
    friends.load_preferences(args)
    validate_options(args)
    if not args.recover_epic:
        resolve_target(install)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
    kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    kernel.ReleaseMutex.argtypes = (ctypes.c_void_p,)
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    mutex = kernel.CreateMutexW(None, False, 'Local\\KF2VR_DevelopmentFixture')
    held = False
    deployment = broker = worker = None
    cleanup_failure = None
    try:
        held = bool(mutex) and kernel.WaitForSingleObject(mutex, 0) in (0, 0x80)
        if not held:
            raise RuntimeError('Another KF2-VR session or build is active.')
        no_game()
        if args.recover_epic:
            from epic_recovery import recover_candidates
            backup = recover_candidates(ROOT, install.executable.parent, digest)
            print('Restored owned deployment: '+str(backup) if backup else 'No temporary native deployment remains.')
            print('In Epic, remove the KF2-VR Launch Options and restore your previous text/switch setting.')
            return
        if (install.executable.parent/'dinput8.dll').exists():
            raise RuntimeError('A proxy is already installed. Close its launcher or select Epic > Fix a stuck session.')
        friends.validate_play_mode(args)
        friends.preflight({**manifest, 'game_sha256': game_install.EPIC_SHA256}, install.root, True)
        args.mods = []
        args.workshop_content = []
        args.address, args.password = '127.0.0.1', 'solo-unused'
        friends.resolve_solo_map(args, friends.installed_solo_maps(install.root))
        if args.map not in friends.installed_solo_maps(install.root):
            raise ValueError('Choose an installed stock solo map; default is KF-BurningParis.')
        friends.breacher.prepare(args, ROOT, manifest)
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') as key:
            user = Path(os.path.expandvars(winreg.QueryValueEx(key, 'Personal')[0]))/'My Games/KillingFloor2/KFGame/Config'
        before = config_hashes(user)
        if not before:
            raise RuntimeError('Start standard KF2 once from Epic, quit it, then try again.')
        run = ROOT/'sessions'/datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-%f')
        role = friends.configure_role(run, 'driver', user, install.root, args)
        configure_menu_first(role, args)
        aligned = align_identical_defaults(Path(role['config_root']), install.root)
        role['config_hashes'] = config_hashes(Path(role['config_root']))
        print(f'Isolated INI timestamp metadata aligned for {aligned} byte-identical default chains.')
        record = dict(schema='kf2vr/epic-manual/1', store='epic', game_root=str(install.root),
                      build_id=manifest['build_id'], role=role, status='prepared', owner=None,
                      recordings=False, user_config_before=before, user_config_root=str(user))
        output = run/'epic-session.json'
        save(output, record)
        if args.prepare_only:
            print('Prepared config: '+str(role['config_root']))
            print('No deployment or live Launch Options. Start KF2-VR and select Epic / Play solo when ready.')
            return
        friends.save_preferences(args)
        settings_path = ROOT/'settings.json'
        settings = json.loads(settings_path.read_text(encoding='utf-8')) if settings_path.exists() else {}
        settings.update(game_root=str(install.root), store='epic')
        settings_path.write_text(json.dumps(settings, indent=2), encoding='utf-8')
        print('\nOpen Epic Library > Killing Floor 2 > Manage > Launch Options.')
        print('Save any previous Launch Options locally, then replace the field with the generated line below. Keep your headset runtime ready.')
        print('Epic opens the stock frontend. Choose Play Solo Offline, your map/difficulty/length, then perk and Ready.')
        print('The VR menu also offers LOCAL MATCH > START LOCAL MATCH > START SOLO MATCH using launcher selections.')
        print('This reconciled startup needs headset retesting. Epic overall acceptance remains NOT PASSED.')
        no_game()
        ticket = PendingEpicLaunch.create(install.executable, game_install.EPIC_SHA256, timeout_seconds=300)
        def claim(identity):
            record.update(owner=identity, status='game_authenticated')
            save(output, record)
        broker = EpicBroker(ticket, Path(role['log']).parent, on_claim=claim,
                            eye_percent=role['eye_render_percent'], dlss=role.get('dlss', 'off'),
                            dlss_sharpness=role.get('dlss_sharpness', 0), hide_bile_lens=role.get('hide_bile_lens', True))
        plan = prepare_session('', role['args'], broker)
        option_path = run/'Launch Options.txt'
        option_path.write_text(plan.prepared, encoding='utf-8')
        deployment = NativeDeployment(ROOT/'Native', install.executable.parent,
                                      run/'native-backup', manifest['native_build'], digest)
        record['status'] = 'deploying'
        save(output, record)
        deployment.install()
        worker = threading.Thread(target=broker.serve, daemon=True)
        worker.start()
        if not broker.ready.wait(10) or broker.error:
            raise RuntimeError('Epic broker could not start: '+str(broker.error))
        print('\nCOPY THIS ENTIRE SINGLE LINE into Epic Launch Options, replacing your saved previous text; switch it ON:\n')
        print('Epic Launch Options: '+plan.prepared, flush=True)
        print('\nAlso saved in: '+str(option_path))
        print('Now click Launch in EPIC yourself. Keep this window open while playing.', flush=True)
        while worker.is_alive():
            worker.join(.25)
        if broker.error:
            raise RuntimeError('Epic session handoff failed: '+str(broker.error))
        print('Epic game connected. Headset playtest is ready; exit KF2 normally when finished.', flush=True)
        while broker.kernel.WaitForSingleObject(broker.owner_handle, 250) == 258:
            pass
        record['status'] = 'game_exited'
        friends.export_preferences(Path(role['config_root']), root=getattr(args, 'profile_root', None), network=False)
        record['preferences_saved'] = True
        friends.save_preferences(args)
        settings_path = ROOT/'settings.json'
        settings = json.loads(settings_path.read_text(encoding='utf-8')) if settings_path.exists() else {}
        settings.update(game_root=str(install.root), store='epic')
        settings_path.write_text(json.dumps(settings, indent=2), encoding='utf-8')
        record['user_config_preserved'] = config_hashes(user) == before
        save(output, record)
    finally:
        if broker:
            broker.cancel()
        if worker:
            worker.join(6)
        if deployment:
            try:
                no_game()
                errors = deployment.restore()
                if errors:
                    raise RuntimeError('; '.join(errors))
                record['cleanup_complete'] = True
                save(output, record)
                print('Temporary native files restored.')
            except Exception as error:
                cleanup_failure = str(error)
                record.update(cleanup_complete=False, cleanup_error=cleanup_failure)
                save(output, record)
                print('Files preserved: '+str(error))
                print('After exiting all KF2 processes, select Epic > Fix a stuck session.')
            print('In Epic, remove the KF2-VR Launch Options and restore your previous text/switch setting before ordinary play.')
        if broker and (not worker or not worker.is_alive()):
            broker.close()
        if held:
            kernel.ReleaseMutex(mutex)
        if mutex:
            kernel.CloseHandle(mutex)
        if cleanup_failure:
            raise RuntimeError('Epic cleanup incomplete. Files preserved: '+cleanup_failure)


def main():
    # Compatibility entry point; the unified player launcher calls run_session.
    import sys
    options = sys.argv[1:]
    options = ['--recover-epic' if item == '--recover' else item for item in options]
    sys.argv = [sys.argv[0], '--store', 'epic', '--solo', '--vr', *options]
    return friends.main()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nCancelled. No game was terminated.')
    except Exception as error:
        print('Epic VR: '+str(error))
        raise SystemExit(1)
