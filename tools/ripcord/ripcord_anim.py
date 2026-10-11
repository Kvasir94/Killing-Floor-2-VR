# Ripcord rig and authored takes: Idle, Fire, Reel (loop), Yank, Reload (the hook winds home and
# latches) and Empty (the hook is out on the line).
#
# Written as code like the Deadbolt's (tools/deadbolt/deadbolt_anim.py, whose curve helpers this
# imports): each channel is a few eased keys plus impulses (slam: hard hit, accelerating return,
# overshoot past rest, short ring-out), sampled at 60 fps for both the review strips and the skeletal
# FBX takes. Every bone rests with world-aligned axes, so a channel's location is a world offset in
# metres and its rotation turns about world axes at the bone head (degrees, XYZ).
#
# Drum sign: a positive Y rotation moves the top of the pack forward (+X), which pays cable out;
# reeling in is negative. A negative Y rotation of RC_Kick lifts the muzzle.
#
# What a take cannot carry is published per take in VRRipcord.json: the tracer glow multiplier
# (glow keys) and the spans in which the seated hook is hidden because it is out on the line. The
# flying hook and the cable beyond the fairlead are drawn by VRRipcordPresentation from the separate
# VRRipcordHook and VRRipcordCable meshes.
import math
from mathutils import Euler, Matrix, Vector
import deadbolt_build as B
import deadbolt_anim as DA
import ripcord_build as R

ease, track, kick, slam, shake, decaying, land = DA.ease, DA.track, DA.kick, DA.slam, DA.shake, DA.decaying, DA.land
FPS = 60
F1 = 1.0/FPS

def _sheave_z():
    return R.sheave_geom()[0].z - 0.020

BONES = [  # name, parent, head
    ("RC_Root", None, (0.0, 0.0, 0.0)),
    ("RC_Kick", "RC_Root", (-0.150, 0.0, 0.0)),                          # whole gauntlet, turns about the mid forearm
    ("RC_Drum", "RC_Kick", (R.DRUM_X, R.sy(0.050), R.DRUM_Z)),           # drum, ratchet and wraps spin about Y
    ("RC_Pawl", "RC_Kick", (-0.116, sum(R.Y_RATCHET)/2, 0.139)),         # ratchet pawl on its pin
    ("RC_Brake", "RC_Kick", (-0.236, R.sy(0.0805), 0.054)),              # brake release lever on its pivot
    ("RC_Guide", "RC_Kick", (R.LW_X, R.DEPART_Y, 0.110)),                # level-wind carriage and diverter sheave
    ("RC_Yoke", "RC_Kick", (R.YOKE_X0, 0.0, R.HOOK_Z)),                  # launch yoke and ram rod
    ("RC_Latch", "RC_Kick", (R.HOOK_X0 + R.HOOK_HINGE_X - 0.013, 0.0, R.HOOK_Z - R.HOOK_BODY_R*0.87 - 0.006)),  # latch dogs
    ("RC_Hook", "RC_Kick", (R.HOOK_X0, 0.0, R.HOOK_Z)),                  # the seated hook, origin at its cable anchor
    ("RC_HoseFeed", "RC_Kick", (-0.175, -0.010, 0.158)),                 # hose whips pivot mid-run
    ("RC_HoseReturn", "RC_Kick", (-0.150, 0.012, 0.168)),
    ("RC_HosePower", "RC_Kick", (-0.288, R.sy(0.040), 0.132)),
]
BONE_NAMES = [b[0] for b in BONES]

# ---------------------------------------------------------------- skinning
def rigid_bone(name):
    if name.startswith("Drum |"): return "RC_Drum"
    if name.startswith("Pawl |"): return "RC_Pawl"
    if name.startswith("Brake |") and not name.startswith("Brake | band"): return "RC_Brake"
    if name.startswith("Guide |"): return "RC_Guide"
    if name.startswith("Yoke |"): return "RC_Yoke"
    if name.startswith(("Latch | dog", "Latch | tooth")): return "RC_Latch"
    if name.startswith("Hook |"): return "RC_Hook"
    return "RC_Kick"

# curve -> (bone at its first point, bone at its last point, whip bone, whip weight)
GRADIENT = {
    "Hose | ram feed": ("RC_Kick", "RC_Kick", "RC_HoseFeed", 1.6),
    "Hose | ram return": ("RC_Kick", "RC_Kick", "RC_HoseReturn", 1.6),
    "Wire | motor power": ("RC_Kick", "RC_Kick", "RC_HosePower", 1.4),
}

