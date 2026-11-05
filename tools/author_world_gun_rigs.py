"""Author the one-frame world gun table from the stock first-person rigs.

A dropped or thrown gun keeps its stock pickup body and art; its first-person
rig frame (the profile root bone, usually RW_Weapon, at Idle frame 0) sits in
that body by the mapping tools/fit_pickup_frames.py fits. For every profiled
firearm this reads the stock rig (PSK) and its Idle clip (PSA), poses it as the
shared world visual does, and writes, in that root frame:

- the primary and support wrists, the same stock Idle contacts the held
  presenter uses, which become the catch zones;
- the fitted pickup mapping (build/world-gun-rigs/pickup-fits.json);
- the reload-only parts Idle parks off the gun, hidden on the world visual;
- the convex hull of the weapon vertices with blade zones from
  tools/world-weapon-regions.json "rig_profiles", which SharpAt answers
  through the native catalog (tools/author_weapon_block_surfaces.py --rigs).

The table needs no first-person mesh at runtime, so the dedicated server uses
it as is. Reads offline UModel exports (PSK/PSA) of the stock packages, e.g.
build/shared-weapon-frames/held-export, and the installed class sources.
"""
import argparse
import json
import re
import struct
import sys
from pathlib import Path

import numpy as np

ROOT = next(p for p in Path(__file__).resolve().parents if (p / 'AGENTS.md').is_file())
sys.path[:0] = [str(ROOT / 'tools'), str(ROOT / 'tools/re')]
from audit_flamethrower_assets import chunks, parse_bones, INFO, KEY, ctext
from audit_stock_gun_assets import global_pose
from audit_m14_assets import rotate, conj
from author_world_weapon_surfaces import author_sharp

WEIGHT = struct.Struct('<fii')
RELOAD_PART = re.compile(r'Magazine\d|Speedloader|StripMag|Shell\d|Cylinder\d|Notes\d')
WEDGE = struct.Struct('<IffBBH')
FACE = struct.Struct('<3HBBI')


# Guns whose world drop keeps its stock pickup art: the G18's pickup carries
# the riot shield, which its first-person rig does not draw.
STOCK_ART = {'KFWeap_SMG_G18'}

# The exported PSK/PSA (UE Viewer, ActorX) are the engine's meshes mirrored in
# Y, and so is every root-frame coordinate read from them: the right wrist
# came out on the gun's left, and 72 of 100 stock pickups (decoded in engine
# space, matching their stored bounds) fit their rig better mirrored and none
# worse. Root-frame results are flipped back once here.
ENGINE = np.array([1.0, -1.0, 1.0])

def profiles():
    """Firearm profiles from VRHandsBridge: class, root bone, idle clip, primary side."""
    text = (ROOT / 'script/KF2VR/Classes/VRHandsBridge.uc').read_text()
    result = {}
    for line in re.findall(r'WeaponProfiles\(\d+\)=\((.+)\)\s*$', text, re.M):
        fields = dict(re.findall(r'(\w+)=("[^"]*"|\([^)]*\)|[^,]+)', line))
        if fields.get('bFirearm') != 'true' or fields.get('bPhysicalDualGauntlets') == 'true':
            continue
        result.setdefault(fields['WeaponClassName'], dict(
            root=fields.get('RootBone', 'RW_Weapon'), idle=fields.get('IdleAnimation', 'Idle'),
            left_primary=fields.get('bLeftHandPrimary') == 'true',
            bore_rotation=tuple(int(dict(re.findall(r'(\w+)=(-?\d+)', fields.get('BoreRotation', '()'))).get(k, 0))
                                for k in ('Pitch', 'Yaw', 'Roll')),
            one_handed=fields.get('bOneHanded') == 'true'))
    return result


