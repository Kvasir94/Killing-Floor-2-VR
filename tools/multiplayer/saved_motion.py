"""Validate and stage a saved clip for a bounded, disposable network review."""
from pathlib import Path
import hashlib
import math
import re
import shutil
from motion_timeline import read_clip

def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()

def inspect_clip(path):
    path=Path(path).resolve(strict=True)
    samples=read_clip(path)
    if not samples[0]['boundary']&1:raise ValueError('Clip is missing its start boundary')
    duration=samples[-1]['seconds']
    if not .5<=duration<=240:
        raise ValueError('Saved review supports clips lasting 0.5..240 seconds')
    name=samples[0]['map']
    if not re.fullmatch(r'KF-[A-Za-z0-9_.-]+',name):
        raise ValueError('Clip has no usable recorded KF- map identity; record a fresh clip')
    if any(s['map'].casefold()!=name.casefold() for s in samples):
        raise ValueError('Review supports one map per clip')
    if any(s['boundary']&24 for s in samples[1:]):
        raise ValueError('Review does not cross recorded respawn or map boundaries')
    return {'path':str(path),'sha256':sha256(path),'samples':len(samples),
            'duration_seconds':duration,'map':name,
            'observation_seconds':max(10,math.ceil(duration+5)),
            'input':'authored synthetic; no physical XR' if all(s['synthetic'] for s in samples)
                else 'saved input with synthetic flag false; review uses no physical XR'}

def stage_clip(source,destination):
    path=Path(source['path']);destination=Path(destination)
    if sha256(path)!=source['sha256']:
        raise ValueError('Source clip changed after validation')
    if destination.exists():raise FileExistsError('Refusing to overwrite staged clip')
    destination.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(path,destination)
    if sha256(destination)!=source['sha256']:
        raise ValueError('Staged clip does not match source')
