"""Review renders of the rigged Ripcord and its authored takes (Blender 5.2, Cycles):

    blender --background --factory-startup --python tools/ripcord/render_ripcord_anim.py
    python tools/ripcord/make_anim_sheets.py

Builds the render model, skins it to the ripcord_anim rig, and writes to build/ripcord-concept/review/:
  review_iso.png, review_side.png       lit three-point views of the idle model
  review_idle_mid.png                   idle from the inner side at hand-held distance
  review_empty.png                      the hook out on the line (Empty): rail bare, pawl up, brake off
  review_reel_mid.png                   mid-reel from the same hand-held view, tracer at reel glow
  full/<take>_<frame>.png               full-size frames at every beat of Fire, Reel, Yank and Reload
  frames/<take>_<frame>.png             strip frames from one fixed camera, poses sampled from the take
  frames.json                           labels for make_anim_sheets.py (take, frame, time, beat)
The tracer glow follows the take's glow keys and the seated hook hides in its hidden spans, as the
game script applies them. RIPCORD_REVIEW=static or =strips renders only one half.
"""
import importlib, json, math, os, sys, time
import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(os.path.dirname(HERE), "deadbolt")
for p in (HERE, DB):
    if p not in sys.path:
        sys.path.insert(0, p)
import deadbolt_build as B, deadbolt_stage as ST, deadbolt_weather as W, deadbolt_glove as G
import ripcord_build as R, ripcord_weather as RW, ripcord_anim as A
for m in (B, ST, W, G, R, RW, A):
    importlib.reload(m)

ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "build", "ripcord-concept", "review")
FR = os.path.join(OUT, "frames")
MODE = os.environ.get("RIPCORD_REVIEW", "all")

STRIPS = {
    "Fire": [0.0, 0.017, 0.033, 0.050, 0.067, 0.083, 0.100, 0.133, 0.167, 0.200, 0.250, 0.300, 0.400, 0.600],
    "Reel": [0.0, 0.20, 0.350, 0.367, 0.400, 0.50, 0.75, 1.050, 1.067, 1.25, 1.50, 1.700, 1.717, 2.00, 2.25, 2.50],
    "Yank": [0.0, 0.017, 0.033, 0.050, 0.067, 0.083, 0.100, 0.133, 0.167, 0.200, 0.250, 0.300],
    "Reload": [0.0, 0.10, 0.20, 0.300, 0.350, 0.400, 0.450, 0.483, 0.517, 0.533, 0.550, 0.583, 0.617, 0.700, 0.900, 1.100],
}

def rig_render_model():
    rig = A.build_armature(B.get_coll(R.COLL))
    for ob in list(B.get_coll(R.COLL).objects):
        if ob == rig:
            continue
        key = A.gradient_key(ob.name)
        if key and ob.type == 'CURVE':
            dg = bpy.context.evaluated_depsgraph_get()
            me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), depsgraph=dg)
            me.transform(ob.matrix_world)
            name = ob.name
            bpy.data.objects.remove(ob, do_unlink=True)
            mo = bpy.data.objects.new(name, me)
            B.get_coll(R.COLL).objects.link(mo)
            for p in me.polygons: p.use_smooth = True
            A.assign_groups(mo, name)
            mo.modifiers.new("rig", 'ARMATURE').object = rig
        else:
            A.parent_rigid(ob, rig, A.rigid_bone(ob.name))
    return rig

def glow_nodes():
    out = []
    for m in bpy.data.materials:
        if m.use_nodes and m.name == "DB_cable":
            out += [n for n in m.node_tree.nodes if n.type == 'VALUE' and n.name.startswith("heat")]
    return out

def set_state(rig, take, t, nodes):
    A.apply_pose(rig, A.TAKES[take][1](t))
    g = A.glow_at(take, t)
    for n in nodes: n.outputs[0].default_value = g
    hidden = A.hook_hidden(take, t)
    for ob in B.get_coll(R.COLL).objects:
        if ob.name.startswith("Hook |"):
            ob.hide_render = hidden
    bpy.context.view_layer.update()

def camera(loc, target, lens=50, res=(1400, 700)):
    sc = bpy.context.scene
    cm = ST.cam()
    cm.location = Vector(loc)
    cm.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    cm.data.type = 'PERSP'; cm.data.lens = lens
    cm.data.clip_start = 0.005; cm.data.clip_end = 20
    sc.render.resolution_x, sc.render.resolution_y = res; sc.render.resolution_percentage = 100

def shot(path, samples):
    sc = bpy.context.scene
    sc.cycles.samples = samples
    sc.render.filepath = path
    t = time.time()
    bpy.ops.render.render(write_still=True)
    return time.time() - t

