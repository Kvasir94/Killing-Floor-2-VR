"""Shared offline PSK/PSA reader for the melee zone and grip tools.

Reads CLI-only UModel exports under build/<slug>-audit/export (see
audit_stock_gun_assets.py for how they are made); no game, SDK or editor.
FK follows the convention of audit_m14_assets.py: the root keeps its stored
quaternion and each child is rotation = mul(parent, conj(q)).

UModel's PSK/PSA export mirrors the mesh in Y. The in-game skeleton does not:
the stock Katana's Idle right wrist reads (-2.7, 7.1, -0.5) in RW_Weapon space
here and the game logs it as (-2.66, -7.11, -0.52) (KF2VR_HANDS
grip-calibrated). Rig.to_local and Rig.to_root therefore return game-space
coordinates (PSK Y negated); all JSON written by these tools is game space.

Used by measure_melee_zones.py and sample_melee_grips.py.
"""
from pathlib import Path
import math
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_flamethrower_assets import chunks, parse_bones, ctext, INFO, KEY  # noqa: E402
from audit_m14_assets import mul, conj, rotate  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"

# All perk knives play the Commando knife's 1P anim set (stock
# KFWeap_Knife_*.uc defaultproperties: AnimSets(0)=WEP_1P_CommandoKnife_ANIM).
SHARED_ANIM = {s: "knife-commando" for s in (
    "knife-berserker", "knife-demolitionist", "knife-fieldmedic", "knife-firebug",
    "knife-gunslinger", "knife-sharpshooter", "knife-support", "knife-survivalist",
    "knife-swat")}

HAND_WORDS = ("Hand", "Arm", "Finger", "Thumb")


def dot(a, b): return sum(x * y for x, y in zip(a, b))
def sub(a, b): return tuple(x - y for x, y in zip(a, b))
def add(a, b): return tuple(x + y for x, y in zip(a, b))
def scale(a, s): return tuple(x * s for x in a)
def norm(a): return math.sqrt(dot(a, a))
def unit(a):
    n = norm(a)
    return tuple(x / n for x in a) if n else a
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def game(v):
    """PSK (UModel, Y-mirrored) to game space and back: negate Y."""
    return (v[0], -v[1], v[2])
def r(v, n=2): return [round(x, n) + 0.0 for x in v]


def principal(points, remove=()):
    """Centroid and dominant axis of points, optionally orthogonal to `remove`."""
    c = scale(tuple(map(sum, zip(*points))), 1.0 / len(points))
    m = [[0.0] * 3 for _ in range(3)]
    for p in points:
        d = sub(p, c)
        for i in range(3):
            for j in range(3):
                m[i][j] += d[i] * d[j]
    v = unit((1.0, 0.31, 0.17))
    for _ in range(200):
        for u in remove:
            v = sub(v, scale(u, dot(v, u)))
        v = tuple(sum(m[i][j] * v[j] for j in range(3)) for i in range(3))
        v = unit(v)
    for u in remove:
        v = unit(sub(v, scale(u, dot(v, u))))
    return c, v


def mesh_path(slug):
    return next((BUILD / f"{slug}-audit/export").glob("*/SkeletalMesh3/*.psk"))


def anim_path(slug):
    source = SHARED_ANIM.get(slug, slug)
    found = list((BUILD / f"{source}-audit/export").glob("*/AnimSet/*.psa"))
    return (found[0] if found else None), source


