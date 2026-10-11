"""Game export for the Ripcord (run inside Blender 5.2):

    blender --background --factory-startup --python tools/ripcord/export_ripcord.py

Rebuilds the model at game resolution and bakes it like the Deadbolt (tools/deadbolt/export_deadbolt.py,
whose bake, decal-stamp and TGA helpers this imports): one 4096 body atlas with the weathering stamped in,
a small emissive atlas for the cable's tracer strand and the power lamp, KF2 _D/_N/_S TGAs with DirectX
normals. Writes build/hand-meshes/:
  VRRipcord.fbx        static gauntlet with the hook seated. Slots: 0 Body (4096 atlas), 1 Glow (tracer, lamp).
  VRRipcordRig.fbx     the same mesh skinned to the ripcord_anim skeleton (slots Body, Glow) with the takes
                       Idle, Fire, Reel, Yank, Reload and Empty (60 fps samples on a 30 fps FBX time base,
                       every take padded to the longest by holding its last pose).
  VRRipcordHook.fbx    the flying hook, claws splayed; origin at its cable anchor, launches along +X.
  VRRipcordCable.fbx   a 1 m cable segment along +X from its origin (slots Body, Glow) for script to stretch
                       between the fairlead and the hook.
  VRRipcord{Body,Glow,Hook,CableBody,CableGlow}_{D,N,S}.tga, VRRipcord.json
Centimetres, axis_forward -X, Z up, the wrist at the origin, +Y the thumb side of the right forearm.
Set RIPCORD_TEX (default 4096) for the body atlas size.
"""
import hashlib, importlib, json, math, os, sys, time
import bpy, bmesh
import numpy as np
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(os.path.dirname(HERE), "deadbolt")
TOOLS = os.path.dirname(HERE)
for p in (HERE, DB, TOOLS):
    if p not in sys.path:
        sys.path.insert(0, p)
import deadbolt_build as B, deadbolt_weather as W, deadbolt_glove as G
import export_deadbolt as XD
import ripcord_build as R, ripcord_weather as RW, ripcord_anim as A
for m in (B, W, G, XD, R, RW, A):
    importlib.reload(m)

ROOT = os.path.dirname(TOOLS)
OUT = os.path.join(ROOT, "build", "hand-meshes")
WORK = os.path.join(ROOT, "build", "ripcord-concept", "game")
NAME = "VRRipcord"
XD.NAME = NAME                     # names the bake images
TEX = int(os.environ.get("RIPCORD_TEX", "4096"))
SIZES = {"Body": TEX, "Glow": 512, "Hook": 1024, "CableBody": 256, "CableGlow": 128}
CM = 100.0
FBX_TIME_BASE = 30
GAME_RQ = dict(rope_seg=6, rope_step=2.0, helix_res=20, helix_turn=8, claw_step=0.004, spiral_pts=16, ratchet_bevel=0.0)
GLOW_MATS = ("DB_status_glow",)
CABLE_PARTS = ("Cable |", "Drum | wrap layer")

def tracer_split(o):
    """Split a baked rope copy into its tracer-strand faces (returned) and the rest (left in o)."""
    att = o.data.attributes.get('tracer')
    if att is None:
        return None
    vals = [0.0]*len(o.data.vertices)
    att.data.foreach_get('value', vals)
    glow = o.copy(); glow.data = o.data.copy(); o.users_collection[0].objects.link(glow)
    for ob, keep_tracer in ((o, False), (glow, True)):
        bm = bmesh.new(); bm.from_mesh(ob.data)
        doomed = [f for f in bm.faces if (sum(vals[v.index] for v in f.verts)/len(f.verts) > 0.5) != keep_tracer]
        bmesh.ops.delete(bm, geom=doomed, context='FACES')
        bm.to_mesh(ob.data); bm.free()
    glow.name = o.name + " tracer"
    return glow

def bake_body(o, size, label, decals):
    base = XD.bake(o, 'Base Color', size, 48 if size >= 2048 else 32, label + "_base")
    metal = XD.bake(o, 'Metallic', size, 16, label + "_metal")
    rough = XD.bake(o, 'Roughness', size, 16, label + "_rough")
    normal = XD.bake(o, 'Normal', size, 16, label + "_normal")
    if decals:
        pos = XD.bake(o, 'Position', size, 1, label + "_pos")
        gnormal = XD.bake(o, 'GeoNormal', size, 1, label + "_gnormal")
        base, metal, rough = XD.stamp_decals(base, metal, rough, pos, gnormal)
    d, s = XD.kf2_maps(base, metal, rough)
    return d, normal, s