def beat_at(take, f):
    beats = A.TAKES[take][2]
    return next((k for k, v in beats.items() if abs(v - f/A.FPS) < 0.5/A.FPS), "")

def main():
    os.makedirs(FR, exist_ok=True)
    for name in ("Cube", "Light"):
        o = bpy.data.objects.get(name)
        if o: o.hide_set(True); o.hide_render = True
    G.build_glove(); R.build_all(); RW.build_weathering()
    rig = rig_render_model()
    nodes = glow_nodes()
    ST.setup("studio")
    sc = bpy.context.scene
    timings = {}
    view = [o for o in B.get_coll(R.COLL).all_objects if o.type != 'ARMATURE'] + [bpy.data.objects["DB_Glove"]]
    set_state(rig, "Idle", 0.0, nodes)
    S = R.SIDE
    if MODE in ("all", "static"):
        ST.OUT = OUT
        t = time.time()
        ST.render(["iso", "side_in"], "review", res=(1600, 800), samples=128, objs=view)
        os.replace(os.path.join(OUT, "review_side_in.png"), os.path.join(OUT, "review_side.png"))
        timings["static views"] = time.time() - t
        tgt = Vector((-0.085, 0.0, 0.065))
        camera(tgt + Vector((-0.005, S*0.53, 0.185)), tgt, lens=28, res=(1600, 900))
        timings["idle mid"] = shot(os.path.join(OUT, "review_idle_mid.png"), 128)
        set_state(rig, "Reel", 1.25, nodes)
        timings["reel mid"] = shot(os.path.join(OUT, "review_reel_mid.png"), 128)
        set_state(rig, "Empty", 0.0, nodes)
        tgt = Vector((-0.010, S*0.010, 0.095))
        camera(tgt + Vector((0.170, S*0.300, 0.150)), tgt, lens=40, res=(1600, 900))
        timings["empty"] = shot(os.path.join(OUT, "review_empty.png"), 128)
        set_state(rig, "Idle", 0.0, nodes)
    labels, full, guides = [], [], {}
    if MODE in ("all", "strips"):
        ST.setup("review")
        tgt = Vector((-0.045, S*0.015, 0.095))
        camera(tgt + Vector((0.42, S*0.84, 0.38)).normalized()*0.56, tgt, lens=40, res=(1200, 560))
        from bpy_extras.object_utils import world_to_camera_view
        bpy.context.view_layer.update()
        guides = {n: tuple(world_to_camera_view(sc, sc.camera, Vector(p))[:2]) for n, p in
                  (("fairlead", R.FAIRLEAD_SOCKET), ("drum", (R.DRUM_X, R.sy(0.07), R.DRUM_Z)))}
        for take, times in STRIPS.items():
            t0 = time.time()
            for tt in times:
                f = round(tt*A.FPS)
                set_state(rig, take, f/A.FPS, nodes)
                path = os.path.join(FR, f"{take}_{f:03d}.png")
                shot(path, 40)
                labels.append(dict(take=take, frame=f, time=round(f/A.FPS, 3), beat=beat_at(take, f), file=os.path.relpath(path, OUT)))
            timings[f"strip {take} ({len(times)} frames)"] = time.time() - t0
        # a full-size frame at every beat
        os.makedirs(os.path.join(OUT, "full"), exist_ok=True)
        sc.render.resolution_x, sc.render.resolution_y = 1600, 746
        t0 = time.time()
        for take in STRIPS:
            T = A.TAKES[take][0]
            for beat, v in sorted(A.TAKES[take][2].items(), key=lambda kv: kv[1]):
                f = min(round(v*A.FPS), round(T*A.FPS))
                set_state(rig, take, f/A.FPS, nodes)
                path = os.path.join(OUT, "full", f"{take}_{f:03d}.png")
                if not os.path.exists(path) or not any(x["file"] == os.path.relpath(path, OUT) for x in full):
                    shot(path, 80)
                full.append(dict(take=take, frame=f, time=round(f/A.FPS, 3), beat=beat, file=os.path.relpath(path, OUT)))
        timings[f"full frames ({len(full)})"] = time.time() - t0
    with open(os.path.join(OUT, "frames.json"), "w", encoding="utf-8") as fh:
        json.dump(dict(fps=A.FPS, guides=guides, full=full, takes={k: dict(seconds=v[0], beats=v[2]) for k, v in A.TAKES.items()},
                       frames=labels, render_seconds={k: round(v, 1) for k, v in timings.items()}), fh, indent=1)
    print("ripcord review:", json.dumps({k: round(v, 1) for k, v in timings.items()}), flush=True)

main()
