"""Render a true bold watch glyph atlas in Blender, with fixed ASCII metrics."""
import bpy
from pathlib import Path

root = Path(__file__).resolve().parents[1]
out = root / 'build/hand-redesign-20260924'
scene = bpy.data.scenes.new('Watch bold glyph source')
bpy.context.window.scene = scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 16
scene.render.film_transparent = True
scene.render.resolution_x = scene.render.resolution_y = 1024
scene.render.resolution_percentage = 100
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
font = bpy.data.fonts.load('C:/Windows/Fonts/consolab.ttf')
font.pack()
mat = bpy.data.materials.new('White glyph coverage')
mat.use_nodes = True
nodes = mat.node_tree.nodes
nodes.clear()
emission = nodes.new('ShaderNodeEmission')
emission.inputs[0].default_value = (1, 1, 1, 1)
output = nodes.new('ShaderNodeOutputMaterial')
mat.node_tree.links.new(emission.outputs[0], output.inputs[0])
for code in range(32, 128):
    index = code - 32
    text = bpy.data.curves.new('ASCII ' + str(code), 'FONT')
    text.body = chr(code) if code < 127 else '?'
    text.font = font
    text.size = 80
    obj = bpy.data.objects.new(text.name, text)
    scene.collection.objects.link(obj)
    obj.location = (index % 16 * 64 + 8, 1024 - index // 16 * 96 - 72, 0)
    text.materials.append(mat)
cam = bpy.data.objects.new('Glyph orthographic camera', bpy.data.cameras.new('Glyph camera'))
scene.collection.objects.link(cam)
cam.location = (512, 512, 1000)
cam.data.type = 'ORTHO'
cam.data.ortho_scale = 1024
cam.data.clip_end = 2000
scene.camera = cam
scene.render.image_settings.file_format = 'TARGA'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.filepath = str(out / 'runtime/VRHorzineWatchFont.tga')
bpy.ops.render.render(write_still=True)
scene.render.image_settings.file_format = 'PNG'
bpy.data.images['Render Result'].save_render(str(out / '18-bold-font.png'), scene=scene)
scene['glyph_metrics'] = 'ASCII32..127; 16 columns; cell64x96; crop offset8,12; crop48x72; kerning1'
bpy.ops.wm.save_as_mainfile(filepath=str(out / '18-watch-font.blend'))
