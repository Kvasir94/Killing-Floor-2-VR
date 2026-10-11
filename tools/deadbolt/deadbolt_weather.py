# Hand-placed weathering for the Deadbolt: decal atlas stamps + heat-tint on the muzzle hardware.
import bpy, bmesh, math, os
from mathutils import Vector
import deadbolt_build as B

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIR = os.path.join(ROOT, "assets", "weapons", "deadbolt")   # atlas written by make_decals.py
ATLAS = os.path.join(DIR, "decal_atlas.png")
METAL = os.path.join(DIR, "decal_metal.png")

CATS = {  # category: (roughness, metallic-from-mask, alpha gain)
    "rust": (0.85, False, 1.0), "oil": (0.12, False, 0.85), "soot": (0.95, False, 1.0),
    "chips": (0.32, True, 1.0), "grime": (0.88, False, 0.8), "scratch": (0.30, False, 0.75),
}

def load(path, non_color=False):
    name = os.path.basename(path)
    im = bpy.data.images.get(name)
    if im: im.reload()
    else: im = bpy.data.images.load(path)
    if non_color: im.colorspace_settings.name = 'Non-Color'
    return im

def decal_mats():
    atlas, metal = load(ATLAS), load(METAL, True)
    for cat, (rough, use_metal, gain) in CATS.items():
        nt = B.NT(B.newmat("decal_" + cat))
        m = B.MATS["decal_" + cat]
        tex = nt.n('ShaderNodeTexImage', image=atlas, interpolation='Cubic')
        p = nt.bsdf((0.1, 0.1, 0.1), 0.0, rough)
        nt.l(tex.outputs['Color'], p.inputs['Base Color'])
        nt.l(nt.math('MULTIPLY', tex.outputs['Alpha'], gain, clamp=True), p.inputs['Alpha'])
        if use_metal:
            mt = nt.n('ShaderNodeTexImage', image=metal, interpolation='Cubic')
            nt.l(mt.outputs['Color'], p.inputs['Metallic'])
            nt.l(nt.maprange(mt.outputs['Color'], 0.0, 1.0, 0.75, rough), p.inputs['Roughness'])
        try:
            m.surface_render_method = 'BLENDED'
        except Exception:
            pass

PLACED = []   # every stamp as placed, for the game export to bake into the body texture

def decal(name, cat, cell, p, n, up, w, h, segs=(1, 1), shrink=None, lift=0.00025):
    n = Vector(n).normalized(); up = Vector(up)
    up = (up - n*up.dot(n)).normalized()
    xv = up.cross(n)
    r, c = divmod(cell, 4)
    u0, v0 = c/4, 1 - (r + 1)/4
    p = Vector(p) + n*lift
    bm = bmesh.new()
    nx, ny = segs
    verts = [[bm.verts.new(p + xv*(i/nx - 0.5)*w + up*(j/ny - 0.5)*h) for i in range(nx + 1)] for j in range(ny + 1)]
    uvl = bm.loops.layers.uv.new("UVMap")
    for j in range(ny):
        for i in range(nx):
            f = bm.faces.new((verts[j][i], verts[j][i+1], verts[j+1][i+1], verts[j+1][i]))
            for loop, (ii, jj) in zip(f.loops, ((i, j), (i+1, j), (i+1, j+1), (i, j+1))):
                loop[uvl].uv = (u0 + ii/nx/4, v0 + jj/ny/4)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me)
    me.materials.append(B.MATS["decal_" + cat])
    for poly in me.polygons: poly.use_smooth = True
    B.link(ob)
    PLACED.append(dict(cat=cat, cell=cell, p=tuple(p - n*lift), n=tuple(n), up=tuple(up), x=tuple(xv), w=w, h=h, curved=bool(shrink)))
    ob.visible_shadow = False
    if shrink:
        tgt = bpy.data.objects.get(shrink)
        if tgt:
            sw = ob.modifiers.new("wrap", 'SHRINKWRAP'); sw.target = tgt
            sw.wrap_method = 'NEAREST_SURFACEPOINT'; sw.offset = lift
    return ob

