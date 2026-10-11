"""Game export for the Deadbolt (run inside Blender 5.2 after `python tools/deadbolt/make_decals.py`):

    blender --background --factory-startup --python tools/deadbolt/export_deadbolt.py

Rebuilds the model at game resolution and bakes the procedural Cycles materials onto one UV atlas
(base colour, metallic, roughness and tangent normal). The weathering decals are stamped into those
maps in texture space, using baked position and normal maps, so the game needs no translucent decal
material. The KF2 diffuse/normal/specular TGAs are derived from the result, with green flipped for
UE3's DirectX normals.

Writes build/hand-meshes/:
  VRDeadbolt.fbx        body and glow. Slots: 0 Body, 1 Glow (emissive).
  VRDeadboltSpike.fbx   thermal spike, origin at its base on the bore axis; launches along +X.
  VRDeadboltRig.fbx     the same body, glow and spike as one skeletal mesh (slots 0 Body, 1 Glow,
                        2 Spike) skinned to the deadbolt_anim rig, with its takes (Idle, Fire,
                        FireLast, Reload, Empty) at 60 fps; take lengths, beats, glow keys and
                        spike-hidden spans are in the report under "rig".
  VRDeadbolt{Body,Glow,Spike}_{D,N,S}.tga, VRDeadbolt.json
Units are centimetres with the same axes as the RAVEN-7 props: the wrist is the origin, +X points
toward the fingers, +Z is up and +Y is the thumb side of the right forearm.
Set DEADBOLT_TEX (default 4096) for the body atlas size.
"""
import hashlib, importlib, json, math, os, struct, sys, time
import bpy, bmesh
import numpy as np
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import deadbolt_build as B, deadbolt_weather as W, deadbolt_glove as G, deadbolt_anim as A
for m in (B, W, G, A):
    importlib.reload(m)

ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "build", "hand-meshes")
WORK = os.path.join(ROOT, "build", "deadbolt-concept", "game")
NAME = "VRDeadbolt"
TEX = int(os.environ.get("DEADBOLT_TEX", "4096"))
SIZES = {"Body": TEX, "Spike": 1024, "Glow": 256}
CM = 100.0
FBX_TIME_BASE = 30

GAME_Q = dict(spike=(200, 24), sleeve=(40, 28), sleeve_solid=False, wrap_seg=36, strap_seg=36, stitch=48,
              stitch_cubes=False, curve=(4, 1), text_extrude=0.0, text_res=3, seg_scale=0.5, bevel_segs=1)
GLOW_MATS = ("DB_bore_glow", "DB_coil_glow", "DB_slot_glow", "DB_flare_glow")
POS_OFFSET = 2.0   # keeps baked positions positive
SKIP_MATS = ("DB_glass",)

# ---------------------------------------------------------------- mesh prep
def export_coll():
    c = bpy.data.collections.get("DB_Export")
    if c:
        for o in list(c.objects):
            bpy.data.objects.remove(o, do_unlink=True)
    else:
        c = bpy.data.collections.new("DB_Export"); bpy.context.scene.collection.children.link(c)
    return c

def baked_copy(ob, coll):
    """Evaluated (modifiers/curves/text applied) mesh in world space as a new object."""
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), preserve_all_data_layers=True, depsgraph=dg)
    me.transform(ob.matrix_world)
    o = bpy.data.objects.new(ob.name + " (game)", me)
    coll.objects.link(o)
    return o

def join(objs, name):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    o = bpy.context.view_layer.objects.active
    o.name = o.data.name = name
    return o

def triangulate(o):
    bpy.ops.object.select_all(action='DESELECT'); o.select_set(True); bpy.context.view_layer.objects.active = o
    m = o.modifiers.new("tri", 'TRIANGULATE'); m.keep_custom_normals = True; m.quad_method = 'BEAUTY'
    bpy.ops.object.modifier_apply(modifier=m.name)

