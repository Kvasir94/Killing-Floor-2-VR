"""Glove-only forearm termination for a staged runtime hand (Blender).

Run inside Blender with KF2VR_ART_REVISION=<new> and KF2VR_BASE_REVISION=<old>.
The base revision's runtime folder is copied without its Blender scenes, then
only the PSK's point positions and cap wedges change: forearm skin beyond the
cut folds forward into a shallow recessed bowl inside the glove cuff (right
hand) or under the watch strap (left hand). The bowl samples one charcoal
glove texel, so the cuff reads as a dark opening instead of a cut-off nub.
Skeleton, weights, faces and every other wedge are preserved; no triangles,
bones or material passes are added. The FBX is regenerated from the PSK.
"""
import hashlib, json, math, os, runpy, shutil, struct
from pathlib import Path
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'build/watch-detail-20260924'
# Axial cut in cm from the wrist bone toward the fingers. The right cut follows
# the glove's own cuff edge per angle; the left one sits just inside the far
# end of the watch strap (the runtime watch spans about -11..3 cm).
RIGHT_TUCK_CM = 0.35
LEFT_CUT_CM = -9.5
BOWL_DEPTH_CM = 1.2
SECTORS = 24


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def shells(points, wedges, faces):
    parent = list(range(len(points)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for face in faces:
        a = wedges[face[0]][0]
        for i in face[1:3]:
            ra, rb = find(a), find(wedges[i][0])
            if ra != rb:
                parent[rb] = ra
    return [find(i) for i in range(len(points))]


def trim(base, out):
    g = runpy.run_path(str(ROOT / 'tools/generate_floating_hands.py'), run_name='asset_source')
    chunks = g['read_psk'](out / 'VRFloatingHands.psk')
    points, wedges, faces, weights = g['decode_geometry'](chunks)
    bones, names = g['bone_data'](chunks)
    bind = g['bind_positions'](bones)
    shell = shells(points, wedges, faces)
    dom = [max(w, key=w.get) for w in weights]
    new_points = [Vector(p) for p in points]
    cap_points, report = set(), {}
    for side in ('Left', 'Right'):
        mine = {i for i, n in enumerate(names) if n.startswith(side)}
        origin = bind[names.index(side + 'Hand_1stP')]
        f = (bind[names.index(side + 'HandMiddle1_1stP')] - origin).normalized()
        axial = lambda p: (Vector(p) - origin).dot(f)
        members = {}
        for p in range(len(points)):
            if dom[p] in mine:
                members.setdefault(shell[p], []).append(p)
        skin = max((s for s in members if min(axial(points[p]) for p in members[s]) < -5),
                   key=lambda s: len(members[s]))
        glove = max((s for s in members if s != skin), key=lambda s: len(members[s]))
        forearm = [p for p in members[skin] if axial(points[p]) < 0]
        # Forearm centre line from the skin rings, so the fold stays centred
        # on the arm rather than on the hand's own axis.
        rings = {}
        for p in forearm:
            rings.setdefault(round(axial(points[p])), []).append(Vector(points[p]))
        keys = sorted(rings)
        near, far = rings[keys[-1]], rings[keys[0]]
        c_near = sum(near, Vector()) / len(near)
        c_far = sum(far, Vector()) / len(far)
        a = (c_near - c_far).normalized()
        if a.dot(f) < 0:
            a = -a
        ref = a.orthogonal().normalized()
        side_ref = a.cross(ref)

        def sector(p):
            r = Vector(p) - c_near
            r -= a * r.dot(a)
            return int((math.atan2(r.dot(side_ref), r.dot(ref)) + math.pi) / (2 * math.pi) * SECTORS) % SECTORS

        def along(p):
            return (Vector(p) - c_near).dot(a)
        if side == 'Right':
            cuff = [math.inf] * SECTORS
            for p in members[glove]:
                s = sector(points[p])
                cuff[s] = min(cuff[s], along(points[p]))
            finite = [c for c in cuff if c < math.inf]
            cuff = [c if c < math.inf else min(finite) for c in cuff]
            cut = [c + RIGHT_TUCK_CM for c in cuff]
        else:
            offset = along(origin + f * LEFT_CUT_CM)
            cut = [offset] * SECTORS
        moved = [p for p in members[skin] if along(points[p]) < cut[sector(points[p])]]
        deepest = min(along(points[p]) for p in moved)
        for p in moved:
            q = Vector(points[p])
            s = along(q)
            c = cut[sector(q)]
            t = min(1.0, (c - s) / max(0.001, c - deepest))
            centre = c_near + a * s
            radial = q - centre
            radial -= a * radial.dot(a)
            angle = t * math.pi / 2
            new_points[p] = c_near + a * (c + BOWL_DEPTH_CM * math.sin(angle)) + radial * math.cos(angle)
            cap_points.add(p)
        report[side] = {'moved_points': len(moved), 'cut_cm': [round(c, 3) for c in (min(cut), max(cut))],
                        'removed_forearm_length_cm': round(min(cut) - deepest, 3),
                        'skin_shell_points': len(members[skin]), 'glove_shell_points': len(members[glove])}
    return chunks, points, wedges, faces, new_points, cap_points, shell, report, g


def cap_texel(g, chunks, wedges, faces, shell, points):
    # The largest-UV-area face of the left glove shell: interior charcoal.
    from collections import Counter
    _, names = g['bone_data'](chunks)
    counts = Counter(shell[wedges[f[0]][0]] for f in faces)
    skin_or_glove = [s for s, _ in counts.most_common(4)]
    best, area = None, -1
    for face in faces:
        if shell[wedges[face[0]][0]] not in skin_or_glove[2:4]:
            continue
        (u0, v0), (u1, v1), (u2, v2) = ((wedges[i][1], wedges[i][2]) for i in face[:3])
        a = abs((u1 - u0) * (v2 - v0) - (u2 - u0) * (v1 - v0))
        if a > area:
            area, best = a, ((u0 + u1 + u2) / 3, (v0 + v1 + v2) / 3)
    return best


def main():
    new, old = os.environ['KF2VR_ART_REVISION'], os.environ['KF2VR_BASE_REVISION']
    base, out = ART / old / 'runtime', ART / new / 'runtime'
    if (out / 'forearm-trim.json').exists():
        raise RuntimeError('This candidate was already trimmed; preserve it and start a new version.')
    out.mkdir(parents=True, exist_ok=True)
    for p in base.iterdir():
        # The hand roundtrip describes the base FBX; it is regenerated for this one.
        if p.is_file() and p.suffix.lower() in {'.fbx', '.psk', '.tga', '.json'} and p.name != 'hand-fbx-roundtrip.json':
            shutil.copy2(p, out / p.name)
    chunks, points, wedges, faces, new_points, cap, shell, report, g = trim(base, out)
    u, v = cap_texel(g, chunks, wedges, faces, shell, points)
    preserved = {k: hashlib.sha256(b''.join(c.rows)).hexdigest() for k, c in chunks.items()
                 if k not in ('PNTS0000', 'VTXW0000', 'FACE0000')}
    chunks['PNTS0000'].rows = [struct.pack('<3f', *p) for p in new_points]
    # Faces wholly inside the fold sample the glove texel through new wedges;
    # faces that straddle the rim keep their skin UVs so no triangle spans
    # two distant atlas islands.
    wedge_rows = list(chunks['VTXW0000'].rows)
    face_rows, capped, cap_wedge = [], 0, {}
    for row in chunks['FACE0000'].rows:
        face = g['FACE'].unpack(row)
        ids = [wedges[i][0] for i in face[:3]]
        if all(p in cap for p in ids):
            new_ids = []
            for i in face[:3]:
                point, _, _, material, r1, r2 = wedges[i]
                key = (point, material)
                if key not in cap_wedge:
                    cap_wedge[key] = len(wedge_rows)
                    wedge_rows.append(g['WEDGE'].pack(point, u, v, material, r1, r2))
                new_ids.append(cap_wedge[key])
            face = (*new_ids, *face[3:])
            capped += 1
        face_rows.append(g['FACE'].pack(*face))
    if len(wedge_rows) > 65535:
        raise RuntimeError('Cap wedges exceed the 16-bit ActorX face index range')
    chunks['VTXW0000'].rows = wedge_rows
    chunks['FACE0000'].rows = face_rows
    psk = out / 'VRFloatingHands.psk'
    psk.write_bytes(b''.join(c.encode() for c in chunks.values()))
    check = g['read_psk'](psk)
    assert preserved == {k: hashlib.sha256(b''.join(c.rows)).hexdigest() for k, c in check.items()
                         if k not in ('PNTS0000', 'VTXW0000', 'FACE0000')}
    assert len(check['FACE0000'].rows) == len(faces)
    export = g['export_fbx'](psk, out / 'VRFloatingHands.fbx')
    result = {'change': 'Glove-only forearm: fold forearm skin into a recessed dark cap inside the cuff/strap',
              'base_revision': int(old), 'sides': report, 'cap_faces': capped, 'cap_wedges_added': len(cap_wedge),
              'cap_uv': [u, v], 'triangles': len(faces), 'triangles_added': 0, 'draw_calls_added': 0,
              'preserved_chunks_sha256': preserved, 'psk_sha256': digest(psk),
              'fbx_sha256': digest(out / 'VRFloatingHands.fbx'), **export}
    (out / 'forearm-trim.json').write_text(json.dumps(result, indent=2))
    return result


if __name__ == '__main__':
    print('HAND_FOREARM_TRIMMED', json.dumps(main()), flush=True)
