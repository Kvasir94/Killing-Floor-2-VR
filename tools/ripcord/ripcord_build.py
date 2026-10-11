# Ripcord forearm winch grapple - procedural build.
#
# Breacher tier-2 gauntlet: Horzine rigging gear. One grapple hook lives permanently on the end of
# the winch cable; the gun launches it, reels the Zed in on it, and winds it home again. The cycle
# reads in the parts:
#
#   launch   a pneumatic ram on top of the rail drives a yoke that kicks the hook's tail flange; the
#            hook leaves along the launch rail over the back of the hand,
#   pay out  the cable runs off the drum, over the swivelling diverter sheave on the level-wind,
#            into a bell mouth on the hollow rail beam, along the beam past a sight slot on the
#            player's side, and out through the four-roller fairlead at the wrist on the hook's line,
#   reel     the sealed electric motor winds the drum through its gear case; the pull line runs from
#            the hook back into the fairlead at the wrist, so the Zed comes to the open palm,
#   home     the last metre winds the hook back onto the rail, tail first, claws folding back along
#            its body, until it seats on the yoke and the latch dogs snap over its hinge ring.
#
# The cable is anchored in the hook's tail by a swaged ferrule and a swivel, so the hook can spin
# without kinking the line. The ratchet pawl and the band-brake lever on the drum are the only manual
# parts. The reservoir block at the rear holds the air for the ram and the power for the motor.
#
# Same frame and harness as the Deadbolt (tools/deadbolt/deadbolt_build.py, imported as B): metres,
# wrist centre at the origin, +X toward the fingers, +Z up, +Y the inner/thumb side of the right
# forearm. The canvas sleeve, wraps, straps and saddle are the Deadbolt's, so the pair reads as one
# kit; only the stamp changes. Object name prefixes are the future rig groups.
import math, os, sys
import bpy, bmesh
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(os.path.dirname(HERE), "deadbolt")
if DB not in sys.path:
    sys.path.insert(0, DB)
import deadbolt_build as B

COLL = "RC_Weapon"
TAU = math.tau

# render-model resolution; the game export lowers these
RQ = dict(rope_seg=15, rope_step=8, helix_res=96, helix_turn=24, claw_step=0.0012, spiral_pts=61, ratchet_bevel=0.0004)

# ---------------------------------------------------------------- dimensions
HOOK_Z = 0.094                      # cable line / hook axis height at the wrist
RAIL_X0, RAIL_X1 = -0.230, -0.018   # rail beam: from the reservoir block to the fairlead's foot
FAIR_X0, FAIR_X1 = 0.016, 0.040     # four-roller fairlead at the wrist
FAIRLEAD_SOCKET = (FAIR_X1, 0.0, HOOK_Z)   # where the cable leaves the gauntlet in flight
YOKE_X0, YOKE_X1 = 0.041, 0.049     # launch yoke in front of the fairlead; the hook flange seats on it
HOOK_LEN = 0.168                    # hook space: x 0 is the cable anchor (ferrule end), +X launch
HOOK_FLANGE = 0.030                 # rear face of the forged body (the face the yoke kicks)
HOOK_BODY_R = 0.0165                # forged hex body, about the rail's width across
HOOK_HINGE_X = 0.112                # claw hinge ring
CLAW_SPLAY = -125.0                 # degrees the claws swing from folded (seated) to splayed (launched)
HOOK_X0 = YOKE_X1 - HOOK_FLANGE     # idle: the ferrule sits in the fairlead throat
CRADLE_X1 = 0.140                   # launch rail ahead of the yoke, under the hook shank
RAM_Z = 0.124                       # launch ram axis, on top of the rail
RAM_X0, RAM_X1 = -0.120, -0.018     # ram end caps included
DRUM_X, DRUM_Z = -0.170, 0.090      # winch drum centre (axis along Y)
DRUM_R = 0.058                      # flange radius
PACK_R = 0.0400                     # solid under-layers of cable
CABLE_R = 0.0019                    # braided cable radius
LAY = 0.016                         # strand lay length
RATCHET_R = (0.0500, 0.0560)        # root, tip
SIDE = 1                            # drum side: +1 the inner/thumb side the player sees, -1 the outer side
def sy(v):
    """A y magnitude measured out from the rail toward the drum side."""
    return SIDE*v
# the drum stack, out from the hanger: ratchet, inner flange, cable barrel, outer flange, brake ring,
# gear case; kept as slim as the Deadbolt's inner side so nothing reaches toward the thumb
Y_RATCHET = (sy(0.031), sy(0.035))
Y_IN_FLANGE = (sy(0.035), sy(0.038))
Y_BARREL = (sy(0.038), sy(0.064))
Y_OUT_FLANGE = (sy(0.064), sy(0.067))
Y_BRAKE = (sy(0.067), sy(0.070))
Y_GEAR = (sy(0.0710), sy(0.0775))   # gear case on the drum's open face, motor to hub
MOTOR_X, MOTOR_Z, MOTOR_R = -0.266, 0.100, 0.0215   # electric motor can, axis along Y
GUARD_A = (70.0, 215.0)             # drum guard arc, degrees from +X toward +Z
GUARD_R = (0.0625, 0.0725)                # 10 mm folded plate
GUARD_Y = (sy(0.031), sy(0.072))
GUARD_GAP = (96.0, 126.0)           # open sight gap in the guard over the top of the pack
LW_X = -0.098                       # level-wind screw and guide sheave
SHEAVE_R = 0.0095
CABLE_TOP_Z = DRUM_Z + PACK_R + 3*CABLE_R + 0.0003   # departure height of the top layer
SHEAVE_Z = CABLE_TOP_Z - SHEAVE_R
DEPART_Y = sy(0.051)
BLOCK = (-0.338, RAIL_X0, -0.054, 0.034, 0.048, 0.120) if SIDE > 0 else (-0.338, RAIL_X0, -0.034, 0.054, 0.048, 0.120)   # x0 x1 y0 y1 z0 z1
BELL = (-0.080, sy(0.0165), 0.1015)   # bell mouth where the cable dives into the hollow rail beam
CH_Y, CH_Z = 0.009, 0.089           # cable run inside the beam, just behind the sight slot
SLOT = (-0.086, -0.022, 0.076, 0.098)   # one continuous sight slot in the beam's inner wall, entry to fairlead: x0 x1 z0 z1

# ---------------------------------------------------------------- helpers
def drum_pt(a_deg, r, y):
    a = math.radians(a_deg)
    return Vector((DRUM_X + r*math.cos(a), y, DRUM_Z + r*math.sin(a)))

def catmull(ctrl, step=0.002):
    """Dense Catmull-Rom path through control points (end points repeated)."""
    P = [Vector(p) for p in ctrl]
    P = [P[0]] + P + [P[-1]]
    out = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i-1], P[i], P[i+1], P[i+2]
        n = max(2, int((p2 - p1).length/step))
        for k in range(n):
            t = k/n
            out.append(0.5*((2*p1) + (-p0 + p2)*t + (2*p0 - 5*p1 + 4*p2 - p3)*t*t + (-p0 + 3*p1 - 3*p2 + p3)*t**3))
    out.append(P[-2])
    return out

def resample(pts, step):
    pts = [Vector(p) for p in pts]
    L = [0.0]
    for a, b in zip(pts, pts[1:]):
        L.append(L[-1] + (b - a).length)
    n = max(2, int(L[-1]/step) + 1)
    out, j = [], 0
    for i in range(n):
        s = L[-1]*i/(n - 1)
        while j < len(L) - 2 and L[j+1] < s:
            j += 1
        seg = max(1e-9, L[j+1] - L[j])
        out.append(pts[j].lerp(pts[j+1], (s - L[j])/seg))
    return out, L[-1]

