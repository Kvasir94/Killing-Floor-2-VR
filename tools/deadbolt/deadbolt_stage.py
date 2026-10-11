# Studio stage + render helpers for the Deadbolt model.
import bpy, math, os
from mathutils import Vector, Euler

STAGE = "DB_Stage"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "build", "deadbolt-concept", "renders")

def coll(name):
    c = bpy.data.collections.get(name)
    if not c:
        c = bpy.data.collections.new(name); bpy.context.scene.collection.children.link(c)
    return c

def area_light(name, loc, target, power, size, color=(1, 1, 1)):
    ob = bpy.data.objects.get(name)
    if not ob:
        ld = bpy.data.lights.new(name, 'AREA'); ob = bpy.data.objects.new(name, ld); coll(STAGE).objects.link(ob)
    ob.data.energy = power; ob.data.size = size; ob.data.color = color; ob.data.shape = 'DISK'
    ob.location = loc
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    return ob

def setup(mood="studio"):
    sc = bpy.context.scene
    for n in ("Light",):
        o = bpy.data.objects.get(n)
        if o: o.hide_render = True; o.hide_set(True)
    sc.render.engine = 'CYCLES'
    prefs = bpy.context.preferences.addons['cycles'].preferences
    for dt in ('OPTIX', 'CUDA'):
        try:
            prefs.compute_device_type = dt; prefs.get_devices()
            if any(d.type == dt for d in prefs.devices):
                for d in prefs.devices: d.use = (d.type == dt)
                break
        except Exception: pass
    sc.cycles.device = 'GPU'
    sc.cycles.samples = 128; sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 8; sc.cycles.transmission_bounces = 8
    sc.view_settings.view_transform = 'Khronos PBR Neutral'; sc.view_settings.look = 'None'; sc.view_settings.exposure = -0.2 if mood == "studio" else -1.1
    sc.render.film_transparent = False
    w = sc.world or bpy.data.worlds.new("World"); sc.world = w
    w.use_nodes = True
    nt = w.node_tree
    for n in list(nt.nodes):
        if n.type != 'OUTPUT_WORLD' and n.name != "Background": nt.nodes.remove(n)
    bg = nt.nodes.get("Background") or nt.nodes.new('ShaderNodeBackground')
    out = [n for n in nt.nodes if n.type == 'OUTPUT_WORLD'][0]
    # camera rays see a bright sheet-paper backdrop; lighting uses the dim world colour
    lp = nt.nodes.new('ShaderNodeLightPath'); cbg = nt.nodes.new('ShaderNodeBackground'); mx = nt.nodes.new('ShaderNodeMixShader')
    # "review" is the studio three-point rig in front of a darker backdrop, so heat and glow read in timing strips
    cbg.inputs[0].default_value = {"studio": (0.50, 0.48, 0.42, 1), "review": (0.085, 0.085, 0.09, 1)}.get(mood, (0.018, 0.017, 0.016, 1)); cbg.inputs[1].default_value = 1.0
    if mood == "review": mood = "studio"
    nt.links.new(lp.outputs['Is Camera Ray'], mx.inputs[0]); nt.links.new(bg.outputs[0], mx.inputs[1]); nt.links.new(cbg.outputs[0], mx.inputs[2])
    nt.links.new(mx.outputs[0], out.inputs['Surface'])
    c = (0.62, 0.60, 0.55) if mood == "studio" else (0.012, 0.012, 0.014)
    bg.inputs[0].default_value = (*c, 1); bg.inputs[1].default_value = 0.18 if mood == "studio" else 1.0
    setup_glow(0.40 if mood == "studio" else 0.45)
    ctr = Vector((-0.06, 0, 0.05))
    bk = bpy.data.objects.get("DB_Back")
    if bk: bk.hide_render = (mood != "studio")
    k = bpy.data.objects.get("DB_Kick")
    if k: k.hide_render = (mood == "studio")
    if mood == "studio":
        area_light("DB_Key", (-0.25, 0.75, 0.75), ctr, 32, 0.45, (1.0, 0.96, 0.9))
        area_light("DB_Fill", (0.4, -0.7, 0.35), ctr, 2.5, 0.8, (0.85, 0.92, 1.0))
        area_light("DB_Rim", (-0.6, -0.35, 0.55), ctr, 34, 0.3, (1.0, 0.72, 0.45))
        area_light("DB_Top", (0.1, 0.1, 0.9), ctr, 5, 0.6)
        area_light("DB_Back", (0.15, -0.60, 0.70), ctr, 18, 0.3, (0.85, 0.9, 1.0))
    else:
        area_light("DB_Key", (-0.25, 0.75, 0.75), ctr, 18, 0.45, (1.0, 0.93, 0.84))
        area_light("DB_Fill", (0.4, -0.7, 0.35), ctr, 2.5, 0.8, (1.0, 0.65, 0.4))
        area_light("DB_Rim", (-0.6, -0.35, 0.55), ctr, 30, 0.25, (1.0, 0.8, 0.6))
        area_light("DB_Top", (0.1, 0.1, 0.9), ctr, 4, 0.6)
        area_light("DB_Kick", (0.35, 0.45, -0.10), ctr, 5, 0.3, (1.0, 0.6, 0.35))

