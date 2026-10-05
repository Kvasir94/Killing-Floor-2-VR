"""Summarize SteamVR background observations by scene process, not headset delivery FPS."""
import argparse
import csv
import json
import math
import statistics
from pathlib import Path


def read_rows(path):
    with Path(path).open(newline='') as stream:
        rows=[{k:float(v) for k,v in row.items()} for row in csv.DictReader(stream)]
    if any(not math.isfinite(v) for row in rows for v in row.values()):
        raise ValueError('Nonfinite runtime timing observation')
    return rows


def summarize(rows):
    groups={}
    for values in rows:
        groups.setdefault(int(values['scenePid']),[]).append(values)
    result={}
    for pid,rows in groups.items():
        valid_refresh=sorted({r['refreshHz'] for r in rows if r['refreshError']==0 and r['refreshHz']>0})
        result[str(pid)]=dict(frames_observed=len(rows),refresh_hz=valid_refresh,
            application_gpu_fields_available=any(r['preSubmitGpuMs']>0 or r['postSubmitGpuMs']>0 for r in rows),
            motion_smoothing_enabled=sorted({bool(r['motionSmoothingEnabled']) for r in rows}),
            motion_smoothing_supported=sorted({bool(r['motionSmoothingSupported']) for r in rows}),
            throttled_frame_fraction=sum(r['throttled']>0 for r in rows)/len(rows),
            additional_prediction_frames_range=[min(r['predicted'] for r in rows),max(r['predicted'] for r in rows)],
            async_reprojection_mode_fraction=sum(bool(int(r['reprojectionFlags'])&4) for r in rows)/len(rows),
            cpu_reprojection_reason_fraction=sum(bool(int(r['reprojectionFlags'])&1) for r in rows)/len(rows),
            gpu_reprojection_reason_fraction=sum(bool(int(r['reprojectionFlags'])&2) for r in rows)/len(rows),
            motion_smoothing_triggered_fraction=sum(bool(int(r['reprojectionFlags'])&8) for r in rows)/len(rows),
            reprojection_flag_values=sorted({int(r['reprojectionFlags']) for r in rows}),
            repeat_presents=sum(max(0,r['presents']-1) for r in rows),
            dropped=sum(r['dropped'] for r in rows),mis_presented=sum(r['misPresented'] for r in rows),
            median_ms={key:statistics.median(r[key] for r in rows) for key in
                ['preSubmitGpuMs','postSubmitGpuMs','totalRenderGpuMs','compositorGpuMs','compositorCpuMs',
                 'clientIntervalMs','presentCpuMs','waitPresentCpuMs','submitMs','transferLatencyMs']})
    return result


def analyze(path):
    result=summarize(read_rows(path))
    return dict(scope='SteamVR-compositor-observations',available=bool(result),processes=result,
        note='Includes warm-up/loading. Scene PID is observed at polling time; first history after a scene switch is omitted. Transfer latency is a runtime field, not a verified end-to-end Wi-Fi/decoder latency. Zero values may mean unsupported telemetry. No delivered-FPS claim.')


def measured_phases(path, run):
    """Conservative observation-time windows, not exact compositor/app frame joins."""
    run=Path(run)
    receipt=json.loads((run/'run.json').read_text(encoding='utf-8-sig'))
    performance=json.loads((run/'performance.json').read_text(encoding='utf-8-sig'))
    if not receipt.get('success') or not performance.get('valid'):
        raise ValueError('Phase attribution requires a validated successful application run')
    pid=receipt['process_id']
    observations=read_rows(path)
    frames=read_rows(run/'frames.csv')
    phases={}
    for phase,label in ((2,'idle'),(4,'horde')):
        app=[r for r in frames if r['phase']==phase]
        if not app: raise ValueError('Missing application measurement phase')
        start=min(r['tickMs']-r['intervalMs'] for r in app)+2000
        end=max(r['tickMs'] for r in app)-2000
        selected=[r for r in observations if r['scenePid']==pid and
                  start<=r.get('firstObservedTickMs',-1)<=end and 0<r.get('firstPollGapMs',1e9)<=500]
        if not selected:
            phases[label]=dict(available=False,reason='No bounded first-observation timestamps for the owned PID')
            continue
        indices=[int(r['frameIndex']) for r in selected]
        if len(indices)!=len(set(indices)) or indices!=sorted(indices):
            raise ValueError('Duplicate or reordered compositor observations')
        coverage=max(r['firstObservedTickMs'] for r in selected)-min(r['firstObservedTickMs'] for r in selected)
        summary=summarize(selected)[str(pid)]
        boundary_coverage=(min(r['firstObservedTickMs'] for r in selected)-start<=500 and
                           end-max(r['firstObservedTickMs'] for r in selected)<=500)
        missing=sum(max(0,b-a-1) for a,b in zip(indices,indices[1:]))
        summary.update(available=len(selected)>=30 and coverage>=20000 and boundary_coverage and missing==0,
                       phase_boundaries_covered=boundary_coverage,
                       observation_window_ms=[start,end],observed_coverage_ms=coverage,
                       missing_frame_indices=missing)
        summary['p95_ms']={key:sorted(r[key] for r in selected)[math.ceil(.95*len(selected))-1]
                           for key in summary['median_ms']}
        phases[label]=summary
    return dict(scope='SteamVR-measured-phase-observations',run_root=str(run),scene_pid=pid,phases=phases,
                wireless_delivery=None,delivered_fps=None,
                note='Owned scene PID and first-observation times; two seconds trimmed at each phase edge. Poll gaps over 500 ms excluded. This is approximate phase attribution, not an exact application/compositor frame join. Zero/unsupported OpenXR fields do not prove zero reprojection. Transfer latency is not verified Wi-Fi/decoder/end-to-end latency.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv',type=Path);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--run',type=Path,help='Validated application run for conservative phase attribution')
    args=parser.parse_args();report=measured_phases(args.csv,args.run) if args.run else analyze(args.csv)
    args.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
