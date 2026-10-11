# Deadbolt rig and authored takes: Fire, FireLast, Reload (the forge), Idle and Empty.
#
# The takes are written as code, not hand keys: each bone channel is a few eased keys plus impulse
# shapes (slam: hard hit, accelerating return, overshoot past rest, short ring-out), sampled at 60 fps.
# The same sampling drives the review renders (render_deadbolt_anim.py) and the skeletal FBX takes
# (export_deadbolt.py), so the frame strips are the game animation.
#
# Frame: metres, wrist at the origin, +X toward the fingers, +Z up, +Y the thumb side (deadbolt_build).
# Every bone rests with world-aligned axes, so a channel's location is a world offset and its
# rotation turns about world axes at the bone head. Pitch: a negative Y rotation lifts the muzzle.
#
# What a skeletal take cannot carry -- material glow, heat colour and part visibility -- is published
# as per-take keys in VRDeadbolt.json; VRDeadboltPresentation applies them by script: glow and spike
# intensity (Scalar_Glow_Intensity), spike heat colour (Vector_Glow_Color, heat_tint below), the
# spike bone hidden in its spans and the muzzle flare bone shown only in its spans.
import math
from mathutils import Euler, Matrix, Quaternion, Vector
import deadbolt_build as B

FPS = 60
F1 = 1.0/FPS
STOW = B.SPIKE_STOW_X0 - B.SPIKE_X0     # spike offset when drawn fully inside the gun (negative)
L = B.SPIKE_LEN

BONES = [  # name, parent, head
    ("DB_Root", None, (0.0, 0.0, 0.0)),
    ("DB_Kick", "DB_Root", (-0.150, 0.0, 0.0)),            # whole gauntlet; turns about the mid forearm
    ("DB_Stack", "DB_Kick", (-0.270, 0.0, 0.050)),         # weapon stack; slides back along the deck rails
    ("DB_Hammer", "DB_Stack", (-0.165, 0.0, B.REAR_TOP + 0.015)),   # pneumatic ram on the housing top
    ("DB_Yoke", "DB_Stack", (0.076, 0.0, 0.055)),          # piston rods + yoke clamp at the muzzle
    ("DB_Crown", "DB_Stack", (0.0665, 0.0, B.AXIS_Z)),     # indexing muzzle crown
    ("DB_Spike", "DB_Stack", (B.SPIKE_X0, 0.0, B.AXIS_Z)), # the rod: base on the bore axis, idle seat
    ("DB_SpikeTip", "DB_Spike", (B.SPIKE_X0 + L, 0.0, B.AXIS_Z)),   # moved forward it stretches the rod
    ("DB_Flare", "DB_Stack", (B.FLARE_X0, 0.0, B.AXIS_Z)), # muzzle burst (script shows it at launch)
    ("DB_FlareTip", "DB_Flare", (B.FLARE_X1, 0.0, B.AXIS_Z)),
    ("DB_HoseOuter", "DB_Stack", (-0.212, -0.014, B.REAR_TOP + 0.013)),   # whips pivot at the ram ports
    ("DB_HoseInner", "DB_Stack", (-0.212, 0.014, B.REAR_TOP + 0.013)),
    ("DB_HoseFeed", "DB_Stack", (-0.168, -0.062, 0.050)),
]
BONE_NAMES = [b[0] for b in BONES]

# ---------------------------------------------------------------- skinning
def rigid_bone(name):
    if name.startswith("Spike |"): return "DB_Spike"
    if name.startswith("Flare |"): return "DB_Flare"
    if name.startswith("Hammer |"): return "DB_Hammer"
    if name.startswith(("Front | piston rod", "Front | piston eye", "Front | yoke")): return "DB_Yoke"
    if name.startswith(("Front | muzzle crown", "Front | crown bolt")): return "DB_Crown"
    if name.startswith(("Gauntlet |", "Strap |", "Mount |", "Display |", "Wire | sleeve", "Decal | plate")): return "DB_Kick"
    return "DB_Stack"