def cam():
    sc = bpy.context.scene
    ob = bpy.data.objects.get("DB_Cam")
    if not ob:
        cd = bpy.data.cameras.new("DB_Cam"); ob = bpy.data.objects.new("DB_Cam", cd); coll(STAGE).objects.link(ob)
    sc.camera = ob
    return ob

VIEWS = {
    # name: (direction from target to camera, ortho?)
    "side_in":  ((0, 1, 0), True),      # inner/thumb side (concept "side profile", mirrored)
    "side_out": ((0, -1, 0), True),
    "top":      ((0, 0, 1), True),
    "front":    ((1, 0, 0), True),
    "iso":      ((-0.80, 0.95, 0.62), False),   # concept 3/4 rear
    "hero":     ((-0.85, 0.80, 0.30), False),    # first-person-ish
    "iso_out":  ((-0.6, -0.9, 0.5), False),
    "front34":  ((0.9, 0.7, 0.35), False),
}

def bounds(objs):
    pts = []
    for o in objs:
        if o.type in ('MESH', 'CURVE', 'FONT') and o.visible_get() and not o.hide_render:
            pts += [o.matrix_world @ Vector(c) for c in o.bound_box]
    mn = Vector([min(p[i] for p in pts) for i in range(3)]); mx = Vector([max(p[i] for p in pts) for i in range(3)])
    return pts, (mn + mx)/2, (mx - mn).length

def render(views, prefix, res=(1400, 800), samples=128, objs=None, margin=1.08, lens=50):
    sc = bpy.context.scene
    sc.cycles.samples = samples
    sc.render.resolution_x, sc.render.resolution_y = res; sc.render.resolution_percentage = 100
    objs = objs or [o for c in ("DB_Weapon", "DB_Hand") for o in bpy.data.collections[c].all_objects]
    bpy.context.view_layer.update()
    pts, c, size = bounds(objs)
    cm = cam()
    outs = []
    for v in views:
        d, ortho = VIEWS[v]
        d = Vector(d).normalized()
        if v == "top": eul = Euler((0, 0, 0))
        else: eul = (-d).to_track_quat('-Z', 'Y').to_euler()
        cm.rotation_euler = eul
        R = eul.to_matrix(); right = R @ Vector((1, 0, 0)); up = R @ Vector((0, 1, 0))
        xs = [(p - c).dot(right) for p in pts]; ys = [(p - c).dot(up) for p in pts]
        w = max(xs) - min(xs); h = max(ys) - min(ys)
        off = right*(max(xs) + min(xs))/2 + up*(max(ys) + min(ys))/2
        aspect = res[0]/res[1]
        cm.data.clip_start = 0.005; cm.data.clip_end = 20
        if ortho:
            cm.data.type = 'ORTHO'; cm.data.ortho_scale = max(w, h*aspect)*margin
            cm.location = c + off + d*size*3
        else:
            cm.data.type = 'PERSP'; cm.data.lens = lens; cm.data.sensor_fit = 'AUTO'
            fov = cm.data.angle
            dist = (max(w, h*aspect)*margin/2)/math.tan(fov/2) + size*0.25
            cm.location = c + off + d*dist
        sc.render.filepath = os.path.join(OUT, f"{prefix}_{v}.png")
        bpy.ops.render.render(write_still=True)
        outs.append(sc.render.filepath)
    return outs


def setup_glow(strength):
    sc = bpy.context.scene
    ng = bpy.data.node_groups.get("DB_Comp")
    if ng: bpy.data.node_groups.remove(ng)
    ng = bpy.data.node_groups.new("DB_Comp", "CompositorNodeTree")
    ng.interface.new_socket("Image", in_out='OUTPUT', socket_type='NodeSocketColor')
    gi = ng.nodes.new("CompositorNodeRLayers"); go = ng.nodes.new("NodeGroupOutput")
    g = ng.nodes.new("CompositorNodeGlare")
    for v in ("Bloom", "Fog Glow", "FOG_GLOW"):
        try:
            g.inputs["Type"].default_value = v; break
        except Exception: pass
    g.inputs["Highlights Threshold"].default_value = 1.6
    g.inputs["Strength"].default_value = strength
    g.inputs["Size"].default_value = 0.38
    ng.links.new(gi.outputs["Image"], g.inputs["Image"]); ng.links.new(g.outputs[0], go.inputs[0])
    sc.compositing_node_group = ng
    sc.render.use_compositing = True
