# Deadbolt pneumatic spike driver - procedural build.
# Frame: +X forward (toward fingers), +Z up, +Y = inner/thumb side of the RIGHT forearm
# (the side the player sees; labels live there). Wrist centre at origin. Metres.
import bpy, bmesh, math
from mathutils import Vector, Matrix, Euler

COLL = "DB_Weapon"

# Mesh resolution. The defaults are the render model; export_deadbolt.py lowers them for the game mesh.
Q = dict(spike=(420, 48), sleeve=(160, 56), sleeve_solid=True, wrap_seg=64, strap_seg=56, stitch=96,
         stitch_cubes=True, curve=(12, 4), text_extrude=1.0, text_res=12, seg_scale=1.0, bevel_segs=None)

def nseg(seg):
    return seg if seg <= 8 else max(8, int(round(seg*Q['seg_scale'])))
TAU = math.tau

# ---------------------------------------------------------------- utilities
def get_coll(name):
    c = bpy.data.collections.get(name)
    if not c:
        c = bpy.data.collections.new(name)
        bpy.context.scene.collection.children.link(c)
    return c

def clear_coll(name):
    c = get_coll(name)
    for o in list(c.objects):
        d = o.data
        bpy.data.objects.remove(o, do_unlink=True)
        if d is not None and d.users == 0:
            if isinstance(d, bpy.types.Mesh): bpy.data.meshes.remove(d)
            elif isinstance(d, bpy.types.Curve): bpy.data.curves.remove(d)
    return c

def link(ob):
    get_coll(COLL).objects.link(ob)
    return ob

def bm_obj(name, bm, mat, smooth=True, bevel=0.0, segs=3, harden=True, angle=None):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me); bm.free()
    for p in me.polygons: p.use_smooth = smooth
    ob = bpy.data.objects.new(name, me)
    if mat: me.materials.append(MATS[mat])
    if bevel > 0:
        m = ob.modifiers.new("bevel", 'BEVEL')
        m.width = bevel; m.segments = Q['bevel_segs'] or segs; m.limit_method = 'ANGLE'
        m.angle_limit = math.radians(angle or 30); m.harden_normals = harden
        m.miter_outer = 'MITER_ARC'
    return link(ob)

def box(name, x0, x1, y0, y1, z0, z1, mat, bevel=0.0015, segs=3):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector(((x0+x1)/2 + v.co.x*(x1-x0), (y0+y1)/2 + v.co.y*(y1-y0), (z0+z1)/2 + v.co.z*(z1-z0)))
    return bm_obj(name, bm, mat, bevel=bevel, segs=segs)