def rope(name, pts, r=CABLE_R, mat="cable", lay=LAY, phase=0.0, tracer=True):
    """Three-strand wire rope swept along a path. One strand carries the 'tracer' attribute, which the
    cable material turns into an emissive stripe spiralling down the line."""
    seg = RQ['rope_seg']
    path, total = resample(pts, lay/RQ['rope_step'])
    n = len(path)
    T = [(path[min(i+1, n-1)] - path[max(i-1, 0)]).normalized() for i in range(n)]
    ref = Vector((0, 0, 1)) if abs(T[0].z) < 0.9 else Vector((1, 0, 0))
    N = (ref - T[0]*ref.dot(T[0])).normalized()
    bm = bmesh.new()
    rings, trc = [], []
    for i in range(n):
        if i:
            N = (N - T[i]*N.dot(T[i])).normalized()
        Bv = T[i].cross(N)
        s = total*i/(n - 1)
        phi = TAU*s/lay + phase
        ring = []
        for j in range(seg):
            th = TAU*j/seg
            psi = (th - phi) % TAU
            k = int(psi/(TAU/3)) % 3
            f = (psi % (TAU/3))/(TAU/3)
            bump = math.sin(math.pi*f)**0.7
            rr = r*(0.80 + 0.20*bump)
            ring.append(bm.verts.new(path[i] + (N*math.cos(th) + Bv*math.sin(th))*rr))
            trc.append((1.0 if k == 0 else 0.0)*min(1.0, bump*1.6) if tracer else 0.0)
        rings.append(ring)
    for a, b in zip(rings[:-1], rings[1:]):
        for j in range(seg):
            k = (j + 1) % seg
            bm.faces.new((a[j], a[k], b[k], b[j]))
    bm.faces.new(list(reversed(rings[0]))); bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = B.bm_obj(name, bm, mat)
    at = ob.data.attributes.new('tracer', 'FLOAT', 'POINT')
    at.data.foreach_set('value', trc)
    return ob

def drum_helix(r, y0, y1, pitch, a_end=90.0):
    """Wraps around the drum axis (Y) from y0 to y1, ending at angle a_end; the angle runs downward so
    the cable leaves the top of the pack heading forward (+X)."""
    turns = abs(y1 - y0)/pitch
    N = int(turns*RQ['helix_res']) + 1
    return [drum_pt(a_end + 360.0*turns*(1 - i/(N - 1)), r, y0 + (y1 - y0)*i/(N - 1)) for i in range(N)]

def disc_y(name, r, y0, y1, mat, seg=48, bevel=0.0008, x=DRUM_X, z=DRUM_Z):
    return B.cyl(name, (x, y0, z), (x, y1, z), r, mat, seg=seg, bevel=bevel)

def ring_y(name, r_out, r_in, y0, y1, mat, seg=56):
    return B.tube_ring(name, (DRUM_X, y0, DRUM_Z), (DRUM_X, y1, DRUM_Z), r_out, r_in, mat, seg=seg)