# curve -> (bone at its first point, bone at its last point, whip bone, whip weight)
GRADIENT = {
    "Hose | outer loop": ("DB_Hammer", "DB_Stack", "DB_HoseOuter", 1.4),
    "Hose | inner loop": ("DB_Hammer", "DB_Stack", "DB_HoseInner", 1.4),
    "Hose | outer drop": ("DB_Stack", "DB_Kick", "DB_HoseOuter", 0.6),
    "Hose | inner drop": ("DB_Stack", "DB_Kick", "DB_HoseInner", 0.6),
    "Hose | reservoir feed": ("DB_Stack", "DB_Hammer", "DB_HoseFeed", 1.2),
    "Wire | red A": ("DB_Hammer", "DB_Stack", None, 0.0),
    "Wire | red B": ("DB_Hammer", "DB_Stack", None, 0.0),
}
# parts blended linearly along X between a base and a tip bone (stretchable)
STRETCH = {
    "Spike | thermal auger": ("DB_Spike", "DB_SpikeTip", B.SPIKE_X0, B.SPIKE_X0 + L),
    "Flare |": ("DB_Flare", "DB_FlareTip", B.FLARE_X0, B.FLARE_X1),
}

def gradient_key(name):
    return next((k for k in GRADIENT if name.startswith(k)), None)

def stretch_key(name):
    return next((k for k in STRETCH if name.startswith(k)), None)

def curve_param(pts, p):
    """Arc-length parameter (0..1) of the point on the control polyline nearest p."""
    pts = [Vector(q) for q in pts]
    seg = [(a, b, (b - a).length) for a, b in zip(pts, pts[1:])]
    total = sum(s[2] for s in seg)
    best, acc, s_best = 1e9, 0.0, 0.0
    for a, b, Ls in seg:
        d = b - a
        x = max(0.0, min(1.0, (p - a).dot(d)/max(Ls*Ls, 1e-12)))
        dist = (a + d*x - p).length
        if dist < best: best, s_best = dist, (acc + x*Ls)/total
        acc += Ls
    return s_best

def gradient_weights(key, p):
    a, b, whip, gain = GRADIENT[key]
    s = curve_param(B.CURVE_PTS[key], p)
    w = {a: max(0.0, 1.0 - s/0.30)**2 if whip else 1.0 - s, b: max(0.0, (s - 0.70)/0.30)**2 if whip else s}
    if whip: w[whip] = w.get(whip, 0.0) + gain*math.sin(math.pi*s)**2
    tot = sum(w.values()) or 1.0
    return {k: v/tot for k, v in w.items() if v > 1e-4}

def assign_groups(ob, source_name):
    """Vertex groups on a world-space mesh copy of one model part."""
    groups = {n: ob.vertex_groups.get(n) or ob.vertex_groups.new(name=n) for n in BONE_NAMES[1:]}
    key, sk = gradient_key(source_name), stretch_key(source_name)
    if key is None and sk is None:
        groups[rigid_bone(source_name)].add(range(len(ob.data.vertices)), 1.0, 'REPLACE')
        return
    for v in ob.data.vertices:
        p = ob.matrix_world @ v.co
        if sk:
            base, tip, x0, x1 = STRETCH[sk]
            u = max(0.0, min(1.0, (p.x - x0)/(x1 - x0)))
            weights = {base: 1.0 - u, tip: u}
        else:
            weights = gradient_weights(key, p)
        for bone, w in weights.items():
            if w > 1e-5: groups[bone].add([v.index], w, 'REPLACE')

# ---------------------------------------------------------------- curve helpers
def ease(kind, x):
    x = max(0.0, min(1.0, x))
    if kind == 'lin': return x
    if kind == 'in': return x*x
    if kind == 'in3': return x*x*x
    if kind == 'inp': return x**1.6
    if kind == 'out': return 1 - (1 - x)**2
    if kind == 'out3': return 1 - (1 - x)**3
    if kind == 'hold': return 0.0 if x < 1 else 1.0
    return x*x*(3 - 2*x)       # 'io'

