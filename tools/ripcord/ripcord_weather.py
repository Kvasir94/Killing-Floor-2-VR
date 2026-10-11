# Hand-placed weathering for the Ripcord, stamped from the Deadbolt's decal atlas
# (assets/weapons/deadbolt/decal_atlas.png) with deadbolt_weather.decal, so both guns wear the same
# rust, oil, grime and chipping. Cells: rust 0-2, oil 4-5, soot 6-7, chips 8-11, grime 12-13.
import math, os, sys
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(os.path.dirname(HERE), "deadbolt")
if DB not in sys.path:
    sys.path.insert(0, DB)
import deadbolt_build as B
import deadbolt_weather as W
import ripcord_build as R

PLACED = []   # this gun's stamps, for the game export bake

SCALE = {"chips": (1.2, 1.6), "rust": (2.6, 1.7), "soot": (1.6, 1.5), "oil": (1.4, 1.4), "grime": (1.0, 1.15), "scratch": (1.2, 1.2)}

def _place(D):
    for i, (cat, cell, p, n, up, w, h) in enumerate(D):
        sw, sh = SCALE[cat]
        upn = Vector(up).normalized()
        shift = (h*sh - h)/2 if (cat == "chips" and cell in (8, 9)) or cat == "rust" else 0.0
        W.decal(f"Decal | rc {cat} {i}", cat, cell, Vector(p) - upn*shift, n, up, w*sw, h*sh)

