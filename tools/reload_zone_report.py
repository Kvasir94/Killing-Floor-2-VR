"""Report and baseline-check the physical reload zones dumped by
ReloadStateTools.VRReloadZoneCommandlet (tools/test-reload-state.ps1 -Zones).

Each KF2VR_RELOAD_ZONE log line is one gun and start (empty or partial): the
bones its reload uses, the insert path's entry and seat (where the ring and
ghost sit, in the gun's root frame, UU), the guide's capture rules, the rack
and follower strokes and the hint shells its rig has. This flags samples that
cannot work in play and every change against the accepted baseline.

    python tools/reload_zone_report.py run.log            # problems + changes
    python tools/reload_zone_report.py run.log --accept   # take as baseline
    python tools/reload_zone_report.py run.log --json out.json
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'tools/reload-zone-baseline.json'
LINE = re.compile(r'KF2VR_RELOAD_ZONE (weapon=.*)$')
VECTORS = ('entry', 'ring', 'seat', 'axis', 'rack_axis', 'rack_rest')
NUMBERS = ('path', 'entry_time', 'end_time', 'capture_dot', 'rack_stroke', 'rack_hand', 'follow_stroke')
FLAGS = ('magazine', 'axial', 'swept', 'rack_sampled', 'follow_sampled')
# A moved seat, entry or stroke beyond this is a change worth a look; below it
# is float noise between editor runs.
MOVE_UU = 0.25
# Shorter than this from entry to seat is no insertion stroke at all.
MIN_INSERT_UU = 0.5
NO_BONE = ('', 'None')


def parse(text):
    """{'weapon/start': {field: value}} from a commandlet log."""
    zones = {}
    for raw in text.splitlines():
        m = LINE.search(raw)
        if not m:
            continue
        fields = dict(part.split('=', 1) for part in m.group(1).split(' ') if '=' in part)
        for key in VECTORS:
            if key in fields:
                fields[key] = [float(v) for v in fields[key].split(',')]
        for key in NUMBERS:
            if key in fields:
                fields[key] = float(fields[key])
        for key in FLAGS:
            if key in fields:
                fields[key] = fields[key] == 'True'
        zones[f"{fields['weapon']}/{fields['start']}"] = fields
    return zones


def problems(zone):
    """Reasons this sample cannot work in play."""
    out = []
    if zone.get('status') != 'sampled':
        return [f"not sampled: {zone.get('status')}"]
    if zone['path'] < 2:
        out.append('no insert path')
    if math.dist(zone['entry'], zone['seat']) < MIN_INSERT_UU:
        out.append('entry on the seat (no insertion stroke)')
    if zone.get('fail'):
        out.append(f"sampler: {zone['fail']}")
    # Only detachable-magazine sessions rack through the sampler; pumps, levers,
    # bolts and break actions own their own parts, and some magazine guns
    # deliberately request no rack.
    if (zone['start'] == 'empty' and zone.get('magazine') and zone.get('rack') not in NO_BONE and not zone['rack'].endswith('_Weapon')
            and not zone['rack_sampled'] and zone.get('rack_fail') != 'not-requested'):
        out.append(f"rack {zone['rack']} not sampled ({zone.get('rack_fail') or 'no reason'})")
    if zone['rack_sampled'] and zone['rack_stroke'] <= 0:
        out.append('zero rack stroke')
    for part in ('mag', 'well', 'slide'):
        if zone.get('glow_' + part, '').endswith('!missing-bone'):
            out.append(f'{part} shell bone missing from the rig')
    return out


def changes(old, new):
    """Differences of one gun/start between two dumps."""
    out = []
    for key in sorted(set(old) | set(new)):
        a, b = old.get(key), new.get(key)
        if key in VECTORS:
            if a is None or b is None or math.dist(a, b) > MOVE_UU:
                out.append(f'{key} {a} -> {b}')
        elif key in NUMBERS:
            tolerance = MOVE_UU if key.endswith(('stroke', 'hand')) else 0.01 if 'time' in key or key == 'capture_dot' else 0
            if a is None or b is None or abs(a - b) > tolerance:
                out.append(f'{key} {a} -> {b}')
        elif a != b:
            out.append(f'{key} {a} -> {b}')
    return out


def report(zones, baseline):
    lines, failing = [], 0
    for name in sorted(zones):
        found = problems(zones[name])
        if found:
            failing += 1
            lines.append(f'PROBLEM {name}: ' + '; '.join(found))
    for name in sorted(set(zones) | set(baseline)):
        if name not in baseline:
            lines.append(f'NEW     {name}')
        elif name not in zones:
            lines.append(f'GONE    {name}')
        else:
            diff = changes(baseline[name], zones[name])
            if diff:
                lines.append(f'CHANGED {name}: ' + '; '.join(diff))
    guns = {z['weapon'] for z in zones.values()}
    lines.append(f'{len(guns)} guns, {len(zones)} starts, {failing} with problems')
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('log', type=Path)
    parser.add_argument('--accept', action='store_true', help='write this dump as the baseline')
    parser.add_argument('--json', type=Path)
    args = parser.parse_args()
    zones = parse(args.log.read_text(encoding='utf-8', errors='replace'))
    if not zones:
        sys.exit('No KF2VR_RELOAD_ZONE lines in ' + str(args.log))
    if args.json:
        args.json.write_text(json.dumps(zones, indent=1, sort_keys=True), encoding='utf-8')
    if args.accept:
        BASELINE.write_text(json.dumps(zones, indent=1, sort_keys=True) + '\n', encoding='utf-8')
        print(f'Baseline written: {BASELINE}')
    baseline = json.loads(BASELINE.read_text(encoding='utf-8')) if BASELINE.exists() else {}
    print('\n'.join(report(zones, baseline)))


if __name__ == '__main__':
    main()
