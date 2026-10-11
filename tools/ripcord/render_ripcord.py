"""Build the Ripcord concept model and render the stage-1 review set.

    blender --background --factory-startup --python tools/ripcord/render_ripcord.py

Needs build/hand-meshes/VRFloatingHands.fbx (tools/build-hand-assets.ps1) for the display glove and the
Deadbolt decal atlas in assets/weapons/deadbolt/. Writes build/ripcord-concept/review/:
  review_{iso,side_in,side_out,top,iso_out}.png   studio views, auto-framed
  review_mid_in.png       inner side at hand-held distance (perspective)
  review_hook_detail.png  the grapple hook seated on the launch rail, latched, flange on the yoke
  review_hook_poses.png   the hook seated (claws folded) and launched (claws splayed)
  review_cable_path.png   drum, diverter sheave, bell mouth, rail beam and fairlead with the cable routed
  review_hero.png, review_hero_out.png   dark-mood heroes (inner rear; outer rear showing the drum)
  review_hook_2m.png      hook out at 2 m on a taut cable, from behind the forearm as the player sees it
  review_hook_2m_tele.png the same eye point through a long lens, to judge the hook itself at 2 m
  pair_side_in.png, pair_side_out.png   Deadbolt above Ripcord on the same forearm and harness, ortho
  pair_dual.png, pair_dual_top.png      dual wield: Deadbolt right forearm, Ripcord mirrored to the left
and build/ripcord-concept/Ripcord_concept.blend. RIPCORD_SET=quick renders three low-sample views only.
"""
import importlib, math, os, sys, time
import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(os.path.dirname(HERE), "deadbolt")
for p in (HERE, DB):
    if p not in sys.path:
        sys.path.insert(0, p)
import deadbolt_build as B, deadbolt_stage as ST, deadbolt_weather as W, deadbolt_glove as G
import ripcord_build as R, ripcord_weather as RW
for m in (B, ST, W, G, R, RW):
    importlib.reload(m)

ROOT = os.path.dirname(os.path.dirname(HERE))
BASE = os.path.join(ROOT, "build", "ripcord-concept")
OUT = os.path.join(BASE, "review")
SET = os.environ.get("RIPCORD_SET", "all")
TIMES = []

def log_time(label, t0):
    TIMES.append((label, time.time() - t0))
    print(f"ripcord: {label} {time.time() - t0:.1f}s")

def objs_of(*colls):
    return [o for c in colls for o in bpy.data.collections[c].all_objects if not o.hide_render]

def camera(loc, target, lens, res):
    sc = bpy.context.scene
    cm = ST.cam()
    cm.data.type = 'PERSP'; cm.data.lens = lens; cm.data.sensor_fit = 'AUTO'
    cm.data.clip_start = 0.005; cm.data.clip_end = 20
    cm.location = Vector(loc)
    cm.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    sc.render.resolution_x, sc.render.resolution_y = res; sc.render.resolution_percentage = 100

def shot(name, samples):
    sc = bpy.context.scene
    sc.cycles.samples = samples
    sc.render.filepath = os.path.join(OUT, name + ".png")
    t0 = time.time()
    bpy.ops.render.render(write_still=True)
    log_time(name, t0)

def tri_count(objs):
    dg = bpy.context.evaluated_depsgraph_get()
    n = 0
    for o in objs:
        if o.type in ('MESH', 'CURVE', 'FONT'):
            me = o.evaluated_get(dg).to_mesh()
            n += sum(len(p.vertices) - 2 for p in me.polygons)
            o.evaluated_get(dg).to_mesh_clear()
    return n

def parent_all(objs, name):
    e = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(e)
    for o in objs:
        o.parent = e
        o.matrix_parent_inverse.identity()
    return e