def track(t, keys):
    """keys: (t0, v0), (t1, v1, ease), ... ; the ease shapes the segment arriving at that key."""
    if t <= keys[0][0]: return keys[0][1]
    for a, b in zip(keys, keys[1:]):
        if t <= b[0]:
            span = b[0] - a[0]
            return a[1] + (b[1] - a[1])*ease(b[2] if len(b) > 2 else 'io', (t - a[0])/span if span > 0 else 1.0)
    return keys[-1][1]

def kick(t, t0, amp, rise=0.03, freq=6.0, decay=0.08):
    """Soft impulse: reaches amp in `rise`, then rings down with overshoot (hoses, small parts)."""
    if t < t0: return 0.0
    tau = t - t0
    if tau < rise: return amp*(1 - (1 - tau/rise)**2)
    tau -= rise
    return amp*math.exp(-tau/decay)*math.cos(2*math.pi*freq*tau)

def slam(t, t0, amp, rise, ret, over=0.18, settle=0.06, ring=11.0):
    """Hard hit: out-eased to amp in `rise`, accelerating back through rest in `ret` to an overshoot of
    over*amp the other way (the one-to-two-frame punch past rest), then a short ring-out."""
    if t < t0: return 0.0
    tau = t - t0
    if tau < rise: return amp*ease('out3', tau/rise)
    tau -= rise
    if tau < ret: return amp + (-over*amp - amp)*ease('in', tau/ret)
    tau -= ret
    return -over*amp*math.exp(-tau/settle)*math.cos(2*math.pi*ring*tau)

def shake(t, t0, t1, amp, freq, seed=0.0):
    """Mechanical tremor between t0 and t1 (amp may be a function of t)."""
    if t <= t0 or t >= t1: return 0.0
    e = min(1.0, (t - t0)/0.04, (t1 - t)/0.04)
    a = amp(t) if callable(amp) else amp
    w = 2*math.pi*freq
    return a*e*(0.6*math.sin(w*t + seed) + 0.3*math.sin(1.73*w*t + 2.1*seed + 1) + 0.1*math.sin(2.91*w*t + seed*3.7))

def decaying(t0, a0, tau):
    return lambda u: a0*math.exp(-max(0.0, u - t0)/tau)

def land(t, T, v, span=0.06):
    """Fade ringing to exact rest over the last `span` seconds so takes chain without a pop."""
    return v*min(1.0, max(0.0, (T - t)/span))

def heat_tint(h):
    """Spike heat colour multiplier for Vector_Glow_Color: 0 dull red, 0.5 the baked orange, 1 white-yellow
    (green and blue lifted past 1 so the HDR emissive clips toward white)."""
    stops = ((0.0, (1.0, 0.22, 0.10)), (0.5, (1.0, 1.0, 1.0)), (1.0, (1.25, 1.55, 1.6)))
    h = max(0.0, min(1.0, h))
    for (h0, c0), (h1, c1) in zip(stops, stops[1:]):
        if h <= h1:
            x = (h - h0)/(h1 - h0)
            return tuple(a + (b - a)*x for a, b in zip(c0, c1))
    return stops[-1][1]

# ---------------------------------------------------------------- takes
def P():
    return {n: [Vector(), Vector()] for n in BONE_NAMES}   # [location m, rotation deg XYZ]

