"""Analyze settled authoritative ammo samples alongside the existing replay verdict.

This parser measures physical-entry/hold tapes on admitted magazine families. It does not infer
insertion, recovery, rendering, map travel or headset acceptance from a pass.
"""
import argparse
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'multiplayer'))
from reload_analyze import analyze as analyze_reload


def analyze(text, case):
    errors, samples = [], []
    fields = ('seq', 'baseline', 'loaded', 'reserve', 'escrow', 'shots', 'tokens', 'mismatch', 'nativeCapability')
    for line in text.splitlines():
        if 'KF2VR_AMMO_OBSERVER ' not in line:
            continue
        row = {}
        for token in line.split('KF2VR_AMMO_OBSERVER ', 1)[1].split():
            if '=' not in token:
                errors.append('Malformed observer field')
                continue
            key, value = token.split('=', 1)
            if key in row:
                errors.append('Duplicate observer field: '+key)
            row[key] = value
        if any(row.get(k) != v for k, v in dict(phase='sample', case=case, source='authority', worldWeapons='False').items()):
            errors.append('Invalid sample identity, source or world policy')
        if any(not re.fullmatch(r'\d+', row.get(k, '')) for k in fields):
            errors.append('Missing or noninteger authority count')
            continue
        values = {k: int(row[k]) for k in fields}
        if values['seq'] != len(samples)+1:
            errors.append('Missing or duplicate sample sequence')
        if values['nativeCapability'] != 9 or values['mismatch']:
            errors.append('Native capability or prop/ledger mismatch')
        if values['loaded']+values['reserve']+values['escrow']+values['shots'] != values['baseline']:
            errors.append('Ammo conservation failed')
        if samples and values['baseline'] != samples[0]['baseline']:
            errors.append('Baseline changed')
        if samples and values['shots'] < samples[-1]['shots']:
            errors.append('Shot count went backwards')
        samples.append(values)
    if not samples or samples[0]['shots'] or samples[0]['escrow'] or samples[0]['tokens']:
        errors.append('Missing clean pre-shot authority baseline')
    if not samples or samples[-1]['shots'] < (2 if case == 'dual' else 1):
        errors.append('Required real shot observations missing')
    if not any(s['tokens'] >= (2 if case == 'dual' else 1) and s['escrow'] > 0 for s in samples):
        errors.append('Required paid magazine observations missing')
    driver = analyze_reload(text, case)
    if not driver['passed']:
        errors.append('Existing physical-entry/hold observer did not pass')
    return dict(passed=not errors, samples=len(samples), errors=errors, observed_counts=samples,
                coverage='physical-entry-hold-and-observed-paid-escrow',
                full_reload_accepted=False, recovery_accepted=False, rendered_ejection_accepted=False,
                multiplayer_accepted=False, headset_accepted=False)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('log', type=Path)
    p.add_argument('--case', choices=('normal', 'dual'), required=True)
    args = p.parse_args()
    from run import log_text
    result = analyze(log_text(args.log), args.case)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
