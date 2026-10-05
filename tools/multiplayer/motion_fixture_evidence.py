"""Analyze actual emulated motion fixture logs and artifacts without claiming tracked capture."""
import argparse, hashlib, json, re, struct
from pathlib import Path
from evidence import verify_transport

def read_log(path):
    data=Path(path).read_bytes()
    return data.decode('utf-16' if data.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig',errors='replace')

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()

def analyze(receipt):
    receipt=Path(receipt);r=json.loads(receipt.read_text())
    roles={x['role']:x for x in r['roles']}
    driver=roles['driver'];game=read_log(driver['log']);native=read_log(driver['native_log'])
    clip=Path(driver['motion_fixture_root'])/'clip-1.kfm'
    clip_info={'path':str(clip),'exists':clip.is_file()}
    if clip.is_file():
        with clip.open('rb') as stream: header=stream.read(12)
        magic,version,count=struct.unpack('<III',header) if len(header)==12 else (0,0,0)
        clip_info.update(bytes=clip.stat().st_size,sha256=sha(clip),format_version=version,sample_count=count,
                         header_valid=magic==0x314d464b and version==1 and 0<count<=32768)
    trace=re.findall(r'ReplayInputIsolationProbe passed=(\d+) blockedKeys=(\d+) blockedAxes=(\d+) blockedChars=(\d+) stockAxesUnchanged=(\d+)',native)
    routing=dict(zip(('passed','blocked_keys','blocked_axes','blocked_chars','stock_axes_unchanged'),map(int,trace[-1]))) if trace else {'passed':0}
    images=[]
    for slot,label in ((850,'recording'),(851,'playback'),(852,'restored_view')):
        path=Path(driver['captures'])/f'hands-{slot}.png';item={'phase':label,'path':str(path),'exists':path.is_file()}
        if path.is_file():
            with path.open('rb') as stream: header=stream.read(24)
            valid=len(header)==24 and header[:8]==b'\x89PNG\r\n\x1a\n' and header[12:16]==b'IHDR'
            width,height=struct.unpack('>II',header[16:24]) if valid else (0,0)
            item.update(bytes=path.stat().st_size,sha256=sha(path),width=width,height=height,png_header_valid=valid and width>0 and height>0)
        images.append(item)
    transport=verify_transport(read_log(roles['server']['log']),game,read_log(roles['observer']['log']))
    frames=[int(x) for x in re.findall(r'KF2VRNet native_frame samples=(\d+)',game)]
    result={'schema':'kf2vr/synthetic-motion-evidence/1','receipt':str(receipt),'input':'authored synthetic; not physical tracked capture',
            'release':r.get('release'),'release_manifest_sha256':r.get('release_manifest_sha256'),
            'no_xr_session_logged':'no XR session' in native,'input_routing':routing,'clip':clip_info,'captures':images,
            'native_decoder_playback_pass':'KF2VR_MOTION_FIXTURE phase=playing passed=True' in game,
            'restored_view_pass':'KF2VR_MOTION_FIXTURE phase=complete passed=True' in game,
            'native_sample_count_observed':max(frames,default=0),'independent_observer_transport':transport,
            'user_config_preserved':r.get('user_config_preserved'),'cleanup_errors':r.get('cleanup_errors')}
    result['observer_captures']=r.get('observer_captures')
    result['controls_restored_logged']='controls_restored=True' in game
    result['passed']=bool(r.get('runtime_pass') and result['no_xr_session_logged'] and routing['passed']==1 and
                         clip_info.get('header_valid') and result['native_decoder_playback_pass'] and result['restored_view_pass'] and
                         transport['passed'] and all(x.get('png_header_valid') for x in images) and r.get('user_config_preserved') and r.get('cleanup_errors')==[])
    return result

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('receipt',type=Path);p.add_argument('--output',type=Path)
    a=p.parse_args();result=analyze(a.receipt);text=json.dumps(result,indent=2)
    if a.output:a.output.write_text(text,encoding='utf-8')
    print(text);return 0 if result['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
