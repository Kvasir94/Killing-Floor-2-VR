"""Coarse exclusive CPU buckets, sampled VM estimates, and nested XR timings.
GPU and XR sub-timings overlap CPU buckets; never sum them into frame time.
"""
import argparse
import csv
import json
import re
import statistics
from pathlib import Path


def breakdown(root):
    text=(Path(root)/'adapter.log').read_text(errors='replace')
    bounds={int(p):int(t) for t,p in re.findall(r'tick_ms=(\d+).*?BenchmarkCapture phase=(\d+) previous=',text)}
    blocks=[];gpu=[];current=None;previous_xr=None
    for line in text.splitlines():
        values={k:float(v) for k,v in re.findall(r'(\w+)=(-?\d+(?:\.\d+)?)',line)}
        if 'FrameTiming elapsedMs=' in line:
            current=dict(values);blocks.append(current)
        elif 'GpuTiming sample=' in line and 'stereoSpanMs=' in line:
            gpu.append(values)
        elif current is not None:
            if 'FrameDetail revision=' in line or 'FrameDrilldown revision=' in line or 'FramePacing mode=' in line:
                current.update({k:v for k,v in values.items() if k.endswith('Ms')})
            elif 'VmSample revision=' in line:
                current['vm']=values
            elif 'XrDetail revision=' in line:
                if previous_xr is not None:
                    current['xr']={k:v-previous_xr[k] for k,v in values.items() if k.endswith('Ms')}
                previous_xr=values
    output={}
    keys=['otherMs','controllerMs','simulationMs','vmDispatchMs','vmBodyMs','leftMs','rightMs',
          'portalMs','worldMs','xrBeginMs','xrSubmitMs','presentMs','eyeCopyMs','viewSetupMs','sceneSetupMs','viewportSetupMs',
          'worldTickMs','leftSceneMs','rightSceneMs','diagnosticOutputMs']
    for phase,label in [(2,'idle'),(4,'horde')]:
        if phase not in bounds or phase+1 not in bounds:continue
        start,end=bounds[phase],bounds[phase+1]
        windows=[b for b in blocks if b['tick_ms']-b['elapsedMs']>=start and b['tick_ms']<=end]
        count=sum(b['presents'] for b in windows)
        if not count:continue
        cpu={k:sum(b[k] for b in windows)/count for k in keys if all(k in b for b in windows)}
        result=dict(windows=len(windows),frames=count,cpu_ms_per_frame=cpu,
                    wall_ms_per_frame=sum(b['elapsedMs'] for b in windows)/count,
                    accounted_ms_per_frame=sum(cpu.values()))
        vm=[b['vm'] for b in windows if 'vm' in b]
        if vm:
            samples=sum(v['samples'] for v in vm);calls=sum(v['calls'] for v in vm)
            result['vm_sampling']=dict(calls=calls,samples=samples,calls_per_frame=calls/count,
                sampled_dispatch_ms=sum(v['dispatchMs'] for v in vm),
                estimated_dispatch_ms_per_frame=sum(v['dispatchMs'] for v in vm)/samples*calls/count if samples else None,
                note='Sampling estimate, overlaps CPU buckets. Direct original VM body excluded; nested adapter-invoked engine work may remain. Body timings are inclusive and must not be summed across recursive calls.')
        xr=[b['xr'] for b in windows if 'xr' in b]
        if len(xr)==len(windows):result['xr_nested_ms_per_frame']={k:sum(x[k] for x in xr)/count for k in xr[0]}
        spans=[g['stereoSpanMs'] for g in gpu if start<=g['tick_ms']<=end]
        if spans:result['gpu_stereo_span']=dict(samples=len(spans),median_ms=statistics.median(spans),
            p95_ms=sorted(spans)[min(len(spans)-1,int(.95*len(spans)))],includes_submission_gaps=True)
        cpu_file=Path(root)/'thread-cpu.csv'
        owner=re.findall(r'Game XR ready thread=(\d+)',text)
        if cpu_file.exists() and len(owner)==1:
            with cpu_file.open(newline='') as stream:
                thread_rows=[r for r in csv.DictReader(stream) if r['threadId']==owner[0] and start<=float(r['tickMs'])<=end]
            if len(thread_rows)>1:
                first,last=thread_rows[0],thread_rows[-1]
                wall=float(last['tickMs'])-float(first['tickMs'])
                busy=float(last['cpuTotalMs'])-float(first['cpuTotalMs'])
                result['owner_thread_cpu']=dict(thread_id=int(owner[0]),observed_wall_ms=wall,cpu_ms=busy,
                    busy_fraction=busy/wall,not_running_ms=wall-busy,
                    note='Read-only OS thread CPU counter. Not-running includes blocking, scheduling and sleeps; it does not identify the cause.')
        output[label]=result
    return dict(scope='diagnostic-breakdown-only',run_root=str(root),phases=output,
        note='Only complete five-second windows inside measured phases. Check performance.json separately for validity. CPU buckets are exclusive; XR details and sampled VM estimates overlap them. GPU spans overlap CPU wall time and omit the compositor.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run',type=Path);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();report=breakdown(args.run)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
