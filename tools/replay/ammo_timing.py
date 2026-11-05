"""Bounded startup/readiness deadlines for isolated replay processes."""
import re


def startup_milestones(log):
    """First engine timestamps for diagnosis; these never release readiness."""
    markers = {'world_loaded':'Bringing World ', 'engine_playable':'KF2VR_DEMO',
               'initial_shell_closed':'KF2VR_AMMO_SETUP action=close-startup-shell',
               'reload_ready':'KF2VR_RELOAD_OBSERVER phase=ready',
               'observer_complete':'KF2VR_RELOAD_OBSERVER phase=complete'}
    found = {}
    for line in log.splitlines():
        stamp = re.search(r'\[(\d+(?:\.\d+)?)\]',line)
        if not stamp:
            continue
        for key,marker in markers.items():
            if key not in found and marker in line:
                if key == 'engine_playable' and 'phase=playable' not in line:
                    continue
                found[key] = float(stamp[1])
    return found


def readiness_seen(log, case):
    if case not in ('normal', 'dual'):
        raise ValueError('Unknown replay case')
    return bool(re.search(r'KF2VR_RELOAD_OBSERVER phase=ready case='+case+r'(?:\s|$)',log))


def startup_budget(total, requested=None, *, reload_case=False):
    if not 30 <= total <= 600:
        raise ValueError('Total timeout must be 30..600 seconds')
    if requested is not None and not 30 <= requested <= 600:
        raise ValueError('Startup timeout must be 30..600 seconds')
    return min(total, requested if requested is not None else (240 if reload_case else 120))


def timeout_phase(elapsed, total, startup, ready):
    if elapsed >= total:
        return 'session' if ready else 'startup'
    if not ready and elapsed >= startup:
        return 'startup'
    return None