def mat_heat():
    nt = B.NT(B.newmat("heat_tint"))
    co = B.obj_coord(nt)
    sep = nt.n('ShaderNodeSeparateXYZ'); nt.l(co, sep.inputs[0])
    nz = nt.noise(60.0, 6, 0.6, co)
    t = nt.math('ADD', nt.maprange(sep.outputs['X'], 0.044, 0.074), nt.math('MULTIPLY', nz.outputs['Fac'], 0.12))
    ramp = nt.n('ShaderNodeValToRGB'); nt.l(t, ramp.inputs['Fac'])
    cr = ramp.color_ramp
    cr.elements[0].position = 0.0; cr.elements[0].color = (0.20, 0.195, 0.19, 1)
    cr.elements[1].position = 1.0; cr.elements[1].color = (0.06, 0.065, 0.08, 1)
    for pos, col in ((0.40, (0.20, 0.19, 0.18)), (0.52, (0.45, 0.34, 0.13)), (0.62, (0.34, 0.18, 0.08)),
                     (0.72, (0.18, 0.10, 0.17)), (0.82, (0.08, 0.14, 0.32)), (0.94, (0.05, 0.055, 0.07))):
        e = cr.elements.new(pos); e.color = (*col, 1)
    soot = nt.maprange(nt.ao(0.01), 0.9, 0.4, 0.0, 0.7)
    col = nt.mix(soot, ramp.outputs['Color'], (0.02, 0.018, 0.016))
    nt.bsdf(col, nt.math('SUBTRACT', 1.0, soot), nt.maprange(nz.outputs['Fac'], 0.3, 0.7, 0.28, 0.5))

HEAT_PREFIXES = ("Front | muzzle collar", "Front | muzzle crown", "Spike | shank",
                 "Front | bore ring", "Front | crown bolt")

def ysl(x):  # rear housing +Y slanted face
    return 0.052 - 0.132*(x + 0.262)