def bake_glow(o, size, label):
    emit = XD.bake(o, 'Emission', size, 32, label + "_emit")
    normal = XD.bake(o, 'Normal', size, 8, label + "_normal")
    d = XD.srgb(emit/max(1e-4, float(np.percentile(emit, 99.5))))
    return d, normal, np.full_like(d, 0.05)

def write_maps(label, maps):
    d, n, s = maps
    return {k: XD.write_tga(os.path.join(OUT, f"{NAME}{label}_{k}.tga"), v) for k, v in (("D", d), ("N", XD.dx_normal(n)), ("S", s))}

def one_material(o, name):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    o.data.materials.clear(); o.data.materials.append(m)
    for p in o.data.polygons: p.material_index = 0

def join_slots(parts, order, name):
    """Join parts (each with one material) into one mesh with slots in `order`."""
    copies = []
    for g in order:
        c = parts[g].copy(); c.data = parts[g].data.copy()
        bpy.context.scene.collection.objects.link(c)
        copies.append(c)
    o = XD.join(copies, name)
    me = o.data
    names = [m.name for m in me.materials]
    remap = [order.index(n.replace(NAME, "", 1)) if n.startswith(NAME) else 0 for n in names]
    idx = [0]*len(me.polygons)
    me.polygons.foreach_get("material_index", idx)
    me.materials.clear()
    for g in order: me.materials.append(bpy.data.materials[f"{NAME}{g}"])
    me.polygons.foreach_set("material_index", [remap[i] for i in idx])
    return o

def stats(o):
    v = np.array([tuple(x.co) for x in o.data.vertices])
    return {"vertices": len(o.data.vertices), "triangles": sum(len(p.vertices) - 2 for p in o.data.polygons),
            "materials": [m.name for m in o.data.materials],
            "bounds_min": [round(float(x), 3) for x in v.min(axis=0)], "bounds_max": [round(float(x), 3) for x in v.max(axis=0)]}

def export_static(o, fbx, scene):
    for other in scene.objects: other.select_set(other == o)
    bpy.context.view_layer.objects.active = o
    path = os.path.join(OUT, fbx)
    r = bpy.ops.export_scene.fbx(filepath=path, use_selection=True, global_scale=1.0, axis_forward='-X', axis_up='Z',
                                 apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS', bake_space_transform=False,
                                 mesh_smooth_type='EDGE', add_leaf_bones=False, bake_anim=False, use_mesh_modifiers=False,
                                 object_types={'MESH'}, use_tspace=True)
    if r != {'FINISHED'}:
        raise RuntimeError(f"FBX export failed: {path}")
    return dict(stats(o), sha256=XD.sha(path))