def class_assets(game_root):
    """FirstPersonMeshName and FirstPersonAnimSetNames, following inheritance."""
    sources = {p.stem: p.read_text(errors='replace')
               for p in (game_root / 'Development/Src/KFGameContent/Classes').glob('KFWeap_*.uc')}

    def lookup(name, pattern, seen=()):
        text = sources.get(name)
        if text is None or name in seen:
            return []
        found = re.findall(pattern, text, re.I | re.M)
        if found:
            return found
        parent = re.search(r'\bextends\s+(\w+)', text, re.I)
        return lookup(parent[1], pattern, seen + (name,)) if parent else []

    def assets(name):
        mesh = lookup(name, r'^\s*FirstPersonMeshName\s*=\s*"([^"]+)"')
        anims = lookup(name, r'^\s*FirstPersonAnimSetNames\(\d+\)\s*=\s*"([^"]+)"')
        return (mesh[0] if mesh else None), anims
    return assets


def idle_pose(bones, psa_paths, idle):
    """Global bone pose at the clip's first frame (VRSharedWeaponVisual.Idle)."""
    for path in psa_paths:
        ac = chunks(path)
        info = next((x for x in INFO.iter_unpack(ac['ANIMINFO'][2]) if ctext(x[0]).lower() == idle.lower()), None)
        if info is None:
            continue
        tracks = {b['name']: i for i, b in enumerate(parse_bones(ac['BONENAMES']))}
        local = []
        for bone in bones:
            if bone['name'] in tracks:
                k = KEY.unpack_from(ac['ANIMKEYS'][2], (info[10] * info[2] + tracks[bone['name']]) * KEY.size)
                local.append((k[:3], k[3:7]))
            else:
                local.append((bone['local_position'], bone['local_quaternion']))
        return global_pose(bones, local)
    raise ValueError(f'no {idle} clip')


def weapon_points(psk, bones, pose, root, with_ids=False, receiver_only=False):
    """Weapon-only vertices skinned to the Idle pose, in the posed root frame
    (with_ids also returns each kept vertex's PSK point index)."""
    c = chunks(psk)
    keep = {root}
    for i, b in enumerate(bones):
        if i and b['parent_index'] in keep:
            keep.add(i)
    bind = global_pose(bones, [(b['local_position'], b['local_quaternion']) for b in bones])
    points = np.array(list(struct.iter_unpack('<3f', c['PNTS0000'][2])))
    weights = {}
    for weight, vertex, bone in WEIGHT.iter_unpack(c['RAWWEIGHTS'][2]):
        weights.setdefault(vertex, []).append((weight, bone))
    used = set()
    for wedge in WEDGE.iter_unpack(c['VTXW0000'][2]):
        used.add(wedge[0])
    groups, ids = {}, {}
    for vertex in sorted(used):
        influences = weights.get(vertex, [])
        total = sum(w for w, b in influences)
        weapon = sum(w for w, b in influences if b in keep)
        # A vertex belongs to the gun when the gun's bones carry most of it.
        if total <= 0 or weapon < 0.5 * total:
            continue
        posed = np.zeros(3)
        for w, b in influences:
            if b not in keep:
                continue
            local = rotate(conj(bind[1][b]), points[vertex] - np.array(bind[0][b]))
            posed += (w / weapon) * (np.array(pose[0][b]) + np.array(rotate(pose[1][b], local)))
        dominant = max((x for x in influences if x[1] in keep), key=lambda x: x[0])[1]
        groups.setdefault(dominant, []).append(ENGINE * rotate(conj(pose[1][root]), posed - np.array(pose[0][root])))
        ids.setdefault(dominant, []).append(vertex)
    if sum(len(g) for g in groups.values()) < 8:
        raise ValueError('no weapon geometry')
    # Idle parks reload-only parts (a spare magazine, speedloader or shell)
    # out of the first-person view, away from the gun. Drop such a part only
    # when it touches nothing grown from the root bone's own geometry; other
    # separate pieces (cables, emitter arms, a muzzle) are the visible gun.
    groups = {b: np.array(g) for b, g in groups.items()}
    boxes = {b: (g.min(0) - 1.5, g.max(0) + 1.5) for b, g in groups.items()}
    attached = {root if root in groups else max(groups, key=lambda b: len(groups[b]))}
    grown = True
    while grown:
        grown = False
        for b, (low, high) in boxes.items():
            if b not in attached and any(np.all(low <= boxes[a][1]) and np.all(boxes[a][0] <= high) for a in attached):
                attached.add(b)
                grown = True
    parts = {b for b in groups if b not in attached and RELOAD_PART.search(bones[b]['name'])}
    detached = {b for b in groups if b in parts or any(a in parts for a in ancestors(bones, b, root))}
    if detached & attached:
        raise ValueError('a reload part carries attached geometry')
    attached = set(groups) - detached
    hidden = sorted(bones[b]['name'] for b in parts if not any(a in parts for a in ancestors(bones, b, root)))
    if receiver_only:
        # The rigid receiver alone: moving parts (barrels, pumps, cylinders,
        # bolts) can sit anywhere on their travel in the Idle frame.
        if root not in groups:
            return (None, []) if with_ids else None
        return (groups[root], ids[root]) if with_ids else groups[root]
    points = np.concatenate([groups[b] for b in sorted(attached)])
    if with_ids:
        return points, hidden, [v for b in sorted(attached) for v in ids[b]]
    return points, hidden


