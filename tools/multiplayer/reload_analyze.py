"""Analyze observed Advanced reload entry/hold logs; never claim full insertion or multiplayer."""
import argparse
import json
from pathlib import Path
import re

PREFIX = 'KF2VR_RELOAD_OBSERVER'

def analyze(text, case):
    errors = []
    rows = []
    if case not in ('normal', 'dual'):
        raise ValueError('Unknown reload case')
    if re.search(r'(?i)(ScriptWarning:|Accessed None|Infinite (?:loop|script recursion)|Critical error|Assertion failed|Fatal error)', text):
        errors.append('Runtime warning or error')
    for line in text.splitlines():
        if PREFIX not in line:
            continue
        payload = line.split(PREFIX, 1)[1].strip()
        pairs = re.findall(r'([A-Za-z][A-Za-z0-9_]*)=([^\s]+)', payload)
        row = dict(pairs)
        if len(row) != len(pairs):
            errors.append('Duplicate observer field')
        if row.get('case') != case:
            errors.append('Unexpected or missing observer case')
        if row.get('phase') not in ('setup','ready','shot','physical-accepted','state','complete'):
            errors.append('Unknown observer phase')
        if row.get('passed') == 'False' or row.get('worldWeapons') == 'True':
            errors.append('Observer reported failure or world weapons enabled')
        rows.append(row)
    ready = [i for i,r in enumerate(rows) if r.get('phase') == 'ready']
    complete = [i for i,r in enumerate(rows) if r.get('phase') == 'complete']
    if len(ready) != 1 or any(r.get('phase') != 'setup' for r in rows[:ready[0] if ready else len(rows)]):
        errors.append('Require one initial ready observation')
    elif any(rows[ready[0]].get(k) != v for k,v in
             {'preset':'Advanced','nativeCapability':'9','worldWeapons':'False','coverage':'physical-entry-hold-only'}.items()):
        errors.append('Ready lacks Advanced capability and world gate')
    if len(complete) != 1 or complete != [len(rows)-1]:
        errors.append('Require one final completion observation')
    states = [r for r in rows if r.get('phase') == 'state']
    required = {'1'} if case == 'normal' else {'0','1'}
    observed = {r.get('hand') for r in states}
    if not required.issubset(observed) or not observed.issubset({'0','1'}):
        errors.append('Expected hand observations missing or invalid')
    for row in states:
        if case == 'normal' and row.get('hand') == '0' and row.get('identity') == 'None' and row.get('stage') == 'empty':
            continue
        for key in ('ammo','reserve'):
            try:
                if int(row.get(key,'')) < 0:
                    raise ValueError()
            except ValueError:
                errors.append('Invalid '+key+' observation')
        if not row.get('identity') or not row.get('weaponClass') or not row.get('stage'):
            errors.append('Missing weapon identity or physical stage')
        if row.get('worldWeapons') != 'False' or row.get('nativeCapability') != '9':
            errors.append('State lacks world gate or native capability')
        if row.get('pairedStatus') == '4' or row.get('stockRequest') not in (None, '0'):
            errors.append('Observed stock paired fallback')
    for hand in required:
        for phase in ('shot','physical-accepted'):
            if not any(r.get('phase') == phase and r.get('hand') == hand for r in rows):
                errors.append('Missing '+phase+' observation for hand '+hand)
        if not any(r.get('hand') == hand and r.get('physicalActive') == 'True'
                   and r.get('authorityHeld') == 'True' for r in states):
            errors.append('Missing accepted physical state for hand '+hand)
        identities = {r.get('identity') for r in rows if r.get('phase') != 'setup'
                      and r.get('hand') == hand and r.get('identity')}
        if len(identities) != 1 or 'None' in identities:
            errors.append('Weapon identity changed for hand '+hand)
        previous = None
        for row in states:
            if row.get('hand') != hand:
                continue
            try:
                ammo = int(row.get('ammo',''))
            except ValueError:
                continue
            if previous is not None and ammo > previous:
                errors.append('Unattended ammo increase for hand '+hand)
            previous = ammo
    if complete:
        end = rows[complete[0]]
        expected = {'passed':'True', 'coverage':'physical-entry-hold-only',
            'fullInsertion':'False', 'multiplayerAccepted':'False'}
        if any(end.get(k) != v for k,v in expected.items()):
            errors.append('Completion lacks bounded entry/hold result')
        if case == 'dual' and (end.get('otherHandShot') != 'True'
                or not any(r.get('phase') == 'shot' and r.get('hand') == '1'
                           and r.get('otherHandShot') == 'True' for r in rows)):
            errors.append('Missing other-hand shot during dual physical hold')
    return {'case':case, 'passed':not errors, 'errors':list(dict.fromkeys(errors)),
        'state_rows':len(states), 'observed_hands':sorted(x for x in observed if x is not None),
        'coverage':'physical-entry-hold-only', 'full_reload_accepted':False,
        'multiplayer_accepted':False, 'headset_accepted':False}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--case', required=True, choices=('normal','dual'))
    args = parser.parse_args()
    data = args.log.read_bytes()
    text = data.decode('utf-16' if data[:2] in (b'\xff\xfe',b'\xfe\xff') else 'utf-8-sig', errors='replace')
    result = analyze(text, args.case)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)

if __name__ == '__main__':
    main()
