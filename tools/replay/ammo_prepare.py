"""Prepare existing normal/dual tapes with passive authoritative ammo observation.

An explicit unselected candidate is verified, never selected. Compilation and
execution still use build-observer.ps1 and run.py's shared fixture/deployment gate.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import sys

from prepare_reload import (ROOT, configure_reload, role_config, config_hashes,
                            verify_native, preflight_configs)
from release_state import digest
from ammo_candidate import verify_candidate
from session import read_ini, set_ini

FAMILIES = {'9mm':'KFWeap_Pistol_9mm', 'ar15':'KFWeap_AssaultRifle_AR15',
            'thompson':'KFWeap_AssaultRifle_Thompson', 'deagle':'KFWeap_Pistol_Deagle',
            'mosin':'KFWeap_Rifle_MosinNagant', '1858':'KFWeap_Revolver_Rem1858',
            'hx25':'KFWeap_GrenadeLauncher_HX25', 'spx':'KFWeap_Rifle_CenterfireMB464',
            'bow':'KFWeap_Bow_CompoundBow', 'mb500':'KFWeap_Shotgun_MB500',
            'm16':'KFWeap_AssaultRifle_M16M203', 'helios':'KFWeap_AssaultRifle_Microwave'}


def configure_case(configs, case, weapon='9mm', no_voice=False, lifecycle_case=None, geometry_input=False):
    from weapons import weapon_path
    selected_path = weapon_path(weapon)
    if geometry_input and (case != 'dual' or weapon != '9mm' or lifecycle_case not in
                           ('hip-tactical-at-capacity', 'dual-removal-backend-busy')):
        raise ValueError('Geometry input requires the explicit paired 9mm hip audit case')
    if case == 'dual' and weapon != '9mm':
        raise ValueError('Existing dual tape requires the paired 9mm family')
    if not lifecycle_case and weapon not in ('9mm', 'ar15', 'thompson', 'deagle') and '.' not in weapon:
        raise ValueError('This family requires observation-only lifecycle mode')
    configure_reload(configs, case)
    game_config = configs/'KFGame.ini'
    game_config.write_text(set_ini(read_ini(game_config), 'KF2VRReplay.ReloadObserver',
        {'SingleWeaponPath':selected_path,
         'bTraceLifecycle':str(bool(lifecycle_case)), 'LifecycleCase':lifecycle_case or '',
         'bGeometryInput':str(bool(geometry_input))}),encoding='utf-16')
    if lifecycle_case:
        # Gravity recovery is part of these declared diagnostic scenarios.
        text = read_ini(game_config)
        for section in ('KF2VR.VRHandsBridge', 'KF2VRNetClient.KF2VRNetHandsBridge'):
            text = set_ini(text, section, {'bDisableGravityPull':'False'})
        game_config.write_text(text, encoding='utf-16')
    if no_voice:
        engine_config = configs/'KFEngine.ini'
        engine_config.write_text(set_ini(read_ini(engine_config), 'VoIP',
            {'bHasVoiceEnabled':'False'}),encoding='utf-16')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidate', type=Path, required=True)
    p.add_argument('--case', choices=('normal', 'dual'), required=True)
    p.add_argument('--weapon', default='9mm', help='Alias or canonical registered weapon class')
    p.add_argument('--no-voice', action='store_true', help='Disable only stock VoIP in this disposable standalone config')
    p.add_argument('--lifecycle-case', help='Observation-only case ID from reload_scenarios.json; never a reload pass')
    p.add_argument('--geometry-input', action='store_true', help='Explicit paired hip audit: production geometry goals through existing native reload ingress')
    p.add_argument('--input', type=Path, help='Explicit authored or measured native tape; required when lifecycle case has no executable prefix')
    p.add_argument('--output', type=Path)
    p.add_argument('--game-root', type=Path)
    p.add_argument('--user-config', type=Path)
    opts = p.parse_args()
    from weapons import weapon_path
    try: weapon_path(opts.weapon)
    except ValueError as error: p.error(str(error))
    if opts.geometry_input and (opts.case != 'dual' or opts.weapon != '9mm' or opts.lifecycle_case not in
                               ('hip-tactical-at-capacity', 'dual-removal-backend-busy')):
        p.error('--geometry-input requires the explicit paired 9mm hip audit case')
    if opts.case == 'dual' and opts.weapon != '9mm':
        p.error('Existing dual tape requires the paired 9mm family')
    scenario = None
    if opts.lifecycle_case:
        catalog = json.loads((ROOT/'tools/replay/reload_scenarios.json').read_text())
        scenario = next((s for s in catalog['scenarios'] if s['id'] == opts.lifecycle_case), None)
        if scenario is None or opts.weapon not in scenario['weapons']:
            p.error('Lifecycle case or weapon does not match reload_scenarios.json')
        if not opts.input and not scenario.get('input'):
            p.error('Scenario needs a measured native tape; see its missing_requirements')
    elif opts.input:
        p.error('--input requires --lifecycle-case')
    if not scenario and opts.weapon not in ('9mm', 'ar15', 'thompson', 'deagle') and '.' not in opts.weapon:
        p.error('This family requires --lifecycle-case')
    pointer = ROOT/'build/multiplayer/current-release.json'
    selection = json.loads(pointer.read_text(encoding='utf-8-sig'))
    record = dict(selected_release=selection['release'],
                  selected_pointer_sha256=digest(pointer),
                  candidate_root=str(opts.candidate.resolve()),
                  candidate_manifest_sha256=digest(opts.candidate/'release.json'))
    release, manifest = verify_candidate(ROOT, record)
    script = json.loads((ROOT/'build/multiplayer/script/build.json').read_text(encoding='utf-8-sig'))
    native = verify_native(ROOT, script, digest)
    game = (opts.game_root or Path(json.loads((ROOT/'docs/intake/install_manifest.json').read_text())['game_root'])).resolve()
    if opts.user_config:
        user = opts.user_config.resolve()
    else:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') as key:
            user = Path(os.path.expandvars(winreg.QueryValueEx(key, 'Personal')[0]))/'My Games/KillingFloor2/KFGame/Config'
    before = config_hashes(user)
    # App-container preparation redirects LOCALAPPDATA; the normal launcher
    # profile belongs to the actual Windows home, not that disposable sandbox.
    profile = Path.home()/'AppData/Local/KF2VR/Profile'
    profile_before = config_hashes(profile)
    if not before:
        raise RuntimeError('Require initialized user config; no profile will be created')
    run = (opts.output or ROOT/'build/reload-replay'/
           (datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-%f')+'-ammo-'+opts.case)).resolve()
    if run.exists() or user.is_relative_to(run) or run.is_relative_to(user) or run.is_relative_to(game):
        raise RuntimeError('Require fresh output outside installed game and user config')
    run.mkdir(parents=True)
    packages = run/'Packages'
    shutil.copytree(release/'Packages', packages)
    role = role_config(run, 'driver', user, packages, game, 7777, 27015, run/'Cache', False)
    configs = Path(role['config_root'])
    configure_case(configs, opts.case, opts.weapon, opts.no_voice, opts.lifecycle_case, opts.geometry_input)
    args = [a for a in role['args'] if not a.startswith(('-MULTIHOME=', '-Port=', '-QueryPort='))]
    # The companion also owns existing initial menu/selector setup. Keep it
    # present for that setup; its hold-only shot accounting is NOT a lifecycle
    # conservation verdict and the runner deliberately does not analyze it.
    ammo_mutator = ',KF2VRReplay.AmmoConservationObserver'
    args[0] = ('KF-Outpost?Game=KFGameContent.KFGameInfo_Survival?Difficulty=0?GameLength=0'
               '?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo'+ammo_mutator+
               '?ReloadReplayCase='+opts.case)
    args += ['-kf2vr-hand-replay', '-onethread', '-kf2vr-probe', '-nohomedir']
    preflight_configs(args, run)
    tape = (opts.input or (ROOT/'tools/replay/geometry-neutral.input' if opts.geometry_input else
            ROOT/scenario['input'] if scenario else
            ROOT/'tools/replay'/('advanced-'+opts.case+'.input'))).resolve()
    record.update(schema='kf2vr/reload-replay-prepared/1', status='prepared', process_started=False,
        reload_case=opts.case, weapon_family=opts.weapon, voice_disabled=opts.no_voice,
        ammo_observer=not bool(scenario), lifecycle_case=opts.lifecycle_case,
        geometry_input=opts.geometry_input,
        lifecycle_missing_requirements=(['Lose-ammo OFF, reversed completion order and queued cancellation',
            'Mixed Deagle/9mm, late recovered-insert cancellation and paid finish swaps',
            'Network authority and headset feel remain separate acceptance checks'] if opts.geometry_input else
            scenario['missing_requirements'] if scenario else []),
        package_root=str(packages), observer_root=str(run/'Observer'),
        arguments=args, game_sha256=digest(game/'Binaries/Win64/KFGame.exe'),
        native_probe={'destination':str(game/'Binaries/Win64/dinput8.dll')},
        environment={'SteamAppId':'232090', 'SteamGameId':'232090', 'KF2VR_LOG_PATH':str(run/'native.log'),
                     'KF2VR_INPUT_REPLAY_WAIT_READY':'1', 'KF2VR_INPUT_REPLAY_REALTIME':'1'},
        user_config_root=str(user), user_config_before=before, prepared_config_sha256=config_hashes(configs),
        saved_profile_root=str(profile), saved_profile_before=profile_before,
        input_file=str(tape), input_sha256=digest(tape), native_artifacts_sha256=native['artifacts_sha256'],
        full_reload_accepted=False, multiplayer_accepted=False, headset_accepted=False)
    if (config_hashes(user) != before or config_hashes(profile) != profile_before
            or digest(pointer) != record['selected_pointer_sha256']):
        raise RuntimeError('User config or player selection changed during preparation')
    (run/'run.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    print(run/'run.json')


if __name__ == '__main__':
    main()