def gradient_key(name):
    return next((k for k in GRADIENT if name.startswith(k)), None)

def gradient_weights(key, p):
    a, b, whip, gain = GRADIENT[key]
    s = DA.curve_param(B.CURVE_PTS[key], p)
    w = {}
    w[a] = w.get(a, 0.0) + max(0.0, 1.0 - s/0.30)**2
    w[b] = w.get(b, 0.0) + max(0.0, (s - 0.70)/0.30)**2
    w[whip] = w.get(whip, 0.0) + gain*math.sin(math.pi*s)**2
    tot = sum(w.values()) or 1.0
    return {k: v/tot for k, v in w.items() if v > 1e-4}

def assign_groups(ob, source_name):
    """Vertex groups on a world-space mesh copy of one model part."""
    groups = {n: ob.vertex_groups.get(n) or ob.vertex_groups.new(name=n) for n in BONE_NAMES[1:]}
    key = gradient_key(source_name)
    if key is None:
        groups[rigid_bone(source_name)].add(range(len(ob.data.vertices)), 1.0, 'REPLACE')
        return
    for v in ob.data.vertices:
        for bone, w in gradient_weights(key, ob.matrix_world @ v.co).items():
            if w > 1e-5: groups[bone].add([v.index], w, 'REPLACE')

# ---------------------------------------------------------------- takes
def P():
    return {n: [Vector(), Vector()] for n in BONE_NAMES}   # [location m, rotation deg XYZ]

PAWL_OUT, BRAKE_OUT = 30.0, -10.0     # pawl flipped up and brake released while the line is out
HOOK_GONE = 0.60                      # how far the seated hook is moved when it is out (and hidden)

IDLE_T = 4.0
def idle_pose(t):
    p = P()
    w = 2*math.pi*t/IDLE_T
    p["RC_Drum"][1].y = 1.5*math.sin(w)
    p["RC_Guide"][0].y = R.sy(0.0006)*math.sin(w + 0.8)
    p["RC_Kick"][0].z = 0.00030*math.sin(2*w)
    p["RC_HoseFeed"][1].x = 1.6*math.sin(2*w + 0.6)
    p["RC_HoseReturn"][1].x = -1.3*math.sin(2*w + 1.4)
    p["RC_HosePower"][1].x = 1.0*math.sin(w + 2.0)
    return p

def out_pose(p):
    """Line out: hook gone from the rail, pawl up, brake released."""
    p["RC_Hook"][0].x = HOOK_GONE
    p["RC_Pawl"][1].y = PAWL_OUT
    p["RC_Brake"][1].y = BRAKE_OUT
    return p

FIRE_T = 0.60
FIRE_BEATS = dict(launch=0.0, streak=F1, hook_gone=2*F1, yoke_peak=0.015, shake_peak=0.030, pawl_flip=0.030, overshoot=0.16, payout=0.30, settled=0.55)
def fire_pose(t):
    """Launch on frame 0: the yoke slams forward and the hook leaves as a stretched streak in frames 0-1
    (then it is out, hidden, and drawn by script on the line). The drum spins free paying out, the pawl
    flips up and the brake releases, hoses whip, the level-wind jumps. The shot's kick is VRHandsBridge
    hand recoil; the gauntlet itself only shakes (1 cm, 2 degrees)."""
    T = FIRE_T
    p = P()
    h = p["RC_Hook"]
    if t < 2*F1:
        h[0].x = 0.05 + 0.20*(t/F1)
    else:
        h[0].x = HOOK_GONE
    p["RC_Yoke"][0].x = land(t, T, slam(t, 0.0, 0.050, 0.015, 0.14, 0.07, 0.04, 14))
    p["RC_Drum"][1].y = track(t, [(0, 0), (T, 1080.0, 'out')]) + land(t, T, kick(t, 0.0, 6.0, 0.02, 9.0, 0.08))
    p["RC_Pawl"][1].y = track(t, [(0, 0), (0.030, PAWL_OUT + 8, 'out3'), (0.110, PAWL_OUT, 'io')]) + land(t, T, kick(t, 0.110, 3.0, 0.02, 10.0, 0.06))
    p["RC_Brake"][1].y = track(t, [(0, 0), (0.050, BRAKE_OUT - 4, 'out3'), (0.150, BRAKE_OUT, 'io')])
    p["RC_Kick"][0].x = land(t, T, slam(t, 0.0, -0.009, 0.030, 0.060, 0.15, 0.035, 12))
    p["RC_Kick"][1].y = land(t, T, slam(t, 0.0, -2.0, 0.030, 0.070, 0.15, 0.035, 11))
    p["RC_Kick"][1].x = land(t, T, kick(t, 0.008, 0.8, 0.030, 9.0, 0.04))
    p["RC_Guide"][0].y = land(t, T, kick(t, 0.010, R.sy(0.004), 0.020, 11.0, 0.07))
    p["RC_Guide"][0].z = land(t, T, kick(t, 0.010, 0.002, 0.015, 13.0, 0.05))
    p["RC_HoseFeed"][1].x = land(t, T, kick(t, 0.015, 22.0, 0.050, 6.0, 0.12))
    p["RC_HoseReturn"][1].x = land(t, T, kick(t, 0.020, -18.0, 0.050, 6.5, 0.12))
    p["RC_HosePower"][1].x = land(t, T, kick(t, 0.025, 10.0, 0.050, 5.5, 0.12))
    return p

