"""Measure passive production-owner traces. Collection is never acceptance."""
import argparse
import json
from pathlib import Path
import re
from ammo_payload_analyze import fields


def analyze(text, case):
    errors, rows = [], []
    warnings = re.findall(r'^.*(?:ScriptWarning:|ScriptError:|Critical:|Fatal error).*$', text, re.M)
    for line in text.splitlines():
        if 'KF2VR_RELOAD_TRACE ' not in line:
            continue
        tokens = re.findall(r'(?:^|\s)(\w+)=([^\s]+)', line.split('KF2VR_RELOAD_TRACE ', 1)[1])
        row = dict(tokens)
        if len(row) != len(tokens):
            errors.append('Duplicate trace field')
        if row.get('case') != case:
            errors.append('Trace case mismatch')
        if not re.fullmatch(r'[1-9]\d*', row.get('seq', '')):
            errors.append('Missing positive trace sequence')
            continue
        if int(row['seq']) != len(rows) + 1:
            errors.append('Missing or duplicate ordered trace sequence')
        if row.get('phase') not in ('input', 'state', 'recovery', 'geometry', 'complete'):
            errors.append('Unknown trace phase')
        if row.get('phase') == 'state':
            if any(not row.get(k) for k in ('weapon', 'pawn', 'world', 'ownership', 'loaded', 'reserve')):
                errors.append('State identity/accounting fields missing')
            if any(not re.fullmatch(r'\d+', row.get(k, '')) for k in ('ownership', 'loaded', 'reserve')):
                errors.append('Invalid state count')
        rows.append(row)
    completed = [r for r in rows if r.get('phase') == 'complete']
    if (len(completed) != 1 or not rows or rows[-1] != completed[0]
            or completed[0].get('status') != 'UNTESTED' or completed[0].get('acceptance') != 'False'):
        errors.append('Require one final observation-only completion')
    counts = {phase: sum(r.get('phase') == phase for r in rows)
              for phase in ('input', 'state', 'recovery', 'geometry')}
    if not counts['input'] or not counts['state']:
        errors.append('Missing real input/state observations')
    if warnings:
        errors.append('Runtime warning or error')
    return dict(case=case, status='UNTESTED', passed=False,
                collection_complete=not errors, samples=counts, errors=errors,
                runtime_warnings=warnings, ordered_observations=rows,
                coverage='passive-production-state-collection-only',
                missing_assertions=['scenario preconditions', 'ordered completion receipts',
                                    'ammo conservation across grants/discards', 'animation events',
                                    'highlight-to-grab agreement', 'rendered transforms'],
                full_reload_accepted=False, multiplayer_accepted=False, headset_accepted=False)


