"""Author the RAVEN-7 one-handed grip on the rendered VR hand skeleton.

Plain Python + numpy (usable inside or outside Blender). The grip starts from
the Bone Crusher mace's right-hand Idle (a one-handed hammer grip on a round
haft: knuckles along RW_Weapon +X, index toward the head along +Z), which is
the tomahawk's own convention (blade +X, haft +Z). Every right-hand finger
joint is then closed onto the tomahawk's measured handle cross-sections using
the skinned VRFloatingHands surface -- the hand VR actually draws around a
held weapon -- so the fit is solved and checked against real skin, not bones.

The result is a 42-bone skeleton: the 41 VRFloatingHands bones in their bind
pose, the solved right-hand fingers, and RW_Weapon placed so the fist closes
on the lower grip wrap. That pose is both the rig's reference pose and its
Idle take; VRHandsBridge samples the grip from Idle like any stock weapon.

Inputs are derived stock assets under ignored build/ (as for the reload
props). Recreate the mace export when missing:
  umodel -export -notex -out=build/blunt-maceandshield-audit/export -path=<KF2>/KFGame/BrewedPC \
      WEP_1P_Shield_Melee_MESH Wep_1stP_Shield_Melee_Rig
  umodel -export -notex -out=build/blunt-maceandshield-audit/export -path=<KF2>/KFGame/BrewedPC \
      WEP_1P_Shield_Melee_ANIM Wep_1stP_Shield_Melee_Anim
"""
from __future__ import annotations

import math
import struct
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
HANDS_PSK = ROOT / 'build/hand-meshes/VRFloatingHands.psk'
MACE = ROOT / 'build/blunt-maceandshield-audit/export'
HEADER = struct.Struct('<20s3i')
BONE = struct.Struct('<64s3i11f')
KEY = struct.Struct('<8f')
INFO = struct.Struct('<64s64s4i3f3i')
FINGERS = ('Index', 'Middle', 'Ring', 'Pinky')
# Where the fist centre (between index and pinky knuckles) closes on the
# authored model: the lower half of the grip wrap, clear of the pommel flare.
FIST_CENTRE_Z = -5.0
GAP = 0.08          # target skin clearance at contact, cm
STEP = math.radians(0.5)
LIMIT = math.radians(40)
THUMB_LIMIT = math.radians(40)


# Quaternions are (x, y, z, w), matching tools/re/audit_m14_assets.py.
def qmul(a, b):
    x, y, z, w = a; X, Y, Z, W = b
    return (w*X + x*W + y*Z - z*Y, w*Y - x*Z + y*W + z*X, w*Z + x*Y - y*X + z*W, w*W - x*X - y*Y - z*Z)


def qconj(q):
    return (-q[0], -q[1], -q[2], q[3])


def qrot(q, p):
    return qmul(qmul(q, (*p, 0.0)), qconj(q))[:3]


def qaxis(axis, angle):
    s = math.sin(angle / 2)
    return (axis[0] * s, axis[1] * s, axis[2] * s, math.cos(angle / 2))


def qmatrix(q):
    x, y, z, w = q
    return np.array(((1 - 2*(y*y + z*z), 2*(x*y - z*w), 2*(x*z + y*w)),
                     (2*(x*y + z*w), 1 - 2*(x*x + z*z), 2*(y*z - x*w)),
                     (2*(x*z - y*w), 2*(y*z + x*w), 1 - 2*(x*x + y*y))))


def add(a, b): return tuple(x + y for x, y in zip(a, b))
def sub(a, b): return tuple(x - y for x, y in zip(a, b))
def scale(a, s): return tuple(x * s for x in a)
def dot(a, b): return sum(x * y for x, y in zip(a, b))
def cross(a, b): return (a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0])
def norm(a): return math.sqrt(dot(a, a))
def unit(a): return scale(a, 1.0 / norm(a))