EMPTY_T = 1.0
def empty_pose(t):
    """The hook is out on the line (in flight, biting, or a Zed held): rail bare, pawl up, brake off,
    the drum ticking over as the line breathes."""
    p = out_pose(P())
    w = 2*math.pi*t/EMPTY_T
    p["RC_Drum"][1].y = 2.0*math.sin(w)
    p["RC_HoseFeed"][1].x = 0.8*math.sin(w)
    return p

REEL_T = 2.5
REEL_JOLTS = (0.35, 1.05, 1.70)
REEL_BEATS = dict(start=0.0, jolt_1=REEL_JOLTS[0], jolt_2=REEL_JOLTS[1], jolt_3=REEL_JOLTS[2], loop=REEL_T)
def reel_pose(t):
    """Two turns of the drum per loop under load: the pawl clicks over every ratchet tooth, the brake
    lever chatters, the level-wind traverses and twitches, the hoses pulse, and three tension jolts snatch
    the drum and tug the gauntlet. Ends exactly where it starts, so it loops."""
    T = REEL_T
    p = P()
    p["RC_Hook"][0].x = HOOK_GONE
    rot = -720.0*t/T
    for j in REEL_JOLTS:
        rot += land(t, T, slam(t, j, -14.0, 0.025, 0.07, 0.35, 0.05, 9), 0.10)
    p["RC_Drum"][1].y = rot
    teeth = 28
    phase = (-rot/360.0*teeth) % 1.0
    p["RC_Pawl"][1].y = 1.5 + 6.0*(1.0 - phase)**3          # rides up each tooth, drops off it
    p["RC_Brake"][1].y = shake(t, 0.0, T + 1, 3.0, 17.0, 0.4)*min(1.0, t/0.05, (T - t)/0.05)
    p["RC_Guide"][0].y = R.sy(0.0060)*math.sin(2*math.pi*2*t/T) + shake(t, 0.0, T + 1, 0.0008, 23.0, 1.3)*min(1.0, t/0.05, (T - t)/0.05)
    p["RC_Guide"][0].z = shake(t, 0.0, T + 1, 0.0005, 29.0, 2.2)*min(1.0, t/0.05, (T - t)/0.05)
    env = min(1.0, t/0.05, (T - t)/0.05)
    for n, f, sgn in (("RC_HoseFeed", 6.0, 1), ("RC_HoseReturn", 6.0, -1), ("RC_HosePower", 4.0, 1)):   # whole cycles per loop
        p[n][1].x = sgn*(4.0*math.sin(2*math.pi*f*t) + sum(land(t, T, kick(t, j, 9.0, 0.03, 6.0, 0.10), 0.1) for j in REEL_JOLTS))
    p["RC_Kick"][1].y = shake(t, 0.0, T + 1, 0.35, 21.0, 0.9)*env \
        + sum(land(t, T, slam(t, j, 1.2, 0.025, 0.07, 0.3, 0.05, 10), 0.1) for j in REEL_JOLTS)
    p["RC_Kick"][0].x = sum(land(t, T, slam(t, j, 0.004, 0.025, 0.07, 0.3, 0.05, 10), 0.1) for j in REEL_JOLTS)
    p["RC_Kick"][0].z = shake(t, 0.0, T + 1, 0.0006, 27.0, 3.3)*min(1.0, t/0.05, (T - t)/0.05)
    return p

