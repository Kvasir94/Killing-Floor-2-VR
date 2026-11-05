"""Audit reload-hint coverage of every stock 1P reload against the generated
hint shells.

For each stock weapon class with exported 1P rig and AnimSet (the UModel
PSK/PSA exports the gun audits already made under build/), this plays every
Reload* clip and finds the weapon parts the stock hands actually work: an RW_
bone that moves against its own parent while a hand or fingertip is near it.
Parts that only ride a moving parent are folded into it. Each worked part is
then matched to the reload-hint shells in build/hand-meshes/VRReloadProps.json
(generate_reload_props.py), so a part the stock reload works but no glow
covers shows up as a gap.

    python tools/reload_hint_audit.py                 # table of every gun
    python tools/reload_hint_audit.py --gaps          # only guns with gaps
    python tools/reload_hint_audit.py --json out.json # full report
    python tools/reload_hint_audit.py KFWeap_Pistol_9mm ...

Read-only on game assets; no game, editor or Blender launch. Rings and other
hints placed by sampled positions at runtime are not visible here; the report
covers the part shells only.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from reload_sound_map import (  # noqa: E402
    Motion, SRC, class_text, class_value, conj, export_file, exported_files, mul, rotate)

PROPS = ROOT / 'build/hand-meshes/VRReloadProps.json'
# A part is worked when it leaves its idle pose against its parent by this much
# while a hand is this close to it or to anything it carries.
MOVE_UU, TURN_DEG, REACH_UU = 0.5, 8.0, 8.0
# Per step of STEPS across the clip; below this a part is settling, not worked.
SPEED_UU = 0.05
STEPS = 120
HAND = re.compile(r'^(Left|Right)Hand\w*_1stP$')
# The incoming ammunition comes from the pouch or the hand, not from a part of
# the gun, so it needs no shell of its own.
INCOMING = re.compile(r'^(RW_Magazine2|RW_Magazine3|RW_Cylinder2|RW_Bullets?2|LW_\w+)$', re.I)
# Rounds, shells and projectiles loaded one at a time are lit by the port or
# chamber ring the runtime places, which has no shell; they are listed apart.
AMMO = re.compile(r'^RW_(Speedloader|StripMag|FreeShell|EmptyShell|Empty_Shell|Shell|Bullet|Round|Projectile|Arrow|Rocket|Grenade|Dart|Bolt\d|Ammo|Cartridge)', re.I)


def weapon_rows(only=()):
    """(class, rig stem, psk, psa) for every stock weapon with exports."""
    rows, seen = [], set()
    for path in sorted(SRC.glob('*/Classes/KFWeap_*.uc')):
        cls = path.stem
        if only and cls not in only:
            continue
        mesh = class_value(cls, 'FirstPersonMeshName')
        animset = class_value(cls, r'FirstPersonAnimSetNames\(0\)')
        if not mesh or not animset or '.' not in mesh or '.' not in animset:
            continue
        pkg_name, set_name = animset.split('.')
        rig = mesh.split('.')[-1]
        psk = export_file('SkeletalMesh3', rig, '.psk')
        psa = next((f for f in exported_files('AnimSet', '.psa')
                    if f.name.lower() == set_name.lower() + '.psa'
                    and f.parent.parent.name.lower() == pkg_name.lower()), None)
        key = (rig.lower(), animset.lower())
        if key in seen and not only:
            continue
        seen.add(key)
        rows.append((cls, rig, psk, psa))
    return rows


def angle(a, b):
    d = abs(sum(x * y for x, y in zip(a, b)))
    return math.degrees(2 * math.acos(min(1.0, d)))


def local(motion, positions, rotations, i):
    parent = motion.bones[i]['parent_index']
    inv = conj(rotations[parent])
    p = rotate(inv, tuple(a - c for a, c in zip(positions[i], positions[parent])))
    return p, mul(inv, rotations[i])


def worked_parts(motion, clip):
    """{bone: (travel UU, turn degrees, driven frames)} for one reload clip.

    A part is worked when it leaves its idle pose against its parent and, on
    at least two steps, a hand bone beside it moves with it (same velocity in
    the weapon frame within half its speed). Passive parts (a carrier riding
    the handle, a sling, springs, cables) move without a hand moving with them.
    """
    bones = motion.bones
    names = [b['name'] for b in bones]
    children = {i: [] for i in range(len(bones))}
    for i, b in enumerate(bones[1:], 1):
        children[b['parent_index']].append(i)

    def subtree(i):
        out = [i]
        for c in children[i]:
            out += subtree(c)
        return out

    rw = [i for i, n in enumerate(names) if n.startswith('RW_') and n != 'RW_Weapon' and i]
    hands = [i for i, n in enumerate(names) if HAND.match(n)]
    if not rw or not hands or 'RW_Weapon' not in motion.index:
        return {}
    w = motion.index['RW_Weapon']
    idle_p, idle_r = motion.world('Idle' if 'Idle' in motion.infos else clip, 0, 1.0)
    idle = {i: local(motion, idle_p, idle_r, i) for i in rw}

    def frame(t):
        positions, rotations = motion.world(clip, t, 1.0)
        inv = conj(rotations[w])
        weapon = [rotate(inv, tuple(a - c for a, c in zip(p, positions[w]))) for p in positions]
        return positions, rotations, weapon

    found = {}
    previous = frame(0.0)
    for s in range(1, STEPS + 1):
        current = frame(s / STEPS)
        positions, rotations, weapon = current
        moved = {}
        for i in rw:
            p, q = local(motion, positions, rotations, i)
            travel, turn = math.dist(p, idle[i][0]), angle(q, idle[i][1])
            if travel > MOVE_UU or turn > TURN_DEG:
                moved[i] = (travel, turn)
        for i, (travel, turn) in moved.items():
            a = bones[i]['parent_index']
            while a and a != w and a not in moved:
                a = bones[a]['parent_index']
            if a and a != w:
                continue
            driven = False
            for j in subtree(i):
                vj = [x - y for x, y in zip(weapon[j], previous[2][j])]
                speed = math.hypot(*vj)
                if speed < SPEED_UU:
                    continue
                for h in hands:
                    if math.dist(weapon[h], weapon[j]) > REACH_UU:
                        continue
                    vh = [x - y for x, y in zip(weapon[h], previous[2][h])]
                    if math.dist(vh, vj) < 0.5 * speed:
                        driven = True
                        break
                if driven:
                    break
            name = names[i]
            old = found.get(name, (0.0, 0.0, 0))
            found[name] = (max(old[0], travel), max(old[1], turn), old[2] + driven)
        previous = current
    return {n: v for n, v in found.items() if v[2] >= 2}


def hint_shells(rig):
    """[(kind, bone)] of the reload-hint shells generated for this rig."""
    try:
        props = json.loads(PROPS.read_text(encoding='utf-8'))['props']
    except (OSError, ValueError, KeyError):
        return []
    suffix = '_' + rig.lower()
    return [(name[len('VRGlow'):len(name) - len(suffix)], p.get('bone', ''))
            for name, p in props.items()
            if name.startswith('VRGlow') and name.lower().endswith(suffix)]


def covered(motion, part, shells):
    """The shell that lights this part: on the part itself, on an ancestor
    that moves it, or on a piece it carries (a cylinder under its swing
    pivot). The frame shell on RW_Weapon lights the well only."""
    bones, names = motion.bones, [b['name'] for b in motion.bones]
    if part not in motion.index:
        return ''
    chain, i = set(), motion.index[part]
    while i:
        if names[i] == 'RW_Weapon':
            break
        chain.add(names[i])
        i = bones[i]['parent_index']
    top = motion.index[part]
    carried = {names[j] for j in range(len(bones)) if j and _under(bones, j, top)}
    for kind, bone in shells:
        if bone != 'RW_Weapon' and (bone in chain or bone in carried):
            return kind
    return ''


def _under(bones, j, top):
    while j:
        if j == top:
            return True
        j = bones[j]['parent_index']
    return False


def audit(rows):
    report = []
    for cls, rig, psk, psa in rows:
        entry = {'class': cls, 'rig': rig, 'parts': [], 'shells': [], 'missing_exports': not (psk and psa)}
        if psk and psa:
            motion = Motion(psk, psa)
            shells = hint_shells(rig)
            entry['shells'] = [f'{k}:{b}' for k, b in shells]
            clips = sorted(c for c in motion.infos if c.startswith('Reload'))
            entry['clips'] = clips
            parts = {}
            for clip in clips:
                for name, (travel, turn, driven) in worked_parts(motion, clip).items():
                    old = parts.setdefault(name, {'travel': 0.0, 'turn': 0.0, 'driven': 0, 'clips': []})
                    old['travel'] = round(max(old['travel'], travel), 2)
                    old['turn'] = round(max(old['turn'], turn), 1)
                    old['driven'] += driven
                    old['clips'].append(clip)
            for name, p in sorted(parts.items()):
                p['part'] = name
                p['incoming'] = bool(INCOMING.match(name))
                p['hint'] = covered(motion, name, shells)
                entry['parts'].append(p)
        unlit = [p['part'] for p in entry['parts'] if not p['hint'] and not p['incoming']]
        entry['gaps'] = [n for n in unlit if not AMMO.match(n)]
        entry['ammo_unlit'] = [n for n in unlit if AMMO.match(n)]
        report.append(entry)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('classes', nargs='*')
    parser.add_argument('--gaps', action='store_true', help='only guns with an unlit worked part')
    parser.add_argument('--json', type=Path, help='write the full report here')
    args = parser.parse_args()
    report = audit(weapon_rows(tuple(args.classes)))
    if args.json:
        args.json.write_text(json.dumps(report, indent=1), encoding='utf-8')
    for e in report:
        if e['missing_exports']:
            if not args.gaps:
                print(f"{e['class']:44s} no rig/anim export")
            continue
        if args.gaps and not e['gaps']:
            continue
        lit = ', '.join(f"{p['part']}={p['hint']}" for p in e['parts'] if p['hint'])
        ammo = ', '.join(e['ammo_unlit'])
        print(f"{e['class']:44s} gaps: {', '.join(e['gaps']) or '-'}   lit: {lit or '-'}"
              + (f"   ammo (ring?): {ammo}" if ammo else ''))
    total = [e for e in report if not e['missing_exports']]
    print(f"\n{len(total)} guns audited, {sum(1 for e in total if e['gaps'])} with unlit worked parts, "
          f"{sum(1 for e in report if e['missing_exports'])} without exports")


if __name__ == '__main__':
    main()
