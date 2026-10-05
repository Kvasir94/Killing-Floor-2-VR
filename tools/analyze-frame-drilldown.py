"""Account for individual CPU frame intervals and correlate sampled stacks with stages.
Stack frequencies measure observed wall-clock occupancy, not CPU cycles or GPU passes.
"""
import argparse
import bisect
from collections import Counter, defaultdict
import csv
import hashlib
import json
import math
from pathlib import Path
import statistics
import struct
import sys

STAGES = ['otherMs','controllerMs','simulationMs','vmDispatchMs','vmBodyMs','leftMs','rightMs',
          'xrBeginMs','xrSubmitMs','presentMs','portalMs','worldMs','eyeCopyMs','viewSetupMs',
          'sceneSetupMs','viewportSetupMs','worldTickMs','leftSceneMs','rightSceneMs','diagnosticOutputMs']
GAME_HASH = '77ab9c2cf43aeaa3038274fff3822064815a3ea02a1b3c81870cdc12a885c994'


def read_csv(path):
    with Path(path).open(newline='', encoding='utf-8-sig') as stream:
        return list(csv.DictReader(stream))


def numbers(row):
    result = {k: float(v) for k, v in row.items()}
    if any(not math.isfinite(v) for v in result.values()):
        raise ValueError('Nonfinite CSV value')
    return result


def percentile(values, p):
    return sorted(values)[max(0, math.ceil(len(values)*p)-1)]


def game_ranges(path):
    """Group unsymbolized game IPs by unwind range, not invented function names."""
    if not path:
        return [], []
    sys.path.insert(0, str(Path(__file__).parent/'re'))
    from pe import PE
    pe = PE(str(path))
    if hashlib.sha256(pe.data).hexdigest() != GAME_HASH:
        raise ValueError('Game executable does not match pinned hash for RVA grouping')
    address, size = pe.dirs[3]
    data = pe.read(address, size)
    ranges = sorted((start, end) for start, end, _ in struct.iter_unpack('<III', data))
    return [start for start, _ in ranges], ranges


def code_label(row, ranges):
    module, symbol = row['module'], row['symbol']
    if symbol and int(row.get('displacement',0)) <= 4096:
        return module+'!'+symbol
    rva = int(row['rva'], 16)
    starts, entries = ranges
    if module.lower() == 'kfgame.exe' and starts:
        index = bisect.bisect_right(starts, rva)-1
        if index >= 0 and rva < entries[index][1]:
            return f'{module}!unwind_0x{starts[index]:x}'
    return f'{module}+0x{rva:x}'