def ancestors(bones, bone, root):
    result, parent = [], bones[bone]['parent_index']
    while parent != root and parent != 0:
        result.append(parent)
        parent = bones[parent]['parent_index']
    return result


def hull(points):
    """Exact 3D convex hull (quickhull); outward-wound triangles over hull vertices."""
    p = np.unique(np.round(points, 4), axis=0)
    span = np.ptp(p, axis=0).max()
    eps = max(span * 1e-7, 1e-6)
    a, b = int(p[:, 0].argmin()), int(p[:, 0].argmax())
    line = p[b] - p[a]
    c = int(np.linalg.norm(np.cross(p - p[a], line), axis=1).argmax())
    normal = np.cross(p[b] - p[a], p[c] - p[a])
    d = int(np.abs((p - p[a]) @ normal).argmax())
    if abs((p[d] - p[a]) @ normal) <= eps:
        raise ValueError('flat weapon geometry')
    centre = p[[a, b, c, d]].mean(0)
    faces = []

    def make(i, j, k):
        n = np.cross(p[j] - p[i], p[k] - p[i])
        if n @ (p[i] - centre) < 0:
            j, k = k, j
            n = -n
        length = np.linalg.norm(n)
        return [i, j, k, n / length if length > 0 else n]

    for i, j, k in ((a, b, c), (a, b, d), (a, c, d), (b, c, d)):
        faces.append(make(i, j, k))
    candidates = np.arange(len(p))
    outside = []
    for f in faces:
        dist = (p[candidates] - p[f[0]]) @ f[3]
        outside.append(candidates[dist > eps])
    while True:
        index = next((i for i, o in enumerate(outside) if len(o)), None)
        if index is None:
            break
        f = faces[index]
        far = int(outside[index][((p[outside[index]] - p[f[0]]) @ f[3]).argmax()])
        visible = [i for i, g in enumerate(faces) if (p[far] - p[g[0]]) @ g[3] > eps]
        edges = set()
        for i in visible:
            g = faces[i]
            for e in ((g[0], g[1]), (g[1], g[2]), (g[2], g[0])):
                edges.add(e)
        horizon = [e for e in edges if (e[1], e[0]) not in edges]
        pool = np.unique(np.concatenate([outside[i] for i in visible]))
        pool = pool[pool != far]
        for i in sorted(visible, reverse=True):
            del faces[i]
            del outside[i]
        for u, v in horizon:
            g = [u, v, far]
            n = np.cross(p[v] - p[u], p[far] - p[u])
            g.append(n / max(np.linalg.norm(n), 1e-12))
            dist = (p[pool] - p[u]) @ g[3] if len(pool) else np.zeros(0)
            mine = pool[dist > eps]
            pool = pool[dist <= eps]
            faces.append(g)
            outside.append(mine)
    used = sorted({i for f in faces for i in f[:3]})
    remap = {old: new for new, old in enumerate(used)}
    return p[used], [[remap[i] for i in f[:3]] for f in faces]