def fresh_uv(o, margin):
    me = o.data
    while me.uv_layers:
        me.uv_layers.remove(me.uv_layers[0])
    me.uv_layers.new(name="UVMap")
    bpy.ops.object.select_all(action='DESELECT'); o.select_set(True); bpy.context.view_layer.objects.active = o
    bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=margin, scale_to_bounds=False)
    bpy.ops.uv.pack_islands(rotate=True, margin=margin)
    bpy.ops.object.mode_set(mode='OBJECT')

# ---------------------------------------------------------------- baking
def principled(mat):
    nt = mat.node_tree
    p = next((n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED'), None)
    o = next((n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL' and n.is_active_output), None) or \
        next((n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL'), None)
    return nt, p, o

def route(mats, channel):
    """Point every material's output at an Emission shader carrying `channel`; returns an undo list."""
    undo = []
    for mat in mats:
        nt, p, o = principled(mat)
        old = [l.from_socket for l in o.inputs['Surface'].links]
        e = nt.nodes.new('ShaderNodeEmission')
        if channel in ('Position', 'GeoNormal'):
            # texel world position (offset to stay positive) or geometric normal remapped to 0..1
            g = nt.nodes.new('ShaderNodeNewGeometry')
            vm = nt.nodes.new('ShaderNodeVectorMath'); vm.operation = 'MULTIPLY_ADD'
            nt.links.new(g.outputs['Position' if channel == 'Position' else 'Normal'], vm.inputs[0])
            vm.inputs[1].default_value = (1, 1, 1) if channel == 'Position' else (0.5, 0.5, 0.5)
            vm.inputs[2].default_value = (POS_OFFSET,)*3 if channel == 'Position' else (0.5, 0.5, 0.5)
            nt.links.new(vm.outputs[0], e.inputs['Color'])
            extra = [g, vm]
        elif p is None:
            e.inputs['Color'].default_value = (0.05, 0.05, 0.05, 1)
        elif channel == 'Emission':
            src = p.inputs['Emission Color']
            if src.is_linked: nt.links.new(src.links[0].from_socket, e.inputs['Color'])
            else: e.inputs['Color'].default_value = src.default_value
            st = p.inputs['Emission Strength']
            if st.is_linked: nt.links.new(st.links[0].from_socket, e.inputs['Strength'])
            else: e.inputs['Strength'].default_value = st.default_value
        else:
            src = p.inputs[channel]
            if src.is_linked:
                nt.links.new(src.links[0].from_socket, e.inputs['Color'])
            else:
                v = src.default_value
                e.inputs['Color'].default_value = (v, v, v, 1) if isinstance(v, float) else tuple(v)
        nt.links.new(e.outputs[0], o.inputs['Surface'])
        undo.append((nt, [e] + (extra if channel in ('Position', 'GeoNormal') else []), o, old))
    return undo

def unroute(undo):
    for nt, nodes, o, old in undo:
        for n in nodes: nt.nodes.remove(n)
        for s in old:
            nt.links.new(s, o.inputs['Surface'])

def target(mats, image):
    nodes = []
    for mat in mats:
        nt = mat.node_tree
        n = nt.nodes.new('ShaderNodeTexImage'); n.image = image
        nt.nodes.active = n
        nodes.append((nt, n))
    return nodes

def bake(o, kind, size, samples, label):
    img = bpy.data.images.new(f"{NAME}_{label}", size, size, alpha=False, float_buffer=True)
    img.colorspace_settings.name = 'Non-Color'
    mats = [s.material for s in o.material_slots if s.material]
    tn = target(mats, img)
    sc = bpy.context.scene
    sc.cycles.samples = samples
    bpy.ops.object.select_all(action='DESELECT'); o.select_set(True); bpy.context.view_layer.objects.active = o
    undo = [] if kind == 'Normal' else route(mats, kind)
    # The shaders' AO grime/edge masks must only see this part: the source objects sit exactly
    # underneath and would read as occlusion everywhere.
    hidden = [(x, x.hide_render) for x in sc.objects if x != o]
    for x, _ in hidden: x.hide_render = True
    t = time.time()
    if kind == 'Normal':
        bpy.ops.object.bake(type='NORMAL', normal_space='TANGENT', margin=8, use_clear=True)
    else:
        bpy.ops.object.bake(type='EMIT', margin=8, use_clear=True)
    for x, h in hidden: x.hide_render = h
    unroute(undo)
    for nt, n in tn:
        nt.nodes.remove(n)
    px = np.array(img.pixels[:], dtype=np.float32).reshape(size, size, 4)[:, :, :3]
    print(f"deadbolt export: baked {o.name} {label} {kind} {size}px in {time.time() - t:.0f}s", flush=True)
    return px

# ---------------------------------------------------------------- texture output
def srgb(x):
    x = np.clip(x, 0, 1)
    return np.where(x <= 0.0031308, x*12.92, 1.055*np.power(x, 1/2.4) - 0.055)

def write_tga(path, rgb01, alpha01=None):
    """Top-left origin TGA from a bottom-up float image (Blender pixel order), like the RAVEN-7 tools."""
    h, w = rgb01.shape[:2]
    chans = [rgb01[..., 2], rgb01[..., 1], rgb01[..., 0]] + ([alpha01] if alpha01 is not None else [])
    data = np.uint8(np.clip(np.stack(chans, axis=2), 0, 1)*255 + 0.5)[::-1].tobytes()
    bpp = 32 if alpha01 is not None else 24
    with open(path, 'wb') as f:
        f.write(struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, w, h, bpp, 32 | (8 if bpp == 32 else 0)))
        f.write(data)
    return path

def kf2_maps(base, metal, rough):
    """PBR -> KF2 diffuse/specular. Metals keep a darker diffuse and a tinted specular; roughness kills specular."""
    m = metal[..., :1]; r = rough[..., :1]
    diffuse = base*(1 - 0.6*m)
    gloss = np.clip(1 - r, 0, 1)**1.4
    spec = (0.05*(1 - m) + base*m*1.4)*(0.25 + 1.5*gloss)
    return srgb(diffuse), srgb(np.clip(spec, 0, 1))

def stamp_decals(base, metal, rough, pos, gnormal):
    """Composite every placed weathering stamp (deadbolt_weather.PLACED) into the body maps in texture space."""
    raw = bpy.data.images.load(W.ATLAS, check_existing=False); raw.colorspace_settings.name = 'Non-Color'
    rmask = bpy.data.images.load(W.METAL, check_existing=False); rmask.colorspace_settings.name = 'Non-Color'
    aw, ah = raw.size
    atlas = np.array(raw.pixels[:], dtype=np.float32).reshape(ah, aw, 4)
    a_rgb = np.where(atlas[..., :3] <= 0.04045, atlas[..., :3]/12.92, ((atlas[..., :3] + 0.055)/1.055)**2.4)
    a_alpha = atlas[..., 3]
    a_metal = np.array(rmask.pixels[:], dtype=np.float32).reshape(ah, aw, 4)[..., 0]
    shape = base.shape
    B_, M_, R_ = base.reshape(-1, 3), metal.reshape(-1, 3), rough.reshape(-1, 3)
    P = pos.reshape(-1, 3) - POS_OFFSET
    N = gnormal.reshape(-1, 3)*2 - 1
    valid = np.abs(pos.reshape(-1, 3)).sum(axis=1) > 1e-6
    stamped = 0
    for d in W.PLACED:
        c, n, up, x = (np.array(d[k], dtype=np.float32) for k in ('p', 'n', 'up', 'x'))
        rel = P - c
        u = rel @ x/d['w'] + 0.5; v = rel @ up/d['h'] + 0.5; depth = np.abs(rel @ n)
        sel = valid & (u >= 0) & (u < 1) & (v >= 0) & (v < 1) & (depth < (0.012 if d['curved'] else 0.004))             & ((N @ n) > (0.45 if d['curved'] else 0.6))
        idx = np.nonzero(sel)[0]
        if not len(idx): continue
        r_, c_ = divmod(d['cell'], 4)
        px = np.clip(((c_ + u[idx])/4*aw).astype(int), 0, aw - 1)
        py = np.clip((((3 - r_) + v[idx])/4*ah).astype(int), 0, ah - 1)
        rough_c, use_metal, gain = W.CATS[d['cat']]
        a = np.clip(a_alpha[py, px]*gain, 0, 1)[:, None]
        B_[idx] = B_[idx]*(1 - a) + a_rgb[py, px]*a
        mval = a_metal[py, px][:, None] if use_metal else np.zeros((len(idx), 1), np.float32)
        rval = (0.75 + (rough_c - 0.75)*mval) if use_metal else np.full((len(idx), 1), rough_c, np.float32)
        M_[idx] = M_[idx]*(1 - a) + mval*a
        R_[idx] = R_[idx]*(1 - a) + rval*a
        stamped += 1
    print(f"deadbolt export: stamped {stamped}/{len(W.PLACED)} decals into the body maps", flush=True)
    return B_.reshape(shape), M_.reshape(shape), R_.reshape(shape)

def dx_normal(n):
    out = n.copy(); out[..., 1] = 1 - out[..., 1]
    return out

def sha(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest().upper()

# ---------------------------------------------------------------- skeletal rig
def rig_copy(parts):
    """Body, Glow and Spike joined into one mesh with material slots in that order."""
    order = [f"{NAME}{g}" for g in ("Body", "Glow", "Spike")]
    copies = []
    for g in ("Body", "Glow", "Spike"):
        c = parts[g].copy(); c.data = parts[g].data.copy()
        bpy.context.scene.collection.objects.link(c)
        copies.append(c)
    o = join(copies, f"{NAME}Rig")
    me = o.data
    names = [m.name for m in me.materials]
    remap = [order.index(n) for n in names]
    idx = [0]*len(me.polygons)
    me.polygons.foreach_get("material_index", idx)
    me.materials.clear()                       # (resets the indices, so set them afterwards)
    for n in order: me.materials.append(bpy.data.materials[n])
    me.polygons.foreach_set("material_index", [remap[i] for i in idx])
    return o

def drop_flare(o):
    """Delete the muzzle burst (vertices skinned to the flare bones) from a static part."""
    ids = {o.vertex_groups[n].index for n in ("DB_Flare", "DB_FlareTip") if n in o.vertex_groups}
    bm = bmesh.new(); bm.from_mesh(o.data)
    dl = bm.verts.layers.deform.verify()
    doomed = [v for v in bm.verts if any(g in ids and w > 0.0 for g, w in v[dl].items())]
    bmesh.ops.delete(bm, geom=doomed, context='VERTS')
    bm.to_mesh(o.data); bm.free()
    print(f"deadbolt export: removed {len(doomed)} flare vertices from the static glow part", flush=True)

def export_rig(mesh, scene):
    """VRDeadboltRig.fbx: deadbolt_anim skeleton (cm), the mesh skinned to it, one take per action.
    Same FBX conventions as the RAVEN-7 rig (tools/raven7_rig.py), whose container post-passes it reuses."""
    sys.path.insert(0, os.path.dirname(HERE))
    from raven7_rig import strip_container_animation
    from generate_floating_hands import remove_fbx_armature_container
    # One key per 60 fps sample, written on a 30 fps FBX time base: the pinned UE3 importer samples
    # takes at 30 Hz (see VREngineerAssetCommandlet), so every key survives, and the commandlet then
    # sets each take's real length (frames / 60). Snaps one frame long stay one frame long.
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
    v = np.array([tuple(x.co) for x in mesh.data.vertices])
    tip = Vector((B.SPIKE_X0 + B.SPIKE_LEN, 0.0, B.AXIS_Z))*CM
    return {"file": os.path.basename(path), "sha256": sha(path), "fps": A.FPS, "fbx_time_base_fps": FBX_TIME_BASE,
            "take_frames": [pad + 1 for t in A.TAKES], "sequence_seconds": [pad/A.FPS for t in A.TAKES],
            "bones": A.BONE_NAMES, "vertices": len(mesh.data.vertices),
            "triangles": sum(len(p.vertices) - 2 for p in mesh.data.polygons),
            "materials": [m.name for m in mesh.data.materials],
            "bounds_min": [round(float(x), 3) for x in v.min(axis=0)], "bounds_max": [round(float(x), 3) for x in v.max(axis=0)],
            "takes": list(A.TAKES), "take_seconds": [A.TAKES[t][0] for t in A.TAKES],
            "take_seconds_note": "authored length; every sequence is padded to sequence_seconds by holding its last pose",
            "beats": {t: A.TAKES[t][2] for t in A.TAKES},
            "heat_keys": {t: [[round(x, 3) for x in k] for k in A.TAKES[t][3]] for t in A.TAKES},
            "heat_keys_columns": ["seconds", "glow_multiplier", "spike_multiplier", "spike_heat"],
            "spike_heat_tint": {"note": "Vector_Glow_Color on the spike material, linear between these stops",
                                "stops": [[h, list(A.heat_tint(h))] for h in (0.0, 0.5, 1.0)]},
            "spike_hidden": {t: A.TAKES[t][4] for t in A.TAKES},
            "flare_shown": {t: A.TAKES[t][5] for t in A.TAKES}, "flare_bone": "DB_Flare",
            "script_end_seconds": {t: A.TAKES[t][0] for t in A.TAKES},
            "fire_kick_note": ("The shot's big kick is VRHandsBridge hand recoil sized from BreacherDeadbolt's stock "
                               "min/maxRecoilPitch (1100/1200: about 4 cm, 0.6 s recovery, halved when braced); "
                               "Fire/FireLast add only a gauntlet shake (1 cm, 2 degrees) plus the stack slide, "
                               "ram/yoke slam, crown index, hose whip, burst and bore flash. Reload lock and seat "
                               "jolts are authored, since no shot fires there."),
            "script_end_note": ("VRDeadboltPresentation ends a one-shot take at its last heat key (= script_end_seconds), "
                                "not at the padded sequence length. Reload instead holds its seated last pose for as long as "
                                "the weapon stays in the Reloading state, so a stock ammo refill after 2.9 s cannot pop the rod; "
                                "the script never refills ammo itself, it only reads AmmoCount."),
            "spike_bone": "DB_Spike", "spike_tip_cm": [round(c, 3) for c in tip],
            "spike_stow_offset_cm": round(A.STOW*CM, 3)}

# ---------------------------------------------------------------- main
def main():
    t0 = time.time()
    os.makedirs(OUT, exist_ok=True); os.makedirs(WORK, exist_ok=True)
    for name in ("Cube", "Light"):
        o = bpy.data.objects.get(name)
        if o: o.hide_set(True); o.hide_render = True
    B.Q.update(GAME_Q)
    B.build_all(); W.build_weathering()
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

    coll = export_coll()
    groups = {"Body": [], "Glow": [], "Spike": []}
    for ob in B.get_coll(B.COLL).objects:
        if ob.type not in ('MESH', 'CURVE', 'FONT'):
            continue
        mats = [s.material.name for s in ob.material_slots if s.material]
        if any(m in SKIP_MATS for m in mats):
            continue
        if ob.name.startswith("Spike | thermal auger"): g = "Spike"
        elif any(m.startswith("DB_decal_") for m in mats): continue   # stamped into the body maps
        elif any(m in GLOW_MATS for m in mats): g = "Glow"
        else: g = "Body"
        copy = baked_copy(ob, coll)
        A.assign_groups(copy, ob.name)          # rig weights travel through join/triangulate/UV
        groups[g].append(copy)
    parts = {g: join(objs, f"{NAME}{g}") for g, objs in groups.items()}
    for g, o in parts.items():
        triangulate(o)
        fresh_uv(o, 0.0015 if g == "Body" else 0.004)

    tex = {}
    for g in ("Body", "Spike", "Glow"):
        o = parts[g]; size = SIZES[g]
        if g == "Body":
            base = bake(o, 'Base Color', size, 48, g + "_base")
            metal = bake(o, 'Metallic', size, 16, g + "_metal")
            rough = bake(o, 'Roughness', size, 16, g + "_rough")
            normal = bake(o, 'Normal', size, 16, g + "_normal")
            pos = bake(o, 'Position', size, 1, g + "_pos")
            gnormal = bake(o, 'GeoNormal', size, 1, g + "_gnormal")
            base, metal, rough = stamp_decals(base, metal, rough, pos, gnormal)
            d, s = kf2_maps(base, metal, rough)
        else:
            emit = bake(o, 'Emission', size, 32, g + "_emit")
            normal = bake(o, 'Normal', size, 8, g + "_normal")
            d = srgb(emit/max(1e-4, float(np.percentile(emit, 99.5))))   # glow colour; the material sets intensity
            s = np.full_like(d, 0.05)
        tex[g] = {k: write_tga(os.path.join(OUT, f"{NAME}{g}_{k}.tga"), v) for k, v in (("D", d), ("N", dx_normal(normal)), ("S", s))}
    # single material per part, then merge body+glow into the held mesh (slot order 0/1)
    for g, o in parts.items():
        m = bpy.data.materials.get(f"{NAME}{g}") or bpy.data.materials.new(f"{NAME}{g}")
        o.data.materials.clear(); o.data.materials.append(m)
        for p in o.data.polygons: p.material_index = 0
    rig_mesh = rig_copy(parts)
    drop_flare(parts["Glow"])      # the static props have no script to hide the launch burst
    spike = parts.pop("Spike")
    held = join([parts["Body"], parts["Glow"]], NAME)
    # spike pivot at its base on the bore axis
    pivot = Vector((B.SPIKE_X0, 0.0, B.AXIS_Z))
    spike.data.transform(Matrix.Translation(-pivot))

    report = {"units": "cm", "frame": "origin at wrist centre; +X toward fingers, +Z up, +Y thumb side (right forearm)",
              "axis_forward": "-X", "axis_up": "Z", "texture_size": SIZES, "build_seconds": None}
    xsc = bpy.data.scenes.new(f"{NAME} export")
    xsc.unit_settings.system = 'METRIC'; xsc.unit_settings.scale_length = 0.01
    for o, fbx in ((held, f"{NAME}.fbx"), (spike, f"{NAME}Spike.fbx")):
        o.data.transform(Matrix.Scale(CM, 4))
        for c in list(o.users_collection): c.objects.unlink(o)
        xsc.collection.objects.link(o)
    bpy.context.window.scene = xsc
    for o, fbx in ((held, f"{NAME}.fbx"), (spike, f"{NAME}Spike.fbx")):
        for other in xsc.objects: other.select_set(other == o)
        bpy.context.view_layer.objects.active = o
        path = os.path.join(OUT, fbx)
        r = bpy.ops.export_scene.fbx(filepath=path, use_selection=True, global_scale=1.0, axis_forward='-X', axis_up='Z',
                                     apply_unit_scale=True, apply_scale_options='FBX_SCALE_UNITS', bake_space_transform=False,
                                     mesh_smooth_type='EDGE', add_leaf_bones=False, bake_anim=False, use_mesh_modifiers=False,
                                     object_types={'MESH'}, use_tspace=True)
        if r != {'FINISHED'}:
            raise RuntimeError(f"FBX export failed: {path}")
        v = np.array([tuple(x.co) for x in o.data.vertices])
        report[fbx] = {"sha256": sha(path), "vertices": len(o.data.vertices),
                       "triangles": sum(len(p.vertices) - 2 for p in o.data.polygons),
                       "materials": [m.name for m in o.data.materials],
                       "bounds_min": [round(float(x), 3) for x in v.min(axis=0)], "bounds_max": [round(float(x), 3) for x in v.max(axis=0)]}
    report["spike_socket_cm"] = [round(c*CM, 3) for c in pivot]
    report["rig"] = export_rig(rig_mesh, xsc)
    report["textures"] = {g: {k: {"file": os.path.basename(p), "sha256": sha(p)} for k, p in d.items()} for g, d in tex.items()}
    report["build_seconds"] = round(time.time() - t0)
    with open(os.path.join(OUT, f"{NAME}.json"), 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=2)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(WORK, f"{NAME}-game.blend"), copy=True)
    print("deadbolt export:", json.dumps({k: report[k] for k in (f"{NAME}.fbx", f"{NAME}Spike.fbx")}), flush=True)

if __name__ == "__main__":   # importable: tools/ripcord reuses these helpers
    main()
