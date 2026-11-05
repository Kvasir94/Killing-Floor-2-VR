"""Selection/configuration and log analysis for several cases in one real game.

This module never simulates a reload. Each case is checked by the existing
production-observation analyzers, bounded by ordered in-game case markers.
"""
import json
import re
from pathlib import Path

SUPPORTED_HOLD = ('9mm', 'deagle', 'ar15', 'thompson')

def module(case):
    return case.get('module') or ('geometry' if case.get('geometry_input') else 'hold')

def actor_key(case):
    from weapons import weapon_path
    return weapon_path(case['weapon']).lower(), case['case']


def validate_cases(cases):
    if not 1 <= len(cases) <= 16:
        raise ValueError('A launch requires 1..16 executable cases')
    saw_geometry = False
    for case in cases:
        if module(case) in ('magazine-hip', 'revolver-hip'):
            from weapons import weapon_path
            weapon_path(case['weapon'])
            if saw_geometry or case.get('case') not in ('normal', 'dual') or not re.fullmatch(r'[A-Za-z0-9_]+', case.get('lifecycle_case', '')):
                raise ValueError('Magazine cases require an identity and must precede legacy geometry')
            if any(type(case.get(k)) is not bool for k in ('keep_chamber', 'lose_ammo', 'recover_mags')):
                raise ValueError('Magazine cases require explicit boolean option profiles')
        elif case.get('geometry_input'):
            if (saw_geometry or case.get('weapon') != '9mm' or case.get('case') != 'dual'
                    or case.get('lifecycle_case') not in ('hip-tactical-at-capacity', 'dual-removal-backend-busy')):
                raise ValueError('Only one final paired-9mm geometry case is supported per launch')
            saw_geometry = True
        elif saw_geometry or case.get('case') != 'normal':
            raise ValueError('Hold cases require supported normal weapons before geometry')
        else:
            from weapons import weapon_path
            weapon_path(case['weapon'])
    return cases


def group_cases(jobs, size=8):
    if not 2 <= size <= 16:
        raise ValueError('Cases per launch must be 2..16')
    indices = [i for i, job in enumerate(jobs) if job['status'] == 'PLANNED' and job.get('scope', 'solo') == 'solo']
    indices.sort(key=lambda i: module(jobs[i]) == 'geometry')
    from weapons import weapon_path
    groups = []
    # Reusing one class would inherit its paid tokens and ammunition from the
    # preceding case. Keep separate option/mode trials in separate launches.
    for index in indices:
        identity = actor_key(jobs[index])
        group = next((g for g in groups if len(g) < size
                      and all(actor_key(jobs[i]) != identity for i in g)
                      and not any(module(jobs[i]) == 'geometry' for i in g)), None)
        if group is None:
            group = []; groups.append(group)
        group.append(index)
    if len(groups) > 1 and len(groups[-1]) == 1 and len(groups[-2]) > 2:
        candidate = next((i for i in reversed(groups[-2]) if module(jobs[i]) != 'geometry'
                          and actor_key(jobs[i]) != actor_key(jobs[groups[-1][0]])), None)
        if candidate is not None:
            groups[-2].remove(candidate); groups[-1].insert(0, candidate)
    for group in groups:
        validate_cases([jobs[i] for i in group])
    return groups