FIRE_T = 0.55
def fire_pose(t, last=False):
    """Launch on frame 0 (the projectile spawns on the trigger): the rod leaves as a stretched streak in
    frames 0-1 behind a muzzle burst, the stack punches back along its rails past rest, ram and yoke
    slam, crown indexes, hoses whip; then a fresh rod screws in and seats (not after the last round).
    The big kick is not in this take: VRHandsBridge applies hand recoil from BreacherDeadbolt's stock
    recoil pitch (about 4 cm, 0.6 s recovery). The gauntlet here only shakes, so the two do not stack."""
    T = FIRE_T
    p = P()
    sp, tip = p["DB_Spike"], p["DB_SpikeTip"]
    if t < 2*F1:                         # f0: base 3 cm out, rod 2x long; f1: 22 cm out, 3x long
        u = t/F1
        sp[0].x = 0.03 + 0.19*min(u, 1.0) + 0.38*max(0.0, u - 1.0)
        tip[0].x = L*min(1.0 + u, 2.0)
    elif t < 3*F1:
        sp[0].x = 0.60; tip[0].x = 2*L    # far out and already hidden (script) before the jump home
    elif last or t < 0.200:
        sp[0].x = STOW
    else:
        sp[0].x = track(t, [(0.200, STOW), (0.400, 0.0, 'in')]) + land(t, T, slam(t, 0.400, 0.006, 0.012, 0.03, 0.3, 0.03, 16))
        sp[1].x = track(t, [(0.200, -360.0), (0.400, 0.0, 'in')])
    # flare: a compact burst on f0 that stretches long on f1
    p["DB_FlareTip"][0].x = track(t, [(0, -0.09), (F1, 0.05, 'out'), (2*F1, 0.10, 'lin')])
    # gauntlet shake on top of the hand recoil: 1 cm back, 2 degrees up, short ring-out
    p["DB_Kick"][0].x = land(t, T, slam(t, 0.0, -0.010, 0.030, 0.060, 0.15, 0.035, 12))
    p["DB_Kick"][1].y = land(t, T, slam(t, 0.0, -2.0, 0.035, 0.070, 0.15, 0.035, 11))
    p["DB_Kick"][1].x = land(t, T, kick(t, 0.008, 1.0, 0.030, 9.0, 0.04))
    # weapon stack slides 4.5 cm back along the deck rails and overshoots forward past rest; it stays
    # flat on the deck (no pitch, so no gap opens under it), the gauntlet carries all the rise
    p["DB_Stack"][0].x = land(t, T, slam(t, 0.0, -0.045, 0.035, 0.080, 0.14, 0.05, 12))
    # ram jolts back with the blow and slams into the bulkhead; the piston yoke hammers the clamp
    # shut on the crown (2 mm rest gap closed to contact, never pulled away)
    p["DB_Hammer"][0].x = land(t, T, slam(t, 0.0, -0.022, 0.025, 0.055, 0.14, 0.04, 16))
    p["DB_Yoke"][0].x = track(t, [(0, 0), (0.017, -0.002, 'out3'), (0.120, 0.0, 'io')])
    # muzzle crown indexes one bolt (60 degrees) per shot with a ratchet overshoot
    p["DB_Crown"][1].x = track(t, [(0, 0), (0.050, 68, 'out3'), (0.110, 60, 'io')])
    # hoses whip by about their own length, pivoting at the ram ports
    p["DB_HoseOuter"][1].z = land(t, T, kick(t, 0.020, -24.0, 0.060, 5.5, 0.13))
    p["DB_HoseOuter"][1].y = land(t, T, kick(t, 0.015, 16.0, 0.050, 6.5, 0.11))
    p["DB_HoseInner"][1].z = land(t, T, kick(t, 0.025, 22.0, 0.060, 5.0, 0.13))
    p["DB_HoseInner"][1].y = land(t, T, kick(t, 0.020, 14.0, 0.050, 7.0, 0.11))
    p["DB_HoseFeed"][1].x = land(t, T, kick(t, 0.020, 18.0, 0.040, 8.0, 0.09))
    if not last:      # the fresh rod's seat taps the stack and nods the gauntlet
        p["DB_Stack"][0].x += land(t, T, slam(t, 0.400, 0.004, 0.012, 0.03, 0.3, 0.03, 14))
        p["DB_Kick"][1].y += land(t, T, slam(t, 0.400, 0.6, 0.015, 0.04, 0.3, 0.03, 12))
    return p

