"""
Blender: cut a left-chest shrink chunk into the rebuilt stock Clot gore mesh.

    blender -b <base.blend> --python tools/gore/build_chest_chunk.py -- <clot_gore.json> <out.blend>

base.blend holds the stock gore mesh "ClotGore" in stock vertex order with its
armature (see docs/re/ZED_GORE_MESH_ALT_WEIGHTS.md). Rules this follows, each
learned from the first attempt:

- No subdivision. Only the outline is cut into the skin, so the mesh grows by
  tens of vertices, not thousands.
- The stock mesh is split along UV seams. Every cut is decided from positions,
  so both copies of a seam are cut the same way (no T-junctions, no gaps).
- The chunk stays inside the left shoulder-slice slab and away from its edge.
- The crater is its own small bowl in the stock meat section, mapped onto the
  open rib cage painted in stock ZED_Gore_D. No third material.
- The new bone copies LeftShoulder's rest frame and is parented to it, so the
  stock shoulder slice still carries the chunk area.
"""
import bpy, bmesh, json, math, random, sys
from mathutils import Vector, kdtree, noise, geometry

argv = sys.argv[sys.argv.index('--') + 1:]
DATA, OUT = argv[0], argv[1]
SEED, SIDES, MAX_R, RINGS = 11, 6, 8.5, 4
BONE, PARENT = 'Gore_ChestL', 'LeftShoulder'
TARGET = (9.5, 137.5)                               # x, z of the middle of the left pec (cm)
# Open rib cage on stock ZED_Gore_D (image coordinates, v down): the character's left half.
RIB_U, RIB_V = (0.125, 0.265), (0.03, 0.25)

D = json.load(open(DATA))
ob = bpy.data.objects['ClotGore']; me = ob.data
rig = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
NBODY = D['chunks'][1]['base']                      # body vertices come first
SL = D['joints'][PARENT]['alt']
N = Vector((0.25, -1.0, 0.1)).normalized()         # outward on the left pec (scene front is -Y)

bm = bmesh.new(); bm.from_mesh(me)
orig = bm.verts.layers.int.new('orig'); part = bm.verts.layers.int.new('part')
blood = bm.verts.layers.float.new('blood')
dl = bm.verts.layers.deform.active; uvl = bm.loops.layers.uv.active
bm.verts.ensure_lookup_table()
for v in bm.verts: v[orig] = v.index
STOCK_VERTS, STOCK_TRIS = len(bm.verts), len(bm.faces)

body = [(v.co.copy(), v.index, dict(v[dl].items())) for v in bm.verts if v.index < NBODY]
kd_body = kdtree.KDTree(len(body))
for i, (co, _, _) in enumerate(body): kd_body.insert(co, i)
kd_body.balance()
gname = {g.index: g.name for g in ob.vertex_groups}


def slab_id(i):
    return str(i) in SL and max(SL[str(i)], key=lambda x: x[1])[0] == PARENT


def slab_at(co):
    """Position-based, so both copies of a UV seam always agree."""
    hits = [body[i][1] for _, i, _ in kd_body.find_range(co, 1e-3)]
    return bool(hits) and all(slab_id(i) for i in hits)


def dominant(w):
    return gname[max(w.items(), key=lambda kv: kv[1])[0]] if w else ''


# 1. Place the chunk: the front-facing slab point farthest from the slab edge and from the arm.
edge_pts = [co for co, i, w in body if not slab_id(i) or dominant(w) in ('LeftArm', 'LeftArmTwist1', 'neck', 'Spine1')]
kd_edge = kdtree.KDTree(len(edge_pts))
for i, co in enumerate(edge_pts): kd_edge.insert(co, i)
kd_edge.balance()
bm.normal_update()
best = None
for v in bm.verts:
    if v.index >= NBODY or not slab_id(v.index) or abs(v.normal.dot(N)) < 0.6 or v.co.y > 0 or not 128 < v.co.z < 146:
        continue
    d = kd_edge.find(v.co)[2]
    # as near the middle of the pec as the slab edge allows
    score = min(d, 7.5) - 0.8 * math.hypot(v.co.x - TARGET[0], v.co.z - TARGET[1])
    if best is None or score > best[0]: best = (score, v.co.copy(), d)
_, C, clear = best
R = min(MAX_R, clear - 1.2)
print(f'CHEST centre {tuple(round(x, 1) for x in C)} clearance {clear:.1f} cm radius {R:.1f} cm')
T1 = N.cross(Vector((0, 0, 1))).normalized(); T2 = N.cross(T1).normalized()


def plane(co):
    d = co - C
    return d.dot(T1), d.dot(T2)


# 2. Torn outline: an irregular polygon of straight breaks.
random.seed(SEED)
angs = [(i + random.uniform(-0.28, 0.28)) * 2 * math.pi / SIDES for i in range(SIDES)]
poly = [(math.cos(a) * r, math.sin(a) * r) for a, r in zip(angs, [R * random.uniform(0.7, 1.0) for _ in angs])]