def sawtooth_wheel(name, teeth, r_root, r_tip, r_in, y0, y1, mat):
    """Ratchet wheel in the XZ plane about the drum axis, extruded along Y."""
    bm = bmesh.new()
    prof = []
    for k in range(teeth):
        a0 = TAU*k/teeth
        prof += [(a0, r_root), (a0 + TAU/teeth*0.70, r_tip), (a0 + TAU/teeth*0.74, r_root)]
    layers = []
    for y in (y0, y1):
        outer = [bm.verts.new((DRUM_X + r*math.cos(a), y, DRUM_Z + r*math.sin(a))) for a, r in prof]
        inner = [bm.verts.new((DRUM_X + r_in*math.cos(a), y, DRUM_Z + r_in*math.sin(a))) for a, _ in prof]
        layers.append((outer, inner))
    (o0, i0), (o1, i1) = layers
    n = len(prof)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((o0[i], o0[j], o1[j], o1[i])); bm.faces.new((i0[j], i0[i], i1[i], i1[j]))
        bm.faces.new((i0[i], i0[j], o0[j], o0[i])); bm.faces.new((o1[i], o1[j], i1[j], i1[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return B.bm_obj(name, bm, mat, bevel=RQ['ratchet_bevel'], angle=50)

def arc_shell(name, a0, a1, r0, r1, y0, y1, mat, n=40, bevel=0.0010):
    rings = []
    for i in range(n + 1):
        a = a0 + (a1 - a0)*i/n
        rings.append([drum_pt(a, r0, y0), drum_pt(a, r1, y0), drum_pt(a, r1, y1), drum_pt(a, r0, y1)])
    return B.loft(name, rings, mat, close_u=True, cap0=True, cap1=True, bevel=bevel)

def gear_case(name, circles, y0, y1, mat):
    """Stadium plate in XZ: the convex hull of circles (x, z, r), extruded along Y."""
    pts = []
    for cx, cz, r in circles:
        pts += [(cx + r*math.cos(TAU*k/48), cz + r*math.sin(TAU*k/48)) for k in range(48)]
    pts = sorted(set(pts))
    def cross(o, a, b):
        return (a[0] - o[0])*(b[1] - o[1]) - (a[1] - o[1])*(b[0] - o[0])
    lo, hi = [], []
    for p in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0: lo.pop()
        lo.append(p)
    for p in reversed(pts):
        while len(hi) >= 2 and cross(hi[-2], hi[-1], p) <= 0: hi.pop()
        hi.append(p)
    hull = lo[:-1] + hi[:-1]
    bm = bmesh.new()
    a = [bm.verts.new((x, y0, z)) for x, z in hull]
    b = [bm.verts.new((x, y1, z)) for x, z in hull]
    bm.faces.new(a); bm.faces.new(list(reversed(b)))
    for i in range(len(hull)):
        j = (i + 1) % len(hull)
        bm.faces.new((a[i], a[j], b[j], b[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return B.bm_obj(name, bm, mat, bevel=0.0012, angle=40)

def sweep(name, path, rad_fn, mat, nv=12, flat=1.0, cap=True, bevel=0.0):
    """Loft a tapered (optionally flattened) section along a dense path; rad_fn(t) -> radius."""
    path = [Vector(p) for p in path]
    n = len(path)
    T = [(path[min(i+1, n-1)] - path[max(i-1, 0)]).normalized() for i in range(n)]
    ref = Vector((0, 0, 1)) if abs(T[0].z) < 0.9 else Vector((0, 1, 0))
    Nn = (ref - T[0]*ref.dot(T[0])).normalized()
    rings = []
    for i in range(n):
        if i:
            Nn = (Nn - T[i]*Nn.dot(T[i])).normalized()
        Bv = T[i].cross(Nn)
        r = rad_fn(i/(n - 1))
        rings.append([path[i] + (Nn*math.cos(TAU*j/nv)*flat + Bv*math.sin(TAU*j/nv))*r for j in range(nv)])
    return B.loft(name, rings, mat, cap0=cap, cap1=cap, bevel=bevel)

# ---------------------------------------------------------------- materials
def mat_cable():
    """Bright galvanised wire rope, greasy in the lay, with one amber tracer strand ('tracer' attribute)
    that glows so the line reads at speed and under load. The 'heat' value is the take's glow key."""
    nt = B.NT(B.newmat("cable"))
    co = B.obj_coord(nt)
    at = nt.n('ShaderNodeAttribute', attribute_type='GEOMETRY', attribute_name='tracer')
    tr = nt.maprange(at.outputs['Fac'], 0.25, 0.75)
    blot = nt.noise(40.0, 6, 0.6, co)
    grease = nt.math('ADD', nt.maprange(nt.ao(0.0018), 0.95, 0.45, 0.0, 0.9), nt.maprange(blot.outputs['Fac'], 0.55, 0.75, 0.0, 0.35))
    col = nt.mix(nt.math('MINIMUM', grease, 0.9), (0.55, 0.54, 0.51), (0.035, 0.030, 0.024))
    col = nt.mix(tr, col, (0.30, 0.10, 0.02))
    wire = nt.n('ShaderNodeVectorMath', operation='MULTIPLY'); nt.l(co, wire.inputs[0]); wire.inputs[1].default_value = (900, 900, 900)
    grain = nt.noise(1.0, 2, 0.5, wire.outputs[0])
    strength = nt.math('MULTIPLY', nt.math('MULTIPLY', tr, 12.0), B.heat(nt))
    nt.bsdf(col, nt.math('SUBTRACT', 1.0, nt.math('MAXIMUM', tr, nt.math('MULTIPLY', grease, 0.5))),
            nt.maprange(grease, 0.0, 1.0, 0.26, 0.62), normal=nt.bump(grain.outputs['Fac'], 0.25, 0.0002),
            emit=(1.0, 0.40, 0.07), emit_strength=strength)

def build_materials(base=True):
    if base:
        B.build_materials()
    mat_cable()
    B.mat_metal("hook_steel", (0.075, 0.072, 0.070), 0.42, grime=0.5)
    B.mat_metal("blade", (0.56, 0.55, 0.53), 0.20, grime=0.25, scratch=0.5)
    B.mat_painted("paint_red", (0.32, 0.025, 0.012), stripes=False, wear=0.7)
    # thin sheet parts: bolder stripes and less edge chipping than the thick Deadbolt panels
    B.mat_painted("hazard_shell", (0.44, 0.28, 0.025), stripe_pitch=0.040, wear=0.12)
    B.mat_painted("yellow_shell", (0.62, 0.36, 0.012), stripes=False, wear=0.12)   # the hollow rail beam's 3 mm walls
    B.mat_emit("status_glow", (1.0, 0.40, 0.07), 6.0)   # power lamp, same amber as the tracer

# ---------------------------------------------------------------- the grapple hook
def claw_path(splay):
    """Claw centre line relative to its hinge, in (along the body, outward) coordinates. Seated, the claw
    lies back along the body in its groove; launched, it swings forward and out and its tip hooks back in
    toward the nose, like a grapple."""
    if splay:
        return [(0.0, 0.0), (0.009, 0.012), (0.020, 0.024), (0.034, 0.031), (0.047, 0.029), (0.055, 0.020), (0.057, 0.012)]
    return [(0.0, 0.0), (-0.012, 0.0015), (-0.026, 0.0025), (-0.040, 0.0020), (-0.052, 0.0000), (-0.059, -0.0025)]

def build_hook(prefix, M, splay=False):
    """Halo-style grapple head in hook space: x 0 is the cable anchor (the swaged ferrule's end), +X the
    launch direction. A forged hex body about the rail's width, a visible swivel and ferrule behind it,
    three heavy claws on a hinge ring with hazard-painted roots and scuffed tips, folded back along the
    body when seated (splay=False) and swung open when launched (splay=True). Built in place, moved by M."""
    objs = []
    o = objs.append
    # cable anchor: swaged ferrule (crimp rings) into a two-part swivel
    o(B.cyl(f"{prefix} | ferrule", (0, 0, 0), (0.016, 0, 0), 0.0045, "steel_bright", seg=20, bevel=0.0004))
    for x in (0.004, 0.008, 0.012):
        o(B.tube_ring(f"{prefix} | swage ring", (x, 0, 0), (x + 0.0012, 0, 0), 0.0047, 0.0040, "steel_dark", seg=20))
    o(B.cyl(f"{prefix} | swivel rear", (0.016, 0, 0), (0.0235, 0, 0), 0.0072, "steel_dark", seg=6, bevel=0.0005))
    o(B.cyl(f"{prefix} | swivel race", (0.0235, 0, 0), (0.0250, 0, 0), 0.0062, "black", seg=24))
    o(B.cyl(f"{prefix} | swivel front", (0.0250, 0, 0), (HOOK_FLANGE, 0, 0), 0.0082, "steel", seg=24, bevel=0.0004))
    # forged hex body: copper wear face where the yoke kicks it, hazard band, red index band
    o(B.cyl(f"{prefix} | body", (HOOK_FLANGE, 0, 0), (0.104, 0, 0), HOOK_BODY_R, "hook_steel", seg=6, r1=HOOK_BODY_R - 0.0015, bevel=0.0012))
    o(B.tube_ring(f"{prefix} | wear face", (HOOK_FLANGE - 0.0006, 0, 0), (HOOK_FLANGE, 0, 0), HOOK_BODY_R - 0.0015, 0.0090, "copper", seg=6))
    o(B.tube_ring(f"{prefix} | hazard band", (0.056, 0, 0), (0.072, 0, 0), HOOK_BODY_R + 0.0004, HOOK_BODY_R - 0.003, "hazard_shell", seg=6))
    o(B.tube_ring(f"{prefix} | index band", (0.084, 0, 0), (0.090, 0, 0), HOOK_BODY_R - 0.0004, HOOK_BODY_R - 0.004, "paint_red", seg=6))
    hx = HOOK_HINGE_X
    o(B.cyl(f"{prefix} | hinge ring", (0.103, 0, 0), (0.119, 0, 0), 0.0200, "steel_dark", seg=6, bevel=0.0010))
    o(B.cyl(f"{prefix} | nose collar", (0.119, 0, 0), (0.125, 0, 0), 0.0130, "steel", seg=6, bevel=0.0006))
    o(B.cyl(f"{prefix} | nose", (0.125, 0, 0), (HOOK_LEN, 0, 0), 0.0120, "blade", seg=6, r1=0.0004, bevel=0.0003))
    path = claw_path(splay)
    for k in range(3):
        a = TAU*k/3 + math.pi/2
        rd = Vector((0, math.cos(a), math.sin(a)))
        tg = Vector((0, -math.sin(a), math.cos(a)))
        H = Vector((hx, 0, 0)) + rd*0.0215
        pts = catmull([H + Vector((u, 0, 0)) + rd*v for u, v in path], step=RQ['claw_step'])
        n = len(pts)
        rad = lambda t: 0.0070*(1 - t) + 0.0018*t + 0.0012*math.sin(math.pi*t)**2
        o(sweep(f"{prefix} | claw", pts, rad, "hook_steel", nv=6, flat=1.0))
        k0 = int(n*0.36)   # hazard-painted root
        o(sweep(f"{prefix} | claw root", pts[:k0], lambda t: rad(t*0.36) + 0.0007, "hazard_shell", nv=6, flat=1.0))
        k1 = int(n*0.74)   # scuffed bright tip
        o(sweep(f"{prefix} | claw tip", pts[k1:], lambda t: rad(0.74 + 0.26*t)*1.06, "blade", nv=6, flat=1.0))
        o(B.box(f"{prefix} | hinge lug", hx - 0.007, hx + 0.007, -0.0045, 0.0045, 0.0, 0.0060, "steel_dark", bevel=0.0006))
        objs[-1].matrix_world = Matrix.Translation(Vector((0, 0, 0)) + rd*0.0160) @ Matrix.Rotation(a - math.pi/2, 4, 'X')
        o(B.cyl(f"{prefix} | claw pin", H - tg*0.0060, H + tg*0.0060, 0.0030, "steel_bright", seg=12, bevel=0.0003))
    for ob in objs:
        ob.matrix_world = M @ ob.matrix_world
    return objs

# ---------------------------------------------------------------- parts
def build_rail():
    """Hollow rail beam along the top of the forearm. It carries the launch ram on top; the cable dives
    in through a bell mouth on its outer top edge and runs inside it to the fairlead, in view through a
    continuous sight slot in the inner wall (the side the player sees). The tension plate
    on the inner wall is embossed steel."""
    x0, x1, zt = RAIL_X0, RAIL_X1, 0.102
    sx0, sx1, sz0, sz1 = SLOT
    B.box("Rail | floor", x0, x1, -0.020, 0.020, 0.053, 0.057, "yellow_shell", bevel=0.0010)
    B.box("Rail | top", x0, x1, -0.020, 0.020, 0.099, zt, "yellow_shell", bevel=0.0012)
    B.box("Rail | outer wall", x0, x1, -0.020, -0.017, 0.057, 0.099, "yellow_shell", bevel=0.0008)
    for a, b, za, zb in ((x0, sx0, 0.057, 0.099), (sx1, x1, 0.057, 0.099), (sx0, sx1, 0.057, sz0), (sx0, sx1, sz1, 0.099)):
        B.box("Rail | inner wall", a, b, 0.017, 0.020, za, zb, "yellow_shell", bevel=0.0006)
    B.box("Rail | rear cap", x0, x0 + 0.003, -0.017, 0.017, 0.057, 0.099, "steel_dark", bevel=0.0004)
    B.box("Rail | front cap", x1 - 0.003, x1, -0.017, 0.017, 0.057, 0.099, "steel_dark", bevel=0.0004)
    B.tube_ring("Rail | cable grommet", (x1 - 0.0005, CH_Y*0.5, CH_Z), (x1 + 0.0025, CH_Y*0.5, CH_Z), 0.0055, 0.0026, "copper", seg=24)
    B.box("Rail | liner", sx0 - 0.004, sx1 + 0.004, -0.017, -0.013, 0.057, 0.099, "black", bevel=0)
    # slot bezel
    for a, b, za, zb in ((sx0 - 0.003, sx1 + 0.003, sz0 - 0.003, sz0), (sx0 - 0.003, sx1 + 0.003, sz1, sz1 + 0.003),
                         (sx0 - 0.003, sx0, sz0, sz1), (sx1, sx1 + 0.003, sz0, sz1)):
        B.box("Rail | slot bezel", a, b, 0.0198, 0.0218, za, zb, "steel_dark", bevel=0.0004)
    for x in (sx0 - 0.0015, sx1 + 0.0015):
        for z in (sz0 - 0.0015, sz1 + 0.0015):
            B.hexbolt("Rail | bezel screw", (x, 0.0218, z), (0, 1, 0), r=0.0012, h=0.0006)
    # bell mouth on the outer top edge, flared toward the guide sheave
    d = (sheave_geom()[6] - Vector(BELL)).normalized()
    B.cyl("Rail | bell mouth", Vector(BELL) - d*0.003, Vector(BELL) + d*0.008, 0.0050, "steel", seg=24, r1=0.0068, bevel=0.0004)
    B.tube_ring("Rail | bell lip", Vector(BELL) + d*0.007, Vector(BELL) + d*0.009, 0.0074, 0.0040, "steel_bright", seg=24)
    for side in (1, -1):
        y0, y1 = sorted((side*0.0200, side*0.0215))
        B.box("Rail | edge strip", x0 + 0.004, x1 - 0.004, y0, y1, zt - 0.006, zt, "steel_dark", bevel=0.0005)
        for x in (-0.214, -0.164, -0.114, -0.064, -0.028):
            if side > 0 and sx0 - 0.006 < x < sx1 + 0.006:
                continue
            B.hexbolt("Rail | side bolt", (x, side*0.0215, 0.064), (0, side, 0), r=0.0019, h=0.0010)
    # embossed tension plate on the inner wall, under the sight slot (the drum hangs over the rear of it)
    px0, px1, pz0, pz1 = sx0 - 0.002, sx1 + 0.002, 0.0575, 0.0725
    B.box("Rail | tension plate", px0, px1, 0.020, 0.0225, pz0, pz1, "steel_plate", bevel=0.0007)
    for x in (px0 + 0.003, px1 - 0.003):
        for z in (pz0 + 0.003, pz1 - 0.003):
            B.hexbolt("Rail | plate rivet", (x, 0.0225, z), (0, 1, 0), r=0.0011, h=0.0006)
    rot_in = (math.radians(90), 0, math.radians(180))
    B.text("Rail | plate LINE UNDER LOAD", "LINE UNDER LOAD", ((px0 + px1)/2, 0.0226, 0.0682), rot_in, 0.0068, "steel_bright", extrude=0.0006)
    B.text("Rail | plate SWL", "SWL 900 KG", ((px0 + px1)/2, 0.0226, 0.0612), rot_in, 0.0056, "steel_bright", extrude=0.0006)
    B.text("Decal | serial", "HZ-RC/02", (-0.150, -0.0202, 0.0780), (math.radians(90), 0, 0), 0.0062, "paint_white", extrude=0.00015)

def build_fairlead():
    """Four-roller fairlead at the wrist on the hook's line. The cable comes straight in from the rail
    beam on the axis and leaves its face; FAIRLEAD_SOCKET is the face centre. The hazard cheeks are
    open frames, so the rollers read from either side."""
    z = HOOK_Z
    B.rect_frame("Fairlead | rear frame", FAIR_X0, FAIR_X0 + 0.005, 0.022, z - 0.024, z + 0.024, 0.008, "steel_dark")
    B.rect_frame("Fairlead | front frame", FAIR_X1 - 0.005, FAIR_X1, 0.022, z - 0.024, z + 0.024, 0.008, "steel_dark")
    for side in (1, -1):
        y0, y1 = sorted((side*0.0215, side*0.0260))
        for a, b, za, zb in ((FAIR_X0 - 0.002, FAIR_X1 + 0.001, z + 0.012, z + 0.022), (FAIR_X0 - 0.002, FAIR_X1 + 0.001, z - 0.026, z - 0.016),
                             (FAIR_X0 - 0.002, FAIR_X0 + 0.004, z - 0.016, z + 0.012), (FAIR_X1 - 0.005, FAIR_X1 + 0.001, z - 0.016, z + 0.012)):
            B.box("Fairlead | cheek", a, b, y0, y1, za, zb, "hazard_shell", bevel=0.0007)
        for x in (FAIR_X0 + 0.001, FAIR_X1 - 0.002):
            B.hexbolt("Fairlead | cheek bolt", (x, side*0.026, z + 0.017), (0, side, 0), r=0.0016, h=0.0009)
    xm = (FAIR_X0 + FAIR_X1)/2
    for s in (1, -1):   # horizontal rollers above and below, vertical rollers either side, axle caps on the cheeks
        B.cyl("Fairlead | roller", (xm, -0.016, z + s*0.0118), (xm, 0.016, z + s*0.0118), 0.0048, "steel_bright", seg=24, bevel=0.0004)
        B.cyl("Fairlead | roller", (xm, s*0.0118, z - 0.016), (xm, s*0.0118, z + 0.016), 0.0048, "steel_bright", seg=24, bevel=0.0004)
        B.cyl("Fairlead | axle", (xm, -0.0262, z + s*0.0118), (xm, 0.0262, z + s*0.0118), 0.0016, "steel_dark", seg=8)
        B.tube_ring("Fairlead | roller groove", (xm, s*0.0118, z - 0.0012), (xm, s*0.0118, z + 0.0012), 0.0050, 0.0040, "steel_dark", seg=24)
    B.box("Fairlead | foot", RAIL_X1 - 0.002, FAIR_X1, -0.022, 0.022, 0.053, z - 0.024, "steel", bevel=0.0010)
    B.text("Decal | unit number", "02", (xm, 0.0262, z - 0.0212), (math.radians(90), 0, math.radians(180)), 0.0072, "paint_white", extrude=0.00015)

def build_launch():
    """Launch ram on top of the rail, the yoke it drives, the launch rail ahead of the fairlead and the
    latch dogs that catch the hook's collar when it winds home."""
    z = RAM_Z
    h = 0.018
    B.cyl("Ram | barrel", (RAM_X0 + 0.009, 0, z), (RAM_X1 - 0.009, 0, z), 0.0150, "gunmetal", seg=40, bevel=0.0010)
    for x in (RAM_X0 + 0.030, RAM_X1 - 0.034):   # clamp bands, as on the Deadbolt's piston drums
        B.tube_ring("Ram | band", (x, 0, z), (x + 0.005, 0, z), 0.0163, 0.0145, "steel_dark", seg=40)
    for x0 in (RAM_X0, RAM_X1 - 0.009):
        B.box("Ram | end cap", x0, x0 + 0.009, -h, h, z - h, z + h, "steel_dark", bevel=0.0016)
    for y in (-0.0135, 0.0135):
        for zz in (z - 0.0135, z + 0.0135):
            B.cyl("Ram | tie rod", (RAM_X0 - 0.003, y, zz), (RAM_X1 + 0.003, y, zz), 0.0021, "steel", seg=12)
            for x in (RAM_X0 - 0.003, RAM_X1 + 0.0005):
                B.cyl("Ram | tie nut", (x, y, zz), (x + 0.0025, y, zz), 0.0034, "steel_dark", seg=6, bevel=0.0002)
    for x0 in (RAM_X0 + 0.010, RAM_X1 - 0.028):
        B.box("Ram | saddle", x0, x0 + 0.016, -0.016, 0.016, 0.101, z - 0.012, "steel_dark", bevel=0.0010)
    B.cyl("Ram | gland", (RAM_X1, 0, z), (RAM_X1 + 0.007, 0, z), 0.0080, "steel_dark", seg=6, bevel=0.0005)
    B.cyl("Ram | rear port", (RAM_X0 + 0.0045, 0.0, z + h), (RAM_X0 + 0.0045, 0.0, z + h + 0.006), 0.0044, "steel_dark", seg=6)
    B.cyl("Ram | front port", (RAM_X1 - 0.0045, 0.0, z + h), (RAM_X1 - 0.0045, 0.0, z + h + 0.006), 0.0040, "steel_dark", seg=6)
    # yoke: rod end clamp on top, the plate the hook's flange seats on, a bore the cable runs through,
    # two guide pins that keep it square as it slides
    B.cyl("Yoke | rod", (RAM_X1 + 0.005, 0, z), (YOKE_X0, 0, z), 0.0050, "chrome", seg=20)
    B.box("Yoke | plate", YOKE_X0, YOKE_X1, -0.0135, 0.0135, HOOK_Z - 0.014, z + 0.008, "steel", bevel=0.0012)
    B.tube_ring("Yoke | bore ring", (YOKE_X1 - 0.0005, 0, HOOK_Z), (YOKE_X1 + 0.0010, 0, HOOK_Z), 0.0112, 0.0085, "copper", seg=32)
    B.cyl("Yoke | rod clamp", (YOKE_X0 - 0.006, 0, z), (YOKE_X1, 0, z), 0.0085, "steel_dark", seg=6, bevel=0.0006)
    for y in (-0.0175, 0.0175):
        B.cyl("Yoke | guide pin", (FAIR_X0 - 0.004, y, HOOK_Z + 0.027), (YOKE_X1, y, HOOK_Z + 0.027), 0.0024, "steel_bright", seg=12)
        B.box("Yoke | pin ear", YOKE_X0, YOKE_X1, y - 0.004, y + 0.004, HOOK_Z + 0.022, HOOK_Z + 0.032, "steel", bevel=0.0006)
        B.box("Fairlead | pin bushing", FAIR_X0 - 0.002, FAIR_X1, y - 0.0040, y + 0.0040, HOOK_Z + 0.022, HOOK_Z + 0.032, "steel_dark", bevel=0.0006)
    # launch rail: cradle under the forged body, from the yoke to the hinge ring; latch dogs reach up
    # between the folded claws and catch the hinge ring's rear face when the hook winds home
    zc = HOOK_Z - HOOK_BODY_R*0.87
    B.box("Rail | cradle", FAIR_X1, CRADLE_X1, -0.0090, 0.0090, zc - 0.012, zc - 0.0015, "steel_dark", bevel=0.0010)
    for side in (1, -1):
        y0, y1 = sorted((side*0.0050, side*0.0090))
        B.box("Rail | cradle lip", YOKE_X1 + 0.002, CRADLE_X1, y0, y1, zc - 0.0015, zc + 0.0020, "steel", bevel=0.0005)
    web = B.box("Rail | cradle web", FAIR_X1 - 0.004, 0.090, -0.0060, 0.0060, 0.060, zc - 0.012, "steel_dark", bevel=0.0008)
    for v in web.data.vertices:   # taper the web forward
        if v.co.x > 0.06:
            v.co.z = max(v.co.z, zc - 0.022)
    hx = HOOK_X0 + HOOK_HINGE_X - 0.009
    for side in (1, -1):
        piv = Vector((hx - 0.004, side*0.0110, zc - 0.006))
        tooth = Vector((hx - 0.004, side*0.0150, HOOK_Z + 0.0125))
        B.cyl("Latch | pin", piv - Vector((0, 0.003*side, 0)), piv + Vector((0, 0.003*side, 0)), 0.0018, "steel_bright", seg=10)
        d = tooth - piv
        dog = B.box("Latch | dog", -0.0018, 0.0018, -0.0016, 0.0016, 0.0, d.length, "hazard_shell", bevel=0.0004)
        dog.matrix_world = Matrix.Translation(piv) @ Matrix.Rotation(-math.atan2(d.y, d.z), 4, 'X')
        B.box("Latch | tooth", hx - 0.0060, hx - 0.0005, tooth.y - 0.0028, tooth.y + 0.0028, tooth.z - 0.0030, tooth.z + 0.0025, "hazard_shell", bevel=0.0004)

def build_drum():
    # hanger plate carries the axle, pawl bracket and level-wind; bolted to the rail beam
    out = Vector((0, SIDE, 0))
    B.box("Frame | drum hanger", -0.228, -0.094, *sorted((sy(0.030), sy(0.0215))), 0.053, 0.118, "steel_dark", bevel=0.0012)
    for x in (-0.218, -0.130, -0.104):
        for z in (0.062, 0.110):
            B.hexbolt("Frame | hanger bolt", (x, sy(0.030), z), out, r=0.0019, h=0.0010)
    disc_y("Frame | axle boss", 0.0145, sy(0.030), sy(0.031), "steel", seg=6)
    # drum (rotates about Y): ratchet, inner flange, cable pack, wound layers, spoked outer flange
    sawtooth_wheel("Drum | ratchet", 28, RATCHET_R[0], RATCHET_R[1], 0.016, *Y_RATCHET, "steel")
    disc_y("Drum | inner flange", DRUM_R, *Y_IN_FLANGE, "steel_dark", seg=64)
    disc_y("Drum | cable pack", PACK_R, Y_BARREL[0] + sy(0.0005), Y_BARREL[1] - sy(0.0005), "cable", seg=64, bevel=0.0012)
    yi, yo = Y_BARREL[0] + sy(0.0022), Y_BARREL[1] - sy(0.0022)
    rope("Drum | wrap layer", drum_helix(PACK_R + CABLE_R, yo, yi, 2*CABLE_R + 0.0002, a_end=150.0), phase=0.0)
    rope("Drum | wrap layer 2", drum_helix(PACK_R + 3*CABLE_R + 0.0002, yo, DEPART_Y + sy(0.0045), 2*CABLE_R + 0.0002, a_end=40.0), phase=1.9)
    ring_y("Drum | outer rim", DRUM_R, DRUM_R - 0.0095, *Y_OUT_FLANGE, "hazard_shell", seg=64)
    ys = sum(Y_OUT_FLANGE)/2
    for k in range(5):
        a = 90 + 72*k
        p0, p1 = drum_pt(a, 0.016, ys), drum_pt(a, DRUM_R - 0.0085, ys)
        sp = B.box("Drum | spoke", -0.0040, 0.0040, -0.0016, 0.0016, 0.0, (p1 - p0).length, "steel_dark", bevel=0.0005)
        sp.matrix_world = Matrix.Translation(p0) @ Matrix.Rotation(-math.radians(a - 90), 4, 'Y')
        B.hexbolt("Drum | rim bolt", drum_pt(a + 36, DRUM_R - 0.0048, Y_OUT_FLANGE[1]), out, r=0.0016, h=0.0009)
    m = B.box("Drum | index mark", -0.0028, 0.0028, -0.0006, 0.0006, 0.0, 0.0085, "paint_white", bevel=0.0002)
    m.matrix_world = Matrix.Translation(drum_pt(90, DRUM_R - 0.0092, Y_OUT_FLANGE[1] + sy(0.0004)))
    ring_y("Drum | brake ring", DRUM_R + 0.002, DRUM_R - 0.007, *Y_BRAKE, "steel_bright", seg=64)
    # sealed electric drive: a finned motor can behind the drum, parallel to it, geared to the hub
    # through a bolted gear case on the drum's open face
    mx, mz, mr = MOTOR_X, MOTOR_Z, MOTOR_R
    B.cyl("Motor | can", (mx, sy(0.0385), mz), (mx, sy(0.0680), mz), mr, "gunmetal", seg=40, bevel=0.0010)
    B.cyl("Motor | end bell", (mx, sy(0.0345), mz), (mx, sy(0.0390), mz), mr - 0.0020, "steel", seg=40, bevel=0.0010)
    for k in range(18):
        a = TAU*k/18
        f = B.box("Motor | fin", -0.0008, 0.0008, *sorted((sy(0.0410), sy(0.0640))), 0.0, 0.0045, "steel_dark", bevel=0.0002)
        f.matrix_world = Matrix.Translation((mx + (mr - 0.0010)*math.cos(a), 0, mz + (mr - 0.0010)*math.sin(a))) @ Matrix.Rotation(math.pi/2 - a, 4, 'Y')
    B.tube_ring("Motor | hazard band", (mx, sy(0.0640), mz), (mx, sy(0.0690), mz), mr + 0.0035, mr - 0.0010, "hazard_shell", seg=40)
    B.box("Motor | terminal box", mx - 0.012, mx + 0.012, *sorted((sy(0.0410), sy(0.0610))), mz + mr - 0.002, mz + mr + 0.0125, "steel_dark", bevel=0.0012)
    B.box("Motor | terminal lid", mx - 0.0105, mx + 0.0105, *sorted((sy(0.0425), sy(0.0595))), mz + mr + 0.0125, mz + mr + 0.0145, "steel", bevel=0.0007)
    for dx in (-0.0075, 0.0075):
        for y in (0.0455, 0.0565):
            B.hexbolt("Motor | lid bolt", (mx + dx, sy(y), mz + mr + 0.0145), (0, 0, 1), r=0.0013, h=0.0007)
    B.cyl("Motor | gland", (mx - 0.012, sy(0.0510), mz + mr + 0.006), (mx - 0.019, sy(0.0510), mz + mr + 0.006), 0.0044, "brass", seg=6)
    gear_case("Motor | gear case", [(DRUM_X, DRUM_Z, 0.0265), (mx, mz, mr + 0.0030)], Y_GEAR[0], Y_GEAR[1], "gunmetal")
    gear_case("Motor | gear cover", [(DRUM_X, DRUM_Z, 0.0200), (mx, mz, mr - 0.0030)], Y_GEAR[1], Y_GEAR[1] + sy(0.0016), "steel_dark")
    for (cx, cz, r, n, a0, span) in ((DRUM_X, DRUM_Z, 0.0232, 7, -60, 220), (mx, mz, mr, 5, 100, 160)):
        for k in range(n):
            a = math.radians(a0 + span*k/(n - 1))
            B.hexbolt("Motor | case bolt", (cx + r*math.cos(a), Y_GEAR[1], cz + r*math.sin(a)), out, r=0.0015, h=0.0008)
    disc_y("Drum | output hub", 0.0090, Y_GEAR[1] + sy(0.0016), Y_GEAR[1] + sy(0.0046), "steel", seg=6, bevel=0.0005)
    B.cyl("Motor | breather", (mx, Y_GEAR[1] + sy(0.0016), mz), (mx, Y_GEAR[1] + sy(0.0050), mz), 0.0040, "brass", seg=12)
    B.text("Decal | drive", "4.2 KW", ((DRUM_X + mx)/2 + 0.004*SIDE, Y_GEAR[1] + sy(0.0019), (DRUM_Z + mz)/2 - 0.001),
           (math.radians(90), 0, math.radians(180) if SIDE > 0 else 0), 0.0058, "paint_white", extrude=0.00015)
    # guard: folded hazard sheet in facets over the top and back, with an open sight gap over the top of
    # the cable pack: from the player's eye above the forearm the glowing wraps show through it
    arc_shell("Guard | drum guard front", GUARD_A[0], GUARD_GAP[0], *GUARD_R, *GUARD_Y, "hazard_shell", n=1, bevel=0.0016)
    arc_shell("Guard | drum guard", GUARD_GAP[1], GUARD_A[1], *GUARD_R, *GUARD_Y, "hazard_shell", n=4, bevel=0.0016)
    gm = sum(GUARD_GAP)/2
    B.box("Guard | grille bar", -0.0022, 0.0022, *sorted(GUARD_Y), -0.0030, 0.0030, "steel_dark", bevel=0.0005).matrix_world = \
        Matrix.Translation(drum_pt(gm, (GUARD_R[0] + GUARD_R[1])/2, 0)) @ Matrix.Rotation(-math.radians(gm), 4, 'Y')
    for y in (0.042, 0.060):
        arc_shell("Guard | rib", GUARD_A[0], GUARD_A[1], GUARD_R[1] - 0.0005, GUARD_R[1] + 0.0022, sy(y), sy(y + 0.004), "steel_dark", n=6, bevel=0.0005)
    for a in (GUARD_A[0] + 5, GUARD_A[1] - 5):
        for y in (0.036, 0.068):
            n = drum_pt(a, 1, 0) - drum_pt(a, 0, 0)
            B.hexbolt("Guard | bolt", drum_pt(a, GUARD_R[1], sy(y)), n, r=0.0017, h=0.0010)
    for a in (205.0, 112.0):   # stays from the hanger out to the guard edge
        B.box("Guard | stay", -0.003, 0.003, *sorted((GUARD_Y[0], GUARD_Y[1] - sy(0.003))), -0.0025, 0.0025, "steel_dark", bevel=0.0005).matrix_world = \
            Matrix.Translation(drum_pt(a, GUARD_R[1] - 0.004, 0)) @ Matrix.Rotation(-math.radians(a), 4, 'Y')

def build_pawl():
    """Ratchet pawl on a bracket ahead of the drum top; the red flip tab is the manual release."""
    B.box("Frame | pawl bracket", -0.128, -0.108, *sorted((sy(0.0215), sy(0.0300))), 0.112, 0.146, "steel", bevel=0.0010)
    yp = sum(Y_RATCHET)/2
    piv = Vector((-0.116, yp, 0.139))
    B.cyl("Frame | pawl pin", (piv.x, sy(0.0215), piv.z), (piv.x, sy(0.0380), piv.z), 0.0028, "steel_bright", seg=16)
    tip = drum_pt(62, RATCHET_R[1] + 0.0005, yp)
    d = (tip - piv); L = d.length
    ang = math.atan2(d.z, d.x)
    pw = B.box("Pawl | dog", 0.0, L, -0.0022, 0.0022, -0.0040, 0.0040, "steel_dark", bevel=0.0008)
    pw.matrix_world = Matrix.Translation(piv) @ Matrix.Rotation(-ang, 4, 'Y')
    for v in pw.data.vertices:   # taper toward the tooth
        if v.co.x > L*0.5:
            v.co.z *= 0.55
    B.cyl("Pawl | boss", (piv.x, yp - sy(0.0025), piv.z), (piv.x, yp + sy(0.0025), piv.z), 0.0062, "steel", seg=20)
    tab = B.box("Pawl | flip tab", -0.0030, 0.0030, -0.0020, 0.0020, 0.0, 0.019, "paint_red", bevel=0.0006)
    tab.matrix_world = Matrix.Translation(piv + Vector((0, sy(0.0012), 0))) @ Matrix.Rotation(math.radians(-18), 4, 'Y')
    B.helix_tube("Pawl | spring", (piv.x + 0.004, sy(0.0285), piv.z + 0.002), 0.012, 0.0022, 0.0018, 0.0006, "steel_bright", turns_res=RQ['helix_turn'])
    # release solenoid on the bracket, lead back to the reservoir block
    B.cyl("Frame | solenoid", (-0.128, sy(0.026), 0.150), (-0.146, sy(0.026), 0.150), 0.0058, "steel", seg=20)
    B.cyl("Frame | solenoid cap", (-0.146, sy(0.026), 0.150), (-0.149, sy(0.026), 0.150), 0.0050, "black", seg=20)
    B.curve_tube("Wire | solenoid", [(-0.149, sy(0.026), 0.150), (-0.165, sy(0.026), 0.150), (-0.200, sy(0.025), 0.142), (-0.222, sy(0.028), 0.124),
                                      (BLOCK[1] - 0.002, sy(0.028), 0.112)], 0.0020, "wire_red", bevel_res=2)

def build_brake():
    """Spring-applied band brake on the brake ring with a release lever behind the drum."""
    r = DRUM_R + 0.0040
    rings = []
    for i in range(41):
        a = 218 + 132*i/40
        rings.append([drum_pt(a, DRUM_R + 0.0022, Y_BRAKE[0] + sy(0.0004)), drum_pt(a, r, Y_BRAKE[0] + sy(0.0004)),
                      drum_pt(a, r, Y_BRAKE[1] - sy(0.0004)), drum_pt(a, DRUM_R + 0.0022, Y_BRAKE[1] - sy(0.0004))])
    B.loft("Brake | band", rings, "steel_dark", cap0=True, cap1=True, bevel=0.0003)
    ya = sum(Y_BRAKE)/2
    a0 = drum_pt(350, DRUM_R + 0.0065, ya)
    B.cyl("Frame | brake anchor", (a0.x, sy(0.0300), a0.z), (a0.x, Y_BRAKE[1] + sy(0.002), a0.z), 0.0030, "steel", seg=12)
    yl = sy(0.0805)
    piv = Vector((-0.236, yl, 0.054))
    B.cyl("Frame | brake pivot", (piv.x, sy(0.0300), piv.z), (piv.x, yl + sy(0.003), piv.z), 0.0036, "steel", seg=16)
    top = Vector((-0.256, yl, 0.132))
    d = top - piv
    lv = B.box("Brake | lever", -0.0048, 0.0048, -0.0020, 0.0020, 0.0, d.length, "steel_dark", bevel=0.0007)
    lv.matrix_world = Matrix.Translation(piv) @ Matrix.Rotation(math.atan2(d.x, d.z), 4, 'Y')
    pad = B.box("Brake | paddle", -0.0075, 0.0075, -0.0024, 0.0024, -0.002, 0.016, "paint_red", bevel=0.0010)
    pad.matrix_world = Matrix.Translation(top) @ Matrix.Rotation(math.atan2(d.x, d.z), 4, 'Y')
    B.cyl("Brake | boss", (piv.x, yl - sy(0.003), piv.z), (piv.x, yl + sy(0.003), piv.z), 0.0062, "steel_dark", seg=16)
    tail = drum_pt(218, DRUM_R + 0.0050, ya)
    B.cyl("Brake | link", piv + Vector((0.004, -sy(0.003), 0.006)), tail, 0.0018, "steel_bright", seg=10)
    sp = B.helix_tube("Brake | spring", (0, 0, 0), 0.020, 0.0030, 0.0028, 0.0006, "steel_bright", turns_res=RQ['helix_turn'])   # built along +X
    q = Vector((1, 0, 0)).rotation_difference(Vector((-0.25, 0.0, 1.0)).normalized())
    sp.matrix_world = Matrix.Translation(piv + Vector((-0.002, 0.0, 0.010))) @ q.to_matrix().to_4x4()

def sheave_geom():
    """Diverter sheave on the level-wind carriage: the cable arrives off the top of the pack heading +X
    and leaves for the bell mouth on the rail beam, so the sheave's plane is the plane of those two
    directions (its axle tilts toward vertical). Returns (centre, axle, e1, e2, wrap, radius, exit)."""
    Rs = SHEAVE_R + CABLE_R
    e1 = Vector((1, 0, 0))
    t_in = Vector((LW_X - 0.004, DEPART_Y, CABLE_TOP_Z))
    bell = Vector(BELL)
    out = (bell - t_in).normalized()
    for _ in range(6):
        n = e1.cross(out).normalized()
        e2 = n.cross(e1)
        c = t_in + e2*Rs
        w = math.acos(max(-1.0, min(1.0, e1.dot(out))))
        ex = c + Rs*(-e2*math.cos(w) + e1*math.sin(w))
        out = (bell - ex).normalized()
    return c, n, e1, e2, w, Rs, ex

def sheave_path():
    c, n, e1, e2, w, Rs, ex = sheave_geom()
    return [c + Rs*(-e2*math.cos(w*k/12) + e1*math.sin(w*k/12)) for k in range(13)]

def build_guide():
    """Level-wind ahead of the drum: a diamond screw traverses a carriage carrying the swivelling
    diverter sheave that turns the cable off the top of the drum and down into the rail beam."""
    c, n, e1, e2, w, Rs, ex = sheave_geom()
    x, zs = LW_X, c.z - 0.020
    B.box("Frame | lw post near", x - 0.004, x + 0.004, *sorted((sy(0.0215), sy(0.0330))), 0.053, zs + 0.006, "steel_dark", bevel=0.0008)
    B.box("Frame | lw post far", x - 0.004, x + 0.004, *sorted((sy(0.0700), sy(0.0760))), 0.044, zs + 0.006, "steel_dark", bevel=0.0008)
    B.cyl("Frame | lw foot tube", (x, sy(0.024), 0.048), (x, sy(0.075), 0.048), 0.0040, "steel", seg=16)
    B.cyl("Frame | lw screw", (x, sy(0.0335), zs), (x, sy(0.0705), zs), 0.0040, "chrome", seg=20)
    ob = B.helix_tube("Frame | lw screw thread", (0, 0, 0), 0.036, 0.0040, 0.0050, 0.0007, "steel_dark", turns_res=RQ['helix_turn'])
    ob.matrix_world = Matrix.Translation((x, sy(0.0340), zs)) @ Matrix.Rotation(-SIDE*math.pi/2, 4, 'Z')
    yc = DEPART_Y
    B.box("Guide | carriage", x - 0.008, x + 0.010, yc - 0.009, yc + 0.009, zs - 0.006, zs + 0.007, "steel", bevel=0.0010)
    B.cyl("Guide | swivel post", (c.x, c.y, zs + 0.007), c - n*0.0065, 0.0034, "steel_dark", seg=12)
    B.cyl("Guide | sheave", c - n*0.0040, c + n*0.0040, SHEAVE_R, "steel_bright", seg=32, bevel=0.0006)
    B.tube_ring("Guide | sheave groove", c - n*0.0018, c + n*0.0018, SHEAVE_R + 0.0002, SHEAVE_R - 0.0026, "steel_dark", seg=32)
    for s_ in (-1, 1):
        B.cyl("Guide | cheek", c + n*(s_*0.0052 - 0.0007), c + n*(s_*0.0052 + 0.0007), SHEAVE_R + 0.0032, "hazard_shell", seg=32, bevel=0.0002)
    B.cyl("Guide | sheave pin", c - n*0.0075, c + n*0.0075, 0.0022, "steel_dark", seg=6)

def beam_run(end):
    """From the bell mouth, down inside the beam, along it, out through the grommet to the fairlead."""
    b = Vector(BELL)
    return catmull([b, Vector((b.x + 0.005, 0.5*(b.y + CH_Y), CH_Z + 0.006)), Vector((b.x + 0.013, CH_Y, CH_Z)),
                    Vector((RAIL_X1, CH_Y*0.5, CH_Z)), Vector((FAIR_X0 + 0.003, 0, HOOK_Z)), end], 0.0015)

def drum_to_bell():
    top = drum_helix(PACK_R + 3*CABLE_R + 0.0002, Y_BARREL[0] - 0.0022, DEPART_Y, 2*CABLE_R + 0.0002, a_end=90.0)
    over = sheave_path()
    ex = over[-1]
    span = [ex.lerp(Vector(BELL), k/30) for k in range(1, 31)]
    return top + catmull([top[-1], over[0]], 0.002)[1:] + over[1:] + span

def build_cable_idle():
    """Visible cable at rest, one continuous path: off the top of the pack, over the diverter sheave, into
    the bell mouth ("Cable | drum run"), then inside the beam past the sight slot, through the fairlead
    to the hook's ferrule ("Cable | throat")."""
    rope("Cable | drum run", drum_to_bell(), phase=0.7)
    rope("Cable | throat", beam_run(Vector((HOOK_X0 - 0.0005, 0, HOOK_Z)))[1:], phase=2.3)

def cable_out_path(anchor):
    """Hook out: inside the beam to the fairlead face, then the pull line to the hook's ferrule."""
    near = beam_run(Vector(FAIRLEAD_SOCKET))[1:]
    far = [Vector(FAIRLEAD_SOCKET).lerp(Vector(anchor), t/80) for t in range(1, 81)]
    return near + far

def build_block():
    """Reservoir block: the air store for the ram and the power cell for the motor, under one yellow
    housing like the Deadbolt's rear pneumatics. Horzine plate on its inner face behind the motor can;
    pressure gauge, power lamp, valve block and power junction on top."""
    x0, x1, y0, y1, z0, z1 = BLOCK
    hb = B.box("Rear | reservoir block", x0, x1, y0, y1, z0, z1, "yellow_hazard", bevel=0.0028)
    for xa, xb in ((x0 - 0.004, x0 + 0.008), (-0.262, -0.255), (x1 - 0.008, x1 + 0.002)):
        B.prism("Rear | frame band", [(y0 - 0.0015, z0 - 0.0015), (y1 + 0.0015, z0 - 0.0015), (y1 + 0.0015, z1 + 0.003), (y0 - 0.0015, z1 + 0.003)], xa, xb, "steel_dark", bevel=0.0012)
    for i in range(5):   # cell vent slots on the top (outer half)
        x = x0 + 0.020 + i*0.010
        B.box("Rear | vent slot", x, x + 0.005, -0.040, -0.016, z1 - 0.0005, z1 + 0.0012, "black", bevel=0.0004)
    # Horzine plate on the inner face, behind the motor can
    px0, px1, pz0, pz1 = -0.336, -0.294, 0.058, 0.112
    yl = y1 + 0.0022
    B.box("Rear | Horzine plate", px0, px1, y1, yl, pz0, pz1, "steel_bright", bevel=0.0009)
    for x in (px0 + 0.004, px1 - 0.004):
        for z in (pz0 + 0.004, pz1 - 0.004):
            B.hexbolt("Rear | plate screw", (x, yl, z), (0, 1, 0), r=0.0014, h=0.0008)
    cx, cz = (px0 + px1)/2, pz1 - 0.020
    B.tube_ring("Rear | logo ring", (cx, yl - 0.0004, cz), (cx, yl + 0.0014, cz), 0.0140, 0.0116, "black", seg=48)
    for dx in (-0.0052, 0.0052):
        B.box("Rear | logo H post", cx + dx - 0.0019, cx + dx + 0.0019, yl, yl + 0.0014, cz - 0.0165, cz + 0.0165, "black", bevel=0.0003)
    B.box("Rear | logo H bar", cx - 0.0052, cx + 0.0052, yl, yl + 0.0014, cz - 0.0018, cz + 0.0018, "black", bevel=0.0003)
    tx = B.text("Rear | HORZINE", "HORZINE", (cx, yl + 0.0002, pz0 + 0.0075), (0, 0, 0), 0.0080, "black", extrude=0.0004)
    tx.rotation_euler = (math.radians(90), 0, math.radians(180))
    B.text("Decal | pressure", "MAX 900 PSI", (cx, y1 + 0.0002, 0.0525), (math.radians(90), 0, math.radians(180)), 0.0046, "paint_white", extrude=0.00015)
    # air pressure gauge and power lamp on the top, by the inner edge, facing the player's eye
    gx, gy = -0.240, 0.022
    B.cyl("Rear | gauge body", (gx, gy, z1), (gx, gy, z1 + 0.008), 0.0100, "brass", seg=32)
    B.cyl("Rear | gauge face", (gx, gy, z1 + 0.0078), (gx, gy, z1 + 0.0084), 0.0085, "gauge_face", seg=32)
    B.box("Rear | gauge needle", gx - 0.0005, gx + 0.0062, gy - 0.0005, gy + 0.0005, z1 + 0.0082, z1 + 0.0088, "wire_red", bevel=0)
    B.cyl("Rear | lamp bezel", (-0.240, -0.022, z1), (-0.240, -0.022, z1 + 0.004), 0.0050, "steel_dark", seg=20)
    B.cyl("Rear | power lamp", (-0.240, -0.022, z1 + 0.003), (-0.240, -0.022, z1 + 0.0055), 0.0034, "status_glow", seg=20, bevel=0)
    # valve block on top: blue isolator, feed and return ports to the ram, charge fitting at the back
    vz = z1 + 0.003
    B.box("Rear | valve block", -0.290, -0.248, -0.014, 0.014, vz, vz + 0.016, "steel", bevel=0.0012)
    B.cyl("Rear | valve stem", (-0.281, 0.0, vz + 0.016), (-0.281, 0.0, vz + 0.022), 0.0022, "steel", seg=12)
    B.cyl("Rear | valve knob", (-0.281, 0.0, vz + 0.022), (-0.281, 0.0, vz + 0.027), 0.0066, "valve_blue", seg=16)
    for y in (-0.007, 0.007):
        B.cyl("Rear | valve port", (-0.248, y, vz + 0.008), (-0.242, y, vz + 0.008), 0.0045, "steel_dark", seg=6)
    B.cyl("Rear | charge fitting", (x0 - 0.004, -0.030, 0.104), (x0 - 0.014, -0.030, 0.104), 0.0050, "brass", seg=6)
    B.cyl("Rear | charge cap", (x0 - 0.014, -0.030, 0.104), (x0 - 0.018, -0.030, 0.104), 0.0060, "paint_red", seg=16)
    # power junction where the motor cable comes in (top, inner rear)
    B.box("Rear | junction box", -0.334, -0.304, 0.008, 0.030, z1, z1 + 0.014, "steel_dark", bevel=0.0012)
    B.cyl("Rear | junction gland", (-0.304, 0.019, z1 + 0.008), (-0.298, 0.019, z1 + 0.008), 0.0050, "brass", seg=6)

def build_hoses():
    """Every line does a job: ram feed and return from the valve block, motor power, pawl solenoid."""
    vz = BLOCK[5] + 0.011
    rz = RAM_Z + 0.018 + 0.006
    B.curve_tube("Hose | ram feed", [(-0.242, -0.007, vz), (-0.226, -0.010, vz + 0.004), (-0.160, -0.012, rz + 0.012), (RAM_X0 + 0.0045, 0.0, rz + 0.012),
                                     (RAM_X0 + 0.0045, 0.0, rz)], 0.0062, "hose")
    B.curve_tube("Hose | ram return", [(-0.242, 0.007, vz), (-0.222, 0.012, vz + 0.010), (-0.150, 0.014, rz + 0.022), (-0.060, 0.010, rz + 0.016),
                                       (RAM_X1 - 0.0045, 0.0, rz + 0.008), (RAM_X1 - 0.0045, 0.0, rz)], 0.0050, "hose")
    for x in (RAM_X0 + 0.0045, RAM_X1 - 0.0045):
        B.cyl("Hose | ferrule", (x, 0, rz), (x, 0, rz + 0.007), 0.0078, "steel", seg=6)
    g = (MOTOR_X - 0.019, sy(0.0510), MOTOR_Z + MOTOR_R + 0.006)
    jz = BLOCK[5] + 0.008
    B.curve_tube("Wire | motor power", [g, (g[0] - 0.008, sy(0.0480), g[2] + 0.004), (-0.292, 0.032, jz + 0.006), (-0.296, 0.021, jz + 0.002),
                                        (-0.298, 0.019, jz)], 0.0042, "hose_smooth", bevel_res=3)
    sp = [tuple(B.cuff_pt(-0.300 + f*0.250, math.radians(150 + 2.25*360*f), 0.0058)) for f in (i/(RQ['spiral_pts'] - 1) for i in range(RQ['spiral_pts']))]
    B.curve_tube("Wire | sleeve spiral", sp, 0.0021, "wire_red", res=4, bevel_res=2)   # heated sleeve lead, as on the Deadbolt

def rename_stamp(objs):
    for ob in objs:
        if ob.name.startswith("Gauntlet | DEADBOLT stamp"):
            ob.data.body = "RIPCORD"; ob.name = "Gauntlet | RIPCORD stamp"
        elif ob.name.startswith("Gauntlet | DEADBOLT plate"):
            ob.name = "Gauntlet | RIPCORD plate"

def build_all(base_materials=True):
    """Build into RC_Weapon. base_materials=False reuses the Deadbolt materials already in the scene
    (both guns in one file); B.COLL is restored afterwards."""
    prev = B.COLL
    B.COLL = COLL
    try:
        B.clear_coll(COLL)
        build_materials(base_materials)
        before = set(B.get_coll(COLL).objects)
        B.build_gauntlet(); B.build_mount()
        rename_stamp([o for o in B.get_coll(COLL).objects if o not in before])
        build_rail(); build_fairlead(); build_launch(); build_drum(); build_pawl(); build_brake(); build_guide()
        build_hook("Hook", Matrix.Translation((HOOK_X0, 0.0, HOOK_Z)))
        build_cable_idle()
        build_block(); build_hoses()
        g = bpy.data.objects.get("DB_Glove")
        if g:
            g.data.materials.clear(); g.data.materials.append(B.MATS["glove"])
            for p in g.data.polygons: p.use_smooth = True
    finally:
        B.COLL = prev
    return len(B.get_coll(COLL).objects)

def build_hook_out(dist=2.0, aim=(1.0, 0.04, -0.13)):
    """Review state: the hook out at `dist` along `aim`, the cable taut from the fairlead. Returns the
    new objects (named 'Out | ...'); the caller hides the idle hook and throat cable."""
    prev = B.COLL
    B.COLL = COLL
    try:
        d = Vector(aim).normalized()
        anchor = Vector(FAIRLEAD_SOCKET) + d*dist
        rot = Vector((1, 0, 0)).rotation_difference(d).to_matrix().to_4x4()
        objs = build_hook("Out | hook", Matrix.Translation(anchor) @ rot, splay=True)
        objs.append(rope("Out | cable", cable_out_path(anchor), phase=0.7))
    finally:
        B.COLL = prev
    return objs
