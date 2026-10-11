"""Render the exported Ripcord game assets as the engine receives them: re-import the FBXs, rebuild the
materials from the TGAs alone, and render with the studio stage. Writes build/ripcord-concept/review/:
  game_iso.png, game_side_in.png, game_top.png, game_hero.png   VRRipcord.fbx (hook seated)
  game_hook_out.png    VRRipcord with VRRipcordHook 60 cm out and VRRipcordCable stretched from the
                       fairlead socket to it, placed from VRRipcord.json the way the script places them
  game_rig_<take>_<frame>.png, game_rig.json   VRRipcordRig.fbx re-imported, posed at take beats with the
                       seated hook hidden in its spans, and the takes and lengths the importer read back

    blender --background --factory-startup --python tools/ripcord/preview_ripcord_export.py
"""
import importlib, json, os, sys
import bpy
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(os.path.dirname(HERE), "deadbolt")
for p in (HERE, DB):
    if p not in sys.path:
        sys.path.insert(0, p)
import deadbolt_stage as ST
importlib.reload(ST)
ROOT = os.path.dirname(os.path.dirname(HERE))
MESHES = os.path.join(ROOT, "build", "hand-meshes")
OUT = os.path.join(ROOT, "build", "ripcord-concept", "review")
NAME = "VRRipcord"

RIG_POSES = [("Idle", 0.0), ("Fire", 0.017), ("Reel", 0.367), ("Yank", 0.050), ("Reload", 0.400), ("Reload", 0.533), ("Empty", 0.0)]

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
    sep = nt.nodes.new('ShaderNodeSeparateColor'); comb = nt.nodes.new('ShaderNodeCombineColor'); inv = nt.nodes.new('ShaderNodeMath')
    inv.operation = 'SUBTRACT'; inv.inputs[0].default_value = 1.0                  # DirectX -> OpenGL green
    nt.links.new(n.outputs['Color'], sep.inputs[0]); nt.links.new(sep.outputs[1], inv.inputs[1])
    nt.links.new(sep.outputs[0], comb.inputs[0]); nt.links.new(inv.outputs[0], comb.inputs[1]); nt.links.new(sep.outputs[2], comb.inputs[2])
    nm = nt.nodes.new('ShaderNodeNormalMap'); nt.links.new(comb.outputs[0], nm.inputs['Color']); nt.links.new(nm.outputs[0], p.inputs['Normal'])
    if slot.endswith("Glow"):
        p.inputs['Base Color'].default_value = (0.02, 0.01, 0.005, 1)
        nt.links.new(d.outputs['Color'], p.inputs['Emission Color'])
        p.inputs['Emission Strength'].default_value = 3.0
        return
    nt.links.new(d.outputs['Color'], p.inputs['Base Color'])
    bw = nt.nodes.new('ShaderNodeRGBToBW'); nt.links.new(s.outputs['Color'], bw.inputs[0])
    rough = nt.nodes.new('ShaderNodeMath'); rough.operation = 'SUBTRACT'; rough.inputs[0].default_value = 0.85
    nt.links.new(bw.outputs[0], rough.inputs[1]); nt.links.new(rough.outputs[0], p.inputs['Roughness'])
    met = nt.nodes.new('ShaderNodeMapRange'); nt.links.new(bw.outputs[0], met.inputs['Value'])
    met.inputs['From Min'].default_value = 0.15; met.inputs['From Max'].default_value = 0.45
    nt.links.new(met.outputs['Result'], p.inputs['Metallic'])

def load(fbx, slots):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=os.path.join(MESHES, fbx))
    new = [o for o in bpy.data.objects if o not in before and o.type == 'MESH']
    for o in new:
        names = [ms.material.name.split(".")[0] for ms in o.material_slots]
        if names != [f"{NAME}{s}" for s in slots]:
            raise RuntimeError(f"{fbx}: material slots {names}, expected {slots}")
        for slot, ms in zip(slots, o.material_slots):
            material(slot, ms.material)
    return new

