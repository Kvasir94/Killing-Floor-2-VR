"""Summarize the stock-launcher observer's actual game events and rearm sequence."""
import argparse
import json
import re
from pathlib import Path

ROW = re.compile(r'KF2VR_INPUT_OBSERVER hand=(\d).*?ammo=(\d+) reserve=(\d+) armed=(True|False) valid=(\d+) trigger=(\d+) active=(\d+) shots=(\d+) reloads=(\d+)')

def analyze(text):
    phases = [0,0]
    suppressed_shots = [None,None]
    events = {'ammo-consumed':[0,0], 'ammo-loaded':[0,0]}
    for line in text.splitlines():
        event = re.search(r'KF2VR_INPUT_OBSERVER event=(ammo-consumed|ammo-loaded) hand=([01])',line)
        if event:
            events[event[1]][int(event[2])] += 1
        match = ROW.search(line)
        if not match:
            continue
        hand, ammo, reserve, armed, valid, trigger, active, shots, reloads = match.groups()
        h=int(hand)
        if h not in (0,1):
            continue
        bit=1<<h
        valid, trigger, active, shots=map(int,(valid,trigger,active,shots))
        if phases[h]==0 and not valid&bit and not active&bit and armed=='False':
            phases[h]=1; suppressed_shots[h]=shots
        elif phases[h]==1 and valid&bit and active&bit and trigger&bit and armed=='False' and shots==suppressed_shots[h]:
            phases[h]=2
        elif phases[h]==2 and valid&bit and active&bit and not trigger&bit and armed=='True' and shots==suppressed_shots[h]:
            phases[h]=3
        elif phases[h]==3 and shots>suppressed_shots[h]:
            phases[h]=4
    complete='KF2VR_INPUT_OBSERVER complete=True stockFallback=True conserved=True' in text
    failed='KF2VR_INPUT_OBSERVER complete=False' in text
    return {'complete':complete and not failed, 'events':events,
            'unavailable_held_release_fire':[p==4 for p in phases], 'headset_accepted':False,
            'physical_reload_accepted':False}

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('log',type=Path)
    args=parser.parse_args()
    result=analyze(args.log.read_text(encoding='utf-8',errors='replace'))
    print(json.dumps(result,indent=2))
    raise SystemExit(0 if result['complete'] and all(result['unavailable_held_release_fire']) else 1)
