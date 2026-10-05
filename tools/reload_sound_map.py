"""Map every stock reload sound of the physical-reload guns to the physical
event that makes it, from the stock animation itself.

For each catalog gun this reads the cooked 1P AnimSet (reload clip notifies)
and the UModel PSK/PSA exports already made by the gun audits, and asks, at
each notify's time, which weapon parts are moving: the outgoing magazine, the
incoming one, the rack part, the magazine release. That decides the sound's
role in a physical reload (release click, eject, insertion contact, seat, rack
back, rack forward, or hand handling with no part moving).

    python tools/reload_sound_map.py --dump [Class ...]   # motion timeline
    python tools/reload_sound_map.py --write              # VRReloadSoundMap.uc

Read-only on game assets; no game, editor or Blender launch.
"""
from __future__ import annotations

import argparse
import glob
import math
import os
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/re'))
sys.path.insert(0, str(ROOT / 'tools'))
from audit_flamethrower_assets import value, chunks, parse_bones, INFO, KEY, ctext  # noqa: E402
from audit_m14_assets import mul, conj, rotate  # noqa: E402
from audit_source_assets import read_package, properties  # noqa: E402

GAME = Path('D:/SteamLibrary/steamapps/common/killingfloor2')
SRC = GAME / 'Development/Src'
WEAPONS = GAME / 'KFGame/BrewedPC/Packages/Weapons'
CATALOG = ROOT / 'script/KF2VR/Classes/VRReloadCatalog.uc'
CLIPS = ('Reload_Half', 'Reload_Empty', 'Reload_Half_Elite', 'Reload_Empty_Elite')
EXTRA_CLIPS = ('Reload_Open_Shell', 'Reload_Open_Shell_Elite')


def find_ci(root, filename):
    want, hits = filename.lower(), []
    for dirpath, _, files in os.walk(root):
        hits += [Path(dirpath) / f for f in files if f.lower() == want]
    return sorted(hits)


def class_text(name):
    path = next(SRC.glob(f'*/Classes/{name}.uc'), None)
    return path.read_text(encoding='utf-8', errors='replace') if path else ''


def class_value(name, key):
    """Default property, following the class's parents."""
    while name:
        text = class_text(name)
        m = re.search(key + r'\s*=\s*"([^"]+)"', text)
        if m:
            return m.group(1)
        m = re.search(r'\bclass\s+\w+\s+extends\s+(\w+)', text)
        name = m.group(1) if m else None
    return None


def catalog():
    """(class, mesh, rack bone, follow bone) rows of VRReloadCatalog."""
    rows = []
    for line in CATALOG.read_text(encoding='utf-8').splitlines():
        m = re.search(r"Profiles\(\d+\)=\(WeaponClass=class'(\w+)',MeshName=(\w+),RackBone=(\w+)", line)
        if m:
            f = re.search(r'FollowBone=(\w+)', line)
            rows.append((m.group(1), m.group(2), m.group(3), f.group(1) if f else ''))
    return rows


class Package:
    def __init__(self, path):
        self.data, self.names, self.imports, self.objects = read_package(Path(path))

    def fields(self, obj):
        return properties(self.data[obj['offset'] + 4:obj['offset'] + obj['size']], self.names)[0]

    def import_path(self, ref):
        imp = self.imports[-ref - 1]
        return (self.import_path(imp['outer']) + '.' if imp['outer'] < 0 else '') + imp['name']