YANK_T = 0.35
YANK_BEATS = dict(rip=0.0, bite=0.020, ratchet_end=0.060, tension_peak=0.040, overshoot=0.11, settled=0.30)
def yank_pose(t):
    """The player jerks the hand back: the drum bites hard and snatches a sixth of a turn, the pawl
    hammers over the teeth, the level-wind slams, the brake lever kicks, hoses jump, and the gauntlet
    takes a big tension overshoot toward the Zed, then settles."""
    T = YANK_T
    p = P()
    p["RC_Hook"][0].x = HOOK_GONE
    rot = track(t, [(0, 0), (0.050, -150.0, 'out3'), (T, -180.0, 'out')]) + land(t, T, slam(t, 0.050, -12.0, 0.015, 0.05, 0.4, 0.04, 12))
    p["RC_Drum"][1].y = rot
    phase = (-rot/360.0*28) % 1.0
    p["RC_Pawl"][1].y = (2.0 + 9.0*(1.0 - phase)**3)*min(1.0, max(0.0, (0.12 - t)/0.06)) + land(t, T, kick(t, 0.12, 2.0, 0.02, 12.0, 0.05))
    p["RC_Brake"][1].y = land(t, T, slam(t, 0.0, -9.0, 0.020, 0.06, 0.35, 0.04, 14)) + shake(t, 0.03, 0.25, decaying(0.03, 3.0, 0.06), 19.0, 1.1)
    p["RC_Guide"][0].y = land(t, T, slam(t, 0.0, R.sy(-0.007), 0.015, 0.05, 0.4, 0.04, 13))
    p["RC_Guide"][0].z = land(t, T, slam(t, 0.005, 0.003, 0.012, 0.04, 0.4, 0.03, 15))
    p["RC_HoseFeed"][1].x = land(t, T, kick(t, 0.010, 28.0, 0.035, 6.5, 0.09))
    p["RC_HoseReturn"][1].x = land(t, T, kick(t, 0.015, -24.0, 0.035, 6.5, 0.09))
    p["RC_HosePower"][1].x = land(t, T, kick(t, 0.020, 16.0, 0.035, 5.5, 0.09))
    p["RC_Kick"][0].x = land(t, T, slam(t, 0.0, 0.011, 0.040, 0.09, 0.35, 0.05, 9))
    p["RC_Kick"][1].y = land(t, T, slam(t, 0.0, 2.5, 0.040, 0.09, 0.35, 0.05, 9))
    p["RC_Kick"][1].x = land(t, T, kick(t, 0.020, -1.2, 0.03, 10.0, 0.05))
    return p