class Rig:
    """Bind pose, skinning and faces of one PSK."""

    def __init__(self, slug):
        self.slug = slug
        self.psk = mesh_path(slug)
        mesh = chunks(self.psk)
        self.bones = parse_bones(mesh["REFSKELT"])
        self.index = {b["name"]: i for i, b in enumerate(self.bones)}
        self.bind_pos, self.bind_rot = self.fk(lambda i, b: (b["local_position"], b["local_quaternion"]))
        self.points = list(struct.iter_unpack("<3f", mesh["PNTS0000"][2]))
        wedges = list(struct.iter_unpack("<IffBBH", mesh["VTXW0000"][2]))
        faces = list(struct.iter_unpack("<3HBBI", mesh["FACE0000"][2]))
        self.faces = [((wedges[f[0]][0], wedges[f[1]][0], wedges[f[2]][0]), f[3]) for f in faces]
        size, count, raw = mesh["MATT0000"]
        self.materials = [ctext(raw[i * size:i * size + 64]) for i in range(count)]
        owner = {}
        self.weights = {}
        for w, p, b in struct.iter_unpack("<fii", mesh["RAWWEIGHTS"][2]):
            self.weights.setdefault(p, []).append((w, b))
            if w > owner.get(p, (0, -1))[0]:
                owner[p] = (w, b)
        self.owner = {p: b for p, (w, b) in owner.items()}
        self.point_material = {}
        for tri, mat in self.faces:
            for p in tri:
                self.point_material.setdefault(p, mat)

    def fk(self, local):
        pos, rot = [], []
        for i, b in enumerate(self.bones):
            p, q = local(i, b)
            if i:
                parent = b["parent_index"]
                p = add(pos[parent], rotate(rot[parent], p))
                q = mul(rot[parent], conj(q))
            pos.append(p); rot.append(q)
        return pos, rot

    def to_local(self, bone, p, pos=None, rot=None):
        """PSK-space point p into `bone` space, returned in game space."""
        pos = pos or self.bind_pos; rot = rot or self.bind_rot
        i = self.index[bone]
        return game(rotate(conj(rot[i]), sub(p, pos[i])))

    def dir_local(self, bone, d, rot):
        """PSK-space direction d into `bone` space, returned in game space."""
        return game(rotate(conj(rot[self.index[bone]]), d))

    def skin(self, p, pos, rot):
        """Point p linearly blend-skinned into a pose (PSK space)."""
        v, out, total = self.points[p], (0.0, 0.0, 0.0), 0.0
        for w, b in self.weights.get(p, ()):
            local = rotate(conj(self.bind_rot[b]), sub(v, self.bind_pos[b]))
            out = add(out, scale(add(pos[b], rotate(rot[b], local)), w))
            total += w
        return scale(out, 1.0 / total) if total else v

    def weapon_points(self, root="RW_Weapon", prefix=None, pose=None, skip=(), only=None):
        """Points used by triangles and skinned (dominant weight) to a weapon
        bone with the root's prefix (RW_/LW_), excluding arms and hands, in
        root-bone space. With pose=(pos, rot) the mesh is skinned into that
        pose first (moving parts such as the Scythe's folding blade sit where
        the animation puts them); otherwise the bind pose.
        Returns [(local, point_index, material)]."""
        prefix = prefix or root[:3]
        used = {p for tri, _ in self.faces for p in tri}
        out = []
        for p in sorted(used):
            b = self.owner.get(p)
            if b is None:
                continue
            name = self.bones[b]["name"]
            if not name.startswith(prefix) or any(w in name for w in HAND_WORDS):
                continue
            if name in skip or (only is not None and name not in only):
                continue
            if pose:
                local = self.to_local(root, self.skin(p, *pose), *pose)
            else:
                local = self.to_local(root, self.points[p])
            out.append((local, p, self.point_material.get(p, 0)))
        return out

    def weapon_triangles(self, keep):
        """Triangles whose three points are all in `keep` (a set of point ids)."""
        return [(tri, mat) for tri, mat in self.faces if all(p in keep for p in tri)]


class Anim:
    """PSA sequences, posed onto a Rig by bone name."""

    def __init__(self, path):
        self.path = path
        anim = chunks(path)
        self.names = [b["name"] for b in parse_bones(anim["BONENAMES"])]
        self.slot = {n: i for i, n in enumerate(self.names)}
        size, count, raw = anim["ANIMINFO"]
        self.infos = [INFO.unpack_from(raw, i * size) for i in range(count)]
        self.keys = anim["ANIMKEYS"][2]
        self.sequences = {ctext(info[0]): info for info in self.infos}

    def frames(self, name):
        return self.sequences[name][11]

    def rate(self, name):
        return self.sequences[name][8]

    def pose(self, rig, name, frame):
        info = self.sequences[name]
        def local(i, b):
            s = self.slot.get(b["name"])
            if s is None:
                return b["local_position"], b["local_quaternion"]
            k = KEY.unpack_from(self.keys, ((info[10] + frame) * info[2] + s) * KEY.size)
            return k[:3], k[3:7]
        return rig.fk(local)


def basis(u):
    """Two unit vectors perpendicular to u (and each other)."""
    a = (1.0, 0.0, 0.0) if abs(u[0]) < 0.9 else (0.0, 1.0, 0.0)
    e1 = unit(sub(a, scale(u, dot(a, u))))
    return e1, cross(u, e1)


def slice_mesh(local, triangles, axis, origin=(0.0, 0.0, 0.0), step=0.5):
    """Cut triangles (point-id triples into `local`) with planes normal to
    `axis` every `step` uu. Returns (t0, [list of section points per plane])
    where plane k sits at t0 + k*step along the axis from `origin`."""
    t = {p: dot(sub(v, origin), axis) for p, v in local.items()}
    t0 = math.floor(min(t.values()) / step) * step
    count = int(math.ceil((max(t.values()) - t0) / step)) + 1
    planes = [[] for _ in range(count)]
    for tri in triangles:
        ts = [t[p] for p in tri]
        lo, hi = min(ts), max(ts)
        k0 = max(0, int(math.ceil((lo - t0) / step)))
        k1 = min(count - 1, int(math.floor((hi - t0) / step)))
        for k in range(k0, k1 + 1):
            c = t0 + k * step
            for i in range(3):
                a, b = tri[i], tri[(i + 1) % 3]
                ta, tb = t[a], t[b]
                if (ta - c) * (tb - c) > 0 or ta == tb:
                    continue
                f = (c - ta) / (tb - ta)
                planes[k].append(add(local[a], scale(sub(local[b], local[a]), f)))
    return t0, planes


def section_stats(points, axis):
    """Centroid, extents along the two cross directions and max radius."""
    if not points:
        return None
    e1, e2 = basis(axis)
    c = scale(tuple(map(sum, zip(*points))), 1.0 / len(points))
    a = [dot(p, e1) for p in points]; b = [dot(p, e2) for p in points]
    rad = max(norm(sub(sub(p, c), scale(axis, dot(sub(p, c), axis)))) for p in points)
    return dict(n=len(points), centroid=c, width1=max(a) - min(a), width2=max(b) - min(b),
                width=max(max(a) - min(a), max(b) - min(b)), radius=rad)
