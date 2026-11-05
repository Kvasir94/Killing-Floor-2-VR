"""One opt-in 9mm physical reload: disposable launch config and strict log checks."""
from pathlib import Path
import math
import re

from evidence import events, mode_is, is_true


def configure(roles):
    from session import read_ini, set_ini, config_hashes
    for role in roles:
        config = Path(role['config_root']) / 'KFGame.ini'
        text = read_ini(config)
        # Clear unrelated input drivers inherited from an old player config.
        for key in ('bDiagnosticAutoFire9mm', 'bDiagnosticSyntheticAutoStart', 'bDiagnosticVRControls',
                    'bDiagnosticDualWeapons', 'bDiagnosticPairedWeapons', 'bDiagnosticMotionFixture',
                    'bDiagnosticVisualReplay', 'bDiagnosticLocomotionReplay'):
            text = set_ini(text, 'KF2VRNet.KF2VRNetPlayerController', {key: 'False'})
        for section in ('KF2VR.VRHandsBridge', 'KF2VRNetClient.KF2VRNetHandsBridge'):
            text = set_ini(text, section, dict(ReloadPreset='2', AmmoRuleSettingsRevision='1',
                bInteractiveReloads='True', bFreeWeaponCycling='True',
                bKeepChamberedRound='True', bLoseReloadAmmo='True', bRecoverMagazineAmmo='True',
                bSupportHandCarry='True', bIndependentHands='True', bToggleGrip='True',
                bHoldSupportGrip='False',
                bWorldWeaponDrops='False', bAllowOtherWeaponPickup='False',
                bExperimentalInteractions='False', bZedGrabEnabled='False', bDisableGravityPull='True',
                bDualHandReplay='False', bUsabilityCapture='False', bPresentationProbe='False',
                bDualWieldProbe='False', bBreakActionCapture='False', bDiagnosticMagazineReloadCapture='False',
                bPairedHandReplay='False', bMeleeReplay='False', bGrabReplay='False', bBashLegReplay='False',
                bReloadHintCapture='False',
                bDiagnostic9mmReload='True' if role['role'] == 'driver' else 'False'))
        if role['role'] == 'server':
            text = set_ini(text, 'KF2VRNet.KF2VRNetGame', {'bIndependentWeapons': 'True'})
            role['args'][0] = role['args'][0].replace('?VRNet9mm=1', '?VRNet9mm=0')
            role['args'][0] += '?VRNet9mmReload=1?VRNetQuietZeds=1'
        elif role['role'] == 'driver':
            role['args'].append('-kf2vr-reload-9mm')
        config.write_text(text, encoding='utf-16')
        engine = config.parent / 'KFEngine.ini'
        engine.write_text(set_ini(read_ini(engine), 'Engine.Engine', {'bSmoothFrameRate': 'False'}), encoding='utf-16')
        role['config_hashes'] = config_hashes(config.parent)


