"""Audit ordered production callback observations in the existing replay harness.

Parser fixtures exercise this analyzer only. Unknown fields, missing callbacks,
zero samples and unsupported actions never establish gameplay acceptance.
"""
import argparse
import json
import math
from pathlib import Path
import re

from ammo_payload_analyze import fields


COUNTS = ('loaded', 'reserve', 'escrow', 'shots', 'grants', 'discarded', 'commits')
BOOLS = ('owed', 'magOut', 'chamberLoaded', 'accepted', 'solicited', 'occupied')
TRACE_SCHEMA = {
    'input': {
        'count': 'buttons grips triggers valid roomEpoch',
        'vector': 'left right leftRotation rightRotation leftHand rightHand leftRoom rightRoom',
        'time': 'elapsed'},
    'state': {
        'count': 'ownership loaded reserve feed mechanismPending',
        'role': 'primary support carryPrimary', 'hand': 'slot',
        'bool': 'current chamberLoaded magOut attached physical awaitAmmo awaitRack',
        'number': 'guide rackPull', 'time': 'elapsed',
        'identity': 'weapon pawn world', 'value': 'owner mesh stockState'},
    'recovery': {
        'hand': 'hand', 'count': 'request token queuedAction remaining',
        'bool': 'active claimed guide requireFresh handBusy hipBusy',
        'vector': 'origin', 'value': 'source target'},
    'geometry': {
        'identity': 'weapon', 'vector': 'entry seat entryLocal seatLocal',
        'number': 'insertTime insertEnd carryTime', 'value': 'cylinderFrame'},
    'complete': {'value': 'status reason acceptance'},
}


def exact_identity(value):
    """PathName identities, including UE package/map names and subobject colons."""
    return bool(re.fullmatch(r'[A-Za-z0-9_-]+(?:[.:][A-Za-z0-9_-]+)+', value or ''))


def finite_number(value):
    try:
        return math.isfinite(float(value))
    except (TypeError, ValueError):
        return False


def validate_trace(row, errors):
    # ReloadObserver emits this marker and phase-specific fields, not a separate
    # schema= token. Validate its actual wire shape rather than inventing one.
    schema = TRACE_SCHEMA.get(row.get('phase'))
    if schema is None:
        errors.append('Invalid or missing trace phase schema')
        return
    for kind, keys in schema.items():
        for key in keys.split():
            value = row.get(key)
            valid = value not in (None, '')
            if kind == 'count':
                valid = bool(re.fullmatch(r'\d+', value or ''))
            elif kind == 'role':
                valid = value in ('-1', '0', '1')
            elif kind == 'hand':
                valid = value in ('0', '1')
            elif kind == 'bool':
                valid = value in ('True', 'False')
            elif kind in ('number', 'time'):
                valid = finite_number(value) and (kind != 'time' or float(value) >= 0)
            elif kind == 'vector':
                parts = (value or '').split(',')
                valid = len(parts) == 3 and all(finite_number(p) for p in parts)
            elif kind == 'identity':
                valid = exact_identity(value)
            if not valid:
                errors.append('Invalid or missing trace '+kind+':'+key)
    if row.get('phase') == 'state' and any(k in row for k in ('owed', 'progress', 'opened', 'engaged', 'actionHand', 'gunHand')):
        for key in ('owed', 'opened', 'engaged'):
            if row.get(key) not in ('True', 'False'):
                errors.append('Invalid or missing trace manual boolean:'+key)
        if not finite_number(row.get('progress')):
            errors.append('Invalid or missing trace manual progress')
        for key in ('actionHand', 'gunHand'):
            if row.get(key) not in ('-1', '0', '1'):
                errors.append('Invalid or missing trace manual hand:'+key)