def prism(name, profile_yz, x0, x1, mat, bevel=0.0012):
    """Extrude a YZ polygon (CCW seen from +X) along X."""
    bm = bmesh.new()
    a = [bm.verts.new((x0, y, z)) for y, z in profile_yz]
    b = [bm.verts.new((x1, y, z)) for y, z in profile_yz]
    n = len(a)
    bm.faces.new(list(reversed(a))); bm.faces.new(b)
    for i in range(n):
        j = (i+1) % n
        bm.faces.new((a[i], a[j], b[j], b[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm_obj(name, bm, mat, bevel=bevel)

def rect_frame(name, x0, x1, yh, z0, z1, t, mat, bevel=0.0012):
    bm = bmesh.new()
    def ring(x):
        o = [(-yh, z0), (yh, z0), (yh, z1), (-yh, z1)]
        i = [(-yh+t, z0+t), (yh-t, z0+t), (yh-t, z1-t), (-yh+t, z1-t)]
        return [bm.verts.new((x, y, z)) for y, z in o], [bm.verts.new((x, y, z)) for y, z in i]
    o0, i0 = ring(x0); o1, i1 = ring(x1)
    for a in range(4):
        b = (a+1) % 4
        bm.faces.new((o0[a], o0[b], o1[b], o1[a])); bm.faces.new((i0[b], i0[a], i1[a], i1[b]))
        bm.faces.new((o0[b], o0[a], i0[a], i0[b])); bm.faces.new((o1[a], o1[b], i1[b], i1[a]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm_obj(name, bm, mat, bevel=bevel)

def orient(p0, p1):
    d = (Vector(p1)-Vector(p0))
    q = d.normalized().to_track_quat('Z', 'Y')
    return d.length, q

def cyl(name, p0, p1, r, mat, seg=32, r1=None, bevel=0.0006, segs=2):
    L, q = orient(p0, p1)
    bm = bmesh.new()
    seg = nseg(seg)
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=seg, radius1=r, radius2=(r if r1 is None else r1), depth=L)
    bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, L/2))
    bmesh.ops.transform(bm, matrix=q.to_matrix().to_4x4(), verts=bm.verts)
    bmesh.ops.translate(bm, verts=bm.verts, vec=Vector(p0))
    return bm_obj(name, bm, mat, bevel=bevel, segs=segs, angle=40)

def tube_ring(name, p0, p1, r_out, r_in, mat, seg=32, bevel=0.0005):
    """Hollow ring/sleeve."""
    seg = nseg(seg)
    L, q = orient(p0, p1)
    bm = bmesh.new()
    rings = []
    for z in (0, L):
        for r in (r_out, r_in):
            rings.append([bm.verts.new((r*math.cos(TAU*i/seg), r*math.sin(TAU*i/seg), z)) for i in range(seg)])
    o0, i0, o1, i1 = rings
    for i in range(seg):
        j = (i+1) % seg
        bm.faces.new((o0[i], o0[j], o1[j], o1[i]))
        bm.faces.new((i0[j], i0[i], i1[i], i1[j]))
        bm.faces.new((o0[j], o0[i], i0[i], i0[j]))
        bm.faces.new((o1[i], o1[j], i1[j], i1[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bmesh.ops.transform(bm, matrix=q.to_matrix().to_4x4(), verts=bm.verts)
    bmesh.ops.translate(bm, verts=bm.verts, vec=Vector(p0))
    return bm_obj(name, bm, mat, bevel=bevel, segs=2, angle=40)

def hexbolt(name, p, axis, r=0.0024, h=0.0018, mat="steel_dark"):
    axis = Vector(axis).normalized()
    p = Vector(p)
    ob = cyl(name, p - axis*0.0004, p + axis*h, r, mat, seg=6, bevel=0.0003)
    return ob

def loft(name, rings, mat, close_u=True, cap0=False, cap1=False, smooth=True, bevel=0.0):
    bm = bmesh.new()
    vr = [[bm.verts.new(p) for p in ring] for ring in rings]
    n = len(rings[0])
    for a, b in zip(vr[:-1], vr[1:]):
        rng = n if close_u else n-1
        for i in range(rng):
            j = (i+1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if cap0: bm.faces.new(list(reversed(vr[0])))
    if cap1: bm.faces.new(vr[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm_obj(name, bm, mat, smooth=smooth, bevel=bevel)

CURVE_PTS = {}   # curve name -> control points; deadbolt_anim skins hoses along them

def curve_tube(name, pts, r, mat, res=12, bevel_res=4, twist_uv=True):
    CURVE_PTS[name] = [tuple(p) for p in pts]
    cu = bpy.data.curves.new(name, 'CURVE')
    cu.dimensions = '3D'; cu.resolution_u = min(res, Q['curve'][0])
    cu.bevel_depth = r; cu.bevel_resolution = min(bevel_res, Q['curve'][1]); cu.use_fill_caps = True
    sp = cu.splines.new('BEZIER')
    sp.bezier_points.add(len(pts)-1)
    for bp, p in zip(sp.bezier_points, pts):
        bp.co = p; bp.handle_left_type = bp.handle_right_type = 'AUTO'
    ob = bpy.data.objects.new(name, cu)
    cu.materials.append(MATS[mat])
    return link(ob)

def helix_tube(name, p0, axis_len, R, pitch, wire_r, mat, turns_res=24):
    pts = []
    turns = axis_len / pitch
    N = int(turns*turns_res)+1
    cu = bpy.data.curves.new(name, 'CURVE'); cu.dimensions = '3D'
    cu.bevel_depth = wire_r; cu.bevel_resolution = min(3, Q['curve'][1]); cu.use_fill_caps = True
    sp = cu.splines.new('POLY'); sp.points.add(N-1)
    for i in range(N):
        t = i/(N-1)
        a = t*turns*TAU
        sp.points[i].co = (p0[0]+t*axis_len, p0[1]+R*math.cos(a), p0[2]+R*math.sin(a), 1)
    ob = bpy.data.objects.new(name, cu); cu.materials.append(MATS[mat])
    return link(ob)

def text(name, body, loc, rot, size, mat, extrude=0.0004, font_bold=True):
    cu = bpy.data.curves.new(name, 'FONT')
    cu.body = body; cu.size = size; cu.extrude = extrude*Q['text_extrude']; cu.resolution_u = Q['text_res']
    cu.align_x = 'CENTER'; cu.align_y = 'CENTER'
    if font_bold:
        for f in ("C:/Windows/Fonts/impact.ttf", "C:/Windows/Fonts/arialbd.ttf"):
            try:
                cu.font = bpy.data.fonts.load(f, check_existing=True); break
            except Exception: pass
    ob = bpy.data.objects.new(name, cu)
    ob.location = loc; ob.rotation_euler = rot
    cu.materials.append(MATS[mat])
    return link(ob)

# ---------------------------------------------------------------- materials
MATS = {}
def sock(node, ident, out=False):
    for s in (node.outputs if out else node.inputs):
        if s.identifier == ident or s.name == ident: return s
    raise KeyError(ident)

class NT:
    def __init__(self, mat):
        mat.use_nodes = True
        self.t = mat.node_tree; self.t.nodes.clear()
        self.out = self.n('ShaderNodeOutputMaterial')
    def n(self, typ, **kw):
        nd = self.t.nodes.new(typ)
        for k, v in kw.items():
            setattr(nd, k, v)
        return nd
    def l(self, a, b):
        self.t.links.new(a, b)
    def math(self, op, a, b=None, clamp=False):
        m = self.n('ShaderNodeMath', operation=op, use_clamp=clamp)
        for i, v in enumerate((a, b)):
            if v is None: continue
            if isinstance(v, (int, float)): m.inputs[i].default_value = v
            else: self.l(v, m.inputs[i])
        return m.outputs[0]
    def mix(self, fac, a, b, blend='MIX'):
        m = self.n('ShaderNodeMix', data_type='RGBA', blend_type=blend)
        for ident, v in (('Factor_Float', fac), ('A_Color', a), ('B_Color', b)):
            s = sock(m, ident)
            if isinstance(v, (int, float)): s.default_value = v
            elif isinstance(v, tuple): s.default_value = v if len(v) == 4 else (*v, 1)
            else: self.l(v, s)
        return sock(m, 'Result_Color', out=True)
    def maprange(self, v, a, b, c=0.0, d=1.0):
        m = self.n('ShaderNodeMapRange', clamp=True)
        self.l(v, m.inputs['Value'])
        m.inputs['From Min'].default_value = a; m.inputs['From Max'].default_value = b
        m.inputs['To Min'].default_value = c; m.inputs['To Max'].default_value = d
        return m.outputs['Result']
    def noise(self, scale, detail=6, rough=0.6, vec=None):
        nz = self.n('ShaderNodeTexNoise')
        nz.inputs['Scale'].default_value = scale; nz.inputs['Detail'].default_value = detail
        nz.inputs['Roughness'].default_value = rough
        if vec is not None: self.l(vec, nz.inputs['Vector'])
        return nz
    def ao(self, dist, inside=False):
        a = self.n('ShaderNodeAmbientOcclusion', inside=inside, samples=8)
        a.inputs['Distance'].default_value = dist
        return a.outputs['AO']
    def bump(self, h, strength=0.3, dist=0.001, normal=None):
        b = self.n('ShaderNodeBump')
        b.inputs['Strength'].default_value = strength; b.inputs['Distance'].default_value = dist
        self.l(h, b.inputs['Height'])
        if normal is not None: self.l(normal, b.inputs['Normal'])
        return b.outputs['Normal']
    def bsdf(self, color, metallic=0.0, rough=0.5, normal=None, emit=None, emit_strength=0.0, **extra):
        p = self.n('ShaderNodeBsdfPrincipled')
        for k, v in (('Base Color', color), ('Metallic', metallic), ('Roughness', rough)):
            s = p.inputs[k]
            if isinstance(v, (int, float)): s.default_value = v
            elif isinstance(v, tuple): s.default_value = v if len(v) == 4 else (*v, 1)
            else: self.l(v, s)
        if normal is not None: self.l(normal, p.inputs['Normal'])
        if emit is not None:
            if isinstance(emit, tuple): p.inputs['Emission Color'].default_value = (*emit, 1)
            else: self.l(emit, p.inputs['Emission Color'])
            if isinstance(emit_strength, (int, float)): p.inputs['Emission Strength'].default_value = emit_strength
            else: self.l(emit_strength, p.inputs['Emission Strength'])
        for k, v in extra.items():
            p.inputs[k.replace('_', ' ')].default_value = v
        self.l(p.outputs[0], self.out.inputs['Surface'])
        return p

def newmat(name):
    m = bpy.data.materials.get("DB_" + name)
    if m: bpy.data.materials.remove(m)
    m = bpy.data.materials.new("DB_" + name)
    MATS[name] = m
    return m

def obj_coord(nt):
    tc = nt.n('ShaderNodeTexCoord')
    return tc.outputs['Object']

def mat_painted(name, paint, stripes=True, stripe_pitch=0.030, stripe_dir=(1.0, 0.55, 1.0), wear=1.0):
    nt = NT(newmat(name))
    co = obj_coord(nt)
    # diagonal hazard stripes in object space, slightly wobbly (hand-painted)
    dot = nt.n('ShaderNodeVectorMath', operation='DOT_PRODUCT')
    nt.l(co, dot.inputs[0]); dot.inputs[1].default_value = stripe_dir
    wob = nt.noise(18.0, 3, 0.5, co)
    wob2 = nt.noise(140.0, 6, 0.7, co)
    s = nt.math('ADD', dot.outputs['Value'], nt.math('MULTIPLY', wob.outputs['Fac'], 0.008))
    s = nt.math('ADD', s, nt.math('MULTIPLY', wob2.outputs['Fac'], 0.0035))
    s = nt.math('FRACT', nt.math('DIVIDE', s, stripe_pitch))
    stripe = nt.math('GREATER_THAN', s, 0.64) if stripes else None
    if stripes:  # worn, scuffed stencil paint
        sw = nt.noise(55.0, 8, 0.7, co)
        stripe = nt.math('MULTIPLY', stripe, nt.math('LESS_THAN', sw.outputs['Fac'], 0.62))
    base = nt.mix(stripe, paint, (0.018, 0.016, 0.014)) if stripes else paint
    # grime / dirt in crevices + broad blotches
    blot = nt.noise(9.0, 8, 0.65, co)
    sv = nt.n('ShaderNodeVectorMath', operation='MULTIPLY'); nt.l(co, sv.inputs[0]); sv.inputs[1].default_value = (70, 70, 7)
    streak = nt.noise(1.0, 6, 0.6, sv.outputs[0])
    grime_mask = nt.math('ADD', nt.maprange(nt.ao(0.035), 0.97, 0.40, 0.0, 1.0),
                         nt.maprange(blot.outputs['Fac'], 0.40, 0.72, 0.0, 0.7))
    grime_mask = nt.math('ADD', grime_mask, nt.maprange(streak.outputs['Fac'], 0.5, 0.75, 0.0, 0.45))
    sepg = nt.n('ShaderNodeSeparateXYZ'); nt.l(co, sepg.inputs[0])
    grime_mask = nt.math('ADD', grime_mask, nt.math('MULTIPLY', nt.maprange(sepg.outputs['X'], -0.06, -0.30, 0.0, 0.40), blot.outputs['Fac']))
    base = nt.mix(nt.math('MINIMUM', grime_mask, 0.85), base, (0.075, 0.045, 0.02))
    # chipped edges -> bare steel
    edge = nt.maprange(nt.ao(0.005, inside=True), 0.92, 0.45)
    chip_n = nt.noise(60.0, 10, 0.75, co)
    chip = nt.math('GREATER_THAN', nt.math('ADD', nt.math('MULTIPLY', edge, wear*1.1), nt.math('MULTIPLY', chip_n.outputs['Fac'], 0.62)), 0.58)
    scr = nt.noise(140.0, 4, 0.5, co)
    chip = nt.math('MAXIMUM', chip, nt.math('GREATER_THAN', nt.math('MULTIPLY', scr.outputs['Fac'], blot.outputs['Fac']), 0.53 if wear > 0.5 else 0.6))
    patchn = nt.noise(7.0, 7, 0.65, co)
    worn = nt.math('GREATER_THAN', nt.math('ADD', patchn.outputs['Fac'], nt.math('MULTIPLY', edge, 0.24)), 0.70 if wear > 0.5 else 0.78)
    rimw = nt.math('MULTIPLY', nt.math('GREATER_THAN', patchn.outputs['Fac'], 0.645), nt.math('SUBTRACT', 1.0, worn))
    chip = nt.math('MAXIMUM', chip, worn)
    base = nt.mix(nt.maprange(patchn.outputs['Fac'], 0.55, 0.70, 0.0, 0.30), base, (0.20, 0.14, 0.05))
    col = nt.mix(chip, base, (0.17, 0.165, 0.155))
    col = nt.mix(nt.math('MULTIPLY', rimw, 0.85), col, (0.05, 0.035, 0.022))
    metal = nt.math('MULTIPLY', chip, 1.0)
    rough = nt.math('ADD', nt.math('MULTIPLY', chip, -0.25), nt.maprange(blot.outputs['Fac'], 0.3, 0.8, 0.62, 0.88))
    nrm = nt.bump(nt.math('MULTIPLY', chip, -1.0), 0.25, 0.0004)
    nt.bsdf(col, metal, rough, normal=nrm)

def mat_metal(name, color, rough=0.38, grime=0.6, scratch=1.0):
    nt = NT(newmat(name))
    co = obj_coord(nt)
    blot = nt.noise(12.0, 8, 0.6, co)
    bv = nt.n('ShaderNodeVectorMath', operation='MULTIPLY'); nt.l(co, bv.inputs[0]); bv.inputs[1].default_value = (6.0, 900.0, 900.0)
    sc = nt.noise(1.0, 3, 0.5, bv.outputs[0])            # fine brushed grain along X
    grime = nt.math('ADD', nt.maprange(nt.ao(0.03), 0.97, 0.45, 0.0, grime*1.25),
                    nt.maprange(blot.outputs['Fac'], 0.5, 0.8, 0.0, grime*0.6))
    sv = nt.n('ShaderNodeVectorMath', operation='MULTIPLY'); nt.l(co, sv.inputs[0]); sv.inputs[1].default_value = (80, 80, 8)
    streak = nt.noise(1.0, 6, 0.6, sv.outputs[0])
    grime = nt.math('ADD', grime, nt.math('MULTIPLY', nt.maprange(streak.outputs['Fac'], 0.55, 0.78, 0.0, 0.45), nt.maprange(blot.outputs['Fac'], 0.45, 0.7)))
    col = nt.mix(nt.math('MINIMUM', grime, 0.85), color, (0.06, 0.036, 0.018))
    rust = nt.noise(35.0, 8, 0.7, co)
    rmask = nt.math('MULTIPLY', nt.maprange(rust.outputs['Fac'], 0.52, 0.70, 0.0, 0.85), nt.maprange(streak.outputs['Fac'], 0.40, 0.7, 0.35, 1.0))
    rmask = nt.math('MAXIMUM', rmask, nt.math('MULTIPLY', nt.maprange(nt.ao(0.015), 0.9, 0.45, 0.0, 0.4), nt.maprange(rust.outputs['Fac'], 0.38, 0.6)))
    col = nt.mix(nt.math('MULTIPLY', rmask, 0.55), col, (0.16, 0.065, 0.025))
    edge = nt.math('MULTIPLY', nt.maprange(nt.ao(0.0012, inside=True), 0.85, 0.40, 0.0, 0.85*scratch), nt.maprange(blot.outputs['Fac'], 0.35, 0.65, 0.2, 1.0))
    col = nt.mix(edge, col, (0.46, 0.45, 0.43))
    r = nt.math('ADD', nt.maprange(blot.outputs['Fac'], 0.3, 0.8, rough-0.1, rough+0.15), nt.math('MULTIPLY', sc.outputs['Fac'], 0.08*scratch))
    r = nt.math('ADD', r, nt.math('MULTIPLY', grime, 0.3))
    nrm = nt.bump(sc.outputs['Fac'], 0.015*scratch, 0.0002)
    nt.bsdf(col, nt.math('SUBTRACT', 1.0, nt.math('MULTIPLY', grime, 0.6)), r, normal=nrm)

def mat_leather(name, color, rough=0.55, wrinkle=0.5, cracks=0.0, oil=0.0):
    nt = NT(newmat(name))
    co = obj_coord(nt)
    n1 = nt.noise(220.0, 6, 0.6, co)
    n2 = nt.noise(28.0, 6, 0.7, co)
    ao = nt.ao(0.02)
    col = nt.mix(nt.maprange(n2.outputs['Fac'], 0.35, 0.7), color, tuple(min(1, c*1.9+0.02) for c in color))
    col = nt.mix(nt.maprange(ao, 0.9, 0.3, 0, 0.8), col, (0.012, 0.009, 0.007))
    col = nt.mix(nt.math('MULTIPLY', nt.maprange(ao, 0.75, 0.35, 0.0, 0.45), nt.maprange(n1.outputs['Fac'], 0.4, 0.7)), col, (0.09, 0.075, 0.06))
    # scuffed, lighter worn edges on folds and wrap edges
    wedge = nt.math('MULTIPLY', nt.maprange(nt.ao(0.0025, inside=True), 0.92, 0.55), nt.maprange(n2.outputs['Fac'], 0.25, 0.7, 0.3, 1.0))
    col = nt.mix(nt.math('MULTIPLY', wedge, 0.75), col, tuple(min(1, c*3.2 + 0.035) for c in color))
    hgt = nt.math('ADD', nt.math('MULTIPLY', n1.outputs['Fac'], 0.4), nt.math('MULTIPLY', n2.outputs['Fac'], wrinkle))
    vor = nt.n('ShaderNodeTexVoronoi', feature='DISTANCE_TO_EDGE'); vor.inputs['Scale'].default_value = 260.0; nt.l(co, vor.inputs['Vector'])
    crack = nt.math('MULTIPLY', nt.maprange(vor.outputs['Distance'], 0.0, 0.025, 1.0, 0.0), nt.maprange(n2.outputs['Fac'], 0.45, 0.7, 0.0, cracks))
    col = nt.mix(nt.math('MULTIPLY', crack, 0.8), col, (0.006, 0.004, 0.003))
    hgt = nt.math('SUBTRACT', hgt, nt.math('MULTIPLY', crack, 0.6))
    nrm = nt.bump(hgt, 0.9, 0.0012)
    nt.bsdf(col, 0.0, nt.maprange(n2.outputs['Fac'], 0.3, 0.7, rough + 0.05, rough + 0.30), normal=nrm, Coat_Weight=oil, Coat_Roughness=0.32)

def mat_webbing(name, color):
    nt = NT(newmat(name))
    co = obj_coord(nt)
    w = nt.n('ShaderNodeTexWave', wave_type='BANDS', bands_direction='Y')
    w.inputs['Scale'].default_value = 900; w.inputs['Distortion'].default_value = 0.5
    nt.l(co, w.inputs['Vector'])
    n2 = nt.noise(30.0, 5, 0.6, co)
    col = nt.mix(nt.maprange(n2.outputs['Fac'], 0.3, 0.7), color, tuple(c*1.7 for c in color))
    nt.bsdf(col, 0.0, 0.85, normal=nt.bump(w.outputs['Fac'], 0.25, 0.0003))

def mat_rubber(name, color=(0.012, 0.012, 0.012), corrugate=True):
    nt = NT(newmat(name))
    tc = nt.n('ShaderNodeTexCoord')
    co = tc.outputs['Object']
    n2 = nt.noise(25.0, 5, 0.6, co)
    col = nt.mix(nt.maprange(n2.outputs['Fac'], 0.4, 0.8, 0, 0.6), color, (0.05, 0.045, 0.04))
    nrm = None
    if corrugate:
        sep = nt.n('ShaderNodeSeparateXYZ'); nt.l(tc.outputs['UV'], sep.inputs[0])
        ridge = nt.math('SINE', nt.math('MULTIPLY', sep.outputs['X'], 1100.0))
        nrm = nt.bump(ridge, 0.6, 0.0008)
    geo = nt.n('ShaderNodeNewGeometry'); sz = nt.n('ShaderNodeSeparateXYZ'); nt.l(geo.outputs['Normal'], sz.inputs[0])
    dust = nt.math('MULTIPLY', nt.maprange(sz.outputs['Z'], 0.4, 0.95, 0.0, 0.22), nt.maprange(nt.noise(60.0, 6, 0.6, co).outputs['Fac'], 0.35, 0.65))
    col = nt.mix(dust, col, (0.07, 0.065, 0.06))
    nt.bsdf(col, 0.0, nt.math('ADD', nt.maprange(n2.outputs['Fac'], 0.3, 0.7, 0.45, 0.7), nt.math('MULTIPLY', dust, 0.25)), normal=nrm)

def mat_simple(name, color, metallic=0.0, rough=0.4, **kw):
    nt = NT(newmat(name))
    nt.bsdf(color, metallic, rough, **kw)

def heat(nt):
    """Value node the animation review keys (glow intensity multiplier); the bake reads its default 1."""
    v = nt.n('ShaderNodeValue', name="heat", label="heat")
    v.outputs[0].default_value = 1.0
    return v.outputs[0]

def mat_emit(name, color, strength):
    nt = NT(newmat(name))
    nt.bsdf((0.05, 0.02, 0.01), 0.0, 0.4, emit=color, emit_strength=nt.math('MULTIPLY', heat(nt), strength))

def mat_spike(name, length):
    """Hot-to-cool forged rod: white-yellow point, orange body, deep red into a dull, dark shank.
    The thread crests run hotter than the grooves so the helix reads in the unlit game material."""
    nt = NT(newmat(name))
    co = obj_coord(nt)
    sep = nt.n('ShaderNodeSeparateXYZ'); nt.l(co, sep.inputs[0])
    t = nt.math('DIVIDE', sep.outputs['X'], length)
    ramp = nt.n('ShaderNodeValToRGB'); nt.l(t, ramp.inputs['Fac'])
    cr = ramp.color_ramp
    cr.elements[0].position = 0.0; cr.elements[0].color = (0.035, 0.010, 0.004, 1)
    cr.elements[1].position = 1.0; cr.elements[1].color = (1.0, 0.94, 0.78, 1)
    for pos, col in ((0.040, (0.30, 0.030, 0.005)), (0.075, (1.0, 0.16, 0.010)), (0.25, (1.0, 0.30, 0.025)),
                     (0.55, (1.0, 0.42, 0.060)), (0.80, (1.0, 0.60, 0.18)), (0.92, (1.0, 0.80, 0.42))):
        e = cr.elements.new(pos); e.color = (*col, 1)
    at = nt.n('ShaderNodeAttribute', attribute_type='GEOMETRY', attribute_name='crest')
    crest = nt.math('ADD', nt.math('MULTIPLY', nt.math('POWER', at.outputs['Fac'], 1.6), 0.93), 0.07)
    nz = nt.noise(70.0, 4, 0.5, co)
    strength = nt.math('MULTIPLY', crest, nt.maprange(t, 0.0, 1.0, 2.4, 3.6))
    strength = nt.math('MULTIPLY', strength, nt.maprange(nz.outputs['Fac'], 0.3, 0.7, 0.85, 1.15))
    strength = nt.math('MULTIPLY', strength, nt.maprange(t, 0.0, 0.06, 0.12, 1.0))
    strength = nt.math('MULTIPLY', strength, heat(nt))
    scale = nt.mix(at.outputs['Fac'], (0.04, 0.022, 0.016), (0.16, 0.07, 0.03))
    # heat colour: the game multiplies the glow texture by Vector_Glow_Color (deadbolt_anim.heat_tint);
    # the review keys this node the same way, the bake leaves it white
    tint = nt.n('ShaderNodeRGB', name="heat_tint", label="heat_tint")
    tint.outputs[0].default_value = (1, 1, 1, 1)
    col = nt.mix(1.0, ramp.outputs['Color'], tint.outputs[0], blend='MULTIPLY')
    nt.bsdf(scale, 0.85, 0.34, emit=col, emit_strength=strength)

def mat_glass(name):
    nt = NT(newmat(name))
    tr = nt.n('ShaderNodeBsdfTransparent'); tr.inputs['Color'].default_value = (0.85, 0.78, 0.72, 1)
    gl = nt.n('ShaderNodeBsdfPrincipled')
    gl.inputs['Base Color'].default_value = (0, 0, 0, 1); gl.inputs['Roughness'].default_value = 0.04
    lw = nt.n('ShaderNodeLayerWeight'); lw.inputs['Blend'].default_value = 0.35
    mx = nt.n('ShaderNodeMixShader')
    nt.l(lw.outputs['Fresnel'], mx.inputs[0]); nt.l(tr.outputs[0], mx.inputs[1]); nt.l(gl.outputs[0], mx.inputs[2])
    ad = nt.n('ShaderNodeAddShader'); nt.l(mx.outputs[0], ad.inputs[0]); nt.l(gl.outputs[0], ad.inputs[1])
    nt.l(mx.outputs[0], nt.out.inputs['Surface'])

def build_materials():
    mat_painted("yellow_hazard", (0.44, 0.28, 0.025))
    mat_painted("yellow_plain", (0.62, 0.36, 0.012), stripes=False, wear=0.8)
    mat_metal("steel_dark", (0.065, 0.064, 0.066), 0.50)
    mat_metal("steel", (0.16, 0.16, 0.165), 0.40)
    mat_metal("steel_plate", (0.18, 0.165, 0.14), 0.46, grime=0.8)
    mat_metal("steel_bright", (0.29, 0.28, 0.265), 0.38, grime=0.6)
    mat_metal("chrome", (0.75, 0.75, 0.75), 0.15, grime=0.25, scratch=0.4)
    mat_metal("copper", (0.75, 0.32, 0.16), 0.3, grime=0.3)
    mat_metal("brass", (0.6, 0.42, 0.15), 0.32, grime=0.4)
    mat_leather("leather_dark", (0.018, 0.012, 0.008), 0.6, wrinkle=0.9, cracks=0.7, oil=0.25)
    mat_leather("leather_band", (0.024, 0.015, 0.009), 0.55, wrinkle=0.45, cracks=0.7, oil=0.35)
    mat_leather("glove", (0.020, 0.015, 0.011), 0.78, wrinkle=0.7)
    mat_webbing("canvas", (0.011, 0.009, 0.007))
    mat_leather("skin", (0.30, 0.17, 0.11), 0.5, wrinkle=0.15)
    mat_leather("skin", (0.30, 0.17, 0.11), 0.5, wrinkle=0.15)
    mat_webbing("webbing", (0.032, 0.028, 0.022))
    mat_rubber("hose")
    mat_rubber("hose_smooth", corrugate=False)
    mat_rubber("wire_red", color=(0.20, 0.022, 0.012), corrugate=False)
    mat_metal("valve_blue", (0.22, 0.21, 0.20), 0.38, grime=0.6)
    mat_simple("black", (0.01, 0.01, 0.01), 0.0, 0.6)
    mat_simple("thread", (0.20, 0.15, 0.09), 0.0, 0.8)
    mat_painted("paint_white", (0.55, 0.53, 0.47), stripes=False, wear=0.6)
    mat_simple("gauge_face", (0.8, 0.75, 0.6), 0.0, 0.4)
    mat_emit("bore_glow", (1.0, 0.16, 0.02), 1.6)
    mat_emit("coil_glow", (1.0, 0.10, 0.015), 0.9)      # dull at idle so the rod leads the slot; heats with the glow keys
    mat_emit("slot_glow", (1.0, 0.24, 0.03), 0.8)       # light bleed from the rod onto the chamber floor and roof
    mat_emit("flare_glow", (1.0, 0.62, 0.22), 1.6)      # launch burst, shown by script for two frames
    mat_painted("gunmetal", (0.030, 0.032, 0.035), stripes=False, wear=0.55)
    mat_glass("glass")
    mat_spike("spike", SPIKE_LEN)

# ---------------------------------------------------------------- dimensions
X_REAR, X_FRONT = -0.315, 0.026        # gauntlet sleeve extent
def cuff_frame(x):
    t = min(1, max(0, (x - X_REAR)/(X_FRONT - X_REAR)))
    ry = 0.047 + (0.039 - 0.047)*t**1.2
    rz = 0.042 + (0.034 - 0.042)*t**1.3
    cz = -0.004 - 0.002*t
    return ry, rz, cz
def cuff_pt(x, th, off=0.0):
    ry, rz, cz = cuff_frame(x)
    return Vector((x, (ry+off)*math.cos(th), cz + (rz+off)*math.sin(th)))
def cuff_top(x): ry, rz, cz = cuff_frame(x); return cz + rz

AXIS_Z = 0.080                          # rod / spike axis height
SPIKE_LEN = 0.34
SPIKE_X0 = -0.085                       # idle: the rod's rear quarter glows in the heating chamber behind the side slot
SPIKE_STOW_X0 = 0.060 - SPIKE_LEN       # drawn fully in: tip just inside the muzzle, tail inside the feed cap
SPIKE_STARTS = 2                        # two-start forged helix
BORE_R = 0.0140                         # clear bore through chamber, muzzle and yoke
REAR_TOP = 0.118                        # top of the rear pneumatic housing

# ---------------------------------------------------------------- parts
def build_gauntlet():
    # canvas base sleeve with soft wrinkles; slightly thickened rear edge (no flare)
    rings = []
    NU, NV = Q['sleeve']
    for i in range(NU+1):
        x = X_REAR + (X_FRONT - X_REAR)*i/NU
        ring = []
        for j in range(NV):
            th = TAU*j/NV
            wr = 0.0009*math.sin(x*310 + 3*th) + 0.0007*math.sin(x*170 - 5*th + 1.3)
            lip = 0.0
            ring.append(cuff_pt(x, th, wr + lip))
        rings.append(ring)
    sl = loft("Gauntlet | canvas sleeve", rings, "canvas")
    if Q['sleeve_solid']:
        s = sl.modifiers.new("solid", 'SOLIDIFY'); s.thickness = 0.003; s.offset = -1
    ry, rz, cz = cuff_frame(X_REAR + 0.012)
    loft("Gauntlet | inner lining", [[Vector((X_REAR + 0.012, ry*0.93*math.cos(TAU*j/40), cz + rz*0.93*math.sin(TAU*j/40))) for j in range(40)]] +
         [[Vector((X_REAR + 0.010, ry*0.94*math.cos(TAU*j/40), cz + rz*0.94*math.sin(TAU*j/40))) for j in range(40)]], "black", cap0=True)
    # overlapping wraps: irregular widths, diagonal tilt, ragged edges, alternating hides
    wraps = []
    x = -0.306
    k = 0
    while x < 0.016:
        w = 0.012 + 0.018*(0.5 + 0.5*math.sin(k*2.17 + 0.6))*(0.6 + 0.4*math.sin(k*0.71 + 1.9)**2)
        wraps.append((x + w/2, w, 0.0060*math.sin(k*1.7 + 0.3), (k*1.93) % TAU,
                      "leather_band" if k % 3 != 1 else "leather_dark"))
        x += w*(0.62 + 0.30*(0.5 + 0.5*math.sin(k*3.1)))
        k += 1
    # padded, rolled rear rim
    rings = []
    for a in range(13):
        ang = math.pi*a/12
        rings.append([cuff_pt(X_REAR + 0.008 - 0.008*math.cos(ang), TAU*j/Q['wrap_seg'], 0.0035 + 0.0075*math.sin(ang)) for j in range(Q['wrap_seg'])])
    loft("Gauntlet | rolled rim", rings, "leather_dark")
    for k, (xc, w, tilt, ph, mat) in enumerate(wraps):
        lay = 0.0006*(k % 3)
        prof = ((-0.5, 0.0028), (-0.47, 0.0040), (0.0, 0.0043), (0.47, 0.0040), (0.5, 0.0028))
        rings = []
        for u, off in prof:
            ring = []
            for j in range(Q['wrap_seg']):
                th = TAU*j/Q['wrap_seg']
                ww = w*(1 + 0.18*math.sin(2*th + ph) + 0.08*math.sin(5*th + 2*ph))
                x = xc + 2.6*tilt*math.sin(th + ph) + u*ww
                ring.append(cuff_pt(min(max(x, X_REAR + 0.002), X_FRONT), th, off + lay))
            rings.append(ring)
        loft(f"Gauntlet | wrap {k}", rings, mat)

    # webbing straps with steel buckles on the inner (+Y) side
    for k, xc in enumerate([-0.247, -0.088, -0.046]):
        w = 0.031
        rings = []
        for x, off in ((xc - w/2, 0.0055), (xc - w/2 + 0.0015, 0.0092), (xc + w/2 - 0.0015, 0.0092), (xc + w/2, 0.0055)):
            rings.append([cuff_pt(x, TAU*j/Q['strap_seg'], off) for j in range(Q['strap_seg'])])
        loft(f"Strap | leather {k}", rings, "leather_band")
        # saddle stitching along both strap edges
        bm = bmesh.new()
        ry_, rz_, cz_ = cuff_frame(xc)
        for ex in (xc - w/2 + 0.0024, xc + w/2 - 0.0024):
            for j in range(Q['stitch']):
                th = TAU*(j + 0.5*(ex > xc))/Q['stitch']
                pc = cuff_pt(ex, th, 0.0093)
                tg = Vector((0, -math.sin(th)*ry_, math.cos(th)*rz_)).normalized()
                nn = Vector((0, math.cos(th), math.sin(th))).normalized()
                sd = tg.cross(nn).normalized()
                if Q['stitch_cubes']:
                    geom = bmesh.ops.create_cube(bm, size=1.0)['verts']
                else:   # game mesh: just the top face of each stitch
                    geom = [bm.verts.new(c) for c in ((-0.5, -0.5, 0.5), (0.5, -0.5, 0.5), (0.5, 0.5, 0.5), (-0.5, 0.5, 0.5))]
                    bm.faces.new(geom)
                M = Matrix((tg*0.0024, sd*0.0007, nn*0.0005)).transposed().to_4x4()
                M.translation = pc
                bmesh.ops.transform(bm, matrix=M, verts=geom)
        bm_obj(f"Strap | stitching {k}", bm, "thread", smooth=False)
        # buckle: rectangular frame on inner side, a little above the equator
        th = math.radians(22)
        p = cuff_pt(xc, th, 0.0085)
        n = Vector((0, math.cos(th), math.sin(th)*0.9)).normalized()
        bw, bh, t = w + 0.005, 0.021, 0.0034
        up = Vector((0, -math.sin(th), math.cos(th))).normalized()
        fwd = Vector((1, 0, 0))
        bm = bmesh.new()
        outer = [(-bw/2, -bh/2), (bw/2, -bh/2), (bw/2, bh/2), (-bw/2, bh/2)]
        inner = [(-bw/2+t, -bh/2+t), (bw/2-t, -bh/2+t), (bw/2-t, bh/2-t), (-bw/2+t, bh/2-t)]
        def P(u, v, d): return p + fwd*u + up*v + n*d
        layers = [[bm.verts.new(P(u, v, d)) for (u, v) in ring] for d in (0, 0.0028) for ring in (outer, inner)]
        o0, i0, o1, i1 = layers
        for i in range(4):
            j = (i+1) % 4
            bm.faces.new((o0[i], o0[j], o1[j], o1[i])); bm.faces.new((i0[j], i0[i], i1[i], i1[j]))
            bm.faces.new((o0[j], o0[i], i0[i], i0[j])); bm.faces.new((o1[i], o1[j], i1[j], i1[i]))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm_obj(f"Strap | buckle {k}", bm, "steel_dark", bevel=0.0007)
        cyl(f"Strap | buckle bar {k}", P(-bw/2 + t/2, 0, 0.0014), P(bw/2 - t/2, 0, 0.0014), 0.0013, "steel_dark", seg=10)
        cyl(f"Strap | buckle prong {k}", P(0, 0, 0.0016), P(0, bh/2 - 0.0004, 0.0034), 0.0008, "steel_dark", seg=8)
        # strap tail
        tail = box(f"Strap | tail {k}", -w/2+0.002, w/2-0.002, -0.004, 0.004, -0.001, 0.001, "webbing", bevel=0.0005)
        tail.matrix_world = Matrix.Translation(P(0, bh/2 + 0.004, 0.0030)) @ Matrix((fwd, up, n)).transposed().to_4x4() @ Matrix.Diagonal((1, 3.6, 1, 1))
        keeper = box(f"Strap | keeper {k}", -bw/2 - 0.0006, bw/2 + 0.0006, -0.003, 0.003, -0.0012, 0.0012, "leather_band", bevel=0.0006)
        keeper.matrix_world = Matrix.Translation(P(0, bh/2 + 0.016, 0.0034)) @ Matrix((fwd, up, n)).transposed().to_4x4()

    # DEADBOLT plate: curved steel plate on the inner side
    x0, x1 = -0.196, -0.104
    th0, th1 = math.radians(-4), math.radians(50)
    rings = []
    for i in range(13):
        th = th0 + (th1 - th0)*i/12
        rings.append([cuff_pt(x, th, off) for x, off in ((x0, 0.0058), (x0, 0.0092), (x1, 0.0092), (x1, 0.0058))])
    loft("Gauntlet | DEADBOLT plate", rings, "steel_plate", close_u=True, cap0=True, cap1=True, bevel=0.0008)
    thm = (th0 + th1)/2
    pm = cuff_pt((x0+x1)/2, thm, 0.0094)
    nrm = Vector((0, math.cos(thm), math.sin(thm)))
    rot = Matrix((Vector((1, 0, 0)), nrm.cross(Vector((1, 0, 0))).normalized()*-1, nrm)).transposed()
    t = text("Gauntlet | DEADBOLT stamp", "DEADBOLT", pm, (0, 0, 0), 0.0190, "black", extrude=0.0004)
    t.rotation_euler = (Matrix.Rotation(0, 3, 'Z') @ Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))).to_euler()
    # orient text: X along sleeve, normal = plate normal
    zt = nrm; xt = Vector((-1, 0, 0)); yt = zt.cross(xt)
    t.rotation_euler = Matrix((xt, yt, zt)).transposed().to_euler()
    t.location = pm + nrm*0.0002
    for (x, th) in ((x0+0.005, th0+0.07), (x1-0.005, th0+0.07), (x0+0.005, th1-0.07), (x1-0.005, th1-0.07)):
        p = cuff_pt(x, th, 0.0092); n = Vector((0, math.cos(th), math.sin(th)))
        cyl("Gauntlet | plate rivet", p - n*0.0005, p + n*0.0012, 0.0017, "steel", seg=12, r1=0.0012)

def build_mount():
    # saddle plate conforming to the top of the sleeve
    rings = []
    for i in range(25):
        x = -0.272 + (0.030 + 0.272)*i/24
        ring = []
        for th, off in ((math.radians(38), 0.0068), (math.radians(142), 0.0068), (math.radians(142), 0.0105), (math.radians(38), 0.0105)):
            ring.append(cuff_pt(x, th, off))
        # densify arc
        arc_lo = [cuff_pt(x, math.radians(38 + 104*k/12), 0.0068) for k in range(13)]
        arc_hi = [cuff_pt(x, math.radians(142 - 104*k/12), 0.0115) for k in range(13)]
        rings.append(arc_lo + arc_hi)
    loft("Mount | saddle plate", rings, "steel_dark", close_u=True, cap0=True, cap1=True, bevel=0.001)
    # flat deck on top of saddle the stack sits on
    box("Mount | deck", -0.270, 0.030, -0.034, 0.034, cuff_top(-0.1) + 0.006, 0.050, "gunmetal", bevel=0.0012)
    # the stack recoils back along these rails, so the deck top is seen on every shot
    for y in (-0.024, 0.024):
        box("Mount | slide rail", -0.268, 0.028, y - 0.004, y + 0.004, 0.0495, 0.0530, "steel_bright", bevel=0.0008)
        for x in (-0.240, -0.160, -0.080, 0.000):
            hexbolt("Mount | rail bolt", (x, y, 0.0530), (0, 0, 1), r=0.0017, h=0.0008)
    box("Mount | rail stop", 0.022, 0.030, -0.030, 0.030, 0.0495, 0.0560, "steel_dark", bevel=0.0008)
    # strap guide loops hanging from the saddle sides
    for xc in (-0.245, -0.088, -0.050):
        for side in (1, -1):
            th = math.radians(36 if side > 0 else 144)
            p = cuff_pt(xc, th, 0.012)
            cyl("Mount | strap guide", p - Vector((0.011, 0, 0)), p + Vector((0.011, 0, 0)), 0.0026, "steel", seg=12)

def build_rear():
    T = REAR_TOP
    # main rear housing (yellow, hazard) - holds the pneumatic chamber; tapers toward the front stack
    hb = box("Rear | housing", -0.262, -0.128, -0.052, 0.052, 0.048, T, "yellow_hazard", bevel=0.0025)
    for v in hb.data.vertices:
        if v.co.x > -0.2: v.co.y *= 0.66
    # steel end caps / frame bands around the housing
    for x0, x1, hw in ((-0.268, -0.256, 0.0555), (-0.170, -0.163, 0.0410), (-0.134, -0.122, 0.0375)):
        prism("Rear | frame band", [(-hw, 0.046), (hw, 0.046), (hw, T + 0.003), (-hw, T + 0.003)], x0, x1, "steel_dark", bevel=0.0012)
    # chamber vent ports on top of the housing
    for i in range(5):
        x = -0.252 + i*0.0115
        box("Rear | vent slot", x, x + 0.0060, -0.034, -0.014, T - 0.0005, T + 0.0012, "black", bevel=0.0005)
    # spike feed cap: closes the bore behind the housing and holds the tail of a drawn-in rod
    cyl("Rear | feed cap", (-0.292, 0, AXIS_Z), (-0.256, 0, AXIS_Z), 0.0175, "steel", seg=40, bevel=0.0012)
    cyl("Rear | feed cap end", (-0.298, 0, AXIS_Z), (-0.290, 0, AXIS_Z), 0.0195, "steel_dark", seg=8, bevel=0.0010)
    tube_ring("Rear | feed cap band", (-0.280, 0, AXIS_Z), (-0.274, 0, AXIS_Z), 0.0190, 0.0170, "steel_dark", seg=40)
    for k in range(4):
        a = TAU*k/4 + math.pi/4
        hexbolt("Rear | feed cap bolt", (-0.298, 0.013*math.cos(a), AXIS_Z + 0.013*math.sin(a)), (-1, 0, 0), r=0.0018, h=0.0012)
    # Horzine power box on the inner (+Y) side
    bx0, bx1, by0, by1, bz0, bz1 = -0.318, -0.200, 0.026, 0.068, 0.004, 0.074
    box("Rear | upper hazard block", -0.316, -0.204, 0.026, 0.066, 0.074, T - 0.005, "yellow_hazard", bevel=0.0022)
    box("Rear | upper block band", -0.262, -0.256, 0.025, 0.0675, 0.073, T - 0.0035, "steel_dark", bevel=0.0008)
    for x in (-0.300, -0.276, -0.236, -0.214):
        for z in (0.012, 0.068):
            hexbolt("Rear | box rivet", (x, 0.068, z), (0, 1, 0), r=0.0016, h=0.0010)
    box("Rear | Horzine box", bx0, bx1, by0, by1, bz0, bz1, "steel", bevel=0.0055)
    box("Rear | Horzine box lid seam", bx0 + 0.004, bx1 - 0.004, by1 - 0.001, by1 + 0.0006, bz1 - 0.012, bz1 - 0.0105, "black", bevel=0.0002)
    box("Rear | Horzine end cap", bx0 - 0.006, bx0 + 0.010, by0 + 0.002, by1 + 0.003, bz0 - 0.002, bz1 + 0.003, "steel_dark", bevel=0.002)
    for i in range(5):
        z = bz0 + 0.010 + i*0.011
        box("Rear | end cap grille", bx0 - 0.0068, bx0 - 0.005, by0 + 0.008, by1 - 0.004, z, z + 0.004, "black", bevel=0.0004)
    lx0, lx1, lz0, lz1 = -0.292, -0.220, 0.024, 0.058
    box("Rear | Horzine label plate", lx0, lx1, by1, by1 + 0.0022, lz0, lz1, "steel_bright", bevel=0.0009)
    for x in (lx0 + 0.004, lx1 - 0.004):
        for z in (lz0 + 0.004, lz1 - 0.004):
            hexbolt("Rear | label screw", (x, by1 + 0.0022, z), (0, 1, 0), r=0.0016, h=0.0008)
    cx = lx1 - 0.013; cz = (lz0 + lz1)/2
    tube_ring("Rear | logo ring", (cx, by1 + 0.0018, cz), (cx, by1 + 0.0036, cz), 0.0150, 0.0124, "black", seg=48)
    yl = by1 + 0.0022
    for dx in (-0.0045, 0.0045):
        box("Rear | logo H post", cx + dx*1.25 - 0.0020, cx + dx*1.25 + 0.0020, yl, yl + 0.0014, cz - 0.0175, cz + 0.0175, "black", bevel=0.0003)
    box("Rear | logo H bar", cx - 0.0056, cx + 0.0056, yl, yl + 0.0014, cz - 0.0019, cz + 0.0019, "black", bevel=0.0003)
    tx = text("Rear | HORZINE", "HORZINE", (cx - 0.036, by1 + 0.0024, cz), (0, 0, 0), 0.0115, "black", extrude=0.0004)
    tx.rotation_euler = (math.radians(90), 0, math.radians(180))
    # status lamp on the box top
    cyl("Rear | lamp bezel", (-0.212, 0.040, T - 0.005), (-0.212, 0.040, T - 0.001), 0.0048, "steel_dark", seg=20)
    cyl("Rear | lamp", (-0.212, 0.040, T - 0.002), (-0.212, 0.040, T + 0.0006), 0.0034, "bore_glow", seg=20)

    # pneumatic reservoir drum on the outer (-Y) side
    ry, rz, rr = -0.066, 0.036, 0.0205
    cyl("Rear | reservoir", (-0.300, ry, rz), (-0.175, ry, rz), rr, "steel", seg=40, bevel=0.0015)
    cyl("Rear | flank tank", (-0.306, 0.071, 0.084), (-0.214, 0.071, 0.084), 0.0115, "steel", seg=40, bevel=0.0013)
    for x in (-0.310, -0.216):
        cyl("Rear | flank tank cap", (x, 0.071, 0.084), (x + 0.006, 0.071, 0.084), 0.0125, "steel_dark", seg=40, bevel=0.0010)
    for x in (-0.284, -0.240):
        tube_ring("Rear | flank tank strap", (x, 0.071, 0.084), (x + 0.006, 0.071, 0.084), 0.0132, 0.0113, "steel_dark", seg=40)
    for x in (-0.304, -0.177):
        cyl("Rear | reservoir cap", (x, ry, rz), (x + 0.010, ry, rz), rr + 0.0015, "steel_dark", seg=40, bevel=0.0012)
    for x in (-0.272, -0.244, -0.215):
        tube_ring("Rear | reservoir clamp", (x, ry, rz), (x + 0.007, ry, rz), rr + 0.0024, rr - 0.0002, "steel_dark", seg=40)
        box("Rear | reservoir clamp foot", x, x + 0.007, ry + 0.012, -0.040, rz - 0.003, rz + 0.012, "steel_dark", bevel=0.0008)
    # pressure gauge on reservoir rear
    gx, gz = -0.288, rz + rr
    cyl("Rear | gauge stem", (gx, ry, gz - 0.003), (gx, ry, gz + 0.006), 0.0024, "brass", seg=12)
    cyl("Rear | gauge body", (gx, ry, gz + 0.006), (gx, ry, gz + 0.014), 0.0095, "brass", seg=32)
    cyl("Rear | gauge face", (gx, ry, gz + 0.0138), (gx, ry, gz + 0.0144), 0.0081, "gauge_face", seg=32)
    box("Rear | gauge needle", gx - 0.0005, gx + 0.0005, ry - 0.0062, ry + 0.0005, gz + 0.0142, gz + 0.0148, "wire_red", bevel=0)
    # pneumatic ram (hammer): a tall block riding rails on the housing top. It jolts back before a
    # shot and slams into the bulkhead as the spike leaves (deadbolt_anim DB_Hammer).
    hx0, hx1, ht = -0.196, -0.134, T + 0.030
    for side in (1, -1):
        y0, y1 = sorted((side*0.0235, side*0.0300))
        box("Rear | ram rail", -0.206, -0.132, y0, y1, T, T + 0.008, "steel_dark", bevel=0.0008)
    box("Hammer | ram block", hx0, hx1, -0.0235, 0.0235, T + 0.001, ht, "steel", bevel=0.0025)
    box("Hammer | ram cap", hx0 + 0.006, hx1 - 0.008, -0.018, 0.018, ht, ht + 0.005, "steel_dark", bevel=0.001)
    box("Hammer | striker plate", hx1 - 0.004, hx1 + 0.0005, -0.019, 0.019, T + 0.004, ht - 0.004, "steel_dark", bevel=0.0008)
    for y in (-0.014, 0.014):
        cyl("Hammer | port", (hx0, y, T + 0.013), (hx0 - 0.009, y, T + 0.013), 0.0072, "steel_dark", seg=6)
    for x in (-0.180, -0.153):
        cyl("Hammer | valve stem", (x, 0.0, ht + 0.005), (x, 0.0, ht + 0.011), 0.0024, "steel", seg=12)
        cyl("Hammer | valve knob", (x, 0.0, ht + 0.011), (x, 0.0, ht + 0.016), 0.0064, "valve_blue", seg=16)
    for side in (1, -1):
        cyl("Hammer | side union", (-0.163, side*0.0235, T + 0.019), (-0.163, side*0.031, T + 0.019), 0.0052, "steel_dark", seg=6)
        hexbolt("Hammer | ram bolt", (-0.188, side*0.0235, T + 0.022), (0, side, 0), r=0.0019, h=0.001)
        hexbolt("Hammer | ram bolt", (-0.142, side*0.0235, T + 0.022), (0, side, 0), r=0.0019, h=0.001)
    for x in (-0.240, -0.212):
        box("Rear | hose saddle", x, x + 0.006, -0.022, 0.022, T, T + 0.006, "steel_dark", bevel=0.0006)

def build_front():
    zc = AXIS_Z
    # side frame: clamp collars that wrap the whole front stack
    rect_frame("Front | clamp collar", -0.128, -0.118, 0.036, 0.046, 0.121, 0.0055, "steel")
    # the forward collars stop at the slot rails, so the rod reads as one continuous glowing length
    for x0, x1 in ((-0.066, -0.060), (-0.012, -0.002)):
        box("Front | clamp collar top", x0, x1, -0.036, 0.036, 0.1155, 0.121, "steel", bevel=0.0010)
        box("Front | clamp collar foot", x0, x1, -0.036, 0.036, 0.046, 0.0515, "steel", bevel=0.0010)
        for side in (1, -1):
            y0, y1 = sorted((side*0.0305, side*0.036))
            box("Front | clamp collar cheek", x0, x1, y0, y1, 0.0965, 0.121, "steel", bevel=0.0008)
            box("Front | clamp collar cheek", x0, x1, y0, y1, 0.046, 0.0635, "steel", bevel=0.0008)
    prism("Front | bulkhead", [(-0.040, 0.040), (0.040, 0.040), (0.040, 0.124), (0.030, 0.134), (-0.030, 0.134), (-0.040, 0.124)], -0.131, -0.119, "steel_dark", bevel=0.0015)
    for side in (1, -1):
        for z in (0.050, 0.088, 0.122):
            hexbolt("Front | bulkhead bolt", (-0.125, side*0.040, z), (0, side, 0), r=0.0024, h=0.0016)
        # gusset bracket dropping from bulkhead onto the saddle
        prism("Front | bulkhead gusset", [(side*0.034, 0.034), (side*0.046, 0.034), (side*0.046, 0.070), (side*0.034, 0.070)] if side > 0 else
              [(side*0.046, 0.034), (side*0.034, 0.034), (side*0.034, 0.070), (side*0.046, 0.070)], -0.134, -0.116, "steel", bevel=0.001)
    # hollow out collars visually by adding dark inner bolts
    for x in (-0.123, -0.007):
        for side in (1, -1):
            for z in (0.054, 0.113):
                hexbolt("Front | collar bolt", (x, side*0.036, z), (0, side, 0))
    # side rails forming the window over the glass tube
    for side in (1, -1):
        y0, y1 = (0.026, 0.033) if side > 0 else (-0.033, -0.026)
        box("Front | window rail upper", -0.120, 0.000, y0, y1, 0.096, 0.101, "steel_dark", bevel=0.0009)
        box("Front | window rail lower", -0.120, 0.000, y0, y1, 0.059, 0.064, "steel_dark", bevel=0.0009)
    # upper hazard plate
    box("Front | upper hazard plate", -0.130, 0.062, -0.031, 0.031, 0.101, 0.121, "yellow_hazard", bevel=0.002)
    box("Front | centre spine", -0.131, -0.028, -0.0065, 0.0065, 0.1205, 0.1265, "steel", bevel=0.0009)
    for x in (-0.118, -0.090, -0.062, -0.040):
        hexbolt("Front | spine bolt", (x, 0, 0.1265), (0, 0, 1), r=0.0019, h=0.0012)
    # top deck plate extending forward over the spike (sight hood in front view)
    prism("Front | top deck", [(-0.022, 0.121), (0.022, 0.121), (0.011, 0.135), (-0.011, 0.135)], -0.030, 0.046, "yellow_hazard", bevel=0.0012)
    for side in (1, -1):
        prism("Front | latch prong", [(side*0.010, 0.121), (side*0.022, 0.121), (side*0.018, 0.131), (side*0.010, 0.131)] if side > 0 else
              [(side*0.022, 0.121), (side*0.010, 0.121), (side*0.010, 0.131), (side*0.018, 0.131)], 0.046, 0.100, "gunmetal", bevel=0.0010)
    box("Front | latch bridge", 0.092, 0.100, -0.021, 0.021, 0.1185, 0.1215, "steel_dark", bevel=0.0008)
    box("Front | latch pin", -0.012, 0.004, -0.003, 0.003, 0.131, 0.1345, "steel_dark", bevel=0.0008)
    for side in (1, -1):
        prism("Front | hood cheek", [(side*0.018, 0.108), (side*0.024, 0.108), (side*0.024, 0.119), (side*0.018, 0.119)] if side > 0 else
              [(side*0.024, 0.108), (side*0.018, 0.108), (side*0.018, 0.119), (side*0.024, 0.119)], 0.040, 0.078, "gunmetal", bevel=0.0007)
    box("Front | deck slot", 0.010, 0.046, -0.003, 0.003, 0.1345, 0.1355, "black", bevel=0.0002)
    # lower hazard rail
    box("Front | lower hazard rail", -0.118, 0.064, -0.033, 0.033, 0.0465, 0.0605, "yellow_hazard", bevel=0.0018)
    # glass heating chamber + superheated rod + energy coil
    # heating chamber behind the side slot: the idle spike's rear quarter sits in it, wound by a heater coil
    tube_ring("Front | glass chamber", (-0.118, 0, zc), (-0.004, 0, zc), 0.0155, 0.0146, "glass", seg=48, bevel=0.0003)
    helix_tube("Front | heater coil", (-0.116, 0, zc), 0.028, 0.0163, 0.0070, 0.0012, "coil_glow")
    for x in (-0.122, -0.008):
        tube_ring("Front | chamber end ring", (x, 0, zc), (x + 0.008, 0, zc), 0.0180, BORE_R + 0.001, "chrome", seg=40)
    tube_ring("Front | coil terminal ring", (-0.088, 0, zc), (-0.085, 0, zc), 0.0172, 0.0156, "copper", seg=40)
    box("Front | slot glow floor", -0.084, -0.003, -0.012, 0.012, 0.0607, 0.0614, "slot_glow", bevel=0)
    box("Front | slot glow roof", -0.084, -0.003, -0.012, 0.012, 0.1000, 0.1007, "slot_glow", bevel=0)
    # pneumatic drive pistons along the lower sides
    # fat pneumatic drive drums along the lower sides; their chrome rods drive the yoke (DB_Yoke)
    for side in (1, -1):
        y = side*0.0405; z = 0.0400
        cyl("Front | piston body", (-0.120, y, z), (-0.044, y, z), 0.0135, "steel", seg=32, bevel=0.0010)
        for xr in (-0.108, -0.084, -0.060):
            tube_ring("Front | piston band", (xr, y, z), (xr + 0.005, y, z), 0.0148, 0.0128, "steel_dark", seg=32)
        cyl("Front | piston gland", (-0.044, y, z), (-0.036, y, z), 0.0096, "steel_dark", seg=6)
        cyl("Front | piston cap", (-0.127, y, z), (-0.119, y, z), 0.0145, "steel_dark", seg=32)
        cyl("Front | piston rod", (-0.036, y, z), (0.074, y, z), 0.0052, "chrome", seg=20)
        cyl("Front | piston eye", (0.071, y, z), (0.080, y, z), 0.0080, "steel_dark", seg=20)
        y0, y1 = (0.008, 0.046) if side > 0 else (-0.046, -0.008)
        box("Front | yoke plate", 0.072, 0.080, y0, y1, 0.032, 0.066, "steel_dark", bevel=0.0010)
    # muzzle block with bore glow
    box("Front | muzzle block", -0.002, 0.040, -0.026, 0.026, 0.064, 0.098, "steel_plate", bevel=0.0025)
    box("Front | muzzle face plate", 0.040, 0.044, -0.022, 0.022, 0.066, 0.096, "steel", bevel=0.0012)
    for y in (-0.019, 0.019):
        for z in (zc - 0.019, zc + 0.019):
            hexbolt("Front | face bolt", (0.044, y, z if z > 0.08 else z + 0.004), (1, 0, 0), r=0.0020)
    tube_ring("Front | bore ring", (0.042, 0, zc), (0.0475, 0, zc), 0.0165, BORE_R, "steel_dark", seg=40)
    tube_ring("Front | muzzle collar", (0.044, 0, zc), (0.064, 0, zc), 0.0185, BORE_R, "steel", seg=48, bevel=0.0008)
    tube_ring("Front | muzzle crown", (0.063, 0, zc), (0.070, 0, zc), 0.0205, BORE_R, "steel_dark", seg=48, bevel=0.0008)
    for k in range(6):
        a = TAU*k/6 + 0.26
        hexbolt("Front | crown bolt", (0.070, 0.0168*math.cos(a), zc + 0.0168*math.sin(a)), (1, 0, 0), r=0.0016, h=0.0012)
    tube_ring("Front | yoke clamp", (0.072, 0, zc), (0.080, 0, zc), 0.0215, BORE_R, "steel", seg=48, bevel=0.0008)
    box("Front | yoke web", 0.072, 0.080, -0.006, 0.006, 0.052, zc - 0.018, "steel_dark", bevel=0.0008)
    for k in range(4):
        a = TAU*k/4 + math.pi/4
        hexbolt("Front | yoke bolt", (0.080, 0.0178*math.cos(a), zc + 0.0178*math.sin(a)), (1, 0, 0), r=0.0017, h=0.0012)
    # throat glow deep in the muzzle: a ring of heat round the spike, a glowing hole when the bore is empty
    cyl("Front | bore glow", (0.046, 0, zc), (0.0475, 0, zc), BORE_R, "bore_glow", seg=40, bevel=0)
    build_flare()
    # side cheek panels on the muzzle block
    for side in (1, -1):
        y0, y1 = (0.029, 0.032) if side > 0 else (-0.032, -0.029)
        box("Front | muzzle cheek", 0.004, 0.036, y0 - side*0.003, y1 - side*0.003, 0.068, 0.094, "steel_dark", bevel=0.0008)
        for x in (0.010, 0.030):
            hexbolt("Front | cheek bolt", (x, side*0.029, 0.090), (0, side, 0), r=0.0016, h=0.0011)

def spike_profile(t):
    """Core radius and thread height at t (0 base .. 1 point) of the forged rod."""
    if t < 0.05:                       # plain shank where the feed grips it
        return 0.0100, 0.0
    body = min(1.0, (t - 0.05)/0.80)
    core = 0.0092 - 0.0054*body
    h = (0.0046 - 0.0024*body)*min(1.0, (t - 0.05)/0.030)
    if t > 0.85:                       # sharp drill point
        k = (1.0 - t)/0.15
        core *= k**0.85
        h *= max(0.0, (k - 0.12)/0.88)
    return core + 0.00015, h

FLARE_X0, FLARE_X1 = 0.071, 0.270
def build_flare():
    """Muzzle burst: a spindle of fire with six petals, in the glow slot. Shown for the launch frames
    only (script hides its bone otherwise); deadbolt_anim stretches it along X with DB_FlareTip."""
    zc = AXIS_Z
    prof = ((0.000, 0.011), (0.06, 0.030), (0.20, 0.042), (0.45, 0.034), (0.75, 0.016), (1.0, 0.0005))
    rings = []
    for u, r in prof:
        x = FLARE_X0 + (FLARE_X1 - FLARE_X0)*u
        rings.append([Vector((x, r*math.cos(TAU*j/16)*(1 + 0.18*math.sin(5*TAU*j/16 + u*7)), zc + r*math.sin(TAU*j/16))) for j in range(16)])
    ob = loft("Flare | muzzle burst", rings, "flare_glow", cap0=True)
    ob.hide_render = True
    for k in range(6):
        a = TAU*k/6 + 0.3
        d = Vector((math.cos(math.radians(38)), math.sin(math.radians(38))*math.cos(a), math.sin(math.radians(38))*math.sin(a)))
        p0 = Vector((FLARE_X0 + 0.004, 0, zc))
        pe = cyl("Flare | petal", p0, p0 + d*0.115, 0.0045, "flare_glow", seg=6, r1=0.0004, bevel=0)
        pe.hide_render = True

def build_spike():
    """Two-start tapered helix (twisted rebar / drill bit), swept as one loft so the thread is continuous.
    The lead tightens toward the point. Origin at the base on the bore axis; +X is the launch direction."""
    L = SPIKE_LEN
    rings = []; crest = []
    NU, NV = Q['spike']
    phase = 0.0
    for i in range(NU + 1):
        t = i/NU
        if i:
            phase += (L/NU)/(0.052 - 0.024*t)      # turns of one flute per metre of rod
        core, h = spike_profile(t)
        ring = []
        for j in range(NV):
            th = TAU*j/NV
            f = (SPIKE_STARTS*(phase - th/TAU)) % 1.0
            tri = 1.0 - abs(2.0*f - 1.0)           # 1 on a crest, 0 in a groove
            prof = tri**1.35
            crest.append(prof if h > 0 else 0.35)
            r = core + h*prof
            ring.append(Vector((t*L, r*math.cos(th), r*math.sin(th))))
        rings.append(ring)
    ob = loft("Spike | thermal auger", rings, "spike", cap0=True)
    a = ob.data.attributes.new('crest', 'FLOAT', 'POINT')
    a.data.foreach_set('value', crest)
    ob.location = (SPIKE_X0, 0, AXIS_Z)
    for name, dx, power in (("Spike | glow light A", 0.045, 2.2), ("Spike | glow light B", 0.200, 1.0)):
        ld = bpy.data.lights.new(name, 'POINT'); ld.energy = power; ld.color = (1.0, 0.38, 0.08); ld.shadow_soft_size = 0.012
        lo = bpy.data.objects.new(name, ld); lo.location = (SPIKE_X0 + dx, 0.0, AXIS_Z); link(lo)
    return ob

def build_hoses():
    T = REAR_TOP
    zs = T + 0.0115
    # valve stack running back from the ram along the housing top (slides with DB_Hammer)
    cyl("Hammer | valve stack", (-0.262, 0, zs), (-0.205, 0, zs), 0.0072, "steel", seg=24)
    for x in (-0.256, -0.232, -0.218):
        cyl("Hammer | stack union", (x, 0, zs), (x + 0.008, 0, zs), 0.0098, "steel_dark", seg=6)
    cyl("Hammer | stack valve stem", (-0.224, 0, zs + 0.006), (-0.224, 0, zs + 0.013), 0.0021, "steel", seg=12)
    cyl("Hammer | stack valve knob", (-0.224, 0, zs + 0.013), (-0.224, 0, zs + 0.017), 0.0054, "valve_blue", seg=16)
    # finger-thick corrugated hoses: ram ports -> U-loops over the back -> reservoir drum and power box
    pz = T + 0.013
    curve_tube("Hose | outer loop", [(-0.204, -0.014, pz), (-0.230, -0.022, pz + 0.002), (-0.264, -0.036, pz - 0.002), (-0.298, -0.054, T - 0.006),
                                     (-0.326, -0.068, 0.084), (-0.338, -0.070, 0.054), (-0.328, -0.066, 0.038), (-0.312, -0.066, 0.036)], 0.0085, "hose")
    curve_tube("Hose | inner loop", [(-0.204, 0.014, pz), (-0.230, 0.022, pz + 0.002), (-0.264, 0.032, pz + 0.001), (-0.302, 0.040, T + 0.006),
                                     (-0.338, 0.046, 0.098), (-0.348, 0.050, 0.074), (-0.344, 0.049, 0.060), (-0.332, 0.048, 0.052)], 0.0085, "hose")
    curve_tube("Hose | inner drop", [(-0.330, 0.052, 0.030), (-0.343, 0.058, 0.012), (-0.346, 0.052, -0.008), (-0.332, 0.042, -0.024), (-0.314, 0.038, -0.032)], 0.0070, "hose")
    curve_tube("Hose | outer drop", [(-0.308, -0.066, 0.022), (-0.330, -0.060, 0.010), (-0.338, -0.052, -0.010), (-0.328, -0.040, -0.026), (-0.312, -0.034, -0.034)], 0.0070, "hose")
    curve_tube("Hose | reservoir feed", [(-0.174, -0.066, 0.040), (-0.168, -0.066, 0.064), (-0.165, -0.058, 0.102), (-0.164, -0.046, T + 0.016), (-0.163, -0.034, T + 0.019)], 0.0065, "hose")
    # red power leads: short, tight runs clipped to the housing
    curve_tube("Wire | red A", [(-0.163, 0.033, T + 0.019), (-0.176, 0.041, T + 0.014), (-0.196, 0.045, T + 0.006), (-0.222, 0.045, T - 0.0025)], 0.0026, "wire_red", bevel_res=2)
    curve_tube("Wire | red B", [(-0.163, -0.033, T + 0.019), (-0.178, -0.046, T + 0.002), (-0.194, -0.052, 0.094), (-0.212, -0.055, 0.076)], 0.0024, "wire_red", bevel_res=2)
    sp = []
    for i in range(61):
        f = i/60
        sp.append(tuple(cuff_pt(-0.300 + f*0.250, math.radians(30 - 2.25*360*f), 0.0058)))
    curve_tube("Wire | sleeve spiral", sp, 0.0021, "wire_red", res=4, bevel_res=2)
    curve_tube("Wire | sleeve black", [tuple(cuff_pt(x, math.radians(a), 0.0068)) for x, a in
                                        ((-0.306, 40), (-0.288, 26), (-0.262, 16), (-0.238, 12), (-0.214, 8))], 0.0026, "hose_smooth", bevel_res=2)
    for pnt in ((-0.222, 0.045, T - 0.0025), (-0.248, 0.018, T + 0.002)):
        cyl("Wire | end fitting", Vector(pnt) + Vector((0.004, 0, 0)), Vector(pnt) - Vector((0.004, 0, 0)), 0.0036, "brass", seg=6)
    curve_tube("Wire | red C", [(-0.300, 0.030, 0.050), (-0.296, 0.026, 0.060), (-0.284, 0.040, T - 0.004), (-0.266, 0.030, T + 0.003), (-0.248, 0.018, T + 0.002)], 0.0020, "wire_red", bevel_res=2)
    for y in (-0.014, 0.014):
        cyl("Hammer | hose ferrule", (-0.204, y, pz), (-0.215, y, pz), 0.0105, "steel", seg=6)
    cyl("Hose | ferrule", (-0.324, 0.048, 0.052), (-0.334, 0.048, 0.052), 0.0105, "steel", seg=6)
    cyl("Hose | ferrule", (-0.304, -0.066, 0.036), (-0.315, -0.066, 0.036), 0.0105, "steel", seg=6)
    cyl("Hose | ferrule", (-0.177, -0.066, 0.040), (-0.169, -0.066, 0.046), 0.0090, "steel", seg=6)
    # hose clips on the housing top
    for y in (-0.030, 0.030):
        box("Hose | clip", -0.244, -0.238, y - 0.011, y + 0.011, T + 0.004, T + 0.0235, "steel_dark", bevel=0.0007)

def build_forearm_stub():
    """The forearm continuing out of the sleeve rear (display only, so the sleeve does not read as a hollow tube)."""
    c = get_coll("DB_Hand")
    old = bpy.data.objects.get("Display | forearm sleeve")
    if old: bpy.data.objects.remove(old, do_unlink=True)
    ry, rz, cz = cuff_frame(X_REAR)
    rings = []
    for i in range(10):
        x = X_REAR + 0.014 - 0.009*i
        k = (0.86 - 0.008*i)*(1.0 if i < 7 else (0.95, 0.84, 0.62)[i - 7])
        rings.append([Vector((x, ry*k*math.cos(TAU*j/40) + 0.0008*math.sin(7*j + i), cz + rz*k*math.sin(TAU*j/40))) for j in range(40)])
    ob = loft("Display | forearm sleeve", rings, "skin", cap1=True)
    ob.hide_render = True    # reads as a mannequin stump; kept for viewport context only
    get_coll(COLL).objects.unlink(ob); c.objects.link(ob)

def build_decals():
    """Stencilled markings in worn white paint."""
    rot_in = (math.radians(90), 0, math.radians(180))   # reads from the inner (+Y) side
    rot_out = (math.radians(90), 0, 0)                  # reads from the outer (-Y) side
    text("Decal | caution hot", "CAUTION  HOT", (-0.062, 0.0312, 0.1110), rot_in, 0.0075, "paint_white", extrude=0.00015)
    text("Decal | unit number", "07", (0.020, 0.0323, 0.0800), rot_in, 0.0150, "paint_white", extrude=0.00015)
    text("Decal | pressure", "MAX 900 PSI", (-0.212, -0.0456, 0.0980), rot_out, 0.0062, "paint_white", extrude=0.00015)
    text("Decal | serial", "HZ-DB/07", (-0.212, -0.0456, 0.0885), rot_out, 0.0052, "paint_white", extrude=0.00015)

def build_all():
    clear_coll(COLL)
    build_materials()
    build_gauntlet(); build_forearm_stub(); build_mount(); build_rear(); build_front(); build_spike(); build_hoses(); build_decals()
    g = bpy.data.objects.get("DB_Glove")
    if g:
        g.data.materials.clear(); g.data.materials.append(MATS["glove"])
        for p in g.data.polygons: p.use_smooth = True
    return len(get_coll(COLL).objects)
