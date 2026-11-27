"""Stock reload choreography of a KF2 weapon, read from its cooked AnimSet
notifies and the UModel PSK/PSA exports under build/*-audit (read-only; no
game, editor or Blender).

    python tools/re/stock_reload_timeline.py Class [Class ...]
        [--clips Reload_Empty,Shoot] [--bones RW_Pump,RW_Bolt] [--top] [--thresh 4]

For each Reload* clip (or the named clips): the notify timeline, then the
spans in which each RW_ part's origin moves in the gun's frame, with its
travel, net displacement and the nearest hand bone. --top drops parts that
only ride a moving parent. A part that only rotates about its own origin (a
hinge, a hammer) shows no span; read those from the notifies.

Used for the 2026-11-09 physical reload audit (stock step order per gun) and
the crossbow ruling R63. render_reload_strip.py draws the same clips.
"""
import argparse
import glob
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import reload_sound_map as rsm  # noqa: E402


class AnyReload:
    def __contains__(self, name):
        return isinstance(name, str) and (name.startswith('Reload') or name.startswith('Shoot'))


rsm.CLIPS = AnyReload()

_files = {}


def exported(folder, ext):
    key = (folder, ext)
    if key not in _files:
        hits = []
        for pat in ('build/*/export/*/%s/*%s', 'build/*/*/*/%s/*%s', 'build/*/*/%s/*%s'):
            hits += glob.glob(str(ROOT / (pat % (folder, ext))))
        _files[key] = tuple(Path(p) for p in hits)
    return _files[key]


rsm.exported_files = exported


def inputs(cls):
    animset = rsm.class_value(cls, r'FirstPersonAnimSetNames\(0\)')
    mesh = rsm.class_value(cls, r'FirstPersonMeshName')
    pkg_name, set_name = animset.split('.')
    pkg = rsm.find_ci(rsm.WEAPONS, pkg_name + '.upk')[0]
    mesh_name = mesh.split('.')[-1]
    psk = next((f for f in exported('SkeletalMesh3', '.psk') if f.name.lower() == mesh_name.lower() + '.psk'), None)
    psa = next((f for f in exported('AnimSet', '.psa')
                if f.name.lower() == set_name.lower() + '.psa'
                and f.parent.parent.name.lower() == pkg_name.lower()), None)
    if psa is None:
        psa = next((f for f in exported('AnimSet', '.psa') if f.name.lower() == set_name.lower() + '.psa'), None)
    return rsm.Package(pkg), set_name, psk, psa


def spans(motion, clip, length, step, thresh):
    """{bone: [(t0, t1, travel, hand, handdist)]} for RW_ bones moving in the weapon frame."""
    n = max(2, int(length / step) + 1)
    times = [length * i / (n - 1) for i in range(n)]
    poses = [motion.pose(clip, t, length) for t in times]
    hands = [h for h in ('LeftHand_1stP', 'RightHand_1stP', 'LeftHand', 'RightHand') if h in poses[0]]
    out = {}
    for bone in poses[0]:
        if not (bone.startswith('RW_') or bone.startswith('LW_')) or bone == 'RW_Weapon':
            continue
        cur = None
        for i in range(1, n):
            d = rsm.dist(poses[i][bone], poses[i - 1][bone])
            moving = d / (times[i] - times[i - 1]) > thresh
            if moving:
                if cur is None:
                    cur = [times[i - 1], times[i], 0.0, i - 1]
                cur[1] = times[i]
                cur[2] += d
            if (not moving or i == n - 1) and cur is not None:
                if cur[2] > 0.8:
                    mid = poses[(cur[3] + i) // 2]
                    best = min(((rsm.dist(mid[h], mid[bone]), h) for h in hands), default=(0, '?'))
                    net = rsm.dist(poses[cur[3]][bone], poses[i if moving else i - 1][bone])
                    out.setdefault(bone, []).append((cur[0], cur[1], cur[2], net, best[1], best[0]))
                cur = None
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('classes', nargs='+')
    ap.add_argument('--clips', default='')
    ap.add_argument('--step', type=float, default=0.05)
    ap.add_argument('--thresh', type=float, default=4.0)
    ap.add_argument('--bones', default='')
    ap.add_argument('--top', action='store_true')
    args = ap.parse_args()
    want = set(c for c in args.clips.split(',') if c)
    only = set(b for b in args.bones.split(',') if b)
    for cls in args.classes:
        try:
            pkg, set_name, psk, psa = inputs(cls)
        except Exception as e:  # noqa: BLE001
            print(f'=== {cls}: {e!r}')
            continue
        print(f'=== {cls} set={set_name} psk={psk is not None} psa={psa is not None}')
        if not (psk and psa):
            continue
        motion = rsm.Motion(psk, psa)
        clips = rsm.read_clips(pkg, set_name)
        for clip in sorted(clips):
            if want and clip not in want:
                continue
            if not want and not clip.startswith('Reload'):
                continue
            data = clips[clip]
            if clip not in motion.infos:
                print(f'  -- {clip}: not in PSA')
                continue
            print(f'  -- {clip} len={data["length"]:.3f} rate={data["rate"]:.2f}')
            for t, kind, detail, props in data['notifies']:
                if kind in ('KFAnimNotify_CameraAnim',):
                    continue
                label = detail.split('.')[-1] if kind == 'AnimNotify_AkEvent' else f'{kind}:{detail}'
                print(f'     {t:6.3f} {label}')
            sp = spans(motion, clip, data['length'], args.step, args.thresh)
            rows = []
            for bone, lst in sp.items():
                if only and bone not in only:
                    continue
                for (a, b, travel, net, hand, hd) in lst:
                    rows.append((a, b, bone, travel, net, hand, hd))
            if args.top:
                parent = {b['name']: motion.bones[b['parent_index']]['name'] for b in motion.bones}
                def covered(bone, a, b):
                    q = parent.get(bone)
                    seen = set()
                    while q and q not in seen and q != 'RW_Weapon':
                        seen.add(q)
                        for (a2, b2, tr2, net2, h2, hd2) in sp.get(q, []):
                            if a2 <= a + 0.11 and b2 >= b - 0.11:
                                return True
                        q = parent.get(q)
                    return False
                rows = [r for r in rows if not covered(r[2], r[0], r[1])]
            for a, b, bone, travel, net, hand, hd in sorted(rows):
                print(f'       {a:5.2f}-{b:5.2f} {bone:26s} travel={travel:6.1f} net={net:6.1f} hand={hand.replace("_1stP","")}@{hd:4.1f}')


if __name__ == '__main__':
    main()
