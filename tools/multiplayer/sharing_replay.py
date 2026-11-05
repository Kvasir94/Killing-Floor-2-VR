"""Explicit dedicated-server sharing replay configuration and log analysis."""
from pathlib import Path
import re

from evidence import events, is_true, mode_is

CHECKS = ('draw', 'sharing_off', 'magazine_remove', 'magazine_published', 'throw',
          'authority_drop', 'remote_mesh', 'free_recipient_hand', 'gun_denied_off',
          'sharing_on', 'magazine_position', 'magazine_denied_no_family',
          'sharing_revoked', 'revocation_position', 'gun_denied_revoked',
          'sharing_restored', 'gun_transferred', 'single_authoritative_owner',
          'stow_transferred_gun', 'magazine_claim_inventory_family', 'magazine_carried',
          'magazine_release', 'magazine_carrier_cleared', 'magazine_reclaim_position',
          'magazine_reclaim', 'magazine_release_again', 'redraw_transferred',
          'timed_return_config', 'timed_throw', 'timed_return', 'redraw_timed',
          'manual_return_config', 'manual_throw', 'manual_stays', 'manual_recall',
          'redraw_manual', 'never_return_config', 'never_throw', 'never_stays',
          'both_controls_denied', 'never_recall_denied', 'enable_manual_recall',
          'quick_swap_recall', 'quick_swap_returned')


def configure(roles):
    from session import read_ini, set_ini, config_hashes
    for role in roles:
        config = Path(role['config_root']) / 'KFGame.ini'
        text = read_ini(config)
        text = set_ini(text, 'KF2VRNet.KF2VRNetPlayerController', {
            'bDiagnosticSharingReplay': 'True' if role['role'] != 'server' else 'False',
            'bDiagnosticDualWeapons': 'False', 'bDiagnosticPairedWeapons': 'False',
            'bDiagnosticAutoFire9mm': 'False', 'bDiagnosticSyntheticAutoStart': 'False',
            'bDiagnosticVRControls': 'False', 'bDiagnosticMotionFixture': 'False',
            'bDiagnosticVisualReplay': 'False', 'bDiagnosticObserverOnly': 'False'})
        for section in ('KF2VR.VRHandsBridge', 'KF2VRNetClient.KF2VRNetHandsBridge'):
            text = set_ini(text, section, {
                'bWorldWeaponDrops': 'True', 'bAllowOtherWeaponPickup': 'False',
                'bWorldDropRadialRecall': 'True', 'WorldDropReturnPolicy': '2',
                'bIndependentHands': 'True', 'bSupportHandCarry': 'True',
                'bToggleGrip': 'True', 'bHoldSupportGrip': 'False',
                'bDualHandReplay': 'False', 'bPairedHandReplay': 'False',
                'bDiagnostic9mmReload': 'False', 'bInteractiveReloads': 'True',
                'bFreeWeaponCycling': 'True',
                'bDisableGravityPull': 'True', 'bExperimentalInteractions': 'False'})
        if role['role'] == 'server':
            role['args'][0] = role['args'][0].replace('?VRNet9mm=1', '?VRNet9mm=0')
            role['args'][0] += '?VRNetSharingReplay=1?VRNetQuietZeds=1'
        else:
            role['args'].append('-kf2vr-sharing-replay')
        config.write_text(text, encoding='utf-16')
        role['config_hashes'] = config_hashes(config.parent)


def warnings(text):
    """Keep stock startup warnings visible; fail all unclassified/runtime warnings."""
    first_case = text.find('KF2VRNet sharing_')
    known, actionable = [], []
    pattern = r'(?m)^.*ScriptWarning:.*(?:\n[ \t]+[^\n]*){0,2}'
    for match in re.finditer(pattern, text):
        block = match.group()
        stock = ("Function KFGame.KFPawn_Human:UpdateActiveSkillsPath:" in block
                 or "Function KFGame.KFGFxMoviePlayer_HUD:UpdateObjectiveActive:" in block
                 or "Function KFGame.KFPlayerController:InitPerkLoadout:" in block)
        target = known if stock and first_case >= 0 and match.start() < first_case else actionable
        target.append(block)
    actionable += re.findall(r'(?im)^.*(?:Critical:|Fatal error:).*$', text)
    return {'known_stock_startup': known, 'actionable': actionable}


def analyze(server, owner, recipient):
    rows = events(server, 'sharing_case')
    actual = [r.get('case') for r in rows if r.get('phase') == 'check']
    warning_report = {role: warnings(log) for role, log in zip(('server', 'owner', 'recipient'), (server, owner, recipient))}
    checks = {
        'ordered_authority_cases': actual == list(CHECKS),
        'authority_results': bool(rows) and all(is_true(r.get('passed'))
            and mode_is(r.get('netmode'), 'dedicated') for r in rows),
        'complete': bool(rows) and rows[-1].get('phase') == 'complete',
        'both_clients_executed': all(events(log, 'sharing_client') for log in (owner, recipient)),
        'remote_mesh': any(is_true(r.get('shared')) and not is_true(r.get('hidden'))
            and mode_is(r.get('netmode'), 'client') for log in (owner, recipient)
            for r in events(log, 'sharing_observer')),
        'no_unclassified_or_runtime_warnings': not any(r['actionable'] for r in warning_report.values()),
    }
    return {'passed': all(checks.values()), 'checks': checks,
            'observed_cases': actual, 'missing_cases': [c for c in CHECKS if c not in actual],
            'warnings': warning_report,
            'limits': 'Synthetic local clients and scripted pawn positioning; mesh state is not visual headset acceptance.'}