def build_weathering(make_mats=True):
    prev = B.COLL
    B.COLL = R.COLL
    start = len(W.PLACED)
    try:
        if make_mats or "decal_rust" not in B.MATS:
            W.decal_mats()
        X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)
        nY, nX = (0, -1, 0), (-1, 0, 0)
        z = R.HOOK_Z
        x0, x1, y0, y1, z0, z1 = R.BLOCK
        D = []
        # rail beam: grime wash and rust runs under the side bolts, chipped top edges
        D += [("grime", 13, (-0.080, -0.0216, 0.074), nY, Z, 0.110, 0.030),
              ("rust", 0, (-0.052, -0.0216, 0.0615), nY, Z, 0.008, 0.020),
              ("rust", 1, (-0.028, -0.0216, 0.0615), nY, Z, 0.008, 0.018),
              ("grime", 12, (-0.050, 0.0216, 0.066), Y, Z, 0.060, 0.016),
              ("chips", 8, (-0.090, 0.0216, 0.0985), Y, Z, 0.050, 0.010),
              ("chips", 9, (-0.150, -0.0216, 0.0985), nY, Z, 0.050, 0.010),
              ("oil", 4, (-0.100, 0.0216, 0.090), Y, Z, 0.012, 0.022)]
        # fairlead and yoke: cable grease round the throat, chipped hazard cheeks
        D += [("oil", 5, (R.YOKE_X1 + 0.0003, 0.0, z + 0.004), X, Z, 0.028, 0.036),
              ("grime", 13, (R.YOKE_X1 + 0.0003, 0.0, z - 0.010), X, Z, 0.028, 0.012),
              ("chips", 10, (0.028, 0.0262, z + 0.012), Y, Z, 0.026, 0.022),
              ("chips", 11, (0.030, -0.0262, z - 0.014), nY, Z, 0.020, 0.020)]
        # launch ram: oil weeping from the gland, rust under the rear tie nuts
        D += [("oil", 4, (R.RAM_X1 + 0.0003, 0.0, R.RAM_Z - 0.010), X, Z, 0.016, 0.020),
              ("rust", 0, (R.RAM_X0 - 0.0003, 0.0135, R.RAM_Z - 0.0155), nX, Z, 0.006, 0.016),
              ("rust", 1, (R.RAM_X0 - 0.0003, -0.0135, R.RAM_Z - 0.0155), nX, Z, 0.006, 0.014)]
        # reservoir block: rust below the plate screws, grime, chipped top edge, scuffed rear
        D += [("rust", 0, (-0.332, y1 + 0.0025, 0.050), Y, Z, 0.007, 0.020),
              ("rust", 2, (-0.298, y1 + 0.0025, 0.050), Y, Z, 0.007, 0.022),
              ("grime", 12, (-0.300, y1 + 0.0003, z0 + 0.010), Y, Z, 0.070, 0.018),
              ("chips", 8, (-0.300, y1 + 0.0003, z1 - 0.003), Y, Z, 0.050, 0.010),
              ("chips", 9, (-0.300, 0.010, z1 + 0.0003), Z, Y, 0.040, 0.012),
              ("grime", 13, (x0 - 0.0003, 0.010, 0.085), nX, Z, 0.070, 0.060),
              ("chips", 10, (x0 - 0.0003, -0.020, 0.112), nX, Z, 0.020, 0.018)]
        # gear case: oil weeping from the output seal; drum hanger rust
        dn = (0, R.SIDE, 0)
        D += [("oil", 4, (R.DRUM_X, R.Y_GEAR[1] + R.sy(0.0034), R.DRUM_Z - 0.012), dn, Z, 0.018, 0.030),
              ("oil", 5, (R.DRUM_X - 0.020, R.Y_BRAKE[1] + R.sy(0.0004), R.DRUM_Z - 0.040), dn, Z, 0.020, 0.016)]
        _place(D)
        # drum guard (curved): chipped leading and trailing edges, grime wash, rust from the bolts
        for k, (a, cat, cell, y, w, h) in enumerate(((80, "chips", 8, 0.042, 0.030, 0.012), (140, "chips", 9, 0.058, 0.030, 0.012),
                                                     (130, "grime", 13, 0.050, 0.040, 0.040), (175, "grime", 12, 0.045, 0.030, 0.030),
                                                     (205, "chips", 10, 0.062, 0.020, 0.020), (190, "rust", 1, 0.066, 0.008, 0.026))):
            p = R.drum_pt(a, R.GUARD_R[1], R.sy(y))
            n = (R.drum_pt(a, 1, 0) - R.drum_pt(a, 0, 0)).normalized()
            up = Vector((0, -1, 0)) if cat != "rust" else (R.drum_pt(a + 90, 1, 0) - R.drum_pt(a, 1, 0)).normalized()
            W.decal(f"Decal | rc guard {k}", cat, cell, p, n, up, w, h, segs=(6, 4), shrink="Guard | drum guard front" if a < R.GUARD_GAP[0] else "Guard | drum guard")
        # launch ram barrel (curved): oil weeping back from the gland, grime in the lower half
        for k, (x, a, cat, cell, w, h) in enumerate(((R.RAM_X1 - 0.022, 60, "oil", 5, 0.022, 0.018), (R.RAM_X0 + 0.050, 70, "grime", 13, 0.050, 0.020),
                                                       (R.RAM_X0 + 0.040, -60, "grime", 12, 0.050, 0.018))):
            aa = math.radians(a)
            n = Vector((0, math.cos(aa), math.sin(aa)))
            p = Vector((x, 0, R.RAM_Z)) + n*0.0151
            W.decal(f"Decal | rc ram {k}", cat, cell, p, n, (1, 0, 0), w, h, segs=(6, 3), shrink="Ram | barrel")
        # RIPCORD plate on the sleeve: dirt wash wrapped onto the plate
        th = math.radians(14)
        pm = B.cuff_pt(-0.136, th, 0.0094)
        nrm = Vector((0, math.cos(th), math.sin(th))); upv = Vector((0, -math.sin(th), math.cos(th)))
        W.decal("Decal | rc plate grime", "grime", 13, pm, nrm, upv, 0.062, 0.030, segs=(8, 6), shrink="Gauntlet | RIPCORD plate")
    finally:
        B.COLL = prev
    PLACED[:] = W.PLACED[start:]
    return len(PLACED)