def configure_suite(configs, cases):
    from datetime import datetime, timezone
    from session import read_ini, set_ini
    validate_cases(cases)
    specs = ['|'.join((c['weapon'], c['case'], module(c), c.get('lifecycle_case') or '') +
                      tuple(str(int(c[k])) for k in ('keep_chamber', 'lose_ammo', 'recover_mags'))
                      if module(c) in ('magazine-hip', 'revolver-hip') else
                      (c['weapon'], c['case'], module(c), c.get('lifecycle_case') or '')) for c in cases]
    path = Path(configs)/'KFGame.ini'
    text = set_ini(read_ini(path), 'KF2VRReplay.BatchObserver',
                   {'Cases': specs, 'HoldSeconds': '12', 'ObservationSeconds': '40',
                    'CaseTimeoutSeconds': '140', 'SetupTimeoutSeconds': '90',
                    'CapturePrefix': 'KF2VR_Replay_'+datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S%f')})
    path.write_text(text, encoding='utf-16')


def _fields(line):
    tokens = re.findall(r'(\w+)=([^\s]+)', line)
    if len(tokens) != len(dict(tokens)):
        raise ValueError('Duplicate suite marker field')
    return dict(tokens)


def analyze_suite(text, native, cases):
    from reload_analyze import analyze as hold_analyze
    from ammo_analyze import analyze as ammo_analyze
    from ammo_payload_analyze import audit as payload_analyze
    from reload_trace_analyze import analyze_geometry
    validate_cases(cases)
    input_isolation_verified = ('KF2VR_INPUT_ISOLATION phase=installed' in text
                                and 'ReplayInputIsolationProbe passed=1' in native)
    errors, results, current, content, completed = [], [], None, [], False
    for line in text.splitlines():
        if 'KF2VR_REPLAY_SUITE ' not in line:
            if current is not None:
                content.append(line)
            continue
        try:
            row = _fields(line.split('KF2VR_REPLAY_SUITE ', 1)[1])
        except ValueError as error:
            errors.append(str(error)); continue
        phase = row.get('phase')
        if completed:
            errors.append('Suite marker after completion')
        if phase == 'begin':
            index = len(results)
            if current is not None or index >= len(cases) or row.get('index') != str(index+1):
                errors.append('Overlapping, duplicate or unexpected case begin'); continue
            expected = cases[index]
            from weapons import weapon_path
            try:
                weapon_matches = weapon_path(row.get('weapon', '')).lower() == weapon_path(expected['weapon']).lower()
            except ValueError:
                weapon_matches = False
            if (not weapon_matches or any(row.get(k) != v for k, v in dict(mode=expected['case'],
                    tests=module(expected)).items())):
                errors.append('Case selection identity mismatch')
            current = expected
            content = []
        elif phase == 'end':
            if current is None or row.get('index') != str(len(results)+1):
                errors.append('Case end without matching begin'); continue
            observed = '\n'.join(content)
            if module(current) == 'magazine-hip':
                from magazine_analyze import analyze
                diagnostic = analyze(observed, current)
                passed = diagnostic['bounded_case_passed']
                item = dict(status='OBSERVED-BOUNDED' if passed else 'FAILED', diagnostic=diagnostic)
            elif module(current) == 'revolver-hip':
                from revolver_analyze import analyze
                diagnostic = analyze(observed, current)
                passed = diagnostic['bounded_case_passed']
                item = dict(status='OBSERVED-BOUNDED' if passed else 'FAILED', diagnostic=diagnostic)
            elif current['geometry_input']:
                diagnostic = analyze_geometry(observed, native, current['lifecycle_case'],
                                              input_isolation_verified=input_isolation_verified)
                passed = diagnostic['bounded_case_passed']
                item = dict(status='OBSERVED-BOUNDED' if passed else 'FAILED', diagnostic=diagnostic)
            else:
                hold = hold_analyze(observed, current['case'])
                ammo = ammo_analyze(observed, current['case'])
                payload = payload_analyze(observed, current['case'])
                # A result for the wrong class is never evidence for the selected weapon.
                from weapons import weapon_path
                classes = re.findall(r'KF2VR_RELOAD_OBSERVER .*?phase=state .*?weaponClass=([^\s]+)', observed)
                expected_class = weapon_path(current['weapon']).rsplit('.', 1)[1]
                class_ok = (bool(classes) and all(c.lower() in (expected_class.lower(), 'none') for c in classes)
                            and expected_class.lower() in [c.lower() for c in classes])
                passed = hold['passed'] and ammo['passed'] and payload['counts_consistent'] and class_ok
                item = dict(status='PASS-BOUNDED-HOLD' if passed else 'FAILED',
                            hold=hold, ammo=ammo, payload=payload, weapon_class_verified=class_ok)
            item.update(weapon=current['weapon'], case=current['case'], tests=current['tests'],
                        index=len(results)+1, errors=[], log_lines=len(content))
            if not passed:
                item['errors'] = (item.get('diagnostic', {}).get('errors', []) +
                    item.get('hold', {}).get('errors', []) + item.get('ammo', {}).get('errors', []) +
                    item.get('payload', {}).get('errors', []))
                if item.get('weapon_class_verified') is False:
                    item['errors'].append('Selected weapon class was not observed')
            if row.get('passed') != 'True':
                item['status'] = 'FAILED'
                item['errors'].append('Case failed: '+row.get('reason', 'missing-reason'))
            results.append(item)
            current, content = None, []
        elif phase == 'complete':
            if completed or current is not None or row.get('count') != str(len(cases)) or row.get('passed') != 'True':
                errors.append('Missing cases or failed suite completion')
            completed = True
        elif phase in ('watchdog', 'failure'):
            errors.append('Suite '+phase+': '+line.split('KF2VR_REPLAY_SUITE ', 1)[1])
        elif phase not in ('setup', 'progress', 'final-state'):
            errors.append('Unknown suite phase: '+str(phase))
    if current is not None or len(results) != len(cases) or not completed:
        errors.append('Missing complete case boundaries or suite completion')
    if re.search(r'(?i)ScriptWarning:|ScriptError:|Critical:|Fatal error|Accessed None|Infinite loop', text):
        errors.append('Runtime warning or fatal error in shared game log')
    epochs = re.findall(r'ReplayInputCase index=(\d+) accepted=([01])', native)
    if epochs != [(str(i+1), '1') for i in range(len(cases))]:
        errors.append('Missing, duplicated or rejected native input case epochs')
    if ('KF2VR_INPUT_ISOLATION phase=installed' not in text
            or 'ReplayInputIsolationProbe passed=1' not in native):
        errors.append('Missing physical input isolation proof')
    return dict(passed=not errors and all(r['status'] in ('OBSERVED-BOUNDED', 'PASS-BOUNDED-HOLD') for r in results),
                errors=errors, cases=results, completed_cases=len(results), expected_cases=len(cases),
                full_reload_accepted=False, headset_accepted=False, multiplayer_accepted=False)


def prepare(candidate, cases, output, *, game_root=None, user_config=None):
    """Reuse single-case preparation, then select the modular suite mutator."""
    import subprocess
    import sys
    from run import ROOT, digest
    from session import config_hashes
    validate_cases(cases)
    # This is only the disposable launch/config carrier. BatchObserver owns
    # actual selected classes and modes, including pairs outside the old tape.
    command = [sys.executable, str(ROOT/'tools/replay/ammo_prepare.py'), '--candidate', str(candidate),
               '--case', 'normal', '--weapon', '9mm', '--no-voice', '--output', str(output)]
    if game_root: command += ['--game-root', str(game_root)]
    if user_config: command += ['--user-config', str(user_config)]
    prepared = subprocess.run(command, capture_output=True, text=True)
    print(prepared.stdout)
    if prepared.returncode:
        print(prepared.stderr)
        raise RuntimeError('Existing case preparation failed')
    output = Path(output)
    record_path = output/'run.json'
    record = json.loads(record_path.read_text(encoding='utf-8-sig'))
    configs = output/'driver/Config'
    configure_suite(configs, cases)
    record['arguments'][0] = record['arguments'][0].replace(',KF2VRReplay.AmmoConservationObserver', '')
    tape = output/'suite.input'
    lines = (ROOT/'tools/replay/advanced-normal.input').read_text().splitlines()
    neutral = next(line for line in reversed(lines) if line and not line.startswith('#'))
    # Keep the neutral carrier available throughout bounded setup and observation.
    lines.append('60000 '+neutral.split(' ', 1)[1])
    tape.write_text('\n'.join(lines)+'\n', encoding='ascii')
    record.update(replay_suite=True, suite_cases=cases, geometry_input=False, ammo_observer=False,
                  lifecycle_case=None, input_file=str(tape.resolve()), input_sha256=digest(tape),
                  prepared_config_sha256=config_hashes(configs))
    record_path.write_text(json.dumps(record, indent=2), encoding='utf-8')
    return record
