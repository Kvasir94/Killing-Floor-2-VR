"""Attribute appended Steam Link driver warnings to conservative phase windows.

Warnings are selective observations, not continuous network/decoder telemetry.
The driver's d metric is retained by name; it is not declared end-to-end latency.
"""
import argparse
import csv
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re

STAMP=re.compile(r'^(\w{3} \w{3} +\d{1,2} \d{4} \d{2}:\d{2}:\d{2}\.\d{3}) ')
BAD=re.compile(r'Bad link event: d=([\d.]+) ms ([\d.]+) mbit/s -> ([\d.]+) mbit/s, ping ([\d.]+) ms, holdoff (\d+), auto (\d+)')
BW=re.compile(r'Link BW: Est ([\d.]+) Mbit/s \(auto: (\d+)\)')
PERF=re.compile(r'\[Perf warning\] ([\d.]+)ms - (.+)')


def events(text, offset_minutes):
    zone=timezone(timedelta(minutes=offset_minutes))
    result=[]
    for line in text.splitlines():
        stamp=STAMP.match(line)
        if not stamp: continue
        time=datetime.strptime(stamp[1],'%a %b %d %Y %H:%M:%S.%f').replace(tzinfo=zone)
        event=dict(local_time=time.isoformat(),unix_ms=time.timestamp()*1000)
        if match:=BAD.search(line):
            event.update(kind='bad_link',driver_d_ms=float(match[1]),from_mbps=float(match[2]),
                         to_mbps=float(match[3]),ping_ms=float(match[4]),holdoff=int(match[5]),automatic=bool(int(match[6])))
        elif match:=BW.search(line):
            event.update(kind='bandwidth_estimate',mbps=float(match[1]),automatic=bool(int(match[2])))
        elif match:=PERF.search(line):
            event.update(kind='performance_warning',duration_ms=float(match[1]),stage=match[2])
        elif 'THROTTLE EVENT:' in line: event.update(kind='driver_throttle_marker')
        elif 'Reset video stream' in line: event.update(kind='stream_reset')
        else: continue
        result.append(event)
    return result


def summarize(selected):
    bad=[e for e in selected if e['kind']=='bad_link']
    return dict(bad_link_events=len(bad),automatic_rate_reductions=sum(e['automatic'] and e['to_mbps']<e['from_mbps'] for e in bad),
                bad_event_ping_ms_range=[min(e['ping_ms'] for e in bad),max(e['ping_ms'] for e in bad)] if bad else None,
                bad_event_driver_d_ms_range=[min(e['driver_d_ms'] for e in bad),max(e['driver_d_ms'] for e in bad)] if bad else None,
                driver_throttle_markers=sum(e['kind']=='driver_throttle_marker' for e in selected),
                stream_resets=sum(e['kind']=='stream_reset' for e in selected),
                performance_warnings=[e for e in selected if e['kind']=='performance_warning'],events=selected)


def analyze(batch_root):
    root=Path(batch_root)
    batch=json.loads((root/'batch.json').read_text(encoding='utf-8-sig'))
    anchor=json.loads((root/'clock-anchor.json').read_text(encoding='utf-8-sig'))
    if not batch.get('success'): raise ValueError('Batch did not complete successfully')
    if previous:=batch.get('clock_anchor_before'):
        if abs((anchor['utc_unix_ms']-anchor['tick_ms'])-(previous['utc_unix_ms']-previous['tick_ms']))>100:
            raise ValueError('Wall clock changed relative to uptime; phase attribution rejected')
    before=(root/'before-driver_vrlink.txt').read_bytes();after=(root/'after-driver_vrlink.txt').read_bytes()
    if not after.startswith(before): raise ValueError('Driver log rotated or changed; cannot establish an appended interval')
    rows=events(after[len(before):].decode('utf-8',errors='replace'),anchor['local_utc_offset_minutes'])
    output=[]
    zone=timezone(timedelta(minutes=anchor['local_utc_offset_minutes']))
    for run in batch['runs']:
        path=Path(run)
        perf=json.loads((path/'performance.json').read_text())
        if not perf.get('valid'): raise ValueError('Application run is invalid')
        with (path/'frames.csv').open(newline='') as stream: frames=list(csv.DictReader(stream))
        phases={}
        for phase,label in ((2,'idle'),(4,'horde')):
            selected=[r for r in frames if int(r['phase'])==phase]
            if not selected: raise ValueError('Missing measurement phase')
            tick_start=min(float(r['tickMs'])-float(r['intervalMs']) for r in selected)+2000
            tick_end=max(float(r['tickMs']) for r in selected)-2000
            start=anchor['utc_unix_ms']+tick_start-anchor['tick_ms']
            end=anchor['utc_unix_ms']+tick_end-anchor['tick_ms']
            result=summarize([e for e in rows if start<=e['unix_ms']<=end])
            result['local_window']=[datetime.fromtimestamp(t/1000,zone).isoformat() for t in (start,end)]
            phases[label]=result
        output.append(dict(run_root=run,percent=perf['percent'],phases=phases))
    return dict(scope='Steam-Link-driver-warning-observations',runs=output,whole_capture=summarize(rows),
                packet_loss_fraction=None,decoder_latency_ms=None,end_to_end_latency_ms=None,
                note='Only appended driver log bytes. Approximate wall-clock association uses a post-capture uptime anchor and trims two seconds from each phase edge; assumes no intervening wall-clock change. Warnings are selectively logged: ping ranges describe bad-link events only, not average network latency. Driver d is not verified end-to-end latency. No packet-loss or decoder measurement is inferred.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('batch',type=Path);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();report=analyze(args.batch)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ('runs','whole_capture')},indent=2))
