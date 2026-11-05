"""Report declared transition/pairwise plans and reanalyze existing game logs.

No process is started. Pairwise rows describe intended headset/native-input
coverage, not a substitute model or an executable claim.
"""
import argparse
from itertools import combinations
import json
from pathlib import Path
import subprocess

from ammo_analyze import analyze as ammo_analyze
from ammo_startup import startup_state
from run import log_text
from reload_trace_analyze import analyze as trace_analyze, analyze_geometry

ROOT = Path(__file__).resolve().parents[2]
COMMON = {
    'hand': ['left', 'right'], 'role': ['primary', 'support-carry'],
    'offhand': ['empty', 'supporting', 'ammo', 'object', 'another-weapon'],
    'ammo': ['belt', 'recovered'], 'location': ['physical', 'hip'],
    'loaded': ['empty', 'partial', 'full'], 'reserve': ['zero', 'partial', 'refill'],
    'chamber': ['empty', 'loaded'], 'magazine': ['installed', 'removed'],
    'grip': ['hold', 'release-regrip', 'transfer'],
    'owed': ['no', 'yes'], 'motion': ['stationary', 'locomotion'],
    'insertion': ['magnetic', 'fast'],
    'interruption': ['none', 'grip-release', 'transfer', 'switch', 'tracking-loss', 'death', 'network-owner'],
    'order': ['valid', 'incomplete', 'invalid', 'repeated', 'near-simultaneous'],
}


def pairwise(factors):
    """Deterministic covering array of declared factor values; no game logic."""
    names = list(factors)
    uncovered = {(i, a, j, b) for i, j in combinations(range(len(names)), 2)
                 for a in factors[names[i]] for b in factors[names[j]]}
    rows = []
    while uncovered:
        i, a, j, b = min(uncovered)
        row = {i: a, j: b}
        for k in range(len(names)):
            if k in row:
                continue
            def score(v):
                return sum((h, w, k, v) in uncovered if h < k else
                           (k, v, h, w) in uncovered for h, w in row.items())
            row[k] = max(factors[names[k]], key=score)
        covered = {(i, row[i], j, row[j]) for i, j in combinations(range(len(names)), 2)}
        uncovered.difference_update(covered)
        rows.append({name: row[k] for k, name in enumerate(names)})
    return rows


def audit_runs(base):
    results = []
    for receipt in sorted(base.rglob('input-replay-run.json')):
        saved = json.loads(receipt.read_text(encoding='utf-8-sig'))
        prepared_path = receipt.parent/'run.json'
        if not prepared_path.exists():
            continue
        prepared = json.loads(prepared_path.read_text(encoding='utf-8-sig'))
        case = prepared.get('reload_case')
        if case not in ('normal', 'dual'):
            continue
        game_log = next((Path(a.split('=', 1)[1]) for a in saved.get('arguments', [])
                         if a.upper().startswith('-ABSLOG=')), receipt.parent/'driver/game.log')
        text = log_text(game_log)
        parsed = ammo_analyze(text, case)
        startup = startup_state(text, case)
        lifecycle = prepared.get('lifecycle_case')
        kind = 'hold'
        status = 'UNTESTED' if parsed['samples'] == 0 else ('PASS-BOUNDED-HOLD' if parsed['passed'] else 'FAILED-BOUNDED-HOLD')
        diagnostic = None
        if lifecycle:
            kind = 'lifecycle'
            diagnostic = trace_analyze(text, lifecycle)
            status = 'UNTESTED'
            if prepared.get('geometry_input'):
                kind = 'geometry'
                native_log = Path(prepared.get('environment', {}).get('KF2VR_LOG_PATH', receipt.parent/'native.log'))
                diagnostic = analyze_geometry(text, log_text(native_log), lifecycle)
                status = diagnostic['status']
        results.append(dict(run=receipt.parent.name, receipt=str(receipt), game_log=str(game_log),
            log_present=game_log.exists(), release=saved.get('release'),
            candidate_manifest_sha256=prepared.get('candidate_manifest_sha256'),
            weapon=prepared.get('weapon_family', '9mm'), case=case,
            saved_observer_complete=saved.get('observer_complete'),
            coverage_kind=kind, lifecycle_case=lifecycle,
            reanalyzed_passed=parsed['passed'] if kind == 'hold' else False, authority_samples=parsed['samples'],
            bounded_case_passed=bool(diagnostic and diagnostic.get('bounded_case_passed')), status=status,
            diagnostic=diagnostic, startup=startup,
            errors=diagnostic['errors'] if diagnostic else parsed['errors'], observed_counts=parsed['observed_counts'],
            full_reload_accepted=False, headset_accepted=False, multiplayer_accepted=False))
    return results


