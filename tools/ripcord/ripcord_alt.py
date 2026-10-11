# Ripcord alternative concept "B": fixed-spool reel (blockout for comparison only, not rigged or exported).
#
# Where the main Ripcord winds its cable on a drum hung beside the forearm, this one stores it on a
# spool lying along the top of the forearm, coaxial with the hook's line, like a giant spinning reel:
#
#   launch   two side rams drive a wide yoke that kicks the hook's tail flange; the cable peels off
#            the front lip of the stationary spool in coils (nothing has to spin up, so pay-out is free),
#            gathers through the wire line cone and leaves through the fairlead at the wrist,
#   reel     the coaxial electric motor spins the rotor cage around the spool; its bail roller lays
#            the cable back on, coil by coil, while the spool oscillates fore and aft,
#   home     the last turns pull the hook tail-first onto the yoke, where the latch dogs catch it.
#
# The spinning rotor is the hero motion. Same frame, harness, hook and fairlead as the main build
# (ripcord_build, imported as R); built into its own collection so both can be rendered together.
import math
from mathutils import Vector, Matrix
import deadbolt_build as B
import ripcord_build as R

COLL = "RCB_Weapon"
TAU = math.tau
AX_Z = 0.106                        # spool / rotor axis
SPOOL = (-0.250, -0.100)            # cable spool along X
CORE_R, PACK_R, ROTOR_R = 0.024, 0.0335, 0.050
MOTOR = (-0.342, -0.262)

def ax(x, r, a_deg, z=AX_Z):
    a = math.radians(a_deg)
    return Vector((x, r*math.cos(a), z + r*math.sin(a)))

def build_spool():
    x0, x1 = SPOOL
    B.cyl("Spool | core", (x0, 0, AX_Z), (x1, 0, AX_Z), PACK_R - 0.0008, "cable", seg=48)
    # outer wound layer as a helix along X
    turns = (x1 - x0 - 0.006)/(2*R.CABLE_R + 0.0002)
    n = int(turns*R.RQ['helix_res'])
    pts = [ax(x0 + 0.003 + (x1 - x0 - 0.006)*i/n, PACK_R + R.CABLE_R, 360.0*turns*i/n) for i in range(n + 1)]
    R.rope("Spool | wrap layer", pts, phase=0.4)
    B.cyl("Spool | rear flange", (x0 - 0.006, 0, AX_Z), (x0, 0, AX_Z), PACK_R + 0.0075, "steel_dark", seg=48, bevel=0.0008)
    B.cyl("Spool | front lip", (x1, 0, AX_Z), (x1 + 0.007, 0, AX_Z), PACK_R + 0.0040, "steel_bright", seg=48, r1=PACK_R - 0.0040, bevel=0.0008)
    # the oscillation shaft the spool rides on, through the motor housing
    B.cyl("Spool | shaft", (MOTOR[1], 0, AX_Z), (x0 - 0.006, 0, AX_Z), 0.0080, "chrome", seg=24)

def build_rotor():
    x0, x1 = SPOOL[0] - 0.004, SPOOL[1] + 0.012
    for x, w in ((x0, 0.010), (x1, 0.012)):
        B.tube_ring("Rotor | ring", (x - w/2, 0, AX_Z), (x + w/2, 0, AX_Z), ROTOR_R + 0.004, ROTOR_R - 0.003, "hazard_shell", seg=64)
    for k in range(3):
        a = 90 + 120*k
        B.cyl("Rotor | bar", ax(x0, ROTOR_R, a), ax(x1, ROTOR_R, a), 0.0042, "steel_dark", seg=12)
    # bail: a heavy wire hoop across the front of the rotor with a line roller on one side
    hoop = [ax(x1 + 0.006 + 0.010*math.sin(math.radians(t)), ROTOR_R - 0.002, -30 + t) for t in range(0, 241, 6)]
    B.curve_tube("Rotor | bail", [tuple(p) for p in hoop], 0.0030, "steel_bright", res=8)
    p = ax(x1 + 0.006, ROTOR_R - 0.002, -30)
    B.cyl("Rotor | line roller", p + Vector((-0.006, 0, 0)), p + Vector((0.008, 0, 0)), 0.0062, "steel_bright", seg=20, bevel=0.0005)
    # ratchet ring on the rotor's rear with the pawl on a bracket: the only manual parts
    B.tube_ring("Rotor | ratchet", (x0 - 0.012, 0, AX_Z), (x0 - 0.006, 0, AX_Z), ROTOR_R - 0.002, ROTOR_R - 0.012, "steel", seg=48)
    B.box("Frame | pawl bracket", x0 - 0.016, x0 - 0.004, 0.030, 0.042, AX_Z + 0.026, AX_Z + 0.050, "steel", bevel=0.0008)
    pw = B.box("Pawl | dog", -0.0025, 0.0025, -0.004, 0.004, 0.0, 0.020, "paint_red", bevel=0.0006)
    pw.matrix_world = Matrix.Translation((x0 - 0.010, 0.036, AX_Z + 0.046)) @ Matrix.Rotation(math.radians(150), 4, 'X')