def read_chunks(path):
    data = Path(path).read_bytes()
    chunks, offset = {}, 0
    while offset < len(data):
        name, flags, size, count = HEADER.unpack_from(data, offset)
        offset += HEADER.size
        chunks[name.rstrip(b'\0').decode()] = (flags, size, [data[offset + i*size:offset + (i + 1)*size] for i in range(count)])
        offset += size * count
    return chunks


class Skeleton:
    """ActorX bones. A child's file quaternion is the conjugate of its local
    rotation; the root's is used directly (tools/re/measure_melee_head.py)."""

    def __init__(self, rows):
        bones = [BONE.unpack(r) for r in rows]
        self.names = [b[0].rstrip(b'\0').decode() for b in bones]
        self.flags = [b[1] for b in bones]
        self.parents = [b[3] for b in bones]
        self.extra = [b[11:] for b in bones]
        self.local_p = [tuple(b[8:11]) for b in bones]
        self.local_q = [tuple(b[4:8]) if i == 0 else qconj(tuple(b[4:8])) for i, b in enumerate(bones)]
        self.index = {n: i for i, n in enumerate(self.names)}

    def world(self, local_q=None, local_p=None):
        local_q = local_q or self.local_q
        local_p = local_p or self.local_p
        P, R = [], []
        for i, parent in enumerate(self.parents):
            if i == 0:
                P.append(local_p[0]); R.append(local_q[0])
            else:
                P.append(add(P[parent], qrot(R[parent], local_p[i])))
                R.append(qmul(R[parent], local_q[i]))
        return P, R

    def rows(self, local_q, local_p):
        out = []
        for i, name in enumerate(self.names):
            q = local_q[i] if i == 0 else qconj(local_q[i])
            children = sum(1 for p in self.parents[1:] if p == i) if i else sum(1 for p in self.parents[1:] if p == 0)
            out.append(BONE.pack(name.encode(), self.flags[i], children, self.parents[i] if i else 0,
                                 *q, *local_p[i], *self.extra[i]))
        return out


def mace_idle():
    """RightHand wrist and finger rotations of the stock mace Idle, in RW_Weapon space."""
    psk = next(MACE.glob('*/SkeletalMesh3/*.psk'), None)
    psa = next(MACE.rglob('*.psa'), None)
    if psk is None or psa is None:
        raise FileNotFoundError(f'Missing Bone Crusher PSK/PSA export under {MACE}; see this module docstring')
    rig = Skeleton(read_chunks(psk)['REFSKELT'][2])
    anim = read_chunks(psa)
    tracks = [BONE.unpack(r)[0].rstrip(b'\0').decode() for r in anim['BONENAMES'][2]]
    infos = [INFO.unpack(r) for r in anim['ANIMINFO'][2]]
    idle = next(i for i in infos if i[0].rstrip(b'\0') == b'Idle')
    keys = anim['ANIMKEYS'][2]
    local_q, local_p = list(rig.local_q), list(rig.local_p)
    for i, name in enumerate(rig.names):
        if name in tracks:
            k = KEY.unpack(keys[idle[10] * idle[2] + tracks.index(name)])
            local_p[i] = tuple(k[:3])
            local_q[i] = tuple(k[3:7]) if i == 0 else qconj(tuple(k[3:7]))
    P, R = rig.world(local_q, local_p)
    rw = rig.index['RW_Weapon']
    wrist = rig.index['RightHand_1stP']
    inv = qconj(R[rw])
    return dict(wrist_p=qrot(inv, sub(P[wrist], P[rw])), wrist_q=qmul(inv, R[wrist]),
                fingers={n: local_q[rig.index[n]] for n in rig.names if n.startswith('RightHand') and n != 'RightHand_1stP'})


