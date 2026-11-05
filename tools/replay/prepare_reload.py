"""Prepare one isolated Advanced reload diagnostic; never launch or save a profile."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/multiplayer'))
from release_state import selected_release, verify_workspace, digest
from native_fixture import verify_native
from session import role_config, read_ini, set_ini, config_hashes
from vr_config import apply_preferences
from run import disable_script_inputs, preflight_configs

ADVANCED = dict(ReloadPreset='2', AmmoRuleSettingsRevision='1', bInteractiveReloads='True',
    bFreeWeaponCycling='True', bKeepChamberedRound='True',
    bLoseReloadAmmo='True', bRecoverMagazineAmmo='True', bSupportHandCarry='True',
    bIndependentHands='True', bToggleGrip='True', bHoldSupportGrip='False',
    bWorldWeaponDrops='False', bAllowOtherWeaponPickup='False',
    bExperimentalStandingHolds='False', bExperimentalInteractions='False',
    bZedGrabEnabled='False', bDisableGravityPull='True')

def configure_reload(configs, case):
    """All overrides are applied only to the caller's disposable config copy."""
    path = configs / 'KFGame.ini'
    # Seed the same complete playable preferences as the ordinary launcher.
    # No persistent profile import/export occurs: this is already a run copy.
    text = apply_preferences(read_ini(path))
    for section in ('KF2VR.VRHandsBridge', 'KF2VRNetClient.KF2VRNetHandsBridge'):
        text = set_ini(text, section, ADVANCED)
    text = set_ini(text, 'KF2VR.VRDemo', {'bNormalGame':'False', 'bRenderDiagnostic':'False'})
    text = set_ini(text, 'KF2VRNet.KF2VRNetPlayerController', {
        'bDiagnosticSyntheticAutoStart':'False', 'bDiagnosticObserverDebug':'False'})
    text = set_ini(text, 'KF2VRReplay.ReloadObserver', {'Scenario':case,
        'HoldSeconds':'12', 'ObservationSeconds':'40', 'bExitOnComplete':'True'})
    path.write_text(text, encoding='utf-16')
    path.write_bytes(disable_script_inputs(path.read_bytes()))
    path = configs / 'KFEngine.ini'
    # The diagnostic viewport inherits the normal VR viewport and filters real
    # keyboard/mouse input, leaving only the explicit native tape and F10 abort.
    text = set_ini(read_ini(path), 'Engine.Engine', {
        'GameViewportClientClassName':'KF2VRNetClient.KF2VRNetViewportClient', 'bSmoothFrameRate':'False'})
    text = set_ini(text, 'KF2VRNetClient.KF2VRNetViewportClient', {'bDiagnosticInputIsolation':'True'})
    path.write_text(text, encoding='utf-16')
    path = configs / 'KFSystemSettings.ini'
    text = set_ini(read_ini(path), 'SystemSettings', {'ResX':'640', 'ResY':'360',
        'ScreenPercentage':'100', 'MaxDrawDistanceScale':'1', 'DynamicShadows':'False'})
    path.write_text(text, encoding='utf-16')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', required=True, choices=('normal','dual'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--game-root', type=Path)
    parser.add_argument('--user-config', type=Path)
    opts = parser.parse_args()
    release, manifest = selected_release(ROOT)
    verify_workspace(ROOT, manifest)
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
    if not before:
        raise RuntimeError('Require an initialized user config; no profile will be created')
    run = (opts.output or ROOT/'build/reload-replay'/
        (datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-%f')+'-'+opts.case)).resolve()
    if run.exists() or user.is_relative_to(run) or run.is_relative_to(user) or run.is_relative_to(game):
        raise RuntimeError('Require a fresh output outside installed game and user profile')
    run.mkdir(parents=True)
    packages = run/'Packages'
    shutil.copytree(release/'Packages', packages)
    role = role_config(run, 'driver', user, packages, game, 7777, 27015, run/'Cache', False)
    configs = Path(role['config_root'])
    configure_reload(configs, opts.case)
    args = [a for a in role['args'] if not a.startswith(('-MULTIHOME=', '-Port=', '-QueryPort='))]
    args[0] = ('KF-Outpost?Game=KFGameContent.KFGameInfo_Survival?Difficulty=0?GameLength=0'
        '?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo?ReloadReplayCase='+opts.case)
    args += ['-kf2vr-hand-replay', '-onethread', '-kf2vr-probe', '-nohomedir']
    preflight_configs(args, run)
    selection = ROOT/'build/multiplayer/current-release.json'
    record = dict(schema='kf2vr/reload-replay-prepared/1', status='prepared', process_started=False,
        reload_case=opts.case, selected_release=release.name, selected_pointer_sha256=digest(selection),
        selected_manifest_sha256=digest(release/'release.json'), package_root=str(packages),
        observer_root=str(run/'Observer'), arguments=args, game_sha256=digest(game/'Binaries/Win64/KFGame.exe'),
        native_probe={'destination':str(game/'Binaries/Win64/dinput8.dll')},
        environment={'SteamAppId':'232090','SteamGameId':'232090','KF2VR_LOG_PATH':str(run/'native.log'),
            'KF2VR_INPUT_REPLAY_WAIT_READY':'1','KF2VR_INPUT_REPLAY_REALTIME':'1'},
        user_config_root=str(user), user_config_before=before, prepared_config_sha256=config_hashes(configs),
        input_file=str(ROOT/'tools/replay'/('advanced-'+opts.case+'.input')),
        input_sha256=digest(ROOT/'tools/replay'/('advanced-'+opts.case+'.input')),
        native_artifacts_sha256=native['artifacts_sha256'], full_reload_accepted=False,
        multiplayer_accepted=False, headset_accepted=False)
    (run/'run.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    if config_hashes(user) != before:
        raise RuntimeError('User config changed during preparation')
    print(run/'run.json')

if __name__ == '__main__':
    main()
