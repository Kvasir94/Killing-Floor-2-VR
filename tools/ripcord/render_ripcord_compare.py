"""Render the main Ripcord beside the alternative fixed-spool concept (ripcord_alt), and the Pixal3D
blockouts of the 2D concepts, for choosing between them.

    blender --background --factory-startup --python tools/ripcord/render_ripcord_compare.py

Writes build/ripcord-concept/review/compare_side_{in,out}.png, alt_{iso,iso_out,hero}.png and, for every
GLB in build/ripcord-concept/pixal/, pixal_<name>_{a,b}.png. make_compare_sheet.py lays them out.
"""
import glob, importlib, math, os, sys, time
import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(os.path.dirname(HERE), "deadbolt")
for p in (HERE, DB):
    if p not in sys.path:
        sys.path.insert(0, p)
import deadbolt_build as B, deadbolt_stage as ST, deadbolt_glove as G
import ripcord_build as R, ripcord_weather as RW, ripcord_alt as A
for m in (B, ST, G, R, RW, A):
    importlib.reload(m)

ROOT = os.path.dirname(os.path.dirname(HERE))
BASE = os.path.join(ROOT, "build", "ripcord-concept")
OUT = os.path.join(BASE, "review")

def parent_all(objs, name):
    e = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(e)
    for o in objs:
        o.parent = e; o.matrix_parent_inverse.identity()
    return e

def render_pixal():
    others = [c for c in (R.COLL, A.COLL, "DB_Hand") if c in bpy.data.collections]
    for c in others:
        bpy.data.collections[c].hide_render = True
    for path in sorted(glob.glob(os.path.join(BASE, "pixal", "*.glb"))):
        name = os.path.splitext(os.path.basename(path))[0]
        before = set(bpy.data.objects)
        pc = bpy.data.collections.new("Pixal " + name); bpy.context.scene.collection.children.link(pc)
        bpy.context.view_layer.active_layer_collection = bpy.context.view_layer.layer_collection.children[pc.name]
        bpy.ops.import_scene.gltf(filepath=path)
        new = [o for o in bpy.data.objects if o not in before]
        meshes = [o for o in new if o.type == 'MESH']
        bpy.context.view_layer.update()
        pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
        mn = Vector([min(p[i] for p in pts) for i in range(3)]); mx = Vector([max(p[i] for p in pts) for i in range(3)])
        e = parent_all([o for o in new if o.parent is None], "Pixal | " + name)
        s = 0.45/max(mx - mn)
        e.scale = (s, s, s); e.location = -(mn + mx)/2*s + Vector((-0.10, 0, 0.05))
        bpy.context.view_layer.update()
        objs = [o for o in new if o.type == 'MESH']
        ST.VIEWS["pix_a"] = ((-0.80, 0.95, 0.62), False)
        ST.VIEWS["pix_b"] = ((0.80, -0.95, 0.45), False)
        t0 = time.time()
        ST.render(["pix_a", "pix_b"], "pixal_" + name, res=(1200, 900), samples=64, objs=objs)
        print(f"ripcord compare: pixal {name} {time.time() - t0:.1f}s")
        for o in new:
            o.hide_render = True
    for c in others:
        bpy.data.collections[c].hide_render = False

def main():
    os.makedirs(OUT, exist_ok=True)
    for name in ("Cube", "Light"):
        o = bpy.data.objects.get(name)
        if o: o.hide_set(True); o.hide_render = True
    glove = G.build_glove()
    R.build_all(); RW.build_weathering(); A.build_alt()
    ST.OUT = OUT
    ST.setup("studio")
    render_pixal()
    if os.environ.get("COMPARE_SET") == "pixal":
        return
    main_objs = [o for o in bpy.data.collections[R.COLL].all_objects if not o.hide_render]
    alt_objs = [o for o in bpy.data.collections[A.COLL].all_objects if not o.hide_render]
    g2 = glove.copy(); bpy.data.collections["DB_Hand"].objects.link(g2)
    e_main = parent_all(list(bpy.data.collections[R.COLL].all_objects) + [glove], "Compare | main")
    e_alt = parent_all(list(bpy.data.collections[A.COLL].all_objects) + [g2], "Compare | alt")
    # the alternative alone
    e_main.location = (0, 0, 5.0); bpy.context.view_layer.update()
    t0 = time.time()
    ST.render(["iso", "iso_out"], "alt", res=(1600, 800), samples=96, objs=alt_objs + [g2])
    ST.setup("dark")
    ST.VIEWS["hero_out"] = ((-0.70, -0.88, 0.48), False)
    ST.render(["hero_out"], "alt", res=(1600, 900), samples=128, objs=alt_objs + [g2], lens=40)
    ST.setup("studio")
    print(f"ripcord compare: alt views {time.time() - t0:.1f}s")
    # main above, alternative below, same forearm and harness
    e_main.location = (0, 0, 0.25); bpy.context.view_layer.update()
    t0 = time.time()
    ST.render(["side_in", "side_out"], "compare", res=(1400, 1100), samples=96, objs=main_objs + alt_objs + [glove, g2])
    print(f"ripcord compare: compare sides {time.time() - t0:.1f}s")

main()