def export_rig(mesh, scene):
    """VRRipcordRig.fbx: ripcord_anim skeleton (cm), the mesh skinned to it, one take per action; the same
    FBX conventions and container post-passes as VRDeadboltRig."""
    from raven7_rig import strip_container_animation
    from generate_floating_hands import remove_fbx_armature_container
    scene.render.fps = FBX_TIME_BASE
    mesh.data.transform(Matrix.Scale(CM, 4))
    for c in list(mesh.users_collection): c.objects.unlink(mesh)
    scene.collection.objects.link(mesh)
    rig = A.build_armature(scene.collection, scale=CM, name=f"{NAME}Rig rig")
    mesh.parent = rig
    mesh.modifiers.new("Armature", 'ARMATURE').object = rig
    for action in list(bpy.data.actions): bpy.data.actions.remove(action)
    rig.animation_data_create()
    pad = A.padded_frames()
    for take in A.TAKES:
        rig.animation_data.action = None
        prev = None
        for f in range(pad + 1):
            prev = A.apply_pose(rig, A.TAKES[take][1](min(f, A.frames(take))/A.FPS), CM, prev)
            for pb in rig.pose.bones:
                pb.keyframe_insert('location', frame=f); pb.keyframe_insert('rotation_quaternion', frame=f)
        rig.animation_data.action.name = take
    rig.animation_data.action = None
    A.apply_pose(rig, A.P(), CM)
    old = bpy.data.objects.get('Armature')
    if old and old != rig: old.name = 'Preserved existing Armature'
    rig.name = 'Armature'
    for o in scene.objects: o.select_set(o in (rig, mesh))
    bpy.context.view_layer.objects.active = mesh
    path = os.path.join(OUT, f"{NAME}Rig.fbx")
    r = bpy.ops.export_scene.fbx(
        filepath=path, use_selection=True, object_types={'ARMATURE', 'MESH'},
        global_scale=1.0, apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS',
        axis_forward='Y', axis_up='Z', use_space_transform=True, bake_space_transform=False,
        add_leaf_bones=False, primary_bone_axis='Y', secondary_bone_axis='X',
        use_armature_deform_only=False, armature_nodetype='NULL', bake_anim=True,
        bake_anim_use_all_actions=True, bake_anim_use_nla_strips=False, bake_anim_simplify_factor=0,
        use_mesh_modifiers=False, mesh_smooth_type='EDGE', path_mode='STRIP', embed_textures=False, use_tspace=True)
    if r != {'FINISHED'}:
        raise RuntimeError(f"FBX export failed: {path}")
    strip_container_animation(path)
    remove_fbx_armature_container(path)
    rig.name = f"{NAME}Rig rig"
    return dict(stats(mesh), file=os.path.basename(path), sha256=XD.sha(path), fps=A.FPS, fbx_time_base_fps=FBX_TIME_BASE,
                take_frames=[pad + 1 for t in A.TAKES], sequence_seconds=[pad/A.FPS for t in A.TAKES],
                bones=A.BONE_NAMES, takes=list(A.TAKES), take_seconds=[A.TAKES[t][0] for t in A.TAKES],
                take_seconds_note="authored length; every sequence is padded to sequence_seconds by holding its last pose",
                beats={t: A.TAKES[t][2] for t in A.TAKES},
                glow_keys={t: [[round(k[0], 3), round(k[1], 3)] for k in A.TAKES[t][3]] for t in A.TAKES},
                glow_keys_columns=["seconds", "tracer_glow_multiplier"],
                hook_hidden={t: [[round(a, 3), round(b, 3)] for a, b in A.TAKES[t][4]] for t in A.TAKES},
                hook_bone="RC_Hook", script_end_seconds={t: A.TAKES[t][0] for t in A.TAKES},
                loops=["Idle", "Reel", "Empty"],
                fire_kick_note=("The shot's kick is VRHandsBridge hand recoil from BreacherRipcord's stock recoil pitch; Fire "
                                "adds only a gauntlet shake (about 1 cm, 2 degrees) plus the yoke slam, drum pay-out, pawl "
                                "flip, brake release and hose whip. Yank and Reload jolts are authored."),
                script_end_note=("VRRipcordPresentation ends a one-shot take (Fire, Yank, Reload) at script_end_seconds, not at "
                                 "the padded sequence length; Idle, Reel and Empty loop at their own length."))