class Handle:
    """Measured elliptical cross-sections of the authored model along +Z."""

    def __init__(self, verts, step=0.5):
        verts = np.asarray(verts, dtype=float)
        self.z0 = float(verts[:, 2].min())
        self.step = step
        count = int(math.ceil((verts[:, 2].max() - self.z0) / step)) + 1
        slot = ((verts[:, 2] - self.z0) / step).astype(int)
        self.cx = np.zeros(count); self.cy = np.zeros(count); self.a = np.zeros(count); self.b = np.zeros(count)
        for i in range(count):
            s = verts[slot == i]
            if len(s) == 0:
                self.a[i] = self.b[i] = -1
                continue
            self.cx[i] = (s[:, 0].min() + s[:, 0].max()) / 2; self.a[i] = (s[:, 0].max() - s[:, 0].min()) / 2
            self.cy[i] = (s[:, 1].min() + s[:, 1].max()) / 2; self.b[i] = (s[:, 1].max() - s[:, 1].min()) / 2
        # Interpolate any empty slice from neighbours.
        for i in range(count):
            if self.a[i] < 0:
                j = next((k for k in range(i + 1, count) if self.a[k] >= 0), i - 1)
                self.cx[i], self.cy[i], self.a[i], self.b[i] = self.cx[j], self.cy[j], self.a[j], self.b[j]

    def distance(self, p):
        """Approximate signed distance (negative inside) for model-space points."""
        p = np.asarray(p, dtype=float)
        slot = ((p[:, 2] - self.z0) / self.step).astype(int)
        outside = (slot < 0) | (slot >= len(self.a))
        slot = np.clip(slot, 0, len(self.a) - 1)
        a = np.maximum(self.a[slot], 0.05); b = np.maximum(self.b[slot], 0.05)
        qx = (p[:, 0] - self.cx[slot]) / a; qy = (p[:, 1] - self.cy[slot]) / b
        d = (np.sqrt(qx*qx + qy*qy) - 1) * np.minimum(a, b)
        d[outside] = 1e3
        return d


class Hand:
    """VRFloatingHands skin; poses its skeleton and returns right-hand vertices."""

    def __init__(self):
        chunks = read_chunks(HANDS_PSK)
        self.skeleton = Skeleton(chunks['REFSKELT'][2])
        self.points = np.array([struct.unpack('<3f', r) for r in chunks['PNTS0000'][2]])
        weights = [struct.unpack('<fii', r) for r in chunks['RAWWEIGHTS'][2]]
        count = len(self.points)
        self.dominant = np.full(count, -1); best = np.zeros(count)
        self.influences = [[] for _ in range(count)]
        for w, point, bone in weights:
            self.influences[point].append((bone, w))
            if w > best[point]: best[point] = w; self.dominant[point] = bone
        names = self.skeleton.names
        right = [i for i, n in enumerate(names) if n.startswith('RightHand')]
        self.right = np.array([i for i in range(count) if self.dominant[i] in right])
        self.bone_of = self.dominant[self.right]
        rows, cols, vals = [], [], []
        for row, point in enumerate(self.right):
            for bone, w in self.influences[point]:
                rows.append(row); cols.append(bone); vals.append(w)
        self.weight = np.zeros((len(self.right), len(names)))
        self.weight[rows, cols] = vals
        self.bind_P, self.bind_R = self.skeleton.world()

    def skin(self, local_q):
        """Right-hand skin in component space for a pose (translations stay bind)."""
        P, R = self.skeleton.world(local_q)
        v = self.points[self.right]
        out = np.zeros_like(v)
        for bone in np.nonzero(self.weight.sum(axis=0))[0]:
            w = self.weight[:, bone:bone + 1]
            local = (v - np.array(self.bind_P[bone])) @ qmatrix(self.bind_R[bone])
            out += w * (local @ qmatrix(R[bone]).T + np.array(P[bone]))
        return out, P, R


