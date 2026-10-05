"""One compact table for a performance batch: one row per trial, valid or not.

Reads batch.json plus each run's performance.json / compositor-phases.json /
adapter.log and writes summary.md next to batch.json (also printed).
"""
import argparse
import json
import re
import statistics
from pathlib import Path


def load(path):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8-sig'))
    except (OSError, ValueError):
        return None


def gpu_ms(run):
    """Median adapter-measured stereo GPU span, if timings were on."""
    try:
        text = (Path(run) / 'adapter.log').read_text(encoding='utf-8', errors='replace')
    except OSError:
        return None
    spans = [float(m) for m in re.findall(r'GpuTiming sample=\d+ stereoSpanMs=([\d.]+)', text)]
    return statistics.median(spans) if spans else None


# Production FrameTiming buckets split by the thread that would own them if
# rendering were threaded (docs/THREADED_RENDERING.md). The viewport-draw
# remainder (left/right view) is counted as render: its canvas commands run
# inline today. xrBegin is excluded: it is where the runtime's pacing wait lands.
GAME = ('otherMs', 'controllerMs', 'simulationMs', 'vmDispatchMs', 'vmBodyMs',
        'viewSetupMs', 'sceneSetupMs', 'viewportSetupMs')
RENDER = ('worldMs', 'leftMs', 'rightMs', 'portalMs', 'xrSubmitMs', 'presentMs', 'eyeCopyMs')


def busy_ms(run, threaded=False):
    """Per-phase work per frame: total (excluding the XR begin/wait), game side
    and render side, from 5 s timing windows wholly inside the measured idle (2)
    and horde (4) phases. Unlike fps it is not quantised by vsync.

    The buckets are timed on the thread that presents. Under threaded
    rendering that is the render thread, so the bucket split is reported only
    for one-thread runs; threaded runs report each thread's CPU time instead
    (game thread from GameThreadTiming, render thread from ThreadCpu), and the
    game thread's wall time it was not running (waiting on the render thread)."""
    try:
        text = (Path(run) / 'adapter.log').read_text(encoding='utf-8', errors='replace')
    except OSError:
        return {}
    starts = {int(p): int(t) for t, p in re.findall(r'tick_ms=(\d+).*?BenchmarkCapture phase=(-?\d+) previous=', text)}
    windows, window, game = [], None, []
    for line in text.splitlines():
        if 'GameThreadTiming revision=' in line:
            game.append({k: float(x) for k, x in re.findall(r'(\w+)=(-?\d+(?:\.\d+)?)', line)})
            continue
        # FrameTiming opens a window; FramePacing and FrameDetail follow it.
        if 'FrameTiming elapsedMs=' in line:
            window = {}
            windows.append(window)
        elif window is None or not ('FramePacing ' in line or 'FrameDetail ' in line or 'ThreadCpu ' in line):
            continue
        window.update({k: float(x) for k, x in re.findall(r'(\w+)=(-?\d+(?:\.\d+)?)', line)})
    result = {}
    for phase, label in ((2, 'idle'), (4, 'horde')):
        if phase not in starts or phase + 1 not in starts:
            continue
        within = lambda w: starts[phase] + 5000 <= w['tick_ms'] <= starts[phase + 1]
        inside = [w for w in windows if w.get('presents') and within(w)]
        frames = sum(w['presents'] for w in inside)
        if not frames:
            continue
        threaded = threaded or any(w.get('threaded') for w in inside)
        cpu = [w for w in inside if 'presentThreadCpuMs' in w]
        cpu_frames = sum(w['presents'] for w in cpu)
        present_cpu = sum(w['presentThreadCpuMs'] for w in cpu) / cpu_frames if cpu_frames else None
        entry = {'work': sum(w['elapsedMs'] - w.get('xrBeginMs', 0) for w in inside) / frames}
        if threaded:
            g = [w for w in game if w.get('frames') and within(w)]
            g_frames = sum(w['frames'] for w in g)
            if g_frames:
                entry['game_cpu'] = sum(w['cpuMs'] for w in g) / g_frames
                entry['game_blocked'] = sum(w['elapsedMs'] - w['cpuMs'] for w in g) / g_frames
            entry['render_cpu'] = present_cpu
        else:
            entry['game'] = sum(sum(w.get(k, 0) for k in GAME) for w in inside) / frames
            entry['render'] = sum(sum(w.get(k, 0) for k in RENDER) for w in inside) / frames
            entry['game_cpu'] = present_cpu
        result[label] = entry
    return result


def fmt(value, digits=1):
    return '-' if value is None else f'{value:.{digits}f}'


def row(trial):
    run = trial.get('run')
    perf = load(Path(run) / 'performance.json') if run else None
    comp = load(Path(run) / 'compositor-phases.json') if run else None
    cells = [str(trial['index']), trial['variant'], trial.get('quality', 'quality'), str(trial['percent']), trial.get('status', '?')]
    busy = busy_ms(run, trial.get('variant') == 'Threaded') if run else {}
    for phase in ('idle', 'horde'):
        p = (perf or {}).get('phases', {}).get(phase) if perf and perf.get('valid') else None
        c = (comp or {}).get('phases', {}).get(phase) or {}
        split = busy.get(phase, {})
        cells += [fmt(p and p['application_fps']), fmt(p and p['p95_ms']), fmt(split.get('work'), 2),
                  fmt(c.get('throttled_frame_fraction'), 2) if c.get('available') else '-']
    refresh = None
    for phase in ((comp or {}).get('phases') or {}).values():
        if phase.get('refresh_hz'):
            refresh = phase['refresh_hz'][0]
    horde = busy.get('horde', {})
    cells += [fmt(horde.get('game'), 2), fmt(horde.get('render'), 2), fmt(horde.get('game_cpu'), 2),
              fmt(horde.get('render_cpu'), 2), fmt(horde.get('game_blocked'), 2), fmt(refresh, 0), fmt(gpu_ms(run) if run else None, 2), trial.get('error', '')[:70]]
    return cells


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('batch_root')
    args = parser.parse_args()
    root = Path(args.batch_root)
    batch = load(root / 'batch.json') or {}
    header = ['#', 'variant', 'quality', 'eye%', 'status', 'idle fps', 'idle p95 ms', 'idle busy ms', 'idle throttled',
              'horde fps', 'horde p95 ms', 'horde busy ms', 'horde throttled', 'horde game ms', 'horde render ms',
              'horde game CPU ms', 'horde render CPU ms', 'horde game blocked ms', 'Hz', 'GPU stereo ms', 'error']
    lines = [f"# {batch.get('label') or batch.get('experiment', '?')}  ({root.name})", '',
             f"warmup {batch.get('warmup_seconds')} s, measure {batch.get('measure_seconds')} s per phase; "
             'application fps is game-side presents (quantised by vsync); busy ms is frame work excluding the XR wait, '
             'the number to compare levers by; GPU stereo ms is the adapter span, not compositor. '
             'Game/render ms split the one thread by timer bucket (one-thread runs only); CPU ms is time each thread '
             'actually ran (one-thread: the game thread does everything); game blocked ms is game-thread time spent '
             'waiting, mostly on the render thread (threaded runs only).', '',
             '| ' + ' | '.join(header) + ' |', '|' + '---|' * len(header)]
    lines += ['| ' + ' | '.join(row(t)) + ' |' for t in batch.get('trials', [])]
    if batch.get('error'):
        lines += ['', f"batch error: {batch['error']}"]
    text = '\n'.join(lines) + '\n'
    (root / 'summary.md').write_text(text, encoding='utf-8')
    print(text, end='')


if __name__ == '__main__':
    main()