def sharp_regions(surface, points, configs):
    """Blade zones in the rig frame. A dict is author_sharp on the contact hull
    (pickup-surface style); a list may add "edge_points" runs traced over the
    real weapon vertices, for edges the hull does not reach (bow limb blades)."""
    if isinstance(configs, dict):
        author_sharp(surface, configs)
        return
    sharp = dict(tip_radius=0, tip_axis=[0, 0, 0], edge_radius=0.25, edge_min_z=-10000, edge_polylines=[])
    for config in configs:
        if config.get('kind') != 'edge_points':
            author_sharp(surface, config)
            found = surface['metadata']['sharp_regions']
            sharp['edge_polylines'] += found.get('edge_polylines', [])
            if 'tip' in found and 'tip' not in sharp:
                sharp.update(tip=found['tip'], tip_axis=found['tip_axis'], tip_radius=found['tip_radius'])
            continue
        mask = np.ones(len(points), dtype=bool)
        for axis, low, high in config['bounds']:
            mask &= (points[:, axis] >= low) & (points[:, axis] <= high)
        region = points[mask]
        if len(region) < 4:
            raise ValueError(f"edge_points region is empty: {config['bounds']}")
        along, across = config['along'], config['across']
        edges = np.linspace(region[:, along].min(), region[:, along].max(), config.get('steps', 16) + 1)
        for side in config['sides']:
            line = []
            for a, b in zip(edges, edges[1:]):
                part = region[(region[:, along] >= a) & (region[:, along] <= b)]
                if len(part):
                    line.append(part[part[:, across].argmax() if side > 0 else part[:, across].argmin()].tolist())
            if len(line) >= 2:
                sharp['edge_polylines'].append(dict(points=line))
        if config.get('tip'):
            tip = region[region[:, along].argmax()]
            sharp.update(tip=tip.tolist(), tip_axis=config['tip_axis'], tip_radius=0.75)
    surface['metadata']['sharp_regions'] = sharp
    surface['metadata']['sharp_authoring'] = 'Rig-frame zones: hull outlines and real weapon vertex runs.'