def build_weathering():
    PLACED.clear()
    decal_mats(); mat_heat()
    for ob in list(B.get_coll(B.COLL).objects):
        if ob.name.startswith(HEAT_PREFIXES) and ob.type == 'MESH':
            ob.data.materials.clear(); ob.data.materials.append(B.MATS["heat_tint"])
    Y, Z, X = (0, 1, 0), (0, 0, 1), (1, 0, 0)
    nsl = (0.132, 1, 0)
    D = []
    # upper hazard plate, inner side: chipped top/bottom edges, front corner, grime wash
    D += [("chips", 8, (-0.100, 0.0312, 0.1150), Y, Z, 0.036, 0.012),
          ("chips", 9, (-0.036, 0.0312, 0.1150), Y, Z, 0.034, 0.012),
          ("chips", 8, (-0.068, 0.0312, 0.1070), Y, (0, 0, -1), 0.030, 0.012),
          ("chips", 11, (0.032, 0.0312, 0.1130), Y, Z, 0.016, 0.016),
          ("grime", 13, (-0.050, 0.0313, 0.1110), Y, Z, 0.090, 0.020)]
    # bulkhead + collar bolts: rust running down
    D += [("rust", 0, (-0.125, 0.0402, 0.1080), Y, Z, 0.010, 0.030),
          ("rust", 1, (-0.125, 0.0402, 0.0750), Y, Z, 0.010, 0.026),
          ("rust", 0, (-0.007, 0.0362, 0.1010), Y, Z, 0.008, 0.026)]
    # rear housing inner slanted face
    for x, cat, cell, z, w, h in ((-0.182, "chips", 9, 0.0980, 0.030, 0.012), (-0.150, "chips", 10, 0.0700, 0.030, 0.030),
                                  (-0.165, "grime", 13, 0.0680, 0.070, 0.040), (-0.140, "oil", 4, 0.0860, 0.014, 0.036)):
        D.append((cat, cell, (x, ysl(x), z), nsl, Z, w, h))
    # HORZINE box: rust under label screws, grime, scuffs, scratches, oil from the canister clamp, dirt in the lettering
    D += [("rust", 0, (-0.288, 0.0682, 0.0170), Y, Z, 0.007, 0.022),
          ("rust", 1, (-0.224, 0.0682, 0.0175), Y, Z, 0.008, 0.020),
          ("rust", 2, (-0.300, 0.0682, 0.0560), Y, Z, 0.008, 0.020),
          ("grime", 12, (-0.304, 0.0682, 0.0160), Y, Z, 0.030, 0.020),
          ("grime", 12, (-0.208, 0.0682, 0.0300), Y, Z, 0.022, 0.030),
          ("chips", 8, (-0.290, 0.0662, 0.0950), Y, Z, 0.040, 0.012),
          ("oil", 4, (-0.240, 0.0662, 0.0900), Y, Z, 0.010, 0.020),
          ("grime", 13, (-0.256, 0.0700, 0.0410), Y, Z, 0.072, 0.034)]
    # muzzle: soot blown back over the cheek and round the bore
    D += [("soot", 7, (0.024, 0.0262, 0.0810), Y, X, 0.030, 0.024),
          ("soot", 7, (0.024, -0.0262, 0.0810), (0, -1, 0), X, 0.030, 0.024),
          ("soot", 6, (0.0443, 0.0, 0.0810), X, Z, 0.044, 0.044),
          ("soot", 7, (0.050, 0.0313, 0.1105), Y, X, 0.020, 0.030),
          ("soot", 7, (0.020, 0.0, 0.0983), Z, X, 0.044, 0.040),
          ("soot", 7, (0.052, 0.0, 0.0608), Z, X, 0.060, 0.026),
          ("soot", 6, (0.058, -0.0313, 0.1110), (0, -1, 0), X, 0.026, 0.022),
          ("soot", 7, (0.044, 0.0333, 0.0535), Y, X, 0.012, 0.034),
          ("grime", 13, (-0.030, 0.0333, 0.0535), Y, Z, 0.140, 0.016),
          ("oil", 4, (-0.070, 0.0333, 0.0540), Y, Z, 0.012, 0.016),
          ("oil", 5, (-0.020, 0.0333, 0.0520), Y, Z, 0.016, 0.012)]
    # tops: chipped edges, oil under the manifold ports, grime, scratched latch deck
    D += [("chips", 9, (-0.090, 0.0250, 0.1212), Z, Y, 0.040, 0.012),
          ("chips", 8, (-0.060, -0.0250, 0.1212), Z, (0, -1, 0), 0.040, 0.012),
          ("grime", 12, (-0.075, 0.0180, 0.1212), Z, X, 0.030, 0.020),
          ("oil", 5, (-0.226, 0.0260, B.REAR_TOP + 0.0002), Z, X, 0.022, 0.022),
          ("chips", 8, (-0.256, 0.0200, B.REAR_TOP + 0.0002), Z, (-1, 0, 0), 0.030, 0.012),
          ("chips", 9, (-0.230, 0.0364, B.REAR_TOP + 0.0002), Z, Y, 0.030, 0.012),
          ("grime", 12, (-0.240, -0.0250, B.REAR_TOP + 0.0002), Z, X, 0.030, 0.030),
          ("grime", 13, (-0.2683, 0.0, 0.0750), (-1, 0, 0), Z, 0.080, 0.050)]
    SCALE = {"chips": (1.2, 1.6), "rust": (2.6, 1.7), "soot": (1.6, 1.5), "oil": (1.4, 1.4), "grime": (1.0, 1.15), "scratch": (1.2, 1.2)}
    for i, (cat, cell, p, n, up, w, h) in enumerate(D):
        sw, sh = SCALE[cat]
        upn = Vector(up).normalized()
        shift = (h*sh - h)/2 if (cat == "chips" and cell in (8, 9)) or cat == "rust" else 0.0
        p2 = Vector(p) - upn*shift            # keep the decal's top (edge / bolt) where it was
        decal(f"Decal | {cat} {i}", cat, cell, p2, n, up, w*sw, h*sh)
    # DEADBOLT plate (curved): dirt wash + rust from the upper rivets, wrapped onto the plate
    th = math.radians(14)
    pm = B.cuff_pt(-0.136, th, 0.0094)
    nrm = Vector((0, math.cos(th), math.sin(th))); upv = Vector((0, -math.sin(th), math.cos(th)))
    decal("Decal | plate grime", "grime", 13, pm, nrm, upv, 0.062, 0.030, segs=(8, 6), shrink="Gauntlet | DEADBOLT plate")
    for x in (-0.163, -0.109):
        th2 = math.radians(34) - 0.07 - 0.20
        pr = B.cuff_pt(x, th2, 0.0094); n2 = Vector((0, math.cos(th2), math.sin(th2))); u2 = Vector((0, -math.sin(th2), math.cos(th2)))
        decal("Decal | plate rust", "rust", 1, pr, n2, u2, 0.007, 0.018, segs=(2, 6), shrink="Gauntlet | DEADBOLT plate")
    return len(D) + 3
