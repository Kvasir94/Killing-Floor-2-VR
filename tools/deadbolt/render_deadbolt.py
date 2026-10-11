"""Build the Deadbolt concept model and render it.

Run `python tools/deadbolt/make_decals.py` first (writes the weathering atlas), then inside Blender 5.2:
    blender --background --python tools/deadbolt/render_deadbolt.py
or exec this file from the Blender MCP. Output: build/deadbolt-concept/renders/<tag>_<view>.png and
build/deadbolt-concept/Deadbolt_concept.blend. Set DEADBOLT_TAG to change the render prefix.
"""
import importlib, os, sys
import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import deadbolt_build as B, deadbolt_stage as ST, deadbolt_weather as W, deadbolt_glove as G
for m in (B, ST, W, G):
    importlib.reload(m)

TAG = os.environ.get("DEADBOLT_TAG", "deadbolt")
os.makedirs(ST.OUT, exist_ok=True)
for name in ("Cube", "Light"):            # Blender's startup scene
    o = bpy.data.objects.get(name)
    if o:
        o.hide_set(True); o.hide_render = True
G.build_glove()
B.build_all()
W.build_weathering()
ST.setup("studio")
ST.render(["side_in", "iso", "top", "front"], TAG, res=(1400, 700), samples=96)
ST.setup("dark")
ST.render(["hero"], TAG, res=(1600, 900), samples=192, lens=40)
for im in bpy.data.images:
    if im.name.startswith("decal_"):
        im.pack()
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(os.path.dirname(ST.OUT), "Deadbolt_concept.blend"), copy=True)
print("deadbolt: rendered", TAG)