def analyze(root, game_exe=None):
    root = Path(root)
    run_record = json.loads((root/'run.json').read_text(encoding='utf-8-sig')) if (root/'run.json').exists() else {}
    frames = [numbers(r) for r in read_csv(root/'frame-stages.csv')]
    if not frames:
        raise ValueError('No frame data')
    for index, frame in enumerate(frames):
        if frame['intervalMs'] <= 0 or any(frame[s] < 0 for s in STAGES):
            raise ValueError('Nonpositive interval or negative stage time')
        if abs(sum(frame[s] for s in STAGES)-frame['intervalMs']) > .02:
            raise ValueError(f"Unaccounted frame time at frame {frame['frame']}")
        if index and (frame['frame'] != frames[index-1]['frame']+1 or
                      frame['tickMs'] <= frames[index-1]['tickMs'] or
                      abs(frame['tickMs']-frames[index-1]['tickMs']-frame['intervalMs']) > .02):
            raise ValueError('Missing or reordered frame intervals')
    if len({f['threadId'] for f in frames}) != 1:
        raise ValueError('Frame capture mixed owner threads')
    frame_by_id = {int(f['frame']): f for f in frames}
    spans = []
    span_total = Counter()
    for row in read_csv(root/'frame-spans.csv'):
        start, end, fid = float(row['startMs']), float(row['endMs']), int(row['frame'])
        if row['stage'] not in STAGES or not math.isfinite(start+end) or end < start or fid not in frame_by_id:
            raise ValueError('Invalid stage span')
        frame = frame_by_id[fid]
        if start < frame['tickMs']-frame['intervalMs']-.02 or end > frame['tickMs']+.02:
            raise ValueError('Stage span outside its frame')
        if spans and start < spans[-1]['end']-.00001:
            raise ValueError('Overlapping or reordered stage spans')
        spans.append(dict(start=start, end=end, frame=fid, stage=row['stage']))
        span_total[(fid, row['stage'])] += end-start
    for fid, frame in frame_by_id.items():
        if not frame['spanOverflow'] and any(abs(span_total[(fid, s)]-frame[s]) > .02 for s in STAGES):
            raise ValueError(f'Stage spans do not account for frame {fid}')
    starts = [s['start'] for s in spans]
    samples = []
    stacks = defaultdict(list)
    receipt = None
    truncated=set()
    if (root/'stack-samples.csv').exists():
        receipt = json.loads((root/'stack-receipt.json').read_text())
        if receipt['thread_id'] != frames[0]['threadId']:
            raise ValueError('Stack sampler and frame trace have different owner threads')
        samples = [numbers(r) for r in read_csv(root/'stack-samples.csv')]
        if len({s['sample'] for s in samples}) != len(samples) or len(samples) != receipt['samples']:
            raise ValueError('Missing or duplicate stack samples')
        ranges = game_ranges(game_exe)
        raw_depths=Counter()
        for row in read_csv(root/'stack-frames.csv'):
            sid=int(row['sample']);stack=stacks[sid]
            if int(row['depth']) != raw_depths[sid]:
                raise ValueError('Missing or reordered stack depth')
            raw_depths[sid]+=1
            # Older raw captures may contain bogus tails after unwind failure.
            # A captured leaf IP remains evidence even when it is unmapped.
            if row['module']=='unknown':
                if not stack:stack.append(code_label(row,ranges))
                truncated.add(sid)
            if sid not in truncated:stack.append(code_label(row, ranges))
        for sample in samples:
            if raw_depths[int(sample['sample'])] != sample['depth']:
                raise ValueError('Stack sample depth does not match captured stack')
    occupancy = defaultdict(Counter)
    inclusive = defaultdict(Counter)
    paths = defaultdict(Counter)
    by_frame = defaultdict(list)
    matched = 0
    for sample in samples:
        stack = stacks[int(sample['sample'])]
        if not sample['contextOk'] or not stack:
            continue
        index = bisect.bisect_right(starts, sample['tickMs'])-1
        if index < 0 or sample['tickMs'] >= spans[index]['end']:
            continue
        span = spans[index]
        frame = frame_by_id[span['frame']]
        if not frame['phaseStable'] or frame['spanOverflow']:
            continue
        phase = {2:'idle',4:'horde'}.get(int(frame['phase']))
        if not phase:
            continue
        matched += 1
        key = (phase, span['stage'])
        occupancy[key][stack[0]] += 1
        # Each code range counted at most once per stack (recursion not additive).
        inclusive[key].update(set(stack))
        paths[key][tuple(stack)] += 1
        by_frame[span['frame']].append(dict(stage=span['stage'], tick_ms=sample['tickMs'], stack=stack))
    phases = {}
    for phase, label in [(2,'idle'),(4,'horde')]:
        selected = [f for f in frames if f['phase'] == phase and f['phaseStable']]
        if not selected:
            continue
        intervals = [f['intervalMs'] for f in selected]
        total = sum(intervals)
        worst = sorted(selected, key=lambda f:f['intervalMs'], reverse=True)[:30]
        stages = {}
        for stage in STAGES:
            values = [f[stage] for f in selected]
            key = (label, stage)
            stages[stage] = dict(mean_ms=statistics.mean(values),p95_ms=percentile(values,.95),
                share_of_wall_time=sum(values)/total,stack_samples=sum(occupancy[key].values()),
                leaf_hotspots=occupancy[key].most_common(20),inclusive_hotspots=inclusive[key].most_common(20),
                top_call_paths=[dict(samples=n,stack=list(path)) for path,n in paths[key].most_common(10)])
        cpu_rows = [f for f in selected if f['cpuCounterValid']]
        phases[label] = dict(frames=len(selected),mean_ms=statistics.mean(intervals),p95_ms=percentile(intervals,.95),
            p99_ms=percentile(intervals,.99),max_ms=max(intervals),stages=stages,
            thread_cpu_fraction=sum(f['threadCpuMs'] for f in cpu_rows)/sum(f['intervalMs'] for f in cpu_rows) if cpu_rows else None,
            span_overflows=sum(f['spanOverflow'] for f in selected),
            worst_frames=[dict(frame=int(f['frame']),tick_ms=f['tickMs'],interval_ms=f['intervalMs'],
                stages={s:f[s] for s in STAGES},samples=by_frame[int(f['frame'])]) for f in worst])
    if not phases:
        raise ValueError('No stable measured-phase frames')
    runtime = {}
    if (root/'frames.csv').exists():
        raw = [numbers(r) for r in read_csv(root/'frames.csv')]
        for phase,label in [(2,'idle'),(4,'horde')]:
            selected = [r for r in raw if r['phase']==phase]
            runtime[label] = dict(frames=len(selected),interrupted_frames=sum(
                r['submitted']!=1 or r['renderable']!=1 or r['focused']!=1 or r['headTracked']!=1 or r['menu']!=0
                for r in selected))
            if label in phases and phases[label]['frames'] != len(selected):
                raise ValueError(f'{label}: per-frame trace coverage differs from application frame CSV')
    return dict(schema='kf2vr/frame-drilldown/1',valid=True,scope='diagnostic-not-fps-comparison',
        run_root=str(root),phases=phases,stack_capture=receipt,matched_stack_samples=matched,
        fixture_success=run_record.get('success'),runtime_frame_health=runtime,
        stacks_with_unmapped_tail_discarded=len(truncated),
        unmatched_or_excluded_stack_samples=len(samples)-matched,
        note='Exclusive CPU wall-time stages sum to each Present interval. GetThreadTimes is quantized: use its phase aggregate, not per-frame CPU estimates. Stack samples include blocked/sleeping time and are not CPU-cycle weights. Inclusive hotspots overlap; do not sum them. Unwind ranges can be function fragments, not named functions. GPU work overlaps CPU and is reported separately by analyze-frame-detail.py. Capture changes timing; never use stack-sampled runs for FPS comparisons.')


