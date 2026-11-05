"""Reconcile observed prop/token rows with settled authority samples.

This validates log evidence, not physical pickup, insertion, rendering or travel.
Missing props retain their paid ledger budget; their absence never means discard.
"""
import argparse
import json
from pathlib import Path
import re


def fields(line, marker, errors):
    result = {}
    for token in line.split(marker, 1)[1].split():
        if '=' not in token:
            errors.append('Malformed '+marker.strip()+' field')
            continue
        key, value = token.split('=', 1)
        if key in result:
            errors.append('Duplicate field: '+key)
        result[key] = value
    return result


def audit(log, case):
    if case not in ('normal', 'dual'):
        raise ValueError('Unknown replay case')
    errors, samples, payloads = [], {}, {}
    for line in log.splitlines():
        if 'KF2VR_AMMO_OBSERVER ' in line:
            row = fields(line, 'KF2VR_AMMO_OBSERVER ', errors)
            if any(row.get(k) != v for k,v in dict(phase='sample', case=case,
                    source='authority', worldWeapons='False').items()):
                errors.append('Invalid authority sample identity or policy')
            if any(not re.fullmatch(r'\d+', row.get(k,'')) for k in ('seq','escrow','tokens')):
                errors.append('Invalid authority sequence or escrow count')
                continue
            seq = int(row['seq'])
            if seq in samples or seq != len(samples)+1:
                errors.append('Missing or duplicate authority sequence')
            samples[seq] = dict(escrow=int(row['escrow']), tokens=int(row['tokens']))
        elif 'KF2VR_AMMO_PAYLOAD ' in line:
            row = fields(line, 'KF2VR_AMMO_PAYLOAD ', errors)
            if any(not re.fullmatch(r'\d+',row.get(k,'')) for k in ('seq','token','remaining')):
                errors.append('Invalid payload sequence, token or remaining count')
                continue
            if (not re.fullmatch(r'-?\d+',row.get('propRounds',''))
                    or row.get('hand') not in ('-1','0','1')
                    or any(row.get(k) not in ('True','False') for k in
                           ('retired','propPresent','meshBound'))
                    or any(not row.get(k) or row[k] == 'None' for k in ('registry','weapon'))
                    or not row.get('carrier')):
                errors.append('Invalid payload ownership or presentation fields')
                continue
            seq, token = int(row['seq']), int(row['token'])
            if seq <= 0 or token <= 0:
                errors.append('Nonpositive payload sequence or token')
                continue
            key = (row['registry'], token)
            rows = payloads.setdefault(seq, {})
            if key in rows:
                errors.append('Duplicate payload identity in settled sample')
            rows[key] = dict(row, remaining=int(row['remaining']), propRounds=int(row['propRounds']))
    previous, absent, unbound, reconciled = {}, set(), set(), []
    for seq in sorted(set(samples) | set(payloads)):
        if seq not in samples:
            errors.append('Payload has no settled authority sample')
            continue
        rows = payloads.get(seq, {})
        live = [row for row in rows.values() if row['retired'] == 'False']
        if (sum(row['remaining'] for row in live) != samples[seq]['escrow']
                or len(live) != samples[seq]['tokens']):
            errors.append('Payload budget/count does not match authority escrow')
        leases = set()
        for key,row in rows.items():
            if row['retired'] == 'True' and row['remaining'] != 0:
                errors.append('Retired payload still contains rounds')
            if (row['carrier'] == 'None') != (row['hand'] == '-1'):
                errors.append('Carrier and hand disagree')
            if row['retired'] == 'False' and row['carrier'] != 'None':
                lease = (row['carrier'], row['hand'])
                if lease in leases:
                    errors.append('Two live payloads lease the same carrier hand')
                leases.add(lease)
            if row['propPresent'] == 'True':
                if row['propRounds'] != row['remaining']:
                    errors.append('Prop rounds do not match ledger remaining')
                if row['meshBound'] == 'False': unbound.add(key)
            else:
                absent.add(key)
                if row['propRounds'] != -1 or row['meshBound'] != 'False':
                    errors.append('Absent prop has presentation data')
            prior = previous.get(key)
            if prior is not None:
                if row['weapon'] != prior['weapon']:
                    errors.append('Paid token source weapon changed')
                if row['remaining'] > prior['remaining']:
                    errors.append('Paid payload refilled')
                if prior['retired'] == 'True' and row['retired'] != 'True':
                    errors.append('Retired token resurrected')
            previous[key] = row
        # Once observed, a live paid token must remain represented even when
        # its cosmetic prop disappears. A new registry is a different identity.
        if any(row['retired'] == 'False' and key not in rows for key,row in previous.items()):
            errors.append('Previously paid token disappeared without retirement')
        reconciled.append(dict(seq=seq, ledger_remaining=sum(row['remaining'] for row in live),
                               live_tokens=len(live)))
    if not samples or not payloads:
        errors.append('No authority samples and paid payload rows observed')
    return dict(counts_consistent=not errors, errors=errors, authority_samples=len(samples),
                payload_rows=sum(len(rows) for rows in payloads.values()), reconciled=reconciled,
                missing_prop_identities=[list(key) for key in sorted(absent)],
                unbound_mesh_identities=[list(key) for key in sorted(unbound)],
                coverage='observed-single-world-authority-payload-accounting',
                full_reload_accepted=False, recovery_accepted=False, rendered_ejection_accepted=False,
                lifecycle_accepted=False, headset_accepted=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log',type=Path)
    parser.add_argument('--case',choices=('normal','dual'),required=True)
    args = parser.parse_args()
    from run import log_text
    result = audit(log_text(args.log),args.case)
    print(json.dumps(result,indent=2))
    raise SystemExit(0 if result['counts_consistent'] else 1)