def report(base):
    plan = json.loads((ROOT/'tools/replay/reload_scenarios.json').read_text())
    families = sorted({s['family'] for s in plan['scenarios']})
    pair_rows = pairwise(COMMON)
    pointer = ROOT/'build/multiplayer/current-release.json'
    return dict(schema='kf2vr/reload-coverage/1',
        revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        selected=json.loads(pointer.read_text(encoding='utf-8-sig')),
        runtime_invoked=False, accepted=False,
        scenarios=plan['scenarios'],
        pairwise=dict(status='planned-not-executed', factors=COMMON, rows_per_family=len(pair_rows),
            family_rows={family: pair_rows for family in families},
            limitation='All declared value pairs covered as plans, not all valid transition sequences. Family incompatibilities and unsupported routes remain explicitly untested.'),
        unsupported=[
            'Mixed Deagle/9mm and left-primary setup: existing normal setup draws right, dual setup is paired9mm only',
            'Measured physical contacts absent: native prefixes cannot establish support, action, insertion, hip or recovered pickup',
            'Death/map replacement stops native ReplayInput; requires separately coordinated sessions, not a restarted tape',
            'Network ownership: existing observer accepts standalone replay only; real Host/Join acceptance remains open',
            'Recovered shells/arrows and hip routes must be admitted by actual production owners; plan is not capability proof',
            'Full feed, owed-no and insertion modes are factor plans; mechanically impossible combinations are N/A after family admission',
            'Animation callbacks, highlight/grab equivalence, complete ammo grant/discard accounting and rendered transforms lack complete ordered assertions',
            'All requested lifecycle scenarios currently UNTESTED; current trace collector intentionally cannot return a reload pass'],
        family_applicability={
            'detachable': 'Magazine/chamber/physical/hip factors need actual family admission; mixed actors unsupported by setup',
            'revolver': 'Detachable magazine factor N/A; recovered detachable-mag token N/A; cylinder chamber occupancy replaces chamber factor',
            'break': 'Detachable magazine and hip-mag insert factors N/A; spent-shell ejection and action closure are required transitions',
            'pump': 'Detachable magazine N/A; shell/tube/port occupancy and pump-owed state are separate; hip-mag factor N/A',
            'bolt': 'Detachable magazine factor N/A for Mosin; clip/individual-round and bolt-owed behavior require actual family route',
            'lever': 'Detachable magazine factor N/A for SPX; lever-owed hand role and relative action motion required',
            'bow': 'Cartridge chamber and detachable magazine N/A; arrow carried/nocked/drawing phase replaces those factors',
            'secondary': 'Primary detachable magazine factors independent of secondary feed; primary and secondary reserve grants must not be conflated',
            'finish-action': 'Paid primary magazine/canister finishing controls retain their accepted profile and partial out/return state; ordinary chamber factors can be N/A and independent secondary feeds remain separate'},
        prior_runs=audit_runs(base))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runs', type=Path, default=ROOT/'build/reload-replay')
    parser.add_argument('--output', type=Path, default=ROOT/'build/reload-replay/transition-coverage.json')
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT/'build'):
        parser.error('Generated coverage must stay under build/')
    result = report(args.runs)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(dict(output=str(output), families=len(result['pairwise']['family_rows']),
        pairwise_rows_per_family=result['pairwise']['rows_per_family'],
        scenarios=len(result['scenarios']), prior_runs=len(result['prior_runs']), accepted=False)))
