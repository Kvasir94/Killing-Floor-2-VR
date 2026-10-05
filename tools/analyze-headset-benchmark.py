"""Analyze explicitly marked real headset play using SteamVR observations."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import statistics

spec = importlib.util.spec_from_file_location('runtime', Path(__file__).with_name('analyze-runtime-monitor.py'))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def analyze(root):
    root = Path(root)
    session = json.loads((root / 'session.json').read_text(encoding='utf-8'))
    rows = runtime.read_rows(root / 'runtime.csv')
    phases = []
    for phase in session['phases']:
        if phase['label'] not in ('noncombat', 'combat'):
            continue
        start, end = phase['start_tick_ms'] + 2000, phase.get('end_tick_ms', 0) - 2000
        selected = [r for r in rows if r['scenePid'] == session['game_pid'] and
                    start <= r.get('firstObservedTickMs', -1) <= end and
                    0 < r.get('firstPollGapMs', 1e9) <= 500]
        issues = []
        if not session.get('controls_unchanged'):
            issues.append('VR controls changed or snapshots unavailable')
        if not session.get('collector_clean_exit'):
            issues.append('Collector has not exited successfully')
        if not phase.get('headset_worn') or not phase.get('active_play'):
            issues.append('Player did not attest worn headset and real active play')
        if not selected:
            phases.append(dict(label=phase['label'], valid=False, issues=issues + ['No attributed observations']))
            continue
        indices = [r['frameIndex'] for r in selected]
        if indices != sorted(set(indices)):
            raise ValueError('Duplicate/reordered compositor frames')
        missing = sum(max(0, b-a-1) for a, b in zip(indices, indices[1:]))
        coverage = max(r['firstObservedTickMs'] for r in selected) - min(r['firstObservedTickMs'] for r in selected)
        if min(r['firstObservedTickMs'] for r in selected)-start > 500 or end-max(r['firstObservedTickMs'] for r in selected) > 500:
            issues.append('Compositor observations do not cover both phase boundaries')
        if coverage < 20000 or len(selected) < 30 or end-start < 20000:
            issues.append('Need at least 24 seconds per phase including edge trimming')
        if missing:
            issues.append('Compositor history has missing frame indices')
        hz = {r['refreshHz'] for r in selected if r['refreshError'] == 0 and r['refreshHz'] > 0}
        if len(hz) != 1 or any(r['refreshError'] != 0 or r['refreshHz'] <= 0 for r in selected):
            issues.append('Refresh rate unavailable or changed')
        intervals = [r['clientIntervalMs'] for r in selected]
        timing = None
        if all(v > 0 for v in intervals):
            timing = dict(mean_ms=statistics.mean(intervals),
                          application_fps=1000/statistics.mean(intervals),
                          p50_ms=statistics.median(intervals),
                          p95_ms=sorted(intervals)[math.ceil(.95*len(intervals))-1],
                          p99_ms=sorted(intervals)[math.ceil(.99*len(intervals))-1],
                          maximum_ms=max(intervals),
                          interval_exceeding_nominal_refresh_fraction=(sum(v > 1000/next(iter(hz)) for v in intervals)/len(intervals) if len(hz)==1 else None))
        else:
            issues.append('Runtime application interval field unsupported/incomplete; FPS unavailable')
        result = runtime.summarize(selected)[str(session['game_pid'])]
        result.update(label=phase['label'], valid=not issues, issues=issues,
                      observed_coverage_seconds=coverage/1000, missing_frame_indices=missing,
                      application_timing=timing, player_note=phase.get('note', ''))
        phases.append(result)
    labels = {p['label'] for p in phases if p['valid']}
    return dict(schema='kf2vr/real-headset-benchmark/1', valid=labels == {'noncombat','combat'} and all(p['valid'] for p in phases),
                context=session['context'], phases=phases, delivered_headset_fps=None,
                note='Player-attested real play; wearing, tracking and combat are not independently verified. Two seconds trimmed at edges. Application FPS uses SteamVR client intervals when supported; this is not panel or wireless delivery FPS. Intervals exceeding nominal refresh include normal pacing jitter and do not measure missed display frames. Quest streaming/decoder/network performance requires the connection app overlay. Compare repeated runs on the same PC, map, connection, refresh and resolution.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    args = parser.parse_args()
    report = analyze(args.root)
    (args.root/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))