def main():
    os.makedirs(OUT, exist_ok=True)
    for name in ("Cube", "Light"):
        o = bpy.data.objects.get(name)
        if o: o.hide_set(True); o.hide_render = True
    t0 = time.time()
    glove = G.build_glove()
    pair = SET in ("all", "pair")
    if pair:   # the Deadbolt first: both guns share its materials
        B.COLL = "DB_Weapon"
        B.build_all(); W.build_weathering()
        bpy.data.collections["DB_Weapon"].hide_render = True
    R.build_all(base_materials=not pair)
    RW.build_weathering(make_mats=not pair)
    log_time("build (cold process)", t0)
    rc = objs_of(R.COLL)
    hook = [o for o in rc if o.name.startswith("Hook |")]
    print(f"ripcord: render-model triangles body+spares {tri_count([o for o in rc if o not in hook])}, hook {tri_count(hook)}")
    view = rc + [glove]
    ST.OUT = OUT
    ST.VIEWS["hero_out"] = ((-0.70, -0.88, 0.48), False)

    if SET == "quick":
        ST.setup("studio")
        t0 = time.time(); ST.render(["iso", "side_out", "top"], "quick", res=(1200, 600), samples=24, objs=view); log_time("quick views", t0)
        return

    if SET in ("all", "review"):
        ST.setup("studio")
        t0 = time.time()
        ST.render(["iso", "side_in", "side_out", "top", "iso_out"], "review", res=(1600, 800), samples=96, objs=view)
        log_time("studio views x5", t0)
        camera((-0.09, 0.53, 0.25), (-0.085, 0.0, 0.065), 28, (1600, 900)); shot("review_mid_in", 128)
        camera((0.330, 0.170, 0.175), (0.105, 0.000, 0.094), 45, (1600, 900)); shot("review_hook_detail", 128)
        # the hook's two poses side by side, seated (claws folded) and launched (splayed), alone under the
        # same three-point studio rig, where the gun usually sits
        for c in (R.COLL, "DB_Hand"):
            bpy.data.collections[c].hide_render = True
        prev = B.COLL; B.COLL = "RC_Poses"
        poses = R.build_hook("Pose | seated", R.Matrix.Translation((-0.165, 0.0, 0.105)))
        poses += R.build_hook("Pose | splayed", R.Matrix.Translation((-0.165, 0.0, 0.005)), splay=True)
        B.COLL = prev
        camera((-0.090, 0.52, 0.16), (-0.075, 0.0, 0.050), 50, (1600, 900)); shot("review_hook_poses", 128)
        for o in poses: bpy.data.objects.remove(o, do_unlink=True)
        for c in (R.COLL, "DB_Hand"):
            bpy.data.collections[c].hide_render = False
        # the cable path: off the drum, over the guide sheave, down the guide tube, into the fairlead
        camera((-0.010, R.SIDE*0.300, 0.290), (-0.075, R.SIDE*0.035, 0.100), 38, (1600, 900)); shot("review_cable_path", 128)
        ST.setup("dark")
        t0 = time.time(); ST.render(["hero", "hero_out"], "review", res=(1600, 900), samples=160, objs=view, lens=40); log_time("heroes x2", t0)
        # hook out at 2 m, cable taut, seen from behind the forearm at eye height
        idle = [o for o in rc if o.name.startswith(("Hook |", "Cable | throat"))]
        for o in idle: o.hide_render = True
        out = R.build_hook_out(2.0)
        hb = out[0].matrix_world.translation
        ld = bpy.data.lights.new("RC_HookLight", "POINT"); ld.energy = 30.0; ld.color = (1.0, 0.85, 0.7); ld.shadow_soft_size = 0.05
        lo = bpy.data.objects.new("RC_HookLight", ld); lo.location = hb + Vector((-0.30, 0.30, 0.30)); bpy.context.scene.collection.objects.link(lo)
        camera((-0.50, 0.19, 0.30), (0.80, -0.03, -0.06), 20, (1600, 900)); shot("review_hook_2m", 192)
        camera((-0.50, 0.19, 0.30), hb, 135, (1600, 900)); shot("review_hook_2m_tele", 192)   # same eye, long lens on the hook
        for o in out: bpy.data.objects.remove(o, do_unlink=True)
        bpy.data.objects.remove(lo, do_unlink=True)
        for o in idle: o.hide_render = False

    if pair:
        ST.setup("studio")
        bpy.data.collections["DB_Weapon"].hide_render = False
        g2 = glove.copy(); bpy.data.collections["DB_Hand"].objects.link(g2)
        db = [o for o in bpy.data.collections["DB_Weapon"].all_objects]
        e_db = parent_all(db + [g2], "Pair | Deadbolt")
        e_rc = parent_all(list(bpy.data.collections[R.COLL].all_objects) + [glove], "Pair | Ripcord")
        both = [o for o in db + [g2] + view if not o.hide_render]
        e_db.location = (0, 0, 0.250); bpy.context.view_layer.update()
        t0 = time.time(); ST.render(["side_in", "side_out"], "pair", res=(1400, 1100), samples=96, objs=both); log_time("pair side x2", t0)
        # dual wield: Deadbolt on the right forearm (-Y), Ripcord mirrored onto the left (+Y)
        e_db.location = (0, -0.16, 0); e_rc.location = (0, 0.16, 0); e_rc.scale = (1, -1, 1)
        bpy.context.view_layer.update()
        camera((-0.52, 0.0, 0.58), (0.10, 0.0, 0.02), 26, (1600, 1000)); shot("pair_dual", 128)
        t0 = time.time(); ST.render(["top"], "pair_dual", res=(1400, 1100), samples=96, objs=both); log_time("pair top", t0)

    for im in bpy.data.images:
        if im.name.startswith("decal_"):
            im.pack()
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(BASE, "Ripcord_concept.blend"), copy=True)
    print("ripcord: timings (each run is a fresh, cold Blender process):")
    for k, v in TIMES:
        print(f"  {k}: {v:.1f}s")

main()