def read_clips(pkg, animset):
    """The four reload clips of the named AnimSet: [(time, kind, detail, props)]."""
    sets = [i + 1 for i, o in enumerate(pkg.objects) if o['cls'] == 'AnimSet' and o['name'].lower() == animset.lower()]
    clips = {}
    for obj in pkg.objects:
        if obj['cls'] != 'AnimSequence' or obj['outer'] not in sets:
            continue
        fs = pkg.fields(obj)
        name = value(fs['SequenceName'], pkg.names)
        if name not in CLIPS and name not in EXTRA_CLIPS:
            continue
        raw = fs['Notifies']['value'] if 'Notifies' in fs else struct.pack('<i', 0)
        count, offset, notes = struct.unpack_from('<i', raw)[0], 4, []
        for _ in range(count):
            nf, size = properties(raw[offset:], pkg.names)
            offset += size
            ref = value(nf['Notify'], pkg.names) if 'Notify' in nf else 0
            t = value(nf['Time'], pkg.names) if 'Time' in nf else 0.0
            kind, detail, props = '(None)', '', {}
            if ref > 0:
                nobj = pkg.objects[ref - 1]
                nfs = pkg.fields(nobj)
                kind = nobj['cls']
                for k, f in nfs.items():
                    if f['kind'] == 'ObjectProperty':
                        r = struct.unpack('<i', f['value'])[0]
                        props[k] = pkg.import_path(r) if r < 0 else str(r)
                    elif f['kind'] in ('NameProperty', 'BoolProperty', 'FloatProperty', 'IntProperty', 'StrProperty'):
                        props[k] = value(f, pkg.names)
                detail = props.get('AkEvent') or props.get('NotifyName') or props.get('BoneName') or ''
            notes.append((t, kind, detail, props))
        clips[name] = dict(length=value(fs['SequenceLength'], pkg.names),
                           rate=value(fs['RateScale'], pkg.names) if 'RateScale' in fs else 1.0, notifies=notes)
    return clips


def export_file(folder, name, ext):
    want = name.lower() + ext
    for p in glob.glob(str(ROOT / 'build' / '**' / folder / ('*' + ext)), recursive=True):
        if Path(p).name.lower() == want:
            return Path(p)
    return None


class Motion:
    """Bone poses of a PSA sequence on the PSK hierarchy, in RW_Weapon's frame."""

    def __init__(self, psk, psa):
        self.bones = parse_bones(chunks(psk)['REFSKELT'])
        self.index = {b['name']: i for i, b in enumerate(self.bones)}
        psa = chunks(psa)
        self.track = {b['name']: i for i, b in enumerate(parse_bones(psa['BONENAMES']))}
        self.infos = {ctext(i[0]): i for i in INFO.iter_unpack(psa['ANIMINFO'][2])}
        self.keys = psa['ANIMKEYS'][2]

    def pose(self, seq, t, length):
        """Positions at raw clip time t, in RW_Weapon's frame."""
        positions, rotations = self.world(seq, t, length)
        w = self.index['RW_Weapon']
        inv = conj(rotations[w])
        return {b['name']: rotate(inv, tuple(a - c for a, c in zip(positions[i], positions[w])))
                for i, b in enumerate(self.bones)}

    def world(self, seq, t, length):
        """Component-space positions and rotations of every bone at raw clip
        time t. UModel folds RateScale into the PSA frame rate, so frames map
        onto the package's own SequenceLength instead."""
        info = self.infos[seq]
        frames = info[11]
        f = max(0, min(frames - 1, round(t / length * (frames - 1))))
        base = (info[10] + f) * info[2]
        positions, rotations = [], []
        for i, b in enumerate(self.bones):
            if b['name'] in self.track:
                k = KEY.unpack_from(self.keys, (base + self.track[b['name']]) * KEY.size)
                p, q = k[0:3], k[3:7]
            else:
                p, q = b['local_position'], b['local_quaternion']
            if i:
                parent = b['parent_index']
                p = tuple(a + c for a, c in zip(positions[parent], rotate(rotations[parent], p)))
                q = mul(rotations[parent], conj(q))
            positions.append(tuple(p)); rotations.append(tuple(q))
        return positions, rotations


