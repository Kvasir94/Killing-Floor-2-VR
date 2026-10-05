"""Index saved motion samples against actual replicated state and engine screenshots."""
from __future__ import annotations
import argparse, hashlib, html, json, math, re, struct
from pathlib import Path
from datetime import datetime, timezone
from evidence import events

MAX_BYTES=64*1024*1024
def log_text(path):
    data=Path(path).read_bytes()
    return data.decode('utf-16' if data.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig',errors='replace')
def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()

class Reader:
    def __init__(self,data):self.data=data;self.at=0
    def get(self,fmt):
        fmt='<'+fmt;n=struct.calcsize(fmt)
        if self.at+n>len(self.data):raise ValueError('Truncated motion clip')
        result=struct.unpack_from(fmt,self.data,self.at);self.at+=n
        if any(isinstance(v,float) and not math.isfinite(v) for v in result):raise ValueError('Nonfinite clip value')
        return result[0] if len(result)==1 else list(result)
    def boolean(self):
        x=self.get('B')
        if x>1:raise ValueError('Invalid boolean')
        return bool(x)
    def pose(self):return {'rotation':self.get('4f'),'position':self.get('3f'),'scale':self.get('f')}
    def hand(self):
        h={'grip_pose':self.pose(),'aim_pose':self.pose()}
        for k in ('pose_valid','pose_tracked','aim_valid','aim_tracked'):h[k]=self.boolean()
        for k in ('trigger','grip','stick_x','stick_y'):h[k]=self.get('f')
        for k in ('primary','secondary','stick_pressed','menu','trigger_active','grip_active','stick_active','primary_active','secondary_active','stick_click_active','menu_active'):h[k]=self.boolean()
        return h
    def text(self):
        raw=self.data[self.at:self.at+128];self.at+=128
        if len(raw)!=128 or b'\0' not in raw:raise ValueError('Invalid clip string')
        return raw.split(b'\0')[0].decode('ascii')

def read_clip(path):
    path=Path(path)
    if path.stat().st_size>MAX_BYTES:raise ValueError('Clip exceeds 64 MiB')
    r=Reader(path.read_bytes());magic,version,count=r.get('III')
    if magic!=0x314d464b or version!=1 or not 0<count<=32768:raise ValueError('Unsupported clip header')
    samples=[]
    for index in range(count):
        start=r.at;s={'index':index,'seconds':r.get('d')}
        s['session_state']=r.get('B')
        for k in ('should_render','views_valid','actions_synced'):s[k]=r.boolean()
        s['predicted_time']=r.get('d');s['predicted_period']=r.get('d')
        s['pose_sample_id']=r.get('Q');s['reference_space_epoch']=r.get('Q')
        s['head']=r.pose();s['head_valid']=r.boolean();s['head_tracked']=r.boolean()
        s['left']=r.hand();s['right']=r.hand();s['reference']=r.pose();s['body']=r.get('4f')
        s['reference_valid']=r.boolean();s['synthetic']=r.boolean()
        s['positions']=[r.get('3f') for _ in range(10)];s['rotations']=[r.get('3i') for _ in range(10)]
        s['state']=r.get('12i');s['body_yaw']=r.get('f');s['eye_height']=r.get('f');s['game_seconds']=r.get('f');s['velocity']=r.get('3f')
        s['weapon_classes']=[r.text(),r.text()];s['weapons']=[r.get('6i'),r.get('6i')];s['animation_rates']=r.get('2f');s['map']=r.text()
        s['boundary'],s['pressed'],s['released']=r.get('III')
        end=r.at;crc=r.get('I');actual=2166136261
        for byte in r.data[start:end]:actual=((actual^byte)*16777619)&0xffffffff
        if crc!=actual:raise ValueError(f'Sample {index} checksum mismatch')
        if index and s['seconds']<=samples[-1]['seconds']:raise ValueError('Nonmonotonic clip samples')
        samples.append(s)
    if r.at!=len(r.data):raise ValueError('Trailing clip bytes')
    return samples

def event_rows(text,kind):
    result=[]
    for line_no,line in enumerate(text.splitlines(),1):
        e=events(line,kind)
        if e:result.append({**e[0],'line':line_no})
    return result

def expected_offsets(sample):
    # Presentation format uses UE world positions. Only yaw rotates the network basis.
    yaw=sample['rotations'][0][1]*2*math.pi/65536
    root=sample['positions'][0];c=math.cos(yaw);s=math.sin(yaw)
    def local(v):
        x,y,z=(a-b for a,b in zip(v,root));return [x*c+y*s,-x*s+y*c,z]
    return {'root':root,'left':local(sample['positions'][2]),'right':local(sample['positions'][3])}

def vector(text):return [float(x) for x in text.split(',')]

def compare(rows,samples):
    mismatches=[];matched=0;classes=set()
    for e in rows:
        i=int(e['sample'])
        if not 0<=i<len(samples):mismatches.append({'event':e,'reason':'sample outside clip'});continue
        s=samples[i];expected=expected_offsets(s);errors={}
        if abs(float(e['clip_time'])-s['seconds'])>.002:errors['time']=e['clip_time']
        for field,value in expected.items():
            if field in e and max(abs(a-b) for a,b in zip(vector(e[field]),value))>1.0:errors[field]=e[field]
        recorded=s['weapon_classes'][1].casefold()
        if e.get('right_class','').casefold().replace('none','')!=recorded:errors['right_class']=e.get('right_class')
        if int(e.get('shot',-1))!=s['weapons'][1][1]:errors['shot']=e.get('shot')
        if errors:mismatches.append({'line':e['line'],'sample':i,'errors':errors})
        else:matched+=1
        if e.get('right_class','').casefold() not in ('', 'none'):classes.add(e.get('right_class'))
    return {'observed':len(rows),'matched':matched,'mismatches':mismatches[:100],'weapon_classes':sorted(classes),'passed':bool(rows) and not mismatches}

def map_identity(samples,captures):
    if not samples or not captures:return False
    if any(not s['map'] or s['map'].casefold()=='none' for s in samples):return False
    return all(0<=e['input_sample_index']<len(samples)
               and e['map'].casefold()==samples[e['input_sample_index']]['map'].casefold()
               for e in captures)

def ordered_resets(server,driver,expected_cases):
    rows=[]
    for kind in ('motion_begin','motion_end','motion_reset'):
        rows.extend({**e,'kind':kind} for e in event_rows(server,kind))
    rows.sort(key=lambda e:e['line'])
    failures=[];cases=[]
    if len(rows)!=expected_cases*3:failures.append('Missing or extra begin/end/reset events')
    previous_id=0;previous_time=-1;previous_ack_time=-1
    acks=event_rows(driver,'motion_batch_reset')
    for index in range(expected_cases):
        part=rows[index*3:index*3+3]
        if len(part)!=3:continue
        begin,end,reset=part
        try:
            ids=[int(e['replay']) for e in part];times=[float(e['time']) for e in part]
            valid=([e['kind'] for e in part]==['motion_begin','motion_end','motion_reset']
                   and ids[0]==ids[1]==ids[2] and ids[0]>previous_id
                   and all(math.isfinite(t) and t>=0 for t in times)
                   and previous_time<=times[0]<=times[1]<=times[2]
                   and reset.get('passed','').casefold()=='true')
            ack=[e for e in acks if int(e['replay'])==ids[0]]
            valid=valid and len(ack)==1 and ack[0].get('passed','').casefold()=='true'
            if len(ack)==1:
                ack_time=float(ack[0]['time'])
                valid=valid and math.isfinite(ack_time) and ack_time>=previous_ack_time and ack_time>=0
                previous_ack_time=ack_time
            cases.append({'replay_id':ids[0],'server_begin_seconds':times[0],
                          'server_end_seconds':times[1],'server_reset_seconds':times[2],
                          'server_log_lines':[e['line'] for e in part],
                          'client_reset':ack[0] if len(ack)==1 else None,'passed':valid})
            if not valid:failures.append('Unverified or unordered reset for case '+str(index+1))
            previous_id=ids[0];previous_time=times[2]
        except (KeyError,ValueError):failures.append('Invalid reset evidence for case '+str(index+1))
    if len(acks)!=expected_cases:failures.append('Missing or extra client reset acknowledgements')
    return {'expected_cases':expected_cases,'cases':cases,'failures':failures,'passed':not failures and len(cases)==expected_cases}

def build(receipt):
    receipt=Path(receipt);run=receipt.parent;r=json.loads(receipt.read_text());roles={x['role']:x for x in r['roles']}
    clip=Path(roles['driver']['motion_fixture_root'])/'clip-1.kfm';samples=read_clip(clip)
    driver=log_text(roles['driver']['log']);server=log_text(roles['server']['log']);observer=log_text(roles['observer']['log'])
    sent=event_rows(driver,'motion_sent');received=event_rows(observer,'motion_received');accepted=event_rows(server,'motion_server')
    checks={'sender':compare(sent,samples),'server':compare(accepted,samples),'observer':compare(received,samples)}
    sent_by={(x['replay'],x['sequence']):x for x in sent};server_by={(x['replay'],x['sequence']):x for x in accepted}
    checks['sequence_chain']={'observed':len(received),'unmatched':[x for x in received if (x['replay'],x['sequence']) not in sent_by or (x['replay'],x['sequence']) not in server_by][:100]}
    checks['sequence_chain']['passed']=bool(received) and not checks['sequence_chain']['unmatched']
    edge_rows=event_rows(server,'motion_edge');edge_groups={}
    for e in edge_rows:edge_groups.setdefault(e['replay'],[]).append(e)
    expected=[s for s in samples if s['pressed'] or s['released'] or s['boundary']]
    first=min(edge_groups,key=int) if edge_groups else None
    observed=edge_groups.get(first,[])
    want=[(s['index'],s['pressed'],s['released'],s['boundary']) for s in expected]
    got=[tuple(int(e[k]) for k in ('sample','pressed','released','boundary')) for e in observed]
    checks['ordered_edges']={'replay':first,'expected_count':len(want),'observed_count':len(got),'passed':got==want}
    capture_rows=event_rows(observer,'motion_capture');captures=r.get('observer_captures',{})
    by_name={x['name']:x for x in captures.get('entries',[])};entries=[]
    for e in capture_rows:
        item=by_name.get(e['name'],{'status':'missing','files':[]});i=int(e['sample']);sample=samples[i] if 0<=i<len(samples) else None
        files=item.get('files',[]);mtime=files[0].get('modified_unix') if files else None
        matching=sent_by.get((e['replay'],e['sequence']));accepted_row=server_by.get((e['replay'],e['sequence']))
        entries.append({'name':e['name'],'status':item['status'],'files':files,'capture_request_game_seconds':float(e['time']),
                        'capture_file_written_utc':datetime.fromtimestamp(mtime,timezone.utc).isoformat() if mtime else None,
                        'replay_id':int(e['replay']),'replay_seconds':float(e['clip_time']),'input_sample_index':i,
                        'input_pose_sample_id':sample['pose_sample_id'] if sample else None,'input_sample_seconds':sample['seconds'] if sample else None,
                        'network_sequence':int(e['sequence']),'paused':e['paused'],'camera_mode':e['camera'],'map':e['map'],
                        'logs':{'observer':{'path':roles['observer']['log'],'line':e['line']},
                                'driver':{'path':roles['driver']['log'],'line':matching['line'] if matching else None},
                                'server':{'path':roles['server']['log'],'line':accepted_row['line'] if accepted_row else None},
                                'adapter':{'path':roles['driver'].get('native_log'),'match_sample':i}},
                        'render_timestamp_precision':'Engine screenshot request time and observed file-write UTC; exact GPU frame timestamp unavailable'})
    file_only=bool(r.get('saved_motion_source'))
    checks['ordered_resets']=ordered_resets(server,driver,1 if file_only else 2)
    if not file_only:checks['coherent_recorded_draw']='phase=recorded_draw passed=True' in driver
    if not file_only:checks['pause']= 'phase=network_pause passed=True' in driver
    checks['natural_end']='phase=network_end passed=True' in driver
    checks['stop_cleanup']='phase=network_complete passed=True' in driver and len(event_rows(server,'motion_end'))>=(1 if file_only else 2)
    checks['captures']=bool(entries) and all(x['status']=='copied' for x in entries)
    checks['map_identity']=map_identity(samples,entries)
    if not file_only:checks['weapon_changes']=len(checks['observer']['weapon_classes'])>=2
    result={'schema':'kf2vr/network-motion-timeline/1','session_id':r.get('session_id',run.name),'mode':'saved-file network player replay',
            'input':r['saved_motion_source']['input'] if file_only else 'authored synthetic; no physical XR','saved_motion_source':r.get('saved_motion_source'),'clip':{'path':str(clip),'sha256':digest(clip),'samples':len(samples),'duration_seconds':samples[-1]['seconds']},
            'recorded_fields':'Raw head/controller poses, action active/pressed flags, trigger/grip/stick axes, reference/body, presentation/weapon fields; see samples.json',
            'build':r.get('release'),'manifest_sha256':r.get('release_manifest_sha256'),'capture_interval_seconds':r.get('motion_capture_interval_seconds',3),
            'clock_anchors':r.get('clock_anchors',[]),'captures':entries,'capture_errors':captures.get('search_errors',[]),'checks':checks,
            'dropped_network_snapshots':{'sent':len(sent),'server':len(accepted),'observer':len(received),'note':'Unreliable pose transport may coalesce/drop samples; reliable input-edge trace is checked separately.'}}
    result['passed']=all(v.get('passed',False) if isinstance(v,dict) else bool(v) for v in checks.values())
    budget=256*1024*1024
    session_files=[p for p in run.rglob('*') if p.is_file()]
    fixed_bytes=sum(p.stat().st_size for p in session_files if p.relative_to(run).parts[0]=='Packages')
    evidence_bytes=sum(p.stat().st_size for p in session_files if p.relative_to(run).parts[0]!='Packages')
    result['disk_budget']={'evidence_limit_bytes':budget,'fixed_package_limit_bytes':512*1024*1024,'fixed_package_bytes':fixed_bytes,'evidence_bytes':evidence_bytes}
    if fixed_bytes>512*1024*1024 or evidence_bytes>budget:raise ValueError('Session package/evidence disk budget exceeded')
    (run/'samples.json').write_text(json.dumps(samples,separators=(',',':')))
    (run/'motion-timeline.json').write_text(json.dumps(result,indent=2))
    rows=[]
    for e in entries:
        for f in e['files']:
            path=Path(f['copied_path']);rel=path.relative_to(run).as_posix()
            rows.append(f'<figure><a href="{html.escape(rel)}"><img src="{html.escape(rel)}"></a><figcaption>replay {e["replay_id"]} Ãƒâ€šÃ‚Â· {e["replay_seconds"]:.3f}s Ãƒâ€šÃ‚Â· sample {e["input_sample_index"]} Ãƒâ€šÃ‚Â· seq {e["network_sequence"]} Ãƒâ€šÃ‚Â· camera {e["camera_mode"]}</figcaption></figure>')
    (run/'index.html').write_text('<!doctype html><meta charset="utf-8"><title>Network motion observer captures</title><style>body{background:#171b22;color:#eee;font:16px system-ui;margin:24px}main{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}figure{margin:0}img{width:100%}a{color:#ace}</style><h1>Actual observer screenshots</h1><p>Saved-file network replay. Synthetic input. Raw captures preserved. File-write UTC is distinct from screenshot request time.</p><p><a href="motion-timeline.json">Timeline</a> Ãƒâ€šÃ‚Â· <a href="samples.json">Recorded samples</a> Ãƒâ€šÃ‚Â· <a href="run.json">Session/log index</a></p><main>'+''.join(rows)+'</main>')
    return result

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('receipt',type=Path);a=p.parse_args();r=build(a.receipt)
    print(json.dumps({'passed':r['passed'],'clip':r['clip'],'checks':r['checks'],'captures':len(r['captures'])},indent=2))
    return 0 if r['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