def write_html(report, path):
    data = json.dumps(report).replace('<', '\\u003c')
    page = r'''<!doctype html><meta charset="utf-8"><title>KF2 VR frame drilldown</title>
<style>body{font:15px system-ui;background:#111827;color:#e5e7eb;margin:30px;max-width:1200px}button,select{padding:8px;margin:5px;background:#26354d;color:white;border:1px solid #72809b}table{border-collapse:collapse;width:100%}th,td{padding:7px;border-bottom:1px solid #374151;text-align:left}pre{white-space:pre-wrap;overflow-wrap:anywhere}button{cursor:pointer}.muted{color:#aebad0}.bar{height:16px;background:#38bdf8;display:inline-block;vertical-align:middle}#detail{background:#182338;padding:16px}</style>
<h1>CPU frame drilldown</h1><p id="note" class="muted"></p><select id="phase"></select><p id="summary"></p>
<h2>Exclusive stages</h2><p class="muted">Click a stage for sampled leaf and inclusive stacks. Sample counts represent wall-clock occupancy, including waits.</p><table id="stages"></table>
<h2>Slow frames</h2><p class="muted">Select a frame to inspect its stage costs and sampled call stacks.</p><div id="frames"></div><pre id="detail"></pre>
<script>const report=DATA;const $=id=>document.getElementById(id);$('note').textContent=report.note;
for(const phase of Object.keys(report.phases)){const o=document.createElement('option');o.textContent=phase;$('phase').append(o)}
function show(){const p=report.phases[$('phase').value];$('summary').textContent=`${p.frames} frames | mean ${p.mean_ms.toFixed(2)} ms | p95 ${p.p95_ms.toFixed(2)} ms | owner CPU ${p.thread_cpu_fraction===null?'unavailable':(100*p.thread_cpu_fraction).toFixed(1)+'%'} | stack samples matched ${Object.values(p.stages).reduce((n,s)=>n+s.stack_samples,0)}`;
$('stages').replaceChildren();const h=document.createElement('tr');for(const t of ['Stage','Mean ms','p95 ms','Share','Samples']){const e=document.createElement('th');e.textContent=t;h.append(e)}$('stages').append(h);
for(const [name,s] of Object.entries(p.stages).sort((a,b)=>b[1].mean_ms-a[1].mean_ms)){const row=document.createElement('tr');for(const v of [name,s.mean_ms.toFixed(3),s.p95_ms.toFixed(3),(s.share_of_wall_time*100).toFixed(1)+'%',s.stack_samples]){const e=document.createElement('td');e.textContent=v;row.append(e)}row.style.cursor='pointer';row.onclick=()=>{$('detail').textContent=name+'\n\nLeaf hotspots (count)\n'+s.leaf_hotspots.map(x=>x[1]+'  '+x[0]).join('\n')+'\n\nInclusive hotspots (overlap)\n'+s.inclusive_hotspots.map(x=>x[1]+'  '+x[0]).join('\n')+'\n\nFrequent call paths (leaf first)\n'+JSON.stringify(s.top_call_paths,null,2)};$('stages').append(row)}
$('frames').replaceChildren();for(const f of p.worst_frames){const b=document.createElement('button');b.textContent='#'+f.frame+' · '+f.interval_ms.toFixed(2)+' ms';b.onclick=()=>{$('detail').textContent=JSON.stringify(f,null,2)};$('frames').append(b)}}$('phase').onchange=show;show();</script>'''
    path.write_text(page.replace('DATA',data),encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run',type=Path)
    parser.add_argument('--game-exe',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    try:
        report = analyze(args.run,args.game_exe)
    except (ValueError,KeyError,OSError,TypeError) as error:
        report = dict(valid=False,error=str(error),scope='diagnostic-not-fps-comparison')
    args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    if report['valid']:
        write_html(report,args.output.with_suffix('.html'))
    print(json.dumps({k:v for k,v in report.items() if k!='phases'},indent=2))
    raise SystemExit(0 if report['valid'] else 1)