def solve(model_verts):
    """Solve the grip for model_verts (authored tomahawk, grip origin, cm)."""
    mace = mace_idle()
    hand = Hand()
    sk = hand.skeleton
    local_q = list(sk.local_q)
    for name, q in mace['fingers'].items():
        local_q[sk.index[name]] = q
    handle = Handle(model_verts)
    wrist = sk.index['RightHand_1stP']
    P, R = sk.world(local_q)
    # RW_Weapon in component space: the authored wrist-to-weapon relation.
    rw_q = qmul(R[wrist], qconj(mace['wrist_q']))
    rw_p = sub(P[wrist], qrot(rw_q, mace['wrist_p']))
    inv = qconj(rw_q)
    to_rw = lambda pts: (np.asarray(pts) - np.array(rw_p)) @ qmatrix(rw_q)
    rw_of = lambda p: qrot(inv, sub(p, rw_p))
    knuckles = (rw_of(P[sk.index['RightHandIndex1_1stP']]), rw_of(P[sk.index['RightHandPinky1_1stP']]))
    offset = np.array((0.0, 0.0, (knuckles[0][2] + knuckles[1][2]) / 2 - FIST_CENTRE_Z))

    def clearance(q, subset=None):
        skin, _, _ = hand.skin(q)
        pts = to_rw(skin) - offset
        d = handle.distance(pts)
        return d if subset is None else d[subset]

    bones = hand.bone_of
    palm = np.isin(bones, [wrist])
    # Keep the palm clear: shift the handle away from the palm in RW XY.
    d = clearance(local_q)
    if d[palm].min() < GAP:
        best = None
        for dx in np.arange(-2.0, 2.01, 0.1):
            for dy in np.arange(-2.0, 2.01, 0.1):
                shifted = offset + (dx, dy, 0)
                skin, _, _ = hand.skin(local_q)
                m = handle.distance(to_rw(skin)[palm] - shifted).min()
                if m >= GAP and (best is None or dx*dx + dy*dy < best[0]):
                    best = (dx*dx + dy*dy, shifted)
        if best is None:
            raise ValueError('No palm-clear handle placement within 2 cm')
        offset = best[1]

    def chain(finger):
        return [sk.index[f'RightHand{finger}{j}_1stP'] for j in (1, 2, 3)]

    def descendants(bone):
        out = {bone}
        for i in range(bone + 1, len(sk.names)):
            if sk.parents[i] in out: out.add(i)
        return out

    report = {}
    for finger in FINGERS + ('Thumb',):
        joints = chain(finger)
        limit = THUMB_LIMIT if finger == 'Thumb' else LIMIT
        P, R = sk.world(local_q)
        a, b, c = (P[j] for j in chain(finger))
        axis_world = unit(cross(sub(b, a), sub(c, b)))
        masks = {j: np.isin(bones, list(descendants(j))) for j in joints}
        def turned(j, angle, q):
            _, Rw = sk.world(q)
            axis = qrot(qconj(Rw[j]), axis_world)
            q = list(q); q[j] = qmul(q[j], qaxis(axis, angle))
            return q
        # Orient the axis so a positive angle closes the finger on the handle.
        probe = turned(joints[-1], STEP * 4, local_q)
        tip = masks[joints[-1]]
        if clearance(probe, tip).mean() > clearance(local_q, tip).mean():
            axis_world = scale(axis_world, -1)
        angles = {j: 0.0 for j in joints}
        # Open any penetrating link, distal first, then proximal.
        for j in reversed(joints):
            while clearance(local_q, masks[j]).min() < GAP and angles[j] > -limit:
                local_q = turned(j, -STEP, local_q); angles[j] -= STEP
        for j in joints:
            while clearance(local_q, masks[j]).min() < GAP and angles[j] > -limit:
                local_q = turned(j, -STEP, local_q); angles[j] -= STEP
        # Close proximal-to-distal until each link and everything beyond it touches.
        moving = list(joints)
        while moving:
            for j in list(moving):
                trial = turned(j, STEP, local_q)
                if angles[j] + STEP > limit or clearance(trial, masks[j]).min() < GAP:
                    moving.remove(j)
                else:
                    local_q = trial; angles[j] += STEP
        report[finger] = {sk.names[j]: round(math.degrees(angles[j]), 1) for j in joints}

    d = clearance(local_q)
    links = {}
    for finger in FINGERS + ('Thumb',):
        for j in chain(finger):
            m = bones == j
            if m.any(): links[sk.names[j]] = round(float(d[m].min()), 3)
    links['RightHand_1stP'] = round(float(d[palm].min()), 3)
    P, R = sk.world(local_q)
    rw_q = qmul(R[wrist], qconj(mace['wrist_q']))
    rw_p = sub(P[wrist], qrot(rw_q, mace['wrist_p']))
    return dict(skeleton=sk, local_q=local_q, rw_q=rw_q, rw_p=rw_p, model_offset=tuple(float(x) for x in offset),
                closure_degrees=report, link_clearance_cm=links,
                penetrating_vertices=int((d < -0.02).sum()), max_penetration_cm=round(float(max(0.0, -d.min())), 3),
                wrist_in_weapon=dict(position=[round(x, 3) for x in mace['wrist_p']], rotation=[round(x, 5) for x in mace['wrist_q']]))