def inside(p):
    x, y = p; ok = False
    for i in range(SIDES):
        (x1, y1), (x2, y2) = poly[i], poly[(i + 1) % SIDES]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1: ok = not ok
    return ok


def near(co, pad):
    d = co - C
    return -5 < d.dot(N) and (d - N * d.dot(N)).length < R + pad


# 3. Cut the outline into the skin with plane bisects: exact straight breaks, same on both seam copies.
before = set(bm.verts)
for i in range(SIDES):
    a, b = poly[i], poly[(i + 1) % SIDES]
    pa = C + T1 * a[0] + T2 * a[1]; pb = C + T1 * b[0] + T2 * b[1]
    faces = [f for f in bm.faces if f.material_index == 0 and all(near(v.co, 1.5) for v in f.verts)]
    geom = list({e for f in faces for e in f.edges}) + list({v for f in faces for v in f.verts}) + faces
    bmesh.ops.bisect_plane(bm, geom=geom, dist=1e-4, plane_co=pa, plane_no=N.cross(pb - pa).normalized(),
                           clear_inner=False, clear_outer=False)
bmesh.ops.triangulate(bm, faces=[f for f in bm.faces if len(f.verts) > 3])


def find_t_junctions():
    loc = [v for v in bm.verts if near(v.co, 4)]
    kd = kdtree.KDTree(len(loc))
    for i, v in enumerate(loc): kd.insert(v.co, i)
    kd.balance(); out = []
    for e in bm.edges:
        if len(e.link_faces) != 1 or not near(e.verts[0].co, 3): continue
        a, b = e.verts[0].co, e.verts[1].co
        for co, i, d in kd.find_range((a + b) / 2, (b - a).length / 2):
            if (co - a).length < 1e-4 or (co - b).length < 1e-4: continue
            p, t = geometry.intersect_point_line(co, a, b)
            if 0.01 < t < 0.99 and (p - co).length < 1e-4: out.append((e, loc[i], t)); break
    return out


# A bisect that reaches one copy of a UV seam edge but not the other leaves a vertex
# in the middle of the uncut copy. Split that copy at the same point.
for _ in range(8):
    tjs = find_t_junctions()
    if not tjs: break
    for e, twin, t in tjs:
        if not e.is_valid: continue
        ne, nv = bmesh.utils.edge_split(e, e.verts[0], t)
        nv.co = twin.co.copy()
        nv[dl].clear()
        for g, w in twin[dl].items(): nv[dl][g] = w
    bmesh.ops.triangulate(bm, faces=[f for f in bm.faces if len(f.verts) > 3])
# A new vertex takes its source vertex from its own faces. A nearest-position lookup
# could return the other copy of a UV seam, which belongs to the other side of a break.
new_verts = [v for v in bm.verts if v not in before]
todo = set(new_verts)
for _ in range(6):
    done = []
    for v in todo:
        cand = [w for f in v.link_faces for w in f.verts if w is not v and w not in todo]
        if cand:
            v[orig] = min(cand, key=lambda w: (w.co - v.co).length)[orig]; done.append(v)
    todo -= set(done)
    if not todo: break
for v in todo: v[orig] = body[kd_body.find(v.co)[1]][1]
cut_verts = len(bm.verts) - len(before)

region = [f for f in bm.faces if f.material_index == 0 and all(near(v.co, 0.5) for v in f.verts)
          and inside(plane(f.calc_center_median())) and all(slab_at(body[kd_body.find(v.co)[1]][0]) or v not in before for v in f.verts)]
rset = set(region)
rim_edges = [e for e in bm.edges if sum(f in rset for f in e.link_faces) == 1]
rim_pos = {}
for e in rim_edges:
    for v in e.verts: rim_pos[v] = v.co.copy()
# ordered rim loop (positions) before the split
nxt = {}
for e in rim_edges:
    a, b = e.verts; nxt.setdefault(a, []).append(b); nxt.setdefault(b, []).append(a)
start = next(iter(nxt)); loop = [start]; prev = None
while True:
    cur = loop[-1]; cand = [x for x in nxt[cur] if x is not prev]
    if not cand or cand[0] is start: break
    prev = cur; loop.append(cand[0])
loop_pos = [v.co.copy() for v in loop]
bmesh.ops.split_edges(bm, edges=rim_edges)
chunk_verts = {v for f in region for v in f.verts}
for v in chunk_verts: v[part] = 1

# skin-side rim vertices in loop order
skin_rim = [v for v in bm.verts if v[part] == 0 and any(len(e.link_faces) == 1 for e in v.link_edges)]
kd_rim = kdtree.KDTree(len(skin_rim))
for i, v in enumerate(skin_rim): kd_rim.insert(v.co, i)
kd_rim.balance()
ring0 = []
for p in loop_pos:
    co, i, d = kd_rim.find(p)
    if d > 1e-3: raise RuntimeError('rim vertex lost its skin copy')
    ring0.append(skin_rim[i])

# 4. Smooth normals merged by proximity, for the inset.
pts = []
for f in bm.faces:
    if f.material_index == 0 and all(near(v.co, 3) for v in f.verts):
        fn = f.normal * f.calc_area()
        for v in f.verts: pts.append((v.co.copy(), fn))