def dist(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def movers(motion, seq, t, length, window=0.05):
    """RW_ bones moving at t (UU/s along the weapon frame), fastest first."""
    a, b = motion.pose(seq, max(0.0, t - window), length), motion.pose(seq, t + window, length)
    speed = {n: dist(a[n], b[n]) / (2 * window) for n in a if n.startswith('RW_') and n != 'RW_Weapon'}
    return sorted(((s, n) for n, s in speed.items() if s > 2.0), reverse=True)


def gun_inputs(cls, mesh):
    animset = class_value(cls, r'FirstPersonAnimSetNames\(0\)')
    pkg_name, set_name = animset.split('.')
    pkg = find_ci(WEAPONS, pkg_name + '.upk')[0]
    psk = export_file('SkeletalMesh3', mesh, '.psk')
    # An AnimSet name is not unique (the 93R ships Wep_1stP_9MM_Anim in its own
    # package): match the exporting package folder too.
    psa = next((Path(f) for f in glob.glob(str(ROOT / 'build' / '**' / 'AnimSet' / '*.psa'), recursive=True)
                if Path(f).name.lower() == set_name.lower() + '.psa'
                and Path(f).parent.parent.name.lower() == pkg_name.lower()), None)
    return Package(pkg), set_name, psk, psa


def dump(classes):
    for cls, mesh, rack, follow in catalog():
        if classes and cls not in classes:
            continue
        pkg, set_name, psk, psa = gun_inputs(cls, mesh)
        print(f'=== {cls} rack={rack} follow={follow} psk={psk is not None} psa={psa is not None}')
        if not (psk and psa):
            continue
        motion = Motion(psk, psa)
        for clip, data in read_clips(pkg, set_name).items():
            print(f'  -- {clip} len={data["length"]:.3f}')
            for t, kind, detail, props in data['notifies']:
                if kind in ('KFAnimNotify_CameraAnim',):
                    continue
                moving = movers(motion, clip, t, data['length'])
                label = detail.split('.')[-1] if kind == 'AnimNotify_AkEvent' else f'{kind}:{detail}'
                print(f'     {t:6.3f} {label:58s} ' + ', '.join(f'{n}={s:.0f}' for s, n in moving[:4]))


# Roles, as VRReloadAudioPlan numbers its cues.
ROLE_NAMES = {1: 'eject', 2: 'contact', 3: 'seat', 4: 'rear', 5: 'forward', 6: 'release', 7: 'fetch'}
EVENT_ROLE = {'unseat': 1, 'clear': 1, 'contact': 2, 'seat': 3, 'rear': 4, 'forward': 5, 'release': 6}
SEATED, CLEAR, CONTACT = 0.5, 6.0, 6.0
# A sound may lead the motion it belongs to a little, or trail it.
LEAD, TRAIL = 0.30, 0.45
HANDLING = ('rustle', 'cloth', 'swish', 'rattle', 'pickup', 'grab')


def motion_events(motion, clip, length, rack, action_kind, steps=240, magazine=None):
    """Times of the magazine and action events in one clip (raw seconds).
    A catalog LoadedBone/SpareBone pair replaces RW_Magazine1 and its kin."""
    idle = motion.pose('Idle', 0, 1.0)
    seat = idle[magazine[0] if magazine else 'RW_Magazine1']
    mags = list(magazine) if magazine else [b for b in idle if re.fullmatch(r'RW_Mag(azine)?\d*', b)]
    times = [length * i / steps for i in range(steps + 1)]
    poses = [motion.pose(clip, t, length) for t in times]
    near = [min(dist(p[b], seat) for b in mags) for p in poses]
    # A rig may hand the seated magazine from one bone to another in a single
    # frame (the AK-12 does at 0.15 s); only a state that lasts is an event.
    hold = 4
    near = [max(near[i:i + hold]) if near[i] > SEATED else near[i] for i in range(len(near))]
    near = [d if (d <= SEATED or all(x > SEATED for x in near[i:i + hold])) else SEATED for i, d in enumerate(near)]
    events = []
    # The well empties: first unseat, then clear of the well.
    out = next((i for i, d in enumerate(near) if d > SEATED), None)
    if out is not None:
        events.append(('unseat', times[out]))
        clear = next((i for i in range(out, len(near)) if near[i] > CLEAR), None)
        if clear is not None:
            events.append(('clear', times[clear]))
        # The last arrival: seat, and the contact that led into it.
        seat_i = next((i for i in range(len(near) - 1, out, -1) if near[i] > SEATED), None)
        if seat_i is not None and seat_i + 1 < len(near):
            events.append(('seat', times[seat_i + 1]))
            contact = next((i for i in range(seat_i, out, -1) if near[i] > CONTACT), None)
            if contact is not None:
                events.append(('contact', times[contact + 1]))
    # The action, along its own travel from Idle (its closed or cocked stop).
    if rack and rack in idle and action_kind != 2:
        travel = [dist(p[rack], idle[rack]) for p in poses]
        top = max(travel)
        if top > 0.5:
            moving_back = None
            for i in range(1, len(travel)):
                d0, d1 = travel[i - 1], travel[i]
                if action_kind == 1:
                    # Open bolt: Idle is cocked; reaching it from forward is the sear.
                    if d0 > top * 0.1 >= d1:
                        events.append(('rear', times[i]))
                    continue
                if d0 < top * 0.9 <= d1:
                    events.append(('rear', times[i]))
                if d0 > top * 0.1 >= d1:
                    events.append(('forward', times[i]))
    if 'RW_Mag_Release' in idle:
        rel = [dist(p['RW_Mag_Release'], idle['RW_Mag_Release']) for p in poses]
        hit = next((i for i, d in enumerate(rel) if d > 0.05), None)
        if hit is not None:
            events.append(('release', times[hit]))
    return sorted(events, key=lambda e: e[1])


# Unambiguous names, checked in order. Single insert sounds are the seat.
NAME_ROLES = (
    (('click', 'button'), 6),
    (('insert_a', 'magin_01', 'mag_in_1', 'magin_a'), 2),
    (('insert_b', 'magin_02', 'mag_in_2', 'magin_b'), 3),
    # The AF2011 names its magazine by reload: Reload_Full_In, Reload_Half_Out.
    (('maginsert', 'magin', 'mag_in', 'mag_reload_in', 'reload_mag_in', 'reload_full_in', 'reload_half_in'), 3),
    (('eject', 'magout', 'mag_out', 'mag_reload_out', 'reload_mag_out', 'reload_full_out', 'reload_half_out'), 1),
    (('boltback', 'bolt_back', 'handle_back', 'pumpback', 'slideback', 'slide_back', 'empty_back'), 4),
    (('boltforward', 'bolt_forward', 'bolt_release', 'handle_fwd', 'pumpforward', 'slideforward',
      'slide_forward', 'empty_forward', 'reload_full_slide'), 5),
    (HANDLING, 7),
)


def name_role(name):
    low = name.lower()
    for tokens, role in NAME_ROLES:
        if any(k in low for k in tokens):
            return role
    return 0


def classify(name, t, events):
    """(role, evidence) for one sound at stock time t: an unambiguous name
    decides, the motion decides the rest; disagreements are marked."""
    motion_role, why = classify_motion(name, t, events)
    named = name_role(name)
    if named:
        if motion_role and motion_role != named and named != 7:
            return named, f'name; MOTION SAYS {ROLE_NAMES[motion_role]} ({why})'
        return named, 'name' + (f'; {why}' if motion_role else '')
    return motion_role, why


def classify_motion(name, t, events):
    low = name.lower()
    best = None
    for kind, et in events:
        d = t - et
        if -LEAD <= d <= TRAIL and (best is None or abs(d) < abs(best[2])):
            best = (kind, et, d)
    if any(k in low for k in HANDLING) and (best is None or best[0] not in ('rear', 'forward', 'seat')):
        return 7, 'handling name' + (f' (near {best[0]})' if best else '')
    if best:
        return EVENT_ROLE[best[0]], f'{best[0]}@{best[1]:.2f} ({best[2]:+.2f}s)'
    return 0, 'no part moving'


def sound_rows(classes=()):
    """[(class, clip, path, time, role, evidence)] for every catalog gun."""
    rows = []
    kinds, magazines = {}, {}
    for line in CATALOG.read_text(encoding='utf-8').splitlines():
        m = re.search(r"WeaponClass=class'(\w+)'.*?ActionKind=(\d)", line)
        if m:
            kinds[m.group(1)] = int(m.group(2))
        m = re.search(r"WeaponClass=class'(\w+)'.*?LoadedBone=(\w+),SpareBone=(\w+)", line)
        if m:
            magazines[m.group(1)] = (m.group(2), m.group(3))
    for cls, mesh, rack, follow in catalog():
        if classes and cls not in classes:
            continue
        pkg, set_name, psk, psa = gun_inputs(cls, mesh)
        motion = Motion(psk, psa)
        for clip, data in read_clips(pkg, set_name).items():
            events = motion_events(motion, clip, data['length'], rack, kinds.get(cls, 0),
                                   magazine=magazines.get(cls))
            for t, kind, detail, props in data['notifies']:
                if kind != 'AnimNotify_AkEvent' or not detail:
                    continue
                role, why = classify(detail.split('.')[-1], t, events)
                rows.append((cls, clip, detail, t, role, why, events))
    return rows


# Sounds whose motion evidence is indirect, decided once by reading the clip
# (timeline in --classify); the reason is the clip, not the name.
OVERRIDES = {
    # The flintlock's hammer cock after the cylinder seats (-1: no physical
    # role; VRReloadAudioPlan leaves it on the stock clip of a no-action gun).
    ('KFWeap_Pistol_Blunderbuss', 'Play_WEP_Blunderbuss_Handling_Reload_C'): -1,
    # Its one insert sound; the cylinder's contact and seat are 0.05 s apart.
    ('KFWeap_Pistol_Blunderbuss', 'Play_WEP_Blunderbuss_Handling_Reload_B'): 3,
    # Named for the stroke but not by the shared tokens; the pump and handle
    # strokes sit 0.15-0.25 s apart, inside one motion window.
    ('KFWeap_Shotgun_HZ12', 'Play_WEP_HZ12_Back'): 4,
    ('KFWeap_Shotgun_HZ12', 'Play_WEP_HZ12_FWD'): 5,
    ('KFWeap_HRG_SonicGun', 'Play_WEP_HRG_SonicGun_Pull_Back'): 4,
    ('KFWeap_HRG_SonicGun', 'Play_WEP_HRG_SonicGun_Reload_Part_02'): 5,
    ('KFWeap_RocketLauncher_SealSqueal', 'Play_WEP_SealSqueal_Handling_GunCheck_PullBack_01'): 4,
    ('KFWeap_RocketLauncher_SealSqueal', 'Play_WEP_SealSqueal_Handling_GunCheck_Forward_01'): 5,
    # The pneumatic recharge after the magazine seats, on the stock clip.
    ('KFWeap_Shotgun_Nailgun', 'Play_WEP_SA_Nailgun_Handling_AirUp'): 8,
    ('KFWeap_Shotgun_Nailgun', 'Play_WEP_SA_Nailgun_Handling_AirDown'): 8,
    ('KFWeap_HRG_Nailgun', 'Play_WEP_SA_Nailgun_Handling_AirUp'): 8,
    ('KFWeap_HRG_Nailgun', 'Play_WEP_SA_Nailgun_Handling_AirDown'): 8,
    # The drum's spinner turns on the stock clip, not with the hand.
    ('KFWeap_AssaultRifle_HRGTeslauncher', 'Play_WEP_Medic_GrenadeLauncher_Spinner'): 8,
    ('KFWeap_AssaultRifle_MedicRifleGrenadeLauncher', 'Play_WEP_Medic_GrenadeLauncher_Spinner'): 8,
    # One insert sound, contact and seat within one motion window: the seat.
    ('KFWeap_AssaultRifle_Microwave', 'Play_WEP_Helios_Handling_Mag_In'): 3,
    ('KFWeap_RocketLauncher_ThermiteBore', 'Play_WEP_Thermite_Mag_In'): 3,
    # The cartridge seats into the open chamber; the chamber then closes on
    # the stock clip with its own sounds.
    ('KFWeap_Ice_FreezeThrower', 'Play_Cryo_Gun_Cartridge_Insert'): 3,
    ('KFWeap_Ice_FreezeThrower', 'Play_Cryo_Gun_Reload_Cartridge_Out_Steam'): 8,
    ('KFWeap_Ice_FreezeThrower', 'Play_Cryo_Gun_Reload_End'): 8,
    ('KFWeap_HRG_Healthrower', 'Play_Cryo_Gun_Cartridge_Insert'): 3,
    ('KFWeap_HRG_Healthrower', 'Play_Cryo_Gun_Reload_Cartridge_Out_Steam'): 8,
    ('KFWeap_HRG_Healthrower', 'Play_Cryo_Gun_Reload_End'): 8,
    # The Pulverizer's pump handle goes down and up on the stock clip.
    ('KFWeap_Blunt_Pulverizer', 'Play_WEP_MEL_Pulverizer_Handle_HandleDown'): 8,
    ('KFWeap_Blunt_Pulverizer', 'Play_WEP_MEL_Pulverizer_Handle_HandleUp'): 8,
    # The rocket's nose enters the tube 0.4 s before its base bone nears the
    # seat: these are the contact.
    ('KFWeap_RocketLauncher_RPG7', 'Play_WEP_SA_RPG7_Handling_Reload_A'): 2,
    ('KFWeap_RocketLauncher_RPG7', 'Play_WEP_SA_RPG7_Handling_Reload_B'): 2,
    ('KFWeap_HRG_MedicMissile', 'Play_WEP_HRG_MedicMissile_Handling_Reload_A'): 2,
    ('KFWeap_HRG_MedicMissile', 'Play_WEP_HRG_MedicMissile_Handling_Reload_B'): 2,
    # The handle sits locked back while the hand works it, then slams home.
    ('KFWeap_AssaultRifle_G36C', 'Play_WEP_G36C_Lever'): 4,
    ('KFWeap_AssaultRifle_G36C', 'Play_WEP_G36C_Shutter'): 5,
    # Plays once the magazine is seated; the gun has no action step.
    ('KFWeap_ZedMKIII', 'Play_WEP_ZEDMKIII_Handling_Reload_Switch'): 3,
    # One combined event, ahead of the magazine leaving.
    ('KFWeap_Rifle_M14EBR', 'Play_EBR_Reload_1'): 1,
}
MAX_GAP = 0.3       # later sounds of one physical event follow at most this late
MAX_FETCH = 2       # handling layers kept on the pouch grab
GENERATED = ROOT / 'script/KF2VR/Classes/VRReloadSoundMap.uc'


def action_kinds():
    kinds = {}
    for line in CATALOG.read_text(encoding='utf-8').splitlines():
        m = re.search(r"WeaponClass=class'(\w+)'", line)
        if m:
            k = re.search(r'ActionKind=(\d)', line)
            kinds[m.group(1)] = int(k.group(1)) if k else 0
    return kinds


def clip_set(rows, cls, clip, empty, action_kind):
    """[(time, path, role)] of one clip after the physical rules."""
    out = []
    for c, cl, path, t, role, why, events in rows:
        if c != cls or cl != clip:
            continue
        short = path.split('.')[-1]
        if (cls, short) in OVERRIDES:
            out.append([t, path, OVERRIDES[(cls, short)], True, False, 0])
            continue
        motion = classify_motion(short, t, events)[0]
        if action_kind == 2 and role in (4, 5):
            # No action step: the stock clip works the part and sounds it.
            role = -1
        elif not empty and role in (4, 5):
            # A tactical reload has no rack: its action sound is left out (the
            # AR-15 sounds its ejection with BoltBack); the set borrows a real
            # ejection sound from the empty reload instead.
            role = -1
        out.append([t, path, role, False, why.startswith('name'), motion])
    # The last named insert sound is the latch; any earlier one is the contact.
    # Overridden and motion-matched sounds (the Disrupter's charge-in after
    # its latch) keep their role and stay out of this ordering.
    inserts = sorted((r for r in out if r[2] in (2, 3) and not r[3] and r[4]), key=lambda r: r[0])
    for i, r in enumerate(inserts):
        r[2] = 3 if i == len(inserts) - 1 else 2
    # A lone named insert sound that plays at contact, ahead of a separate
    # seat sound (the P90's MagIn before its Hit), stays the contact.
    if len(inserts) == 1 and inserts[0][5] == 2 and any(r[2] == 3 and not r[4] for r in out):
        inserts[0][2] = 2
    if empty and action_kind == 1:
        # An open bolt has one physical moment, the cock: every action sound
        # (the MKb.42's pull, then its settle onto the sear) plays there in order.
        for r in out:
            if r[2] == 5 and not r[3]:
                r[2] = 4
    if empty:
        actions = [r for r in out if r[2] in (4, 5) and not r[3]]
        if len(actions) == 1:
            # One recorded stroke: an open bolt's cock, or a rack's return.
            actions[0][2] = 4 if action_kind == 1 else 5
    return [r[:3] for r in out]


def chosen_sets():
    """{(class, empty): [(role, delay, path)]} and the problems found."""
    rows = sound_rows()
    kinds = action_kinds()
    result, problems = {}, []
    classes = list(dict.fromkeys(r[0] for r in rows))
    for cls in classes:
        for empty in (False, True):
            base = 'Reload_Empty' if empty else 'Reload_Half'
            regular = clip_set(rows, cls, base, empty, kinds.get(cls, 0))
            elite = clip_set(rows, cls, base + '_Elite', empty, kinds.get(cls, 0))
            # A sound no physical event explains belongs to a part the stock
            # clip still drives (the Seeker Six's doors, a Teslauncher's
            # mechanism, the Nailgun's air): it keeps its stock time (role 8).
            for rows_ in (regular, elite):
                for i, (t, path, role) in enumerate(rows_):
                    if role == 0:
                        rows_[i] = (t, path, 8)
            # Regular clips first (physical reloads sample them); the elite
            # clip fills a physical event the regular clip does not sound.
            have = {r[2] for r in regular}
            picked = [r for r in regular if r[2] > 0] + [r for r in elite if r[2] > 0 and r[2] not in have]
            if empty and kinds.get(cls, 0) == 0 and 5 in {r[2] for r in picked} and 4 not in {r[2] for r in picked}:
                other = [r for r in clip_set(rows, cls, 'Reload_Empty_Elite' if base == 'Reload_Empty' else base, True, 0)
                         if r[2] == 4]
                picked += other[:1]
            # A sound the hand plays at a physical event never also keeps a
            # stock time (the Teslauncher's spinner would sound twice).
            owned = {r[1] for r in picked if r[2] != 8}
            picked = [r for r in picked if r[2] != 8 or r[1] not in owned]
            entries = []
            for role in sorted({r[2] for r in picked}):
                group = sorted({(r[0], r[1]) for r in picked if r[2] == role})
                seen = set()
                group = [g for g in group if not (g[1] in seen or seen.add(g[1]))]
                if role == 7:
                    group = group[:MAX_FETCH]
                t0 = group[0][0]
                entries += [(role, round(min(t - t0, MAX_GAP), 3), path) for t, path in group]
            result[(cls, empty)] = entries
        # The magazine moves the same way in both reload types: a set missing
        # an eject, contact, seat or release sound takes the other set's.
        for empty in (False, True):
            mine, other = result[(cls, empty)], result[(cls, not empty)]
            for role in (1, 2, 3, 6):
                if role not in {e[0] for e in mine}:
                    mine += [e for e in other if e[0] == role]
        # A sound in three or more of the gun's four clips is part of how the
        # gun sounds (the Disrupter's charge-in after every seat): both sets
        # keep it, at its usual gap after the event's first sound.
        clips = {}
        for clip in ('Reload_Half', 'Reload_Half_Elite', 'Reload_Empty', 'Reload_Empty_Elite'):
            for t, path, role in clip_set(rows, cls, clip, 'Empty' in clip, kinds.get(cls, 0)):
                clips.setdefault(path, []).append((clip, t, role))
        for path, seen in clips.items():
            roles = {r for c, t, r in seen}
            # Only a physical role spreads; stock-clock (8) and left-out (-1)
            # sounds stay where the clip has them.
            if len({c for c, t, r in seen}) < 3 or len(roles) != 1 or roles & {-1, 0, 4, 5, 8}:
                continue
            role = roles.pop()
            gaps = []
            for clip, t, r in seen:
                firsts = [tt for p2, (cc, tt, rr) in ((p2, s) for p2, ss in clips.items() for s in ss)
                          if cc == clip and rr == role]
                gaps.append(min(t - min(firsts), MAX_GAP))
            for empty in (False, True):
                mine = result[(cls, empty)]
                if role == 7 and sum(1 for e in mine if e[0] == 7) >= MAX_FETCH:
                    continue
                if path not in {e[2] for e in mine}:
                    mine.append((role, round(max(gaps), 3), path))
        empty_set = result[(cls, True)]
        if kinds.get(cls, 0) == 0 and 5 in {e[0] for e in empty_set} and 4 not in {e[0] for e in empty_set}:
            back = bank_back_sound(empty_set)
            if back:
                empty_set.append((4, 0.0, back))
            else:
                print(f'note: {cls} has no recorded back stroke; its rear stop is silent')
        for empty in (False, True):
            have = {e[0] for e in result[(cls, empty)]}
            roles_of = {}
            for e in result[(cls, empty)]:
                if e[0] not in (7, 8):
                    roles_of.setdefault(e[2], set()).add(e[0])
            for path, roles in roles_of.items():
                if len(roles) > 1:
                    problems.append(f'{cls} {"empty" if empty else "half"}: {path} plays as roles {sorted(roles)}')
            if 1 not in have:
                # A rocket or other single round leaves nothing to eject.
                print(f'note: {cls} {"empty" if empty else "half"} has no eject sound')
            for need in (3,) + ((5,) if empty and kinds.get(cls, 0) == 0 else ()):
                if need not in have:
                    problems.append(f'{cls} {"empty" if empty else "half"}: no {ROLE_NAMES[need]} sound')
    return result, problems


BACK_TOKENS = ('boltback', 'bolt_back', 'slideback', 'slide_back', 'handle_back', 'empty_back', 'pumpback')


def bank_back_sound(entries):
    """A back-stroke event exported by the gun's own sound bank, if it has one."""
    banks = {e[2].split('.')[0] for e in entries}
    sfx = GAME / 'KFGame/BrewedPC/Packages/Audio'
    for bank in sorted(banks):
        for f in find_ci(sfx, bank + '.upk'):
            data, names, imports, objs = read_package(f)
            for o in objs:
                if o['cls'] == 'AkEvent' and any(k in o['name'].lower() for k in BACK_TOKENS):
                    return f'{bank}.{o["name"]}'
    return None


def write():
    sets, problems = chosen_sets()
    if problems:
        print('\n'.join(problems))
        raise SystemExit('Refusing to write an incomplete sound map.')
    lines = []
    for (cls, empty), entries in sets.items():
        for role, delay, path in entries:
            lines.append(f'    Entries({len(lines)})=(Weapon={cls},bEmpty={str(empty)},Role={role},'
                         f'Delay={delay},Sound="{path}")')
    text = f'''// GENERATED by tools/reload_sound_map.py --write from the stock 1P reload
// clips and their bone motion; edit the tool, not this file.
// Every stock reload sound of each physical-reload gun, by the physical event
// that makes it: 1 eject, 2 insertion contact, 3 seat, 4 rear stop (an open
// bolt's cock), 5 forward return, 6 magazine release click, 7 pouch grab.
// One set per gun and reload type (bEmpty), whichever perk clip plays; a
// later sound of one event follows the first by its stock gap, at most {MAX_GAP} s.
class VRReloadSoundMap extends Object;

struct SoundEntry
{{
    var name Weapon;
    var bool bEmpty;
    var byte Role;
    var float Delay;
    var string Sound;
}};
var array<SoundEntry> Entries;

static function bool Covers(class<KFWeapon> W)
{{
    local int I;
    if (W == None) return false;
    for (I = 0; I < default.Entries.Length; ++I)
        if (default.Entries[I].Weapon == W.Name) return true;
    return false;
}}

static function Collect(class<KFWeapon> W, bool bEmpty, out array<SoundEntry> Out)
{{
    local int I;
    Out.Length = 0;
    if (W == None) return;
    for (I = 0; I < default.Entries.Length; ++I)
        if (default.Entries[I].Weapon == W.Name && default.Entries[I].bEmpty == bEmpty)
            Out.AddItem(default.Entries[I]);
}}

// The first sound of one event, as a path (the slide-lock release outside a reload).
static function string FirstSound(class<KFWeapon> W, bool bEmpty, byte Role)
{{
    local int I;
    if (W == None) return "";
    for (I = 0; I < default.Entries.Length; ++I)
        if (default.Entries[I].Weapon == W.Name && default.Entries[I].bEmpty == bEmpty
            && default.Entries[I].Role == Role) return default.Entries[I].Sound;
    return "";
}}

defaultproperties
{{
{chr(10).join(lines)}
}}
'''
    GENERATED.write_text(text, encoding='utf-8', newline='\r\n')
    print(f'Wrote {len(lines)} entries for {len({k[0] for k in sets})} guns to {GENERATED.relative_to(ROOT)}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dump', action='store_true')
    ap.add_argument('--classify', action='store_true')
    ap.add_argument('--write', action='store_true')
    ap.add_argument('classes', nargs='*')
    args = ap.parse_args()
    if args.dump:
        dump(set(args.classes))
    if args.write:
        write()
    if args.classify:
        last = None
        for cls, clip, path, t, role, why, events in sound_rows(set(args.classes)):
            if (cls, clip) != last:
                print(f'== {cls} {clip}  events: ' + ', '.join(f'{k}@{et:.2f}' for k, et in events))
                last = (cls, clip)
            print(f'   {t:6.3f} {path.split(".")[-1]:52s} {ROLE_NAMES.get(role, "?REVIEW"):8s} {why}')


if __name__ == '__main__':
    main()
