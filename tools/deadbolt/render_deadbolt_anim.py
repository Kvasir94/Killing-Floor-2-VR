"""Review renders of the rigged Deadbolt and its authored takes (Blender 5.2, Cycles):

    blender --background --factory-startup --python tools/deadbolt/render_deadbolt_anim.py
    python tools/deadbolt/make_anim_sheets.py

Builds the render model, skins it to the deadbolt_anim rig, and writes to
build/deadbolt-concept/review/:
  review_iso.png, review_side.png     lit three-point views of the idle model
  review_idle_slot.png                close-up of the idle spike glowing through the side slot
  review_empty_slot.png               the same view with the magazine empty (rod parked, bore dark)
  review_idle_mid.png                 idle from the inner side at hand-held distance (~55 cm)
  full/<take>_<frame>.png             full-size frames at the launch/kick and lock/seat beats (FULL)
  frames/<take>_<frame>.png           strip frames from one fixed camera, poses sampled from the take
  frames.json                         labels for make_anim_sheets.py (take, frame, time, beat)
Glow and spike visibility follow the HEAT/HIDDEN keys the game script applies.
Set DEADBOLT_REVIEW=static or =strips to render only one half.
"""
import importlib, json, math, os, sys, time
import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import deadbolt_build as B, deadbolt_stage as ST, deadbolt_weather as W, deadbolt_glove as G, deadbolt_anim as A
for m in (B, ST, W, G, A):
    importlib.reload(m)

OUT = os.path.join(os.path.dirname(ST.OUT), "review")
FR = os.path.join(OUT, "frames")
MODE = os.environ.get("DEADBOLT_REVIEW", "all")

# strip frames: (take, seconds) -- dense where the action is, with every beat included
STRIPS = {
    "Fire": [0.0, 0.017, 0.033, 0.050, 0.067, 0.083, 0.100, 0.133, 0.167, 0.200, 0.250, 0.300, 0.350, 0.400, 0.433, 0.550],
    "Reload": [0.0, 0.10, 0.18, 0.30, 0.42, 0.60, 0.80, 0.95, 1.10, 1.25, 1.40, 1.48, 1.50, 1.53, 1.60, 1.80,
               2.00, 2.20, 2.40, 2.433, 2.48, 2.60, 2.75, 2.90],
}
# full-size frames for judging amplitude: launch, streak, shake/stack peak, overshoot; lock, jolt peak, seat, bounce
FULL = {"Fire": [0.0, 0.017, 0.033, 0.150], "Reload": [1.483, 1.517, 2.400, 2.433]}

def rig_render_model():
    rig = A.build_armature(B.get_coll(B.COLL))
    for ob in list(B.get_coll(B.COLL).objects):
        if ob == rig:
            continue
        key = A.gradient_key(ob.name)
        if A.stretch_key(ob.name) and ob.type == 'MESH':
            A.assign_groups(ob, ob.name)
            ob.modifiers.new("rig", 'ARMATURE').object = rig
        elif key and ob.type == 'CURVE':
            dg = bpy.context.evaluated_depsgraph_get()
            me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), depsgraph=dg)
            me.transform(ob.matrix_world)
            name = ob.name
            bpy.data.objects.remove(ob, do_unlink=True)
            mo = bpy.data.objects.new(name, me)
            B.link(mo)
            for p in me.polygons: p.use_smooth = True
            A.assign_groups(mo, name)
            mo.modifiers.new("rig", 'ARMATURE').object = rig
        else:
            A.parent_rigid(ob, rig, A.rigid_bone(ob.name))
    for ob in B.get_coll("DB_Hand").objects:
        if ob.name.startswith("Display |"):
            A.parent_rigid(ob, rig, "DB_Kick")
    return rig

def heat_nodes():
    glow, spike = [], []
    for m in bpy.data.materials:
        if not m.use_nodes: continue
        for n in m.node_tree.nodes:
            if (n.type == 'VALUE' and n.name.startswith("heat")) or (n.type == 'RGB' and n.name.startswith("heat_tint")):
                (spike if m.name == "DB_spike" else glow).append(n)
    return glow, spike

def set_state(rig, take, t, glow_nodes, spike_nodes):
    A.apply_pose(rig, A.TAKES[take][1](t))
    g, s, h = A.heat_at(take, t)
    for n in glow_nodes: n.outputs[0].default_value = g
    for n in spike_nodes:
        if n.type == 'RGB': n.outputs[0].default_value = (*A.heat_tint(h), 1.0)
        else: n.outputs[0].default_value = s
    hidden, flare = A.spike_hidden(take, t), A.flare_shown(take, t)
    for ob in B.get_coll(B.COLL).objects:
        if ob.name.startswith("Spike |"):
            ob.hide_render = hidden
            if ob.type == 'LIGHT':
                ob.data.energy = ob.get("base_energy", ob.data.energy)*s
        elif ob.name.startswith("Flare |"):
            ob.hide_render = not flare
        elif ob.name == "Flare light":
            ob.data.energy = 6.0 if flare else 0.0
    bpy.context.view_layer.update()

def camera(loc, target, lens=50, res=(1400, 700), ortho=None):
    sc = bpy.context.scene
    cm = ST.cam()
    cm.location = Vector(loc)
    cm.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    if ortho:
        cm.data.type = 'ORTHO'; cm.data.ortho_scale = ortho
    else:
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