def audit(text, case, required_functions=()):
    errors, missing, rows, traces = [], set(), [], []
    calls, stack, receipts, totals = {}, [], set(), {}
    functions, sequence, trace_sequence = [], 0, 0
    terminal, complete_count, last_elapsed = False, 0, 0.0
    observed_weapons = set()
    for line in text.splitlines():
        if re.search(r'(?:ScriptWarning:|ScriptError:|Critical:|Assertion failed:)', line):
            errors.append('Runtime warning or error')
        if 'KF2VR_RELOAD_TRACE ' in line:
            row = fields(line, 'KF2VR_RELOAD_TRACE ', errors)
            if terminal:
                errors.append('Trace observation after terminal completion')
            if row.get('case') != case:
                errors.append('Trace case mismatch')
            validate_trace(row, errors)
            if not re.fullmatch(r'[1-9]\d*', row.get('seq', '')):
                errors.append('Invalid trace sequence')
            else:
                trace_sequence += 1
                if int(row['seq']) != trace_sequence:
                    errors.append('Missing or duplicate trace sequence')
            if row.get('phase') in ('input', 'state') and finite_number(row.get('elapsed')):
                elapsed = float(row['elapsed'])
                if elapsed < last_elapsed:
                    errors.append('Trace elapsed time went backwards')
                last_elapsed = elapsed
            if row.get('phase') == 'state' and exact_identity(row.get('weapon')):
                observed_weapons.add(row['weapon'])
            if row.get('phase') == 'geometry' and row.get('weapon') not in observed_weapons:
                errors.append('Geometry weapon has no preceding state identity')
            if row.get('phase') == 'complete':
                complete_count += 1
                if (row.get('status') != 'UNTESTED' or row.get('acceptance') != 'False'):
                    errors.append('Completion must be observation-only UNTESTED with acceptance=False')
                if complete_count != 1:
                    errors.append('Duplicate terminal completion')
                if not all(any(r.get('phase') == p for r in traces) for p in ('input', 'state')):
                    errors.append('Terminal completion precedes required input/state observations')
                terminal = True
            traces.append(row)
            continue
        if 'KF2VR_RELOAD_CALLBACK ' not in line:
            continue
        if terminal:
            errors.append('Production callback after terminal completion')
        row = fields(line, 'KF2VR_RELOAD_CALLBACK ', errors)
        if row.get('case') != case or row.get('source') != 'production':
            errors.append('Callback case or production source mismatch')
        if any(not re.fullmatch(r'[1-9]\d*', row.get(k, '')) for k in ('seq', 'call')):
            errors.append('Invalid callback sequence or invocation')
            continue
        sequence += 1
        if int(row['seq']) != sequence:
            errors.append('Missing or duplicate callback sequence')
        if not exact_identity(row.get('function')) or not exact_identity(row.get('weapon')):
            errors.append('Missing responsible function or exact weapon identity')
        if observed_weapons and row.get('weapon') not in observed_weapons:
            errors.append('Callback weapon has no preceding state identity')
        if not observed_weapons:
            missing.add('preceding-state-observations')
        if not any(r.get('phase') == 'input' for r in traces):
            missing.add('preceding-input-observations')
        if row.get('action', 'Unknown') == 'Unknown':
            missing.add('callback-action')
        elif row['action'] not in ('reload', 'insert', 'cycle', 'role', 'recover', 'eject', 'shot', 'grant', 'discard'):
            errors.append('Invalid callback action')
        for key in ('feed', 'receipt'):
            value = row.get(key, 'Unknown')
            if value == 'Unknown':
                missing.add('callback:'+key)
            elif not re.fullmatch(r'\d+', value):
                errors.append('Invalid callback '+key)
        for key in COUNTS:
            value = row.get(key, 'Unknown')
            if value == 'Unknown':
                missing.add('counter:'+key)
            elif not re.fullmatch(r'\d+', value):
                errors.append('Invalid counter:'+key)
        for key in BOOLS:
            value = row.get(key, 'Unknown')
            if value == 'Unknown':
                missing.add('predicate:'+key)
            elif value not in ('True', 'False'):
                errors.append('Invalid boolean:'+key)
        if row.get('progress', 'Unknown') != 'Unknown':
            try:
                if not math.isfinite(float(row['progress'])):
                    raise ValueError()
            except ValueError:
                errors.append('Invalid cycle progress')
        else:
            missing.add('cycle-progress')
        for key in ('primary', 'support'):
            if row.get(key, 'Unknown') == 'Unknown':
                missing.add('role:'+key)
            elif row[key] not in ('-1', '0', '1'):
                errors.append('Invalid hand role:'+key)
        if all(re.fullmatch(r'\d+', row.get(key, '')) for key in COUNTS):
            # Reconcile observed authoritative numbers, never simulate payment.
            total = sum(int(row[k]) for k in ('loaded', 'reserve', 'escrow', 'shots', 'discarded')) - int(row['grants'])
            prior = totals.setdefault(row.get('weapon'), total)
            if total != prior:
                errors.append('Observed ammo duplicated or lost')
        call = int(row['call'])
        if row.get('phase') == 'before':
            if call in calls:
                errors.append('Invocation id reused')
            if call != len(calls) + 1:
                errors.append('Missing or nonmonotonic callback invocation')
            calls[call] = row
            stack.append(call)
        elif row.get('phase') == 'after':
            before = calls.get(call)
            if not stack or stack[-1] != call:
                errors.append('Callback return is missing, duplicate or out of order')
            else:
                stack.pop()
            if before is None:
                errors.append('Callback has no before observation')
            elif any(row.get(k) != before.get(k) for k in ('function', 'weapon', 'action')):
                errors.append('Callback invocation identity changed')
            else:
                functions.append(row['function'])
                if row.get('accepted') == 'True':
                    if row.get('action') == 'reload' and before.get('solicited') == 'False':
                        errors.append('Unsolicited automatic reload accepted')
                    if row.get('action') == 'insert' and before.get('occupied') == 'True':
                        errors.append('Insertion accepted into occupied target feed')
                    if row.get('action') in ('insert', 'reload'):
                        if not re.fullmatch(r'[1-9]\d*', row.get('receipt', '')):
                            missing.add('accepted-commit-receipt')
                        else:
                            key = (row['weapon'], row['receipt'])
                            if key in receipts:
                                errors.append('Receipt committed more than once')
                            receipts.add(key)
                if row.get('action') == 'role':
                    if before.get('owed') == 'True' and row.get('owed') == 'False':
                        errors.append('Role change cleared an owed cycle')
                    if all(r.get('progress', 'Unknown') != 'Unknown' for r in (before, row)):
                        try:
                            if abs(float(row['progress']) - float(before['progress'])) > 0.0001:
                                errors.append('Role change lost or advanced cycle progress')
                        except ValueError:
                            pass  # Already reported as malformed above.
                if all(re.fullmatch(r'\d+', r.get('commits', '')) for r in (before, row)):
                    delta = int(row['commits']) - int(before['commits'])
                    if delta < 0 or delta > 1 or (row.get('accepted') == 'False' and delta != 0):
                        errors.append('Invalid or duplicate commit count transition')
        else:
            errors.append('Invalid callback phase')
        rows.append(row)
    if stack:
        missing.add('callback-return')
    if not rows:
        missing.add('production-callbacks')
    if not any(r.get('phase') == 'input' for r in traces):
        missing.add('ordered-input-observations')
    if not any(r.get('phase') == 'state' for r in traces):
        missing.add('logical-and-visual-state-observations')
    if not any(r.get('phase') == 'complete' for r in traces):
        missing.add('observation-completion')
    cursor = 0
    for required in required_functions:
        try:
            cursor = functions.index(required, cursor) + 1
        except ValueError:
            missing.add('ordered-callback:'+required)
    return dict(status='FAILED' if errors else 'UNTESTED' if missing else 'OBSERVED',
                errors=errors, missing=sorted(missing), callback_rows=len(rows),
                trace_rows=len(traces), completed_functions=functions,
                observed_invariants=bool(rows) and not errors and not missing,
                full_reload_accepted=False, headset_accepted=False, multiplayer_accepted=False,
                coverage='finite-authored-case-only; no exhaustive acceptance')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--case', required=True)
    opts = parser.parse_args()
    from run import log_text
    plan = json.loads(Path(__file__).with_name('reload_scenarios.json').read_text())
    scenario = next((s for s in plan['scenarios'] if s['id'] == opts.case), None)
    if scenario is None:
        parser.error('Unknown authored trace case')
    result = audit(log_text(opts.log), opts.case, scenario.get('callback_order', ()))
    if not scenario.get('callback_order'):
        result['missing'].append('authored-callback-order')
        if result['status'] != 'FAILED':
            result['status'] = 'UNTESTED'
            result['observed_invariants'] = False
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['status'] == 'OBSERVED' else 1)