def main():
    t0 = time.time()
    os.makedirs(OUT, exist_ok=True); os.makedirs(WORK, exist_ok=True)
    for name in ("Cube", "Light"):
        o = bpy.data.objects.get(name)
        if o: o.hide_set(True); o.hide_render = True
    B.Q.update(XD.GAME_Q)
    B.Q.update(wrap_seg=22, strap_seg=28)     # the harness a little lighter than the Deadbolt's: the drum carries more mesh
    R.RQ.update(GAME_RQ)
    R.build_all(); RW.build_weathering()
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    prefs = bpy.context.preferences.addons['cycles'].preferences
    for dt in ('OPTIX', 'CUDA'):
        try:
            prefs.compute_device_type = dt; prefs.get_devices()
            if any(d.type == dt for d in prefs.devices):
                for d in prefs.devices: d.use = (d.type == dt)
                break
        except Exception:
            pass
    sc.cycles.device = 'GPU'

    coll = XD.export_coll()
    groups = {"Body": [], "Glow": []}
    for ob in list(B.get_coll(R.COLL).objects):
        if ob.type not in ('MESH', 'CURVE', 'FONT'):
            continue
        mats = [s.material.name for s in ob.material_slots if s.material]
        if any(m.startswith("DB_decal_") for m in mats):
            continue                                    # stamped into the body maps
        copy = XD.baked_copy(ob, coll)
        A.assign_groups(copy, ob.name)                  # rig weights travel through split, join and UV
        if any(m in GLOW_MATS for m in mats):
            groups["Glow"].append(copy); continue
        if ob.name.startswith(CABLE_PARTS):
            tr = tracer_split(copy)
            if tr is not None and len(tr.data.polygons):
                groups["Glow"].append(tr)
        groups["Body"].append(copy)
    parts = {g: XD.join(objs, f"{NAME}{g}") for g, objs in groups.items()}
    for g, o in parts.items():
        XD.triangulate(o)
        XD.fresh_uv(o, 0.0015 if g == "Body" else 0.004)

    # the flying hook (claws splayed) and the 1 m cable segment, built apart from the gauntlet
    prev = B.COLL; B.COLL = "RC_Pieces"
    hook_objs = R.build_hook("Out | hook", Matrix.Identity(4), splay=True)
    seg = [Vector((x/100.0, 0.0, 0.0)) for x in range(101)]
    R.RQ.update(rope_seg=8, rope_step=6)
    cable = R.rope("Out | cable", seg, lay=0.10)
    B.COLL = prev
    hook = XD.join([XD.baked_copy(o, coll) for o in hook_objs], f"{NAME}Hook")
    cb = XD.baked_copy(cable, coll)
    cg = tracer_split(cb)
    pieces = {"Hook": hook, "CableBody": XD.join([cb], f"{NAME}CableBody"), "CableGlow": XD.join([cg], f"{NAME}CableGlow")}
    for g, o in pieces.items():
        XD.triangulate(o)
        XD.fresh_uv(o, 0.004)
    for o in list(B.get_coll("RC_Pieces").objects):
        o.hide_render = True

    tex = {}
    tex["Body"] = write_maps("Body", bake_body(parts["Body"], SIZES["Body"], "Body", decals=True))
    tex["Glow"] = write_maps("Glow", bake_glow(parts["Glow"], SIZES["Glow"], "Glow"))
    tex["Hook"] = write_maps("Hook", bake_body(pieces["Hook"], SIZES["Hook"], "Hook", decals=False))
    tex["CableBody"] = write_maps("CableBody", bake_body(pieces["CableBody"], SIZES["CableBody"], "CableBody", decals=False))
    tex["CableGlow"] = write_maps("CableGlow", bake_glow(pieces["CableGlow"], SIZES["CableGlow"], "CableGlow"))
    for g, o in list(parts.items()) + list(pieces.items()):
        one_material(o, f"{NAME}{g}")
    rig_mesh = join_slots(parts, ["Body", "Glow"], f"{NAME}Rig")
    held = join_slots(parts, ["Body", "Glow"], NAME)
    cable_mesh = join_slots(pieces, ["CableBody", "CableGlow"], f"{NAME}Cable")

    report = {"units": "cm", "frame": "origin at wrist centre; +X toward fingers, +Z up, +Y thumb side (right forearm)",
              "axis_forward": "-X", "axis_up": "Z", "texture_size": SIZES, "build_seconds": None,
              "drum_side": "inner (+Y)" if R.SIDE > 0 else "outer (-Y)"}
    xsc = bpy.data.scenes.new(f"{NAME} export")
    xsc.unit_settings.system = 'METRIC'; xsc.unit_settings.scale_length = 0.01
    statics = ((held, f"{NAME}.fbx"), (pieces["Hook"], f"{NAME}Hook.fbx"), (cable_mesh, f"{NAME}Cable.fbx"))
    for o, fbx in statics:
        o.data.transform(Matrix.Scale(CM, 4))
        for c in list(o.users_collection): c.objects.unlink(o)
        xsc.collection.objects.link(o)
    bpy.context.window.scene = xsc
    for o, fbx in statics:
        report[fbx] = export_static(o, fbx, xsc)
    report["fairlead_socket_cm"] = [round(c*CM, 3) for c in R.FAIRLEAD_SOCKET]
    report["hook_seat_cm"] = [round(c*CM, 3) for c in (R.HOOK_X0, 0.0, R.HOOK_Z)]
    report["hook_length_cm"] = round(R.HOOK_LEN*CM, 3)
    report["hook_note"] = "VRRipcordHook origin is its cable anchor (the swaged ferrule's end); it points along +X with the claws splayed"
    report["cable_length_cm"] = 100.0
    report["cable_note"] = "VRRipcordCable runs from its origin along +X for 100 cm; scale X by distance/100 to span the fairlead to the hook"
    report["rig"] = export_rig(rig_mesh, xsc)
    report["textures"] = {g: {k: {"file": os.path.basename(p), "sha256": XD.sha(p)} for k, p in d.items()} for g, d in tex.items()}
    report["build_seconds"] = round(time.time() - t0)
    with open(os.path.join(OUT, f"{NAME}.json"), 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=2)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(WORK, f"{NAME}-game.blend"), copy=True)
    print("ripcord export:", json.dumps({k: report[k]["triangles"] for k in (f"{NAME}.fbx", f"{NAME}Hook.fbx", f"{NAME}Cable.fbx")}),
          "rig", report["rig"]["triangles"], "seconds", report["build_seconds"], flush=True)

if __name__ == "__main__":
    main()
