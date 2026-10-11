"""Render the exported Deadbolt game assets as the engine receives them: re-import the FBXs, rebuild
materials from the TGAs only, and render with the studio stage. Writes
build/deadbolt-concept/renders/game_<view>.png, then re-imports VRDeadboltRig.fbx the same way and
renders it at the beats listed in RIG_POSES (game_rig_<take>_<frame>.png), with a list of the takes
and lengths the importer read back (game_rig.json).

    blender --background --factory-startup --python tools/deadbolt/preview_game_export.py
"""
import importlib, json, os, sys
import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import deadbolt_stage as ST
importlib.reload(ST)
ROOT = os.path.dirname(os.path.dirname(HERE))
MESHES = os.path.join(ROOT, "build", "hand-meshes")
NAME = "VRDeadbolt"

def img(path, non_color):
    im = bpy.data.images.load(path, check_existing=True)
    if non_color: im.colorspace_settings.name = 'Non-Color'
    return im

def material(slot, mat):
    mat.use_nodes = True
    nt = mat.node_tree; nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    p = nt.nodes.new('ShaderNodeBsdfPrincipled'); nt.links.new(p.outputs[0], out.inputs['Surface'])
    d = nt.nodes.new('ShaderNodeTexImage'); d.image = img(os.path.join(MESHES, f"{NAME}{slot}_D.tga"), False)
    n = nt.nodes.new('ShaderNodeTexImage'); n.image = img(os.path.join(MESHES, f"{NAME}{slot}_N.tga"), True)
    s = nt.nodes.new('ShaderNodeTexImage'); s.image = img(os.path.join(MESHES, f"{NAME}{slot}_S.tga"), True)
    # DirectX -> OpenGL green for Blender's normal map node
    sep = nt.nodes.new('ShaderNodeSeparateColor'); comb = nt.nodes.new('ShaderNodeCombineColor'); inv = nt.nodes.new('ShaderNodeMath')
    inv.operation = 'SUBTRACT'; inv.inputs[0].default_value = 1.0
    nt.links.new(n.outputs['Color'], sep.inputs[0]); nt.links.new(sep.outputs[1], inv.inputs[1])
    nt.links.new(sep.outputs[0], comb.inputs[0]); nt.links.new(inv.outputs[0], comb.inputs[1]); nt.links.new(sep.outputs[2], comb.inputs[2])
    nm = nt.nodes.new('ShaderNodeNormalMap'); nt.links.new(comb.outputs[0], nm.inputs['Color']); nt.links.new(nm.outputs[0], p.inputs['Normal'])
    if slot in ("Glow", "Spike"):
        p.inputs['Base Color'].default_value = (0.02, 0.01, 0.005, 1)
        nt.links.new(d.outputs['Color'], p.inputs['Emission Color'])
        p.inputs['Emission Strength'].default_value = 3.0
        return
    nt.links.new(d.outputs['Color'], p.inputs['Base Color'])
    # engine-style specular: brightness of S drives a dielectric/metal-ish response
    bw = nt.nodes.new('ShaderNodeRGBToBW'); nt.links.new(s.outputs['Color'], bw.inputs[0])
    rough = nt.nodes.new('ShaderNodeMath'); rough.operation = 'SUBTRACT'; rough.inputs[0].default_value = 0.85
    nt.links.new(bw.outputs[0], rough.inputs[1]); nt.links.new(rough.outputs[0], p.inputs['Roughness'])
    met = nt.nodes.new('ShaderNodeMapRange'); nt.links.new(bw.outputs[0], met.inputs['Value'])
    met.inputs['From Min'].default_value = 0.15; met.inputs['From Max'].default_value = 0.45
    nt.links.new(met.outputs['Result'], p.inputs['Metallic'])

# (take, seconds) poses of the imported skeletal takes: the fire kick and the forge lock and hold
RIG_POSES = [("Idle", 0.0), ("Fire", 0.017), ("Fire", 0.050), ("Reload", 1.10), ("Reload", 1.517), ("Reload", 2.00)]