def author(name, profile, assets, exports, animations, regions, fits):
    mesh_name, anims = assets(name)
    if not mesh_name or not anims:
        raise ValueError('no first-person mesh or animations in the class source')
    psk = exports.get(mesh_name.split('.')[-1].lower())
    if psk is None:
        raise ValueError(f'no export of {mesh_name}')
    psas = [animations[a.split('.')[-1].lower()] for a in anims if a.split('.')[-1].lower() in animations]
    bones = parse_bones(chunks(psk)['REFSKELT'])
    index = {b['name']: i for i, b in enumerate(bones)}
    root = index.get(profile['root'])
    if root is None or 'RightHand_1stP' not in index or 'LeftHand_1stP' not in index:
        raise ValueError('rig lacks the profile root or a wrist')
    pose = idle_pose(bones, psas, profile['idle'])
    points, hidden = weapon_points(psk, bones, pose, root)

    def wrist(bone):
        return ENGINE * rotate(conj(pose[1][root]), np.array(pose[0][index[bone]]) - np.array(pose[0][root]))
    right, left = wrist('RightHand_1stP'), wrist('LeftHand_1stP')
    # The quickhull is tuned on the exported (mirrored) cloud; hull that and
    # mirror the result, flipping the winding so faces stay outward.
    vertices, triangles = hull(points * ENGINE)
    vertices = vertices * ENGINE
    triangles = [[t[0], t[2], t[1]] for t in triangles]
    surface = dict(metadata=dict(weapon=name, mesh=mesh_name, rig_weapon=name, frame=profile['root'] + ' at Idle frame 0',
                                 sha256=__import__('hashlib').sha256(psk.read_bytes()).hexdigest(),
                                 approximation='convex hull of the weapon-only Idle vertices'),
                   vertices=vertices.tolist(), triangles=triangles,
                   original_faces=[-1] * len(triangles), face_regions=[0] * len(triangles))
    if name in regions:
        sharp_regions(surface, points, regions[name])
    fit = fits.get(name, {})
    if 'rotation' not in fit:
        raise ValueError('no fitted stock pickup mapping')
    axes = np.array(fit['rotation'])
    return dict(weapon=name, mesh=mesh_name, root=profile['root'],
                pickup_mesh=fit['pickup_mesh'], pickup_origin=fit['origin'],
                pickup_axes=[(fit['scale'] * axes[:, i]).tolist() for i in range(3)],
                primary=(left if profile['left_primary'] else right).tolist(),
                support=(right if profile['left_primary'] else left).tolist(),
                left_primary=profile['left_primary'], support_grip=not profile['one_handed'],
                sharp_zones=name in regions, stock_art=name in STOCK_ART,
                hidden=hidden, hull_triangles=len(triangles)), surface


def vec(v):
    return '(X=%s,Y=%s,Z=%s)' % tuple(('%.4f' % x).rstrip('0').rstrip('.') for x in v)


def vec6(v):
    return '(X=%s,Y=%s,Z=%s)' % tuple(('%.6f' % x).rstrip('0').rstrip('.') for x in v)