def build_motor():
    x0, x1 = MOTOR
    B.cyl("Motor | can", (x0, 0, AX_Z), (x1, 0, AX_Z), 0.030, "gunmetal", seg=48, bevel=0.0012)
    for k in range(20):
        a = 360*k/20
        f = B.box("Motor | fin", x0 + 0.008, x1 - 0.008, -0.0008, 0.0008, 0.0, 0.0050, "steel_dark", bevel=0.0002)
        f.matrix_world = Matrix.Translation(ax(0, 0.029, a)) @ Matrix.Rotation(math.radians(a - 90), 4, 'X')
    B.tube_ring("Motor | hazard band", (x1 - 0.010, 0, AX_Z), (x1, 0, AX_Z), 0.0345, 0.029, "hazard_shell", seg=48)
    B.cyl("Motor | gearbox", (x1, 0, AX_Z), (SPOOL[0] - 0.016, 0, AX_Z), 0.034, "steel", seg=48, bevel=0.0012)
    B.cyl("Motor | end bell", (x0 - 0.008, 0, AX_Z), (x0, 0, AX_Z), 0.026, "steel_dark", seg=6, bevel=0.0010)
    B.box("Motor | foot", x0 + 0.004, SPOOL[0] - 0.016, -0.026, 0.026, 0.050, AX_Z - 0.024, "steel_dark", bevel=0.0012)
    B.box("Motor | terminal box", x0 + 0.020, x0 + 0.044, -0.012, 0.012, AX_Z + 0.028, AX_Z + 0.040, "steel_dark", bevel=0.0010)

def build_front():
    z = R.HOOK_Z
    # wire line cone: gathers the coils peeling off the spool lip into the fairlead
    x0, x1 = SPOOL[1] + 0.012, R.FAIR_X0 - 0.002
    B.tube_ring("Cone | rear ring", (x0, 0, AX_Z), (x0 + 0.005, 0, AX_Z), 0.047, 0.043, "steel_dark", seg=48)
    for k in range(8):
        a = 360*k/8 + 22.5
        B.cyl("Cone | wire", ax(x0 + 0.004, 0.045, a), ax(x1, 0.018, a, z=z), 0.0016, "steel", seg=8)
    B.box("Rail | beam", -0.100, R.FAIR_X0, -0.020, 0.020, 0.053, 0.068, "yellow_plain", bevel=0.0012)
    # twin side rams and the wide yoke
    for s in (1, -1):
        y = s*0.034
        B.cyl("Ram | barrel", (-0.080, y, 0.074), (0.000, y, 0.074), 0.0110, "steel", seg=32, bevel=0.0008)
        B.cyl("Ram | cap", (-0.086, y, 0.074), (-0.080, y, 0.074), 0.0122, "steel_dark", seg=6, bevel=0.0006)
        B.cyl("Yoke | rod", (0.000, y, 0.074), (R.YOKE_X0, y, 0.074), 0.0042, "chrome", seg=16)
    B.box("Yoke | plate", R.YOKE_X0, R.YOKE_X1, -0.044, 0.044, 0.064, z + 0.012, "steel", bevel=0.0012)
    # air bottle (inner side) and power cell (outer side) under the spool
    B.cyl("Rear | air bottle", (-0.330, 0.052, 0.058), (-0.150, 0.052, 0.058), 0.0165, "steel", seg=40, bevel=0.0012)
    B.box("Rear | Horzine plate", -0.300, -0.250, 0.0685, 0.0705, 0.048, 0.068, "steel_bright", bevel=0.0006)
    B.box("Rear | power cell", -0.330, -0.160, -0.070, -0.036, 0.040, 0.080, "yellow_hazard", bevel=0.0025)
    B.cyl("Rear | power lamp", (-0.180, -0.0705, 0.070), (-0.180, -0.0725, 0.070), 0.0034, "status_glow", seg=16, bevel=0)

def build_alt():
    prev = B.COLL
    B.COLL = COLL
    try:
        B.clear_coll(COLL)
        before = set(B.get_coll(COLL).objects)
        B.build_gauntlet(); B.build_mount()
        R.rename_stamp([o for o in B.get_coll(COLL).objects if o not in before])
        build_spool(); build_rotor(); build_motor(); build_front()
        R.build_fairlead()
        R.build_hook("Hook", Matrix.Translation((R.HOOK_X0, 0.0, R.HOOK_Z)))
        # visible line: off the spool lip, through the cone, into the fairlead, to the ferrule
        lip = ax(SPOOL[1] + 0.006, PACK_R, 100)
        R.rope("Cable | line", R.catmull([lip, ax(SPOOL[1] + 0.040, 0.026, 60, z=0.5*(AX_Z + R.HOOK_Z)), Vector((R.FAIR_X0 - 0.010, 0, R.HOOK_Z)),
                                          Vector((R.HOOK_X0 - 0.0005, 0, R.HOOK_Z))], 0.002), phase=1.1)
    finally:
        B.COLL = prev
    return len(B.get_coll(COLL).objects)
