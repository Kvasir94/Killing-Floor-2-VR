"""Validate raw application-frame evidence. Never reports compositor/delivery FPS."""
import argparse
import csv
import json
import math
from pathlib import Path
import re
import statistics

VARIANTS = {'Baseline': (False, False), 'Optimized': (True, True),
            'CallbackOnly': (True, False), 'SettingsOnly': (False, True)}


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def distance(a, b):
    return math.sqrt(sum((x-y)**2 for x, y in zip(a, b)))


def angle(a, b):
    aa = math.sqrt(sum(x*x for x in a))
    bb = math.sqrt(sum(x*x for x in b))
    if aa < .9 or bb < .9:
        raise ValueError('Invalid headset quaternion')
    dot = abs(sum(x*y for x, y in zip(a, b)) / (aa*bb))
    return math.degrees(2*math.acos(min(1, dot)))


def analyze(root):
    root = Path(root)
    if (root/'invalidated.json').exists():
        invalidation = json.loads((root/'invalidated.json').read_text(encoding='utf-8-sig'))
        raise ValueError('Run explicitly invalidated: ' + invalidation['reason'])
    record = json.loads((root/'run.json').read_text(encoding='utf-8-sig'))
    if record.get('workload_contamination') or record.get('workload_monitor_error'):
        raise ValueError('Competing host workload or workload monitor failure; not FPS evidence')
    workload_guard=bool(record.get('workload_guard'))
    if workload_guard:
        snapshots=[json.loads(line) for line in (root/'host-workloads.jsonl').read_text(encoding='utf-8-sig').splitlines() if line.strip()]
        if len(snapshots)<2 or any(s.get('competing_processes') is None or s['competing_processes'] for s in snapshots):
            raise ValueError('Competing host workload or incomplete workload evidence')
    if record.get('render_performance',{}).get('stack_sampling') or (root/'stack-samples.csv').exists():
        raise ValueError('Stack-sampled diagnostic run cannot be used for FPS comparison')
    if not record.get('performance_benchmark') or not record.get('success'):
        raise ValueError('Fixture did not complete successfully')
    if record.get('forced_stop') or record.get('cleanup_error'):
        raise ValueError('Fixture did not exit/restore cleanly')
    game = (root/'game.log').read_text(errors='replace')
    native = (root/'adapter.log').read_text(errors='replace')
    if 'BenchmarkCapture invalid=1' in native:
        raise ValueError('Native capture reported tracking, focus or visibility loss')
    scenario = re.findall(r'KF2VR_BENCHMARK scenario=([^\r\n]+)', game)
    horde = re.findall(r'KF2VR_BENCHMARK horde=([^\r\n]+)', game)
    if len(horde) != 1 or len(horde[0].split(';')) != 12:
        raise ValueError('Missing/ambiguous twelve-enemy horde signature')
    if len(scenario) != 1 or game.count('KF2VR_BENCHMARK phase=complete passed=True reason=completed') != 1:
        raise ValueError('Missing/ambiguous scenario completion')
    if re.findall(r'BenchmarkCapture phase=(-?\d+) ', native) != ['1','2','3','4','5']:
        raise ValueError('Native capture did not complete the ordered warm-up/measurement phases')
    perf = record['render_performance']
    detail_markers=native.count('FrameDrilldown enabled=1 revision=1')
    if detail_markers != int(perf.get('frame_drilldown',False)):
        raise ValueError('Frame drilldown mode did not match live evidence')
    if perf.get('frame_drilldown') and not (root/'frame-stages.csv').exists():
        raise ValueError('Missing frame drilldown output')
    experiment = record['render_experiment']
    variant = experiment['variant']
    if experiment.get('revision') != 1 or variant not in VARIANTS or (
            experiment['identity_reuse'], experiment['settings_cache']) != VARIANTS[variant]:
        raise ValueError('Invalid experiment variant')
    expected_identity, expected_cache = VARIANTS[variant]
    fast_identity = experiment.get('fast_vm_identity', False)
    metadata_cache=experiment.get('metadata_cache',False)
    hand_writes=experiment.get('batch_hand_writes',False)
    if 'batch_hand_writes' in experiment and re.findall(r'HandWriteExperiment revision=1 batched=(\d)',native)!=[str(int(hand_writes))]:
        raise ValueError('Hand write mode did not match live evidence')
    write_counts=[tuple(map(int,match)) for match in re.findall(
        r'HandWriteBatch revision=1 cumulative=1 commits=(\d+) rangeQueries=(\d+) writes=(\d+) failures=(\d+)',native)]
    if 'HandWriteBatch invalid=1' in native or any(c[-1]!=0 for c in write_counts):
        raise ValueError('Hand write batch refused an update')
    if hand_writes and (not write_counts or write_counts[-1][0]==0 or write_counts[-1][2]==0):
        raise ValueError('Hand write batch has no recorded live commits/writes')
    if any(any(b<a for a,b in zip(previous,current)) for previous,current in zip(write_counts,write_counts[1:])):
        raise ValueError('Hand write cumulative counters regressed')
    # Receipts that predate these switches ran the legacy CPU path.
    checked_reads=experiment.get('checked_reads',True)
    per_eye_presentation=experiment.get('per_eye_presentation',True)
    if 'checked_reads' in experiment and re.findall(r'ReadExperiment revision=1 guardedReads=(\d)',native)!=[str(int(not checked_reads))]:
        raise ValueError('Script read mode did not match live evidence')
    if 'threaded_render' in experiment and re.findall(r'ThreadedRender revision=1 requested=(\d)',native)!=[str(int(experiment['threaded_render']))]:
        raise ValueError('Threaded rendering mode did not match live evidence')
    if 'per_eye_presentation' in experiment and re.findall(r'PresentationExperiment revision=1 perEyeFinalize=(\d)',native)!=[str(int(per_eye_presentation))]:
        raise ValueError('Presentation finalize mode did not match live evidence')
    prepass=experiment.get('depth_prepass','Inherited')
    if prepass not in ('Inherited','Enabled','Disabled'):
        raise ValueError('Invalid depth prepass experiment')
    if prepass!='Inherited' and re.findall(r'RenderPassReadback revision=1 verified=(\d)',native)!=['1']:
        raise ValueError('Depth prepass readback mapping was not verified')
    if 'metadata_cache' in experiment and re.findall(r'MetadataExperiment revision=1 fieldCache=(\d)',native)!=[str(int(metadata_cache))]:
        raise ValueError('Metadata cache mode did not match live evidence')
    cache_counts=[tuple(map(int,match)) for match in re.findall(
        r'MetadataCache revision=1 cumulative=1 hits=(\d+) misses=(\d+) invalidations=(\d+)',native)]
    # The cache is per thread and logged at Present; with threaded rendering
    # that is the render thread, which never reads script fields.
    if metadata_cache and not experiment.get('threaded_render') and (not cache_counts or cache_counts[-1][0]==0):
        raise ValueError('Metadata cache has no recorded live hits')
    if any(any(b<a for a,b in zip(previous,current)) for previous,current in zip(cache_counts,cache_counts[1:])):
        raise ValueError('Metadata cache cumulative counters regressed')
    if 'fast_vm_identity' in experiment and re.findall(r'VmEntryExperiment revision=1 fastIdentity=(\d)', native) != [str(int(fast_identity))]:
        raise ValueError('Native VM entry read mode did not match the request')
    if re.findall(r'RenderExperiment revision=1 identityReuse=(\d)', native) != [str(int(expected_identity))]:
        raise ValueError('Native optimization mode did not match the request')
    if re.findall(r'KF2VR_RENDER_AB revision=1 settingsCache=(True|False)', game) != [str(expected_cache)]:
        raise ValueError('Live script optimization mode did not match the request')
    controls = record['runtime_controls_before']['effective_controls_sha256']
    if not controls or controls != record['runtime_controls_after']['effective_controls_sha256']:
        raise ValueError('Host VR controls changed or were not verified')
    if perf['vm_timings'] or record.get('capture_eyes'):
        raise ValueError('Unexpected capture/profiling configuration')
    if not re.search(r'RenderPerformance eyeRenderPercent=' + str(perf['eye_render_percent']) +
                     r' frameTimings=' + str(int(perf['frame_timings'])) + r' vmTimings=0\b', native):
        raise ValueError('Native configuration does not match the launch request')
    recommendation = re.findall(r'Game XR ready[^\r\n]*recommendedEye=(\d+)x(\d+)', native)
    if len(recommendation) != 1:
        raise ValueError('Missing/ambiguous runtime recommended extent')
    expected_extent = tuple((int(v)*perf['eye_render_percent']+50)//100 for v in recommendation[0])
    with (root/'frames.csv').open(newline='') as stream:
        rows = [{k: float(v) for k, v in row.items()} for row in csv.DictReader(stream)]
    if not rows or any(not math.isfinite(v) for row in rows for v in row.values()):
        raise ValueError('Empty/nonfinite raw frame data')
    for previous, current in zip(rows, rows[1:]):
        if current['tickMs'] <= previous['tickMs'] or current['phase'] < previous['phase']:
            raise ValueError('Duplicate/reordered timestamps or phases')
        if current['phase'] == previous['phase'] and abs(current['tickMs']-previous['tickMs']-current['intervalMs']) > .01:
            raise ValueError('Frame rows missing or interval clock mismatch')
    phases = {}
    for stage, label in [(2, 'idle'), (4, 'horde')]:
        frames = [r for r in rows if r['phase'] == stage]
        if len(frames) < 30:
            raise ValueError(f'{label}: insufficient frames')
        if prepass!='Inherited' and any(
                r.get('depthPrepassLeft')!=int(prepass=='Enabled') or
                r.get('depthPrepassRight')!=int(prepass=='Enabled') or
                r.get('prepassOverrideLeft')!=0 or r.get('prepassOverrideRight')!=0 for r in frames):
            raise ValueError(f'{label}: live depth prepass setting/constructor override did not match')
        if any(r['intervalMs'] <= 0 or r['submitted'] != 1 or r['renderable'] != 1 or
               r['focused'] != 1 or r['headTracked'] != 1 or r['menu'] != 0 for r in frames):
            raise ValueError(f'{label}: interrupted XR submission, tracking, focus or menu visibility')
        extents = {(r['width'], r['height']) for r in frames}
        if len(extents) != 1 or next(iter(extents)) != expected_extent:
            raise ValueError(f'{label}: scene resolution changed or invalid')
        periods = [r['periodMs'] for r in frames]
        if min(periods) <= 0 or max(periods) > 1000:
            raise ValueError(f'{label}: invalid predicted runtime period')
        values = [r['intervalMs'] for r in frames]
        seconds = sum(values)/1000
        requested = record['benchmark_measure_seconds']
        if not requested-.5 <= seconds <= requested+10:
            raise ValueError(f'{label}: incomplete or excessive measurement duration: {seconds:.3f}s')
        def vec(r, prefix, suffixes):
            return [r[prefix+s] for s in suffixes]
        head = vec(frames[0], 'head', 'XYZ')
        rotation = vec(frames[0], 'headQ', 'xyzw')
        pawn = vec(frames[0], 'pawn', 'XYZ')
        head_motion = max(distance(head, vec(r, 'head', 'XYZ')) for r in frames)
        head_angle = max(angle(rotation, vec(r, 'headQ', 'xyzw')) for r in frames)
        pawn_motion = max(distance(pawn, vec(r, 'pawn', 'XYZ')) for r in frames)
        if head_motion > .05 or head_angle > 3 or pawn_motion > 50:
            raise ValueError(f'{label}: fixed view moved (head {head_motion:.3f}m/{head_angle:.2f}deg, pawn {pawn_motion:.1f}uu)')
        phases[label] = dict(frames=len(frames), seconds=seconds, application_fps=len(values)/seconds,
            mean_ms=statistics.mean(values), p50_ms=percentile(values,.5), p95_ms=percentile(values,.95),
            p99_ms=percentile(values,.99), maximum_ms=max(values),
            over_90_budget=sum(v>1000/90 for v in values), over_120_budget=sum(v>1000/120 for v in values),
            scene_eye=list(next(iter(extents))), runtime_period_ms=statistics.mean(periods),
            runtime_period_range_ms=[min(periods), max(periods)],
            head_start=head, head_rotation_start=rotation, pawn_start=pawn,
            head_motion_m=head_motion, head_motion_degrees=head_angle, pawn_motion_uu=pawn_motion)
    return dict(valid=True, scope='application-rendering-only', run_root=str(root),
        scenario=scenario[0], horde=horde[0], percent=perf['eye_render_percent'], phases=phases,
        variant=variant, fast_vm_identity=fast_identity,metadata_cache=metadata_cache,depth_prepass=prepass,
        batch_hand_writes=hand_writes,checked_reads=checked_reads,per_eye_presentation=per_eye_presentation,
        hand_write_cumulative_counts=(dict(zip(('commits','range_queries','writes','failures'),write_counts[-1])) if write_counts else None),
        metadata_cache_cumulative_counts=(dict(zip(('hits','misses','invalidations'),cache_counts[-1])) if cache_counts else None),
        frame_timings=perf['frame_timings'],
        frame_drilldown=perf.get('frame_drilldown',False),workload_guard=workload_guard,
        host_workload_note=('Known render/compile processes sampled; short-lived or unlisted workloads may be missed.' if workload_guard else 'Background workload history was not recorded.'),
        runtime_controls_sha256=controls,
        recommended_eye=[int(v) for v in recommendation[0]], original_config_sha256=record['original_config_sha256'],
        script_sha256=record['script_sha256'], native_sha256=next(
            f['sha256'] for f in record['native_files'] if f['destination'].lower().endswith('dinput8.dll')),
        compositor_drops=None, reprojection=None, wireless_delivery=None)


def compare(results, experiment='Resolution', cross_run_angle_degrees=3):
    if not math.isfinite(cross_run_angle_degrees) or not 0 < cross_run_angle_degrees <= 180:
        raise ValueError('Invalid cross-run angular tolerance')
    if len(results) < 2:
        raise ValueError('Comparison requires repeated runs')
    base = results[0]
    for run in results[1:]:
        if run.get('workload_guard',False)!=base.get('workload_guard',False):
            raise ValueError('Host workload instrumentation must match')
        if run.get('frame_drilldown',False)!=base.get('frame_drilldown',False):
            raise ValueError('Frame drilldown instrumentation must match')
        for key in ('scenario','horde','script_sha256','native_sha256','recommended_eye','original_config_sha256',
                    'runtime_controls_sha256'):
            if run[key] != base[key]:
                raise ValueError(f'Cross-run mismatch: {key}')
        for label in ('idle','horde'):
            a,b = base['phases'][label],run['phases'][label]
            if (distance(a['head_start'],b['head_start']) > .05 or
                angle(a['head_rotation_start'],b['head_rotation_start']) > cross_run_angle_degrees or
                distance(a['pawn_start'],b['pawn_start']) > 50):
                raise ValueError(f'Cross-run view mismatch: {label}')
    variants=[r['variant'] for r in results]
    scales=[r['percent'] for r in results]
    timings=[r['frame_timings'] for r in results]
    fast_modes=[r.get('fast_vm_identity',False) for r in results]
    metadata_modes=[r.get('metadata_cache',False) for r in results]
    prepass_modes=[r.get('depth_prepass','Inherited') for r in results]
    hand_write_modes=[r.get('batch_hand_writes',False) for r in results]
    cpu_modes=[(r.get('checked_reads',True),r.get('per_eye_presentation',True)) for r in results]
    if experiment!='CpuPathQuick' and len(set(cpu_modes))!=1:
        raise ValueError('CPU path mode must remain fixed in this comparison')
    if experiment!='HandWriteQuick' and len(set(hand_write_modes))!=1:
        raise ValueError('Hand write mode must remain fixed in this comparison')
    if experiment!='DepthPrepassQuick' and len(set(prepass_modes))!=1:
        raise ValueError('Depth prepass mode must remain fixed in this comparison')
    if experiment!='MetadataQuick' and len(set(metadata_modes))!=1:
        raise ValueError('Metadata cache mode must remain fixed in this comparison')
    if experiment != 'VmIdentityQuick' and len(set(fast_modes)) != 1:
        raise ValueError('VM entry read mode must remain fixed in this comparison')
    if experiment == 'CpuPathQuick':
        if variants!=['Optimized','Optimized'] or len(set(scales))!=1 or not all(timings) or cpu_modes!=[(True,True),(False,False)]:
            raise ValueError('CpuPathQuick requires matched optimized runs with legacy/lean CPU paths')
        cell=lambda r:'LegacyCpuPath' if r['checked_reads'] else 'LeanCpuPath'
        baseline='LegacyCpuPath'
    elif experiment == 'HandWriteQuick':
        if variants!=['Optimized','Optimized'] or len(set(scales))!=1 or not all(timings) or hand_write_modes!=[False,True]:
            raise ValueError('HandWriteQuick requires matched optimized runs with individual/batched writes')
        cell=lambda r:'BatchedWrites' if r['batch_hand_writes'] else 'IndividualWrites'
        baseline='IndividualWrites'
    elif experiment == 'DepthPrepassQuick':
        if variants!=['Optimized','Optimized'] or len(set(scales))!=1 or not all(timings) or prepass_modes!=['Enabled','Disabled']:
            raise ValueError('DepthPrepassQuick requires matched optimized runs with prepass enabled/disabled')
        cell=lambda r:'Prepass'+r['depth_prepass']
        baseline='PrepassEnabled'
    elif experiment == 'MetadataQuick':
        if variants!=['Optimized','Optimized'] or len(set(scales))!=1 or not all(timings) or metadata_modes!=[False,True]:
            raise ValueError('MetadataQuick requires matched optimized runs with uncached/cached metadata')
        cell=lambda r:'CachedMetadata' if r['metadata_cache'] else 'UncachedMetadata'
        baseline='UncachedMetadata'
    elif experiment == 'VmIdentityQuick':
        if variants != ['Optimized','Optimized'] or len(set(scales)) != 1 or not all(timings) or fast_modes != [False,True]:
            raise ValueError('VmIdentityQuick requires matched optimized runs with checked/fast VM entry reads')
        cell=lambda r:'FastEntry' if r['fast_vm_identity'] else 'CheckedEntry'
        baseline='CheckedEntry'
    elif experiment == 'CodeABQuick':
        if variants != ['Baseline','Optimized'] or len(set(scales)) != 1 or not all(timings):
            raise ValueError('CodeABQuick requires fixed-scale Baseline/Optimized with identical timings')
        cell=lambda r:r['variant']
        baseline='Baseline'
    elif experiment == 'CodeAB':
        if variants != ['Baseline','Optimized','Optimized','Baseline'] or len(set(scales)) != 1 or not all(timings):
            raise ValueError('CodeAB requires fixed-scale Baseline/Optimized/Optimized/Baseline with identical timings')
        cell=lambda r:r['variant']
        baseline='Baseline'
    elif experiment == 'Attribution':
        if variants != ['Baseline','CallbackOnly','SettingsOnly','Optimized','Optimized','SettingsOnly','CallbackOnly','Baseline'] or len(set(scales)) != 1 or not all(timings):
            raise ValueError('Attribution requires the mirrored four-mode plan at one scale')
        cell=lambda r:r['variant']
        baseline='Baseline'
    elif experiment == 'TimingOverhead':
        if len(set(scales)) != 1 or len(set(variants)) != 1 or timings != [False,True,True,False]:
            raise ValueError('TimingOverhead requires off/on/on/off at one scale and optimization mode')
        cell=lambda r:'TimingsOn' if r['frame_timings'] else 'TimingsOff'
        baseline='TimingsOff'
    elif experiment == 'Resolution':
        if len(set(variants)) != 1 or len(set(timings)) != 1:
            raise ValueError('Resolution comparison must not also change optimization or instrumentation')
        cell=lambda r:str(r['percent'])
        baseline=str(base['percent'])
    else:
        raise ValueError('Unknown comparison experiment')
    groups={}
    for run in results:
        groups.setdefault(cell(run),[]).append(run)
    comparisons={}
    for label in ('idle','horde'):
        cells={key:dict(repeats=len(runs),
                       mean_ms=statistics.mean(r['phases'][label]['mean_ms'] for r in runs),
                       mean_ms_range=[min(r['phases'][label]['mean_ms'] for r in runs),max(r['phases'][label]['mean_ms'] for r in runs)],
                       p95_ms=[r['phases'][label]['p95_ms'] for r in runs],
                       p99_ms=[r['phases'][label]['p99_ms'] for r in runs],
                       misses_90_fraction=[r['phases'][label]['over_90_budget']/r['phases'][label]['frames'] for r in runs])
               for key,runs in groups.items()}
        reference=cells[baseline]
        for key,cell_report in cells.items():
            cell_report['frame_time_reduction_percent']=100*(1-cell_report['mean_ms']/reference['mean_ms'])
            if key != baseline:
                lo,hi=cell_report['mean_ms_range']; blo,bhi=reference['mean_ms_range']
                cell_report['interpretation']=('insufficient repeats' if min(cell_report['repeats'],reference['repeats'])<2 else
                    'repeat ranges overlap; benefit not resolved' if lo<=bhi and blo<=hi else
                    'all treatment repeats faster in this batch' if hi<blo else 'all treatment repeats slower in this batch')
        comparisons[label]=cells
    return dict(valid=True, scope=base['scope'], experiment=experiment, runs=results, comparisons=comparisons,
        cross_run_angle_tolerance_degrees=cross_run_angle_degrees,
        note='Descriptive repeated-run comparison, not a significance test. Predicted XR periods are outcomes, not headset refresh measurements. Host controls match; headset-side streaming settings remain unverified. TimingOverhead holds CSV collection constant and measures only extra coarse CPU/GPU tracing, not total instrumentation overhead. AI scheduling is nondeterministic; no compositor/delivery or headset comfort claim.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runs', nargs='+', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cross-run-angle-degrees', type=float, default=3,
                        help='Cross-run orientation tolerance only; within-run stability checks remain unchanged')
    parser.add_argument('--experiment', choices=['Resolution','CodeAB','CodeABQuick','VmIdentityQuick','MetadataQuick','DepthPrepassQuick','HandWriteQuick','CpuPathQuick','Attribution','TimingOverhead'], default='Resolution')
    args = parser.parse_args()
    try:
        results = [analyze(root) for root in args.runs]
        report = results[0] if len(results)==1 else compare(results,args.experiment,args.cross_run_angle_degrees)
    except (ValueError, KeyError, OSError, StopIteration, TypeError) as error:
        report = dict(valid=False, error=str(error), scope='application-rendering-only')
    args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))
    raise SystemExit(0 if report['valid'] else 1)