RELOAD_T = 1.10
RELOAD_BEATS = dict(wind=0.0, hook_in_view=0.30, seat=0.52, latch=0.535, pawl_drop=0.56, brake_set=0.58, settled=0.90)
def reload_pose(t):
    """The hook comes home: the drum back-spins the last metre fast and decelerating, the hook flies in
    along the rail tail first, slams onto the yoke, the latch dogs snap over its hinge ring, the pawl
    drops into the ratchet and the brake sets; the gauntlet takes the seat."""
    T = RELOAD_T
    p = P()
    seat = RELOAD_BEATS['seat']
    p["RC_Drum"][1].y = track(t, [(0, 0), (seat, -540.0, 'out')]) + land(t, T, slam(t, seat, -10.0, 0.012, 0.05, 0.35, 0.04, 12))
    h = p["RC_Hook"]
    if t < RELOAD_BEATS['hook_in_view']:
        h[0].x = HOOK_GONE
    else:
        h[0].x = track(t, [(RELOAD_BEATS['hook_in_view'], 0.12), (seat, 0.0, 'in')]) + land(t, T, slam(t, seat, -0.004, 0.010, 0.04, 0.35, 0.03, 14))
        h[1].x = track(t, [(RELOAD_BEATS['hook_in_view'], -40.0), (seat, 0.0, 'out')])     # the swivel lets it spin in
    p["RC_Latch"][1].y = track(t, [(0, 0), (seat - 0.07, 0.0), (seat - 0.015, -22.0, 'out'), (RELOAD_BEATS['latch'], 0.0, 'in3')]) \
        + land(t, T, kick(t, RELOAD_BEATS['latch'], 3.0, 0.010, 14.0, 0.04))
    p["RC_Yoke"][0].x = land(t, T, slam(t, seat, -0.004, 0.010, 0.04, 0.35, 0.03, 14))
    p["RC_Pawl"][1].y = track(t, [(0, PAWL_OUT), (seat, PAWL_OUT), (RELOAD_BEATS['pawl_drop'], -2.0, 'in3'), (0.66, 0.0, 'out')])
    p["RC_Brake"][1].y = track(t, [(0, BRAKE_OUT), (seat, BRAKE_OUT), (RELOAD_BEATS['brake_set'], 1.5, 'in3'), (0.70, 0.0, 'out')])
    p["RC_Guide"][0].y = land(t, T, kick(t, seat, R.sy(0.003), 0.015, 11.0, 0.06))
    p["RC_Kick"][0].x = land(t, T, slam(t, seat, -0.006, 0.014, 0.04, 0.35, 0.035, 13))
    p["RC_Kick"][1].y = land(t, T, slam(t, seat, 1.5, 0.014, 0.045, 0.35, 0.035, 12)) + shake(t, 0.0, seat, 0.25, 21.0, 0.3)
    for n, sgn in (("RC_HoseFeed", 1), ("RC_HoseReturn", -1), ("RC_HosePower", 1)):
        p[n][1].x = sgn*land(t, T, kick(t, seat, 14.0, 0.03, 6.0, 0.10))
    return p

TAKES = {
    # name: (seconds, pose, beats, glow keys (t, tracer glow multiplier), hook hidden spans)
    "Idle": (IDLE_T, idle_pose, {}, [(t/8*IDLE_T, 1.0 + 0.10*math.sin(2*math.pi*2*t/8)) for t in range(9)], []),
    "Fire": (FIRE_T, fire_pose, FIRE_BEATS, [(0.0, 3.0), (0.10, 2.2), (0.30, 1.6), (FIRE_T, 1.2)], [(2*F1, FIRE_T)]),
    "Reel": (REEL_T, reel_pose, REEL_BEATS,
             [(0.0, 2.2)] + [k for j in REEL_JOLTS for k in ((j, 2.2), (j + 0.03, 4.0), (j + 0.20, 2.2))] + [(REEL_T, 2.2)], [(0.0, REEL_T)]),
    "Yank": (YANK_T, yank_pose, YANK_BEATS, [(0.0, 2.2), (0.02, 5.0), (0.12, 3.0), (YANK_T, 2.2)], [(0.0, YANK_T)]),
    "Reload": (RELOAD_T, reload_pose, dict(RELOAD_BEATS, end=RELOAD_T), [(0.0, 2.0), (0.50, 2.4), (0.53, 3.2), (0.70, 1.2), (RELOAD_T, 1.0)],
               [(0.0, RELOAD_BEATS['hook_in_view'])]),
    "Empty": (EMPTY_T, empty_pose, {}, [(0.0, 1.4), (EMPTY_T, 1.4)], [(0.0, EMPTY_T)]),
}

def frames(name):
    return round(TAKES[name][0]*FPS)

def padded_frames():
    """The pinned UE3 FBX importer samples every take over the first take's interval, so the export pads
    each take to this shared length by holding its last pose; script ends a take at its own seconds."""
    return max(frames(n) for n in TAKES)

def glow_at(name, t):
    keys = TAKES[name][3]
    return track(t, [(k[0], k[1], 'lin') for k in keys])

def hook_hidden(name, t):
    T = TAKES[name][0]
    return any(a <= t < b or (b >= T - 1e-6 and t >= a) for a, b in TAKES[name][4])

# ---------------------------------------------------------------- armature
def build_armature(coll, scale=1.0, name="RC_Rig"):
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
    b = rig.data.bones[bone]
    ob.parent = rig; ob.parent_type = 'BONE'; ob.parent_bone = bone
    ob.matrix_parent_inverse = (rig.matrix_world @ b.matrix_local @ Matrix.Translation((0, b.length, 0))).inverted()