def analyze_geometry(text, native_text, case, *, input_isolation_verified=False):
    """Check only the finite paired-9mm input path, from actual callsite logs."""
    errors, events, callbacks, stack = [], [], [], []
    for line in text.splitlines():
        marker = next((m for m in ('KF2VR_RELOAD_GEOMETRY ', 'KF2VR_RELOAD_CALLBACK ') if m in line), None)
        if marker is None:
            continue
        row = fields(line, marker, errors)
        row['_order'] = len(events) + len(callbacks)
        if row.get('case') != case:
            errors.append('Geometry case mismatch')
        if marker.startswith('KF2VR_RELOAD_GEOMETRY'):
            events.append(row)
            continue
        callbacks.append(row)
        if row.get('source') != 'production' or row.get('seq') != str(len(callbacks)):
            errors.append('Missing ordered production callback')
        if row.get('phase') == 'before':
            if not re.fullmatch(r'[1-9]\d*', row.get('call', '')):
                errors.append('Invalid callback invocation')
            stack.append(row)
        elif row.get('phase') == 'after' and stack:
            before = stack.pop()
            if any(before.get(k) != row.get(k) for k in ('call', 'function', 'weapon', 'action')):
                errors.append('Unbalanced callback identity')
        else:
            errors.append('Unbalanced callback return')
    if stack:
        errors.append('Missing production callback return')
    initial = [r for r in events if r.get('phase') == 'initial']
    terminal = [r for r in events if r.get('phase') == 'complete']
    if not events:
        return dict(status='UNTESTED', bounded_case_passed=False, errors=['No geometry samples'],
                    full_reload_accepted=False, headset_accepted=False, multiplayer_accepted=False)
    if len(initial) != 1 or len(terminal) != 1 or events[-1] != terminal[0]:
        errors.append('Require one initial and final geometry outcome')
    if not initial or not terminal:
        return dict(status='FAILED', bounded_case_passed=False, errors=errors,
                    full_reload_accepted=False, headset_accepted=False, multiplayer_accepted=False)
    start, end = initial[0], terminal[0]
    try:
        reserve = int(start['reserve'])
        if reserve < 30 or start.get('loadedLeft') != '15' or start.get('loadedRight') != '15':
            raise ValueError()
    except (KeyError, ValueError):
        reserve = -1
        errors.append('Invalid observed initial ammo')
    weapons = [start.get('left'), start.get('right')]
    if (any(not w or '.' not in w for w in weapons) or weapons[0] == weapons[1]
            or not start.get('pawn') or start.get('authoredInput') != 'True'
            or start.get('measuredHumanInput') != 'False' or start.get('loseAmmo') != 'True'):
        errors.append('Invalid initial identity or authored policy')
    if (end.get('passed') != 'True' or end.get('reason') != 'authored-contact-path-completed'
            or any(end.get(k) != 'True' for k in ('leftContact', 'rightContact'))
            or any(end.get(k) != 'False' for k in ('multiplayerAccepted', 'headsetAccepted'))):
        errors.append('Geometry path did not complete its bounded checks')
    after = [r for r in callbacks if r.get('phase') == 'after']
    removals = {}
    for hand, weapon in enumerate(weapons):
        def call(name):
            return [r for r in after if r.get('weapon') == weapon and r.get('function') == name]
        remove = call('KF2VR.VRMagazineAuthority.Remove')
        read = [r for r in call('KF2VR.VRMagazineAuthority.Read') if r.get('kind') == '0']
        seat = [r for r in call('KF2VR.VRCylinderSession.Tick') if r.get('boundary') == 'seat-contact']
        paid = call('KF2VR.VRCylinderSession.Complete')
        if any(len(rows) != 1 for rows in (remove, read, seat, paid)):
            errors.append('Need exactly one removal/read/contact/payment per weapon')
            continue
        remove, read, seat, paid = remove[0], read[0], seat[0], paid[0]
        token = remove.get('receipt', '')
        removals[hand] = token
        if (not re.fullmatch(r'[1-9]\d*', token) or read.get('receipt') != token
                or end.get('leftRemoval' if hand == 0 else 'rightRemoval') != token
                or remove.get('actual') != '14' or remove.get('remaining') != '14'
                or read.get('actual') != '14' or read.get('remaining') != '14'
                or any(r.get('accepted') != 'True' for r in (remove, read, seat, paid))
                or seat.get('hip') != 'True' or seat.get('hand') != str(hand)
                or paid.get('loaded') != '16' or not re.fullmatch(r'[1-9]\d*', paid.get('receipt', ''))
                or not (remove['_order'] < read['_order'] < seat['_order'] < paid['_order'])):
            errors.append('Invalid ordered removal, contact or paid receipt')
    if len(removals) != 2 or removals.get(0) == removals.get(1):
        errors.append('Distinct actual removal receipts missing')
    if case == 'dual-removal-backend-busy':
        queued = [r for r in after if r.get('function') == 'KF2VR.VRCylinderSession.BeginMagazine'
                  and r.get('boundary') == 'admission-wait' and r.get('accepted') == 'True']
        if not queued or end.get('busyObserved') != 'True':
            errors.append('Actual backend contention was not observed')
    ledgers = {r.get('step'): r for r in events if r.get('phase') == 'ledger'}
    for step, loaded, expected_reserve, escrow, tokens in (
            ('1', 30, reserve, 0, 0), ('4', 2, reserve, 28, 2),
            ('5', 32, reserve - 30, 28, 2), ('7', 32, reserve - 30, 28, 2)):
        row = ledgers.get(step, {})
        expected = dict(loaded=loaded, reserve=expected_reserve, escrow=escrow, tokens=tokens, shots=0, mismatch=0)
        if any(row.get(k) != str(v) for k, v in expected.items()):
            errors.append('Missing or inconsistent actual ledger at step '+step)
    if (not input_isolation_verified and ('KF2VR_INPUT_ISOLATION phase=installed' not in text
            or 'ReplayInputIsolationProbe passed=1' not in native_text)):
        errors.append('Physical input isolation was not verified')
    collected = analyze(text, case)
    errors.extend(collected['errors'])
    return dict(status='FAILED' if errors else 'OBSERVED-BOUNDED', bounded_case_passed=not errors,
                errors=errors, geometry_rows=len(events), callback_rows=len(callbacks),
                coverage='paired9mm-capacity-removal-both-hip-seats-full-rejection; loseAmmo=True',
                remaining=['lose-ammo OFF', 'reverse completion order', 'cancellation',
                           'late recovered insert', 'paid finish swap', 'network', 'headset feel'],
                full_reload_accepted=False, headset_accepted=False, multiplayer_accepted=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--case', required=True)
    args = parser.parse_args()
    from run import log_text
    result = analyze(log_text(args.log), args.case)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['collection_complete'] else 1)