def rig_check(report):
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for a in list(bpy.data.actions):
        bpy.data.actions.remove(a)
    sc = bpy.context.scene
    sc.render.fps = report["rig"].get("fbx_time_base_fps", report["rig"]["fps"])   # one imported frame per key
    fps = report["rig"]["fps"]
    bpy.ops.import_scene.fbx(filepath=os.path.join(MESHES, report["rig"]["file"]))
    arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
    mesh = next(o for o in bpy.data.objects if o.type == 'MESH')
    if [m.material.name.split(".")[0] for m in mesh.material_slots] != [f"{NAME}{g}" for g in ("Body", "Glow", "Spike")]:
        raise RuntimeError("rig material slots are not Body, Glow, Spike")
    for slot, ms in zip(("Body", "Glow", "Spike"), mesh.material_slots):
        material(slot, ms.material)
    counts = [0, 0, 0]
    for p in mesh.data.polygons: counts[p.material_index] += 1
    if min(counts) == 0:
        raise RuntimeError(f"rig material slot without faces: {counts}")
    takes = {}
    for a in bpy.data.actions:
        name = a.name.split("|")[-1]
        takes[name] = dict(frames=[round(x) for x in a.frame_range], seconds=round((a.frame_range[1] - a.frame_range[0])/fps, 3))
    hidden = report["rig"]["spike_hidden"]
    flare_shown = report["rig"].get("flare_shown", {})
    for take, t in RIG_POSES:
        act = next(a for a in bpy.data.actions if a.name.split("|")[-1] == take)
        arm.animation_data.action = act
        if hasattr(arm.animation_data, "action_slot") and act.slots:
            arm.animation_data.action_slot = act.slots[0]
        f = round(t*fps)
        sc.frame_set(round(act.frame_range[0]) + f)      # the importer starts takes at frame 1
        # the game hides the spike bone by script in these spans; mimic it with the spike material
        # the game hides bones by script (HideBone scales them to zero); do the same here
        gone = any(a <= t < b for a, b in hidden.get(take, []))
        shown = any(a <= t < b for a, b in flare_shown.get(take, []))
        # (a zero Limit Scale constraint, since the imported takes key scale and would override the pose)
        for bone, visible in (("DB_Spike", not gone), ("DB_Flare", shown)):
            if bone in arm.pose.bones:
                pb = arm.pose.bones[bone]
                c = pb.constraints.get("hide") or pb.constraints.new('LIMIT_SCALE')
                c.name = "hide"
                c.use_min_x = c.use_min_y = c.use_min_z = c.use_max_x = c.use_max_y = c.use_max_z = True
                c.min_x = c.min_y = c.min_z = c.max_x = c.max_y = c.max_z = 0.0
                c.mute = visible
        bpy.context.view_layer.update()
        ST.setup("review")
        ST.render(["iso"], f"game_rig_{take}_{f:03d}", res=(1200, 600), samples=64, objs=[mesh], margin=0.9)
    with open(os.path.join(ST.OUT, "game_rig.json"), "w", encoding="utf-8") as fh:
        json.dump(dict(takes=takes, bones=[b.name for b in arm.data.bones], slot_faces=counts), fh, indent=1)
    print("deadbolt preview: rig takes", json.dumps(takes), flush=True)

def main():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    report = json.load(open(os.path.join(MESHES, f"{NAME}.json"), encoding='utf-8'))
    objs = []
    for fbx, slots in ((f"{NAME}.fbx", ("Body", "Glow")), (f"{NAME}Spike.fbx", ("Spike",))):
        before = set(bpy.data.objects)
        bpy.ops.import_scene.fbx(filepath=os.path.join(MESHES, fbx))
        new = [o for o in bpy.data.objects if o not in before and o.type == 'MESH']
        for o in new:
            for slot, ms in zip(slots, o.material_slots):
                material(slot, ms.material)
            if fbx.endswith("Spike.fbx"):
                o.location = Vector(report["spike_socket_cm"])*0.01
        objs += new
    bpy.context.view_layer.update()
    ST.setup("studio")
    ST.render(["side_in", "iso", "top"], "game", res=(1400, 700), samples=96, objs=objs)
    ST.setup("dark")
    ST.render(["hero"], "game", res=(1600, 900), samples=128, objs=objs, lens=40)
    if "rig" in report:
        rig_check(report)
    print("deadbolt preview: ok", flush=True)

if __name__ == "__main__":   # importable: tools/ripcord reuses these helpers
    main()