RELOAD_T = 2.90
R = dict(prime=0.0, heat=0.18, spike_in=0.42, extrude=0.80, lock=1.48, hold_end=2.00, seat=2.40, vent=2.48)
def reload_pose(t):
    """The forge. Prime, heat-up with growing tremor, the rod forms dull red in the slot, screws out
    accelerating to 5 rev/s (orange), dead-stops into a hard lock (white flash, gauntlet jolt, rattle),
    holds white hot and trembling, screws back in cooling to orange and seats with a snap and bounce;
    the ram vents."""
    T = RELOAD_T
    p = P()
    lock, hold_end, seat, vent = R['lock'], R['hold_end'], R['seat'], R['vent']
    tremor = lambda u: 0.35*min(1.0, max(0.0, (u - 0.18)/0.62)) + 0.35*min(1.0, max(0.0, (u - 0.80)/0.68))
    # ram cocks back, holds the charge, slams home after the seat (vent)
    p["DB_Hammer"][0].x = track(t, [(0, 0), (0.18, -0.018, 'out3'), (vent - 0.04, -0.018), (vent, 0.0, 'in3')]) \
        + land(t, T, slam(t, vent, -0.004, 0.010, 0.03, 0.3, 0.04, 16)) + slam(t, lock, -0.006, 0.012, 0.04, 0.3, 0.03, 16)*(t < vent - 0.1)
    # yoke opens the clamp, slams it shut on the lock, takes the seat shock
    # (the clamp eases 3 mm open for the extrusion and slams to contact on the crown; it never enters it)
    p["DB_Yoke"][0].x = track(t, [(0, 0), (0.18, 0.003, 'out'), (lock - 0.02, 0.003), (lock + 0.01, -0.002, 'in3'),
                                  (seat, -0.002), (seat + 0.05, 0.0, 'out')])
    # crown unlocks, turns with the rod as a forming die, snaps five bolts on into lock and rattles
    p["DB_Crown"][1].x = track(t, [(0, 0), (0.18, -30, 'out3'), (R['extrude'], -30), (lock, 270, 'inp'), (lock + 0.03, 308, 'out3'), (lock + 0.12, 300, 'io')]) \
        + shake(t, lock + 0.03, lock + 0.30, decaying(lock, 7.0, 0.08), 30, 0.7)
    # whole gauntlet: brace, heat tremor, lock jolt (2.5 cm, 5 degrees, punch past rest), white-hot
    # tremble, seat snap with a two-frame bounce
    p["DB_Kick"][1].y = track(t, [(0, 0), (0.18, 1.5, 'io'), (0.50, 0.0, 'io')]) \
        + slam(t, lock, -5.5, 0.030, 0.075, 0.25, 0.05, 10) + land(t, T, slam(t, seat, 2.5, 0.016, 0.040, 0.35, 0.035, 14))
    p["DB_Kick"][1].x = shake(t, 0.18, lock, tremor, 26, 0.3) + slam(t, lock, -2.0, 0.025, 0.06, 0.25, 0.05, 12) \
        + shake(t, lock + 0.10, hold_end, 0.5, 23, 1.9)
    p["DB_Kick"][0].x = slam(t, lock, -0.022, 0.030, 0.075, 0.22, 0.05, 10) + land(t, T, slam(t, seat, -0.012, 0.014, 0.035, 0.35, 0.035, 14))
    p["DB_Kick"][0].z = shake(t, 0.18, lock, lambda u: 0.0012*tremor(u), 31, 1.7) + shake(t, lock + 0.10, hold_end, 0.0009, 29, 0.4)
    p["DB_Stack"][0].x = track(t, [(0, 0), (R['extrude'], 0.0), (lock, -0.004, 'in'), (1.60, 0.0, 'io')]) \
        + slam(t, lock, -0.020, 0.025, 0.06, 0.25, 0.04, 12) + land(t, T, slam(t, seat, -0.010, 0.012, 0.03, 0.35, 0.03, 16))
    # the stack rattles on its rails at the lock (along them, and a hair across) instead of pivoting
    p["DB_Stack"][0].x += shake(t, lock, lock + 0.30, decaying(lock, 0.004, 0.08), 34, 1.1)
    p["DB_Stack"][0].z = shake(t, 0.18, lock, lambda u: 0.0006*tremor(u), 37, 4.1) + shake(t, lock, lock + 0.30, decaying(lock, 0.0012, 0.08), 41, 2.6)
    p["DB_Stack"][0].y = shake(t, lock, lock + 0.30, decaying(lock, 0.0015, 0.08), 36, 5.3)
    # hoses pulse while the charge builds, jump on the lock, whip on seat and vent
    for n, ax, sgn, f in (("DB_HoseOuter", 'z', -1, 9.0), ("DB_HoseInner", 'z', 1, 7.7), ("DB_HoseFeed", 'x', 1, 11.0)):
        v = sgn*(shake(t, 0.18, lock, lambda u: 3.0*tremor(u), f, f) + kick(t, lock, 20.0, 0.04, 6.0, 0.12)
                 + kick(t, seat, 10.0, 0.03, 7.0, 0.10)*(t < vent) + land(t, T, kick(t, vent, 12.0, 0.04, 7.5, 0.10)))
        setattr(p[n][1], ax, v)
    # the rod: dull in the chamber, screws out accelerating to 5 rev/s, dead stop at the lock with a
    # backlash, trembles white hot, screws back in at up to 4.5 rev/s and snaps into its seat
    sp = p["DB_Spike"]
    if t < R['spike_in']:
        sp[0].x = STOW
    else:
        sp[0].x = track(t, [(R['spike_in'], STOW), (R['extrude'], STOW), (lock, 0.085, 'inp'), (hold_end, 0.085), (seat, 0.0, 'in')]) \
            + slam(t, lock, -0.008, 0.012, 0.035, 0.3, 0.03, 16)*(t < hold_end) \
            + shake(t, lock + 0.06, hold_end, 0.0012, 32, 2.2) + land(t, T, slam(t, seat, 0.006, 0.010, 0.030, 0.4, 0.03, 16))
        sp[1].x = track(t, [(R['spike_in'], 0.0), (R['extrude'], 90.0, 'in'), (lock, 702.0, 'in'), (hold_end, 702.0), (seat, 360.0, 'in')]) \
            + slam(t, lock, -16.0, 0.015, 0.04, 0.3, 0.03, 14)*(t < hold_end)
    return p