def analyze(server, owner, observer):
    """Require independent authority, owning input and remote presentation results."""
    checks = {}
    phases = ('ready', 'shot_before', 'physical', 'held', 'reloaded', 'shot_after', 'complete')
    identities = ('world', 'connection', 'pawn', 'item', 'hand', 'target', 'capacity')
    try:
        streams = [events(server, 'reload_case'), events(owner, 'reload_case')]
        expected = [list(phases), list(phases[:4]) + ['carried'] + list(phases[4:])]
        for rows, role, wanted, mode in zip(streams, ('server', 'owner'), expected, ('dedicated', 'client')):
            checks[role + '_sequence'] = ([r['phase'] for r in rows] == wanted
                and all(r['role'] == role and mode_is(r.get('netmode'), mode) for r in rows))
        baseline = streams[0][0]
        checks['identity'] = all(all(r[k] == baseline[k] for k in identities) for rows in streams for r in rows)
        checks['identity'] &= all(int(baseline[k]) > 0 for k in ('world', 'connection', 'pawn', 'item'))
        checks['identity'] &= baseline['hand'] == '1' and baseline['target'].endswith('-reload9mm')
        capacity, reserve = int(baseline['capacity']), int(baseline['reserve'])
        checks['initial'] = capacity > 1 and int(baseline['ammo']) == capacity and reserve >= capacity
        expected_state = {
            'ready': (capacity, reserve, 0), 'shot_before': (capacity - 1, reserve, 1),
            'physical': (1, reserve, 1), 'held': (1, reserve, 1), 'carried': (1, reserve, 1),
            'reloaded': (capacity + 1, reserve - capacity, 1),
            'shot_after': (capacity, reserve - capacity, 2), 'complete': (capacity, reserve - capacity, 2)}
        checks['ammo_and_damage'] = all(tuple(int(r[k]) for k in ('ammo', 'reserve', 'damage'))
            == expected_state[r['phase']] for rows in streams for r in rows)
        held = next(r for r in streams[0] if r['phase'] == 'held')
        checks['hold'] = math.isfinite(float(held['held_seconds'])) and float(held['held_seconds']) >= 4
        # The normal physical reload implementation must report actual completion.
        completed = re.findall(r'KF2VR_INTERACTIVE_RELOAD phase=complete weapon=KFGameContent\.KFWeap_Pistol_9mm\s+ammo=(\d+)\b', owner)
        checks['physical_completion'] = completed == [str(capacity + 1)]
        # Independently observed server damage; checkpoint reports cannot invent it.
        damage = [r for r in events(server, 'target_damage') if r.get('target') == baseline['target']]
        checks['target_damage'] = ([int(r['receipt']) for r in damage] == [1, 2]
            and all(mode_is(r.get('netmode'), 'dedicated') and int(r['before']) > int(r['after'])
                    and int(r['damage']) > 0 for r in damage))
        observed_damage = [r for r in events(observer, 'target_state') if r.get('target') == baseline['target']]
        checks['observer_damage'] = checks['target_damage'] and all(any(int(r['receipt']) == int(hit['receipt'])
            and int(r['health']) == int(hit['after']) and mode_is(r.get('netmode'), 'client')
            for r in observed_damage) for hit in damage)
        remote = [r for r in events(observer, 'remote_weapon') if all(r.get(k) == baseline[k]
                  for k in ('world', 'connection', 'pawn', 'item', 'hand'))
                  and r.get('weapon') == 'KFGameContent.KFWeap_Pistol_9mm']
        # A baseline, pre-reload shot, reload, loaded presentation and later shot,
        # in observer log order. Absolute counters alone can include older effects.
        stage = 0
        initial_shots = reloaded_shots = 0
        for r in remote:
            if not (mode_is(r.get('netmode'), 'client') and is_true(r.get('ready'))):
                continue
            if not (math.isfinite(float(r['muzzle_error'])) and float(r['muzzle_error']) <= 2
                    and math.isfinite(float(r['bore_error'])) and float(r['bore_error']) <= 3):
                continue
            shots, reloads, ammo = int(r['shots']), int(r['reloads']), int(r['ammo'])
            if stage == 0 and ammo == capacity and reloads == 0 and shots == 0:
                initial_shots = shots; stage = 1
            elif stage == 1 and ammo == capacity - 1 and shots > initial_shots:
                stage = 2
            elif stage == 2 and reloads >= 1:
                stage = 3
            elif stage == 3 and ammo == capacity + 1:
                reloaded_shots = shots; stage = 4
            elif stage == 4 and ammo == capacity and shots > reloaded_shots:
                stage = 5
        checks['observer_weapon'] = stage == 5
        checks['runtime_warnings'] = not any(re.search(r'ScriptWarning:|Critical:|Fatal error:', log, re.I)
                                             for log in (server, owner, observer))
    except (KeyError, ValueError, IndexError, StopIteration, TypeError) as error:
        return {'passed': False, 'checks': checks, 'error': 'Missing or malformed observations: ' + str(error)}
    return {'passed': bool(checks) and all(checks.values()), 'checks': checks}