kd_n = kdtree.KDTree(len(pts))
for i, (co, _) in enumerate(pts): kd_n.insert(co, i)
kd_n.balance()


def snorm(co):
    acc = Vector()
    for _, i, d in kd_n.find_range(co, 1.5): acc += pts[i][1] * (1.5 - d)
    if acc.length < 1e-9: return N
    acc.normalize()
    return -acc if acc.dot(N) < 0 else acc


def meat_uv(co):
    x, y = plane(co)
    u = RIB_U[0] + (RIB_U[1] - RIB_U[0]) * (0.5 + x / (2.2 * R))
    v = RIB_V[0] + (RIB_V[1] - RIB_V[0]) * (0.5 - y / (2.2 * R))
    return (u, 1 - v)


def new_vert(co, src_co):
    v = bm.verts.new(co); v[part] = 2
    _, i, _ = kd_body.find(src_co); v[orig] = body[i][1]
    for g, w in body[i][2].items(): v[dl][g] = w
    return v


# 5. Crater: a skin-thickness lip, then a bowl of rings down to a centre point.
m = len(ring0)
floor_c = C - N * 4.2
rings = [ring0]
lip = [new_vert(p - snorm(p) * 0.7, p) for p in loop_pos]
rings.append(lip)
for k in range(1, RINGS + 1):
    t = k / (RINGS + 1)
    ring = []
    for p, l in zip(loop_pos, lip):
        base = l.co.lerp(floor_c, t)
        sag = (1 - (1 - t) ** 2) * 1.6 * (1 - t)            # bowl: steep walls, flatter floor
        co = base - N * sag + N * 0.35 * noise.noise(base * 0.5) * t
        ring.append(new_vert(co, p))
    rings.append(ring)
centre = new_vert(floor_c + N * 0.3 * noise.noise(floor_c * 0.5), C)
crater_faces = []
for a, b in zip(rings[:-1], rings[1:]):
    for i in range(m):
        j = (i + 1) % m
        for tri in ((a[i], a[j], b[j]), (a[i], b[j], b[i])):
            try: crater_faces.append(bm.faces.new(tri))
            except ValueError: pass
for i in range(m):
    try: crater_faces.append(bm.faces.new((rings[-1][i], rings[-1][(i + 1) % m], centre)))
    except ValueError: pass
for f in crater_faces:
    f.material_index = 1; f.smooth = True
    for l in f.loops: l[uvl].uv = meat_uv(l.vert.co)
bmesh.ops.recalc_face_normals(bm, faces=crater_faces)
if sum(f.normal.dot(N) for f in crater_faces) < 0:
    for f in crater_faces: f.normal_flip()

# 6. Render-only stand-in for a wound decal: a soft blood fade outside the rim.
kd_loop = kdtree.KDTree(len(loop_pos))
for i, p in enumerate(loop_pos): kd_loop.insert(p, i)
kd_loop.balance()
for v in bm.verts:
    if v[part] == 0 and v[orig] < NBODY and near(v.co, 5):
        d = kd_loop.find(v.co)[2]
        v[blood] = max(0.0, 1 - d / (2.4 + 1.2 * noise.noise(v.co * 0.35))) ** 1.6

# 7. Checks.
bm.verts.ensure_lookup_table(); bm.verts.index_update()
tj = len(find_t_junctions())
chunk_tris = [f for f in bm.faces if all(v[part] == 1 for v in f.verts)]
slivers = sum(1 for f in chunk_tris if f.calc_area() < 0.02)
report = dict(stock_vertices=STOCK_VERTS, vertices=len(bm.verts), added_vertices=len(bm.verts) - STOCK_VERTS,
              stock_triangles=STOCK_TRIS, triangles=len(bm.faces), cut_vertices=cut_verts, rim_vertices=m,
              chunk_vertices=len(chunk_verts), chunk_triangles=len(chunk_tris), sliver_triangles=slivers,
              crater_vertices=sum(1 for v in bm.verts if v[part] == 2), t_junctions=tj,
              radius_cm=round(R, 2), clearance_cm=round(clear, 2), materials=len(me.materials))
print('CHEST ' + json.dumps(report))
if tj: raise RuntimeError(f'{tj} T-junctions')
bm.to_mesh(me); bm.free(); me.update()

# 8. The chunk bone: LeftShoulder's rest frame, parented to it.
bpy.context.view_layer.objects.active = rig; bpy.ops.object.mode_set(mode='EDIT')
eb = rig.data.edit_bones; src = eb[PARENT]; nb = eb.new(BONE)
nb.head = src.head; nb.tail = src.tail; nb.roll = src.roll; nb.parent = src
bpy.ops.object.mode_set(mode='OBJECT')
ob.vertex_groups.new(name=BONE)
json.dump(report, open(OUT.replace('.blend', '.json'), 'w'), indent=1)
bpy.ops.wm.save_as_mainfile(filepath=OUT)