def main():
    os.makedirs(FR, exist_ok=True)
    for name in ("Cube", "Light"):
        o = bpy.data.objects.get(name)
        if o: o.hide_set(True); o.hide_render = True
    G.build_glove(); B.build_all(); W.build_weathering()
    rig = rig_render_model()
    for ob in B.get_coll(B.COLL).objects:
        if ob.type == 'LIGHT': ob["base_energy"] = ob.data.energy
    glow_nodes, spike_nodes = heat_nodes()
    # the launch burst lights its surroundings in the review (the game flare is unlit emissive)
    ld = bpy.data.lights.new("Flare light", 'POINT'); ld.color = (1.0, 0.6, 0.25); ld.shadow_soft_size = 0.03
    fl = bpy.data.objects.new("Flare light", ld); fl.location = (0.14, 0.0, B.AXIS_Z); B.link(fl)
    A.parent_rigid(fl, rig, "DB_Flare")
    ST.setup("studio")
    sc = bpy.context.scene
    timings = {}
    set_state(rig, "Idle", 0.0, glow_nodes, spike_nodes)
    if MODE in ("all", "static"):
        ST.OUT = OUT
        t = time.time()
        ST.render(["iso", "side_in"], "review", res=(1600, 800), samples=128)
        timings["static views"] = time.time() - t
        os.replace(os.path.join(OUT, "review_side_in.png"), os.path.join(OUT, "review_side.png"))
        # idle close-up through the side slot (inner side, slightly ahead and above)
        tgt = Vector((-0.020, 0.0, 0.084))
        camera(tgt + Vector((0.095, 0.300, 0.105)), tgt, lens=50, res=(1600, 900))
        timings["idle slot"] = shot(os.path.join(OUT, "review_idle_slot.png"), 160)
        set_state(rig, "Empty", 0.0, glow_nodes, spike_nodes)
        timings["empty slot"] = shot(os.path.join(OUT, "review_empty_slot.png"), 160)
        set_state(rig, "Idle", 0.0, glow_nodes, spike_nodes)
        # hand-held scale: the inner side of the forearm seen from about 55 cm, a little above
        tgt = Vector((-0.04, 0.0, 0.06))
        camera(tgt + Vector((0.12, 0.52, 0.16)), tgt, lens=35, res=(1600, 900))
        timings["idle mid"] = shot(os.path.join(OUT, "review_idle_mid.png"), 128)
    labels = []; guides = {}; full = []
    if MODE in ("all", "strips"):
        # one fixed camera for every strip frame, so recoil and travel read against the frame
        ST.setup("review")
        tgt = Vector((0.0, 0.0, 0.055))
        camera(tgt + Vector((0.22, 0.95, 0.42)).normalized()*0.98, tgt, lens=42, res=(1200, 560))
        from bpy_extras.object_utils import world_to_camera_view
        bpy.context.view_layer.update()
        guides = {name: tuple(world_to_camera_view(sc, sc.camera, Vector(p))[:2]) for name, p in
                  (("muzzle", (0.070, 0.0, B.AXIS_Z)), ("ram", (-0.134, 0.0, B.REAR_TOP + 0.030)))}
        for take, times in STRIPS.items():
            beats = A.TAKES[take][2]
            t0 = time.time()
            for t in times:
                f = round(t*A.FPS)
                set_state(rig, take, f/A.FPS, glow_nodes, spike_nodes)
                path = os.path.join(FR, f"{take}_{f:03d}.png")
                shot(path, 48)
                beat = next((k for k, v in beats.items() if abs(v - f/A.FPS) < 0.5/A.FPS), "")
                labels.append(dict(take=take, frame=f, time=round(f/A.FPS, 3), beat=beat, file=os.path.relpath(path, OUT)))
            timings[f"strip {take} ({len(times)} frames)"] = time.time() - t0
        os.makedirs(os.path.join(OUT, "full"), exist_ok=True)
        sc.render.resolution_x, sc.render.resolution_y = 1920, 896
        t0 = time.time()
        for take, times in FULL.items():
            beats = A.TAKES[take][2]
            for t in times:
                f = round(t*A.FPS)
                set_state(rig, take, f/A.FPS, glow_nodes, spike_nodes)
                path = os.path.join(OUT, "full", f"{take}_{f:03d}.png")
                shot(path, 96)
                beat = next((k for k, v in beats.items() if abs(v - f/A.FPS) < 0.5/A.FPS), "")
                full.append(dict(take=take, frame=f, time=round(f/A.FPS, 3), beat=beat, file=os.path.relpath(path, OUT)))
        timings["full frames (8)"] = time.time() - t0
    with open(os.path.join(OUT, "frames.json"), "w", encoding="utf-8") as fh:
        json.dump(dict(fps=A.FPS, guides=guides, full=full, takes={k: dict(seconds=v[0], beats=v[2]) for k, v in A.TAKES.items()}, frames=labels,
                       render_seconds={k: round(v, 1) for k, v in timings.items()}), fh, indent=1)
    print("deadbolt review:", json.dumps({k: round(v, 1) for k, v in timings.items()}), flush=True)

main()
