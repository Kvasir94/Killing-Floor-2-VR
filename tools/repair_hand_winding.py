"""Repair a versioned legacy ActorX hand without changing its rig or surface."""
import os, runpy, hashlib, json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/watch-detail-20260924'/os.environ['KF2VR_ART_REVISION']/'runtime'
if (OUT/'winding-repair.json').exists():raise RuntimeError('This candidate was already repaired; preserve it and start a new version.')
g=runpy.run_path(str(ROOT/'tools/generate_floating_hands.py'),run_name='asset_source')
psk=OUT/'VRFloatingHands.psk';chunks=g['read_psk'](psk)
preserved={k:hashlib.sha256(b''.join(c.rows)).hexdigest() for k,c in chunks.items() if k!='FACE0000'}
rows=[]
for row in chunks['FACE0000'].rows:
    a,b,c,material,aux,smoothing=g['FACE'].unpack(row)
    rows.append(g['FACE'].pack(a,c,b,material,aux,smoothing))
chunks['FACE0000'].rows=rows
psk.write_bytes(b''.join(c.encode() for c in chunks.values()))
check=g['read_psk'](psk)
assert preserved=={k:hashlib.sha256(b''.join(c.rows)).hexdigest() for k,c in check.items() if k!='FACE0000'}
report={'change':'Reverse legacy inside-out ActorX face order; regenerate outward FBX normals',
        'all_non_face_psk_chunks_preserved':preserved,'triangles':len(rows),
        'vertices_added':0,'draw_calls_added':0,**g['export_fbx'](psk,OUT/'VRFloatingHands.fbx')}
(OUT/'winding-repair.json').write_text(json.dumps(report,indent=2))
print('HAND_WINDING_REPAIRED',json.dumps(report),flush=True)