def rig_rows(result):
    """REFSKELT rows: VRFloatingHands bones in the solved pose plus RW_Weapon under Root."""
    sk = result['skeleton']
    local_q, local_p = list(result['local_q']), list(sk.local_p)
    P, R = sk.world(local_q, local_p)
    rows = sk.rows(local_q, local_p)
    rw_local_q = qmul(qconj(R[0]), result['rw_q'])
    rw_local_p = qrot(qconj(R[0]), sub(result['rw_p'], P[0]))
    # Root gains a child; rows() counts children from the original parents only.
    root = list(BONE.unpack(rows[0])); root[2] += 1; rows[0] = BONE.pack(*root)
    rows.append(BONE.pack(b'RW_Weapon', 0, 0, 0, *qconj(rw_local_q), *rw_local_p, *sk.extra[0]))
    return rows


def write_psk(rows, bone, point, path):
    """Skeleton-only PSK for Blender's importer: one tiny triangle on `bone`."""
    points = [point, add(point, (0.1, 0, 0)), add(point, (0, 0, 0.1))]
    chunks = [
        ('ACTRHEAD', 0, []),
        ('PNTS0000', 12, [struct.pack('<3f', *v) for v in points]),
        ('VTXW0000', 16, [struct.pack('<IffBBH', i, 0.0, 0.0, 0, 0, 0) for i in range(3)]),
        ('FACE0000', 12, [struct.pack('<3HBBI', 0, 1, 2, 0, 0, 1)]),
        ('MATT0000', 88, [struct.pack('<64s6i', b'Rig', 0, 0, 0, 0, 0, 0)]),
        ('REFSKELT', 120, rows),
        ('RAWWEIGHTS', 12, [struct.pack('<fii', 1.0, i, bone) for i in range(3)]),
    ]
    data = b''.join(HEADER.pack(name.encode(), 1999801 if name == 'ACTRHEAD' else 0, size, len(r)) + b''.join(r)
                    for name, size, r in chunks)
    Path(path).write_bytes(data)


def write_rig_psk(result, path):
    rows = rig_rows(result)
    write_psk(rows, len(rows) - 1, result['rw_p'], path)


def write_weapon_bone_psk(result, path):
    """A lone RW_Weapon root at the origin: the third-person attachment skeleton."""
    extra = result['skeleton'].extra[0]
    write_psk([BONE.pack(b'RW_Weapon', 0, 0, 0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, *extra)], 0, (0.0, 0.0, 0.0), path)


if __name__ == '__main__':
    import json
    import sys
    source = json.loads(Path(sys.argv[1]).read_text())
    verts = np.array(source['v']) * float(sys.argv[2] if len(sys.argv) > 2 else 1.0)
    result = solve(verts)
    print(json.dumps({k: v for k, v in result.items() if k not in ('skeleton', 'local_q')}, indent=1, default=str))