IDLE_T = 4.0
def idle_pose(t):
    p = P()
    w = 2*math.pi*t/IDLE_T
    p["DB_Stack"][0].z = 0.00035*math.sin(2*w)
    p["DB_Hammer"][0].x = -0.0006*(0.5 - 0.5*math.cos(w))
    p["DB_HoseOuter"][1].z = -1.5*math.sin(2*w + 0.6)
    p["DB_HoseInner"][1].z = 1.2*math.sin(2*w + 1.4)
    return p

EMPTY_T = 1.0
def empty_pose(t):
    p = P()                    # dry: rod parked inside the gun (and hidden by script), bore dark
    p["DB_Spike"][0].x = STOW
    return p

TAKES = {
    # name: (seconds, pose, beats, heat keys (t, glow, spike, spike heat 0..1), spike hidden spans, flare shown spans)
    "Idle": (IDLE_T, idle_pose, {},
             [(t/8*IDLE_T, 1.0 + 0.12*math.sin(2*math.pi*3*t/8), 1.0 + 0.08*math.sin(2*math.pi*2*t/8 + 1.0), 0.5) for t in range(9)], [], []),
    "Fire": (FIRE_T, fire_pose, dict(launch=0.0, streak=F1, spike_gone=0.025, shake_peak=0.035, stack_peak=0.035, overshoot=0.16, rechamber=0.200, seat=0.400, settled=0.50),
             [(0, 4.5, 1.6, 0.9), (0.033, 4.5, 1.6, 0.9), (0.10, 2.2, 0.0, 0.9), (0.200, 1.5, 2.2, 0.85), (0.300, 1.4, 1.9, 0.75),
              (0.400, 2.6, 1.6, 0.65), (0.550, 1.0, 1.0, 0.5)], [(0.025, 0.200)], [(0.0, 0.025)]),
    "FireLast": (FIRE_T, lambda t: fire_pose(t, True), dict(launch=0.0, streak=F1, spike_gone=0.025, shake_peak=0.035, stack_peak=0.035, settled=0.45),
                 [(0, 4.5, 1.6, 0.9), (0.033, 4.5, 1.6, 0.9), (0.10, 2.2, 0.0, 0.0), (0.300, 1.0, 0.0, 0.0), (0.550, 0.25, 0.0, 0.0)],
                 [(0.025, FIRE_T)], [(0.0, 0.025)]),
    "Reload": (RELOAD_T, reload_pose, dict(R, end=RELOAD_T),
               [(0, 0.25, 0.0, 0.0), (0.18, 0.40, 0.0, 0.0), (0.42, 1.2, 0.6, 0.0), (0.80, 2.6, 1.2, 0.2), (1.46, 3.4, 2.2, 0.6),
                (1.50, 5.5, 4.0, 1.0), (1.62, 4.0, 3.4, 1.0), (2.00, 3.0, 3.0, 0.9), (2.40, 2.0, 1.6, 0.55), (2.43, 3.4, 1.9, 0.6),
                (2.90, 1.0, 1.0, 0.5)], [(0.0, 0.42)], []),
    "Empty": (EMPTY_T, empty_pose, {}, [(0, 0.25, 0.0, 0.0), (EMPTY_T, 0.25, 0.0, 0.0)], [(0.0, EMPTY_T)], []),
}