def rig_check(report):
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for a in list(bpy.data.actions):
        bpy.data.actions.remove(a)
    sc = bpy.context.scene
    rig = report["rig"]
    sc.render.fps = rig["fbx_time_base_fps"]
    fps = rig["fps"]
    bpy.ops.import_scene.fbx(filepath=os.path.join(MESHES, rig["file"]))
    arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
    mesh = next(o for o in bpy.data.objects if o.type == 'MESH')
    if [m.material.name.split(".")[0] for m in mesh.material_slots] != [f"{NAME}{g}" for g in ("Body", "Glow")]:
        raise RuntimeError("rig material slots are not Body, Glow")
    for slot, ms in zip(("Body", "Glow"), mesh.material_slots):
        material(slot, ms.material)
    counts = [0, 0]
    for p in mesh.data.polygons: counts[p.material_index] += 1
    if min(counts) == 0:
        raise RuntimeError(f"rig material slot without faces: {counts}")
    takes = {}
    for a in bpy.data.actions:
        takes[a.name.split("|")[-1]] = dict(frames=[round(x) for x in a.frame_range], seconds=round((a.frame_range[1] - a.frame_range[0])/fps, 3))
    if sorted(takes) != sorted(rig["takes"]):
        raise RuntimeError(f"imported takes {sorted(takes)} != {sorted(rig['takes'])}")
    for take, t in RIG_POSES:
        act = next(a for a in bpy.data.actions if a.name.split("|")[-1] == take)
        arm.animation_data.action = act
        if hasattr(arm.animation_data, "action_slot") and act.slots:
            arm.animation_data.action_slot = act.slots[0]
        f = round(t*fps)
        sc.frame_set(round(act.frame_range[0]) + f)
        gone = any(a <= t < b or (b >= rig["script_end_seconds"][take] - 1e-6 and t >= a) for a, b in rig["hook_hidden"].get(take, []))
        pb = arm.pose.bones[rig["hook_bone"]]
        c = pb.constraints.get("hide") or pb.constraints.new('LIMIT_SCALE')   # the game hides the bone by script
        c.name = "hide"
        c.use_min_x = c.use_min_y = c.use_min_z = c.use_max_x = c.use_max_y = c.use_max_z = True
        c.min_x = c.min_y = c.min_z = c.max_x = c.max_y = c.max_z = 0.0
        c.mute = not gone
        bpy.context.view_layer.update()
        ST.setup("review")
        ST.VIEWS["rig"] = ((0.55, 0.85, 0.45), False)
        ST.render(["rig"], f"game_rig_{take}_{f:03d}", res=(1200, 600), samples=64, objs=[mesh], margin=0.95)
    with open(os.path.join(OUT, "game_rig.json"), "w", encoding="utf-8") as fh:
        json.dump(dict(takes=takes, bones=[b.name for b in arm.data.bones], slot_faces=counts), fh, indent=1)
    print("ripcord preview: rig takes", json.dumps(takes), flush=True)

def main():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    os.makedirs(OUT, exist_ok=True)
    ST.OUT = OUT
    report = json.load(open(os.path.join(MESHES, f"{NAME}.json"), encoding='utf-8'))
    body = load(f"{NAME}.fbx", ("Body", "Glow"))
    bpy.context.view_layer.update()
    ST.setup("studio")
    ST.render(["side_in", "iso", "top"], "game", res=(1400, 700), samples=96, objs=body)
    ST.setup("dark")
    ST.render(["hero"], "game", res=(1600, 900), samples=128, objs=body, lens=40)
    # the script's composition: hook out along the line, the unit cable stretched from the fairlead socket
    hook = load(f"{NAME}Hook.fbx", ("Hook",))
    cable = load(f"{NAME}Cable.fbx", ("CableBody", "CableGlow"))
    sock = Vector(report["fairlead_socket_cm"])*0.01
    tip = sock + Vector((0.60, 0.04, -0.06))
    d = (tip - sock)
    rot = Vector((1, 0, 0)).rotation_difference(d.normalized()).to_matrix().to_4x4()
    for o in hook:      # keep the importer's own unit/axis matrix, then aim and place it
        o.matrix_world = Matrix.Translation(tip) @ rot @ o.matrix_world
    for o in cable:     # the segment is 1 m long: stretch it along the line to the hook
        o.matrix_world = Matrix.Translation(sock) @ rot @ Matrix.Diagonal((d.length, 1.0, 1.0, 1.0)) @ o.matrix_world
    bpy.context.view_layer.update()
    ST.setup("studio")
    ST.VIEWS["out"] = ((-0.55, 0.80, 0.50), False)
    ST.render(["out"], "game_hook", res=(1600, 800), samples=96, objs=body + hook + cable)
    rig_check(report)
    print("ripcord preview: ok", flush=True)

if __name__ == "__main__":
    main()