def write_script(rows, path):
    lines = [
        '// Generated by tools/author_world_gun_rigs.py from the stock first-person rigs.',
        '// One frame per world gun: the profile root bone at Idle frame 0, placed in',
        '// the stock pickup mesh PickupMesh at PickupOrigin with axes PickupX/Y/Z one',
        '// rig unit long (pickup local, tools/fit_pickup_frames.py; a pickup modelled',
        '// at another size has longer or shorter axes). Primary and Support are the',
        '// stock Idle wrists in the rig frame (Primary authored on the right hand',
        '// unless bLeftPrimary); a one-handed gun has no support catch.',
        'class VRWorldGunRigs extends Object;',
        '',
        'struct GunRig',
        '{',
        '    var name Weapon;',
        '    var name PickupMesh;',
        '    var vector PickupOrigin, PickupX, PickupY, PickupZ, Primary, Support;',
        '    // bStockArt: the world gun shows its stock pickup art, not the rig.',
        '    var bool bLeftPrimary, bSupportGrip, bSharpZones, bStockArt;',
        '    // Reload-only parts that Idle parks away from the gun; never shown.',
        '    var array<name> Hidden;',
        '};',
        'var array<GunRig> Rigs;',
        '// NativeSharpAt mailbox on a short-lived query object.',
        'var transient int SharpResult;',
        '',
        '// The blade zone at a point in the root frame of this rig: 0 blunt, 1 edge, 2 tip.',
        '// Zones come from tools/world-weapon-regions.json rig_profiles; Slack widens',
        '// them (UU) for a contact that is not exactly on the surface.',
        'static function int SharpAt(name Weapon, vector LocalPoint, optional float Slack)',
        '{',
        '    local int Geometry;',
        '    local VRWorldGunRigs Query;',
        "    Geometry = class'VRWeaponBlockSurfaceIds'.static.GetRig(Weapon);",
        '    if (Geometry <= 0) return 0;',
        "    Query = new class'VRWorldGunRigs';",
        '    Query.NativeSharpAt(Geometry, LocalPoint, FMax(Slack, 0));',
        '    return Query.SharpResult;',
        '}',
        '',
        'function NativeSharpAt(int Geometry, vector LocalPoint, float Slack) {}',
        '',
        'static function int Find(class<Inventory> ItemClass)',
        '{',
        '    local class<KFWeapon> W;',
        '    local int I;',
        '    W = class<KFWeapon>(ItemClass);',
        '    if (W == None) return -1;',
        "    W = class'VRReloadCatalog'.static.ProfileClass(W);",
        '    if (W == None) return -1;',
        '    for (I = 0; I < default.Rigs.Length; ++I)',
        '        if (default.Rigs[I].Weapon == W.Name) return I;',
        '    return -1;',
        '}',
        '',
        'defaultproperties',
        '{',
    ]
    for i, r in enumerate(rows):
        x, y, z = r['pickup_axes']
        lines.append(f"    Rigs({i})=(Weapon={r['weapon']},PickupMesh={r['pickup_mesh']},"
                     f"PickupOrigin={vec(r['pickup_origin'])},PickupX={vec6(x)},PickupY={vec6(y)},PickupZ={vec6(z)},"
                     f"Primary={vec(r['primary'])},Support={vec(r['support'])}"
                     + (',bLeftPrimary=true' if r['left_primary'] else '')
                     + (',bSupportGrip=true' if r['support_grip'] else '')
                     + (',bSharpZones=true' if r['sharp_zones'] else '')
                     + (',bStockArt=true' if r['stock_art'] else '')
                     + ''.join(f",Hidden({j})={b}" for j, b in enumerate(r['hidden'])) + ')')
    lines.append('}')
    path.write_text('\n'.join(lines) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--exports', type=Path, default=ROOT / 'build/shared-weapon-frames/held-export')
    parser.add_argument('--game-root', type=Path, default=Path('D:/SteamLibrary/steamapps/common/killingfloor2'))
    parser.add_argument('--surfaces', type=Path, default=ROOT / 'build/world-gun-rigs/surfaces')
    parser.add_argument('--report', type=Path, default=ROOT / 'build/world-gun-rigs/rigs.json')
    parser.add_argument('--script', type=Path, default=ROOT / 'script/KF2VR/Classes/VRWorldGunRigs.uc')
    parser.add_argument('--fits', type=Path, default=ROOT / 'build/world-gun-rigs/pickup-fits.json')
    args = parser.parse_args()
    exports = {p.stem.lower(): p for p in args.exports.rglob('*.psk')}
    animations = {p.stem.lower(): p for p in args.exports.rglob('*.psa')}
    regions = json.loads((ROOT / 'tools/world-weapon-regions.json').read_text()).get('rig_profiles', {})
    assets = class_assets(args.game_root)
    fits = json.loads(args.fits.read_text())
    rows, surfaces, unavailable = [], [], {}
    for name, profile in sorted(profiles().items()):
        try:
            row, surface = author(name, profile, assets, exports, animations, regions, fits)
        except (ValueError, KeyError, StopIteration) as ex:
            unavailable[name] = str(ex)
            print(name, 'unavailable:', ex, flush=True)
            continue
        rows.append(row)
        surfaces.append(surface)
        print(name, row['pickup_mesh'], 'hull', row['hull_triangles'], 'hidden', row['hidden'], flush=True)
    args.surfaces.mkdir(parents=True, exist_ok=True)
    for surface in surfaces:
        (args.surfaces / (surface['metadata']['weapon'] + '.json')).write_text(json.dumps(surface, separators=(',', ':')) + '\n')
    (args.surfaces / 'summary.json').write_text(json.dumps([s['metadata'] for s in surfaces], indent=2) + '\n')
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(dict(rigs=rows, unavailable=unavailable), indent=2) + '\n')
    write_script(rows, args.script)
    print('World gun rigs:', len(rows), 'unavailable:', sorted(unavailable))


if __name__ == '__main__':
    main()