def frames(name):
    return round(TAKES[name][0]*FPS)

# The pinned UE3 FBX importer samples every take over the first take's interval, so the export pads
# each take to this shared length by holding its last pose; script ends a take at its own seconds.
def padded_frames():
    return max(frames(n) for n in TAKES)

def heat_at(name, t):
    """(glow, spike intensity, spike heat) at t, linear between keys like the game script."""
    keys = TAKES[name][3]
    return tuple(track(t, [(k[0], k[i], 'lin') for k in keys]) for i in (1, 2, 3))

def in_spans(name, idx, t):
    T = TAKES[name][0]
    return any(a <= t < b or (b >= T - 1e-6 and t >= a) for a, b in TAKES[name][idx])

def spike_hidden(name, t):
    return in_spans(name, 4, t)

def flare_shown(name, t):
    return in_spans(name, 5, t)

# ---------------------------------------------------------------- armature
def build_armature(coll, scale=1.0, name="DB_Rig"):
    import bpy
    arm = bpy.data.armatures.new(name)
    ob = bpy.data.objects.new(name, arm)
    coll.objects.link(ob)
    vl = bpy.context.view_layer
    vl.update()
    for o in vl.objects: o.select_set(False)
    vl.objects.active = ob; ob.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    for n, parent, head in BONES:
        eb = arm.edit_bones.new(n)
        eb.head = Vector(head)*scale; eb.tail = eb.head + Vector((0, 0.02*scale, 0)); eb.roll = 0.0
        if parent: eb.parent = arm.edit_bones[parent]; eb.use_connect = False
    bpy.ops.object.mode_set(mode='OBJECT')
    for pb in ob.pose.bones: pb.rotation_mode = 'QUATERNION'
    return ob

def apply_pose(rig, pose, scale=1.0, prev=None):
    """Set pose bones; returns the quaternions so callers can keep sign continuity between frames."""
    qs = {}
    for n in BONE_NAMES:
        loc, rot = pose[n]
        pb = rig.pose.bones[n]
        pb.location = loc*scale
        q = Euler([math.radians(a) for a in rot], 'XYZ').to_quaternion()
        if prev is not None: q.make_compatible(prev[n])
        pb.rotation_quaternion = q
        qs[n] = q
    return qs

def parent_rigid(ob, rig, bone):
    """Bone-parent an object without moving it (rest pose)."""
    b = rig.data.bones[bone]
    ob.parent = rig; ob.parent_type = 'BONE'; ob.parent_bone = bone
    ob.matrix_parent_inverse = (rig.matrix_world @ b.matrix_local @ Matrix.Translation((0, b.length, 0))).inverted()
