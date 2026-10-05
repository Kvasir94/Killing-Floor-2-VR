"""Render the converted original Portal 2 mesh and textures for inspection."""
from pathlib import Path
import json
import sys
import bpy
from mathutils import Vector, Matrix

OUT = Path(__file__).resolve().parents[1] / 'build/portal'
MODEL = 'PortalGunWorld' if '--world' in sys.argv else 'PortalGun'
bpy.ops.wm.open_mainfile(filepath=str(OUT/(MODEL+'.blend')))
scene = bpy.context.scene
for rig in [o for o in scene.objects if o.type=='ARMATURE']:
    rig.animation_data_clear()
    for bone in rig.pose.bones:
        bone.matrix_basis = Matrix.Identity(4)
report = json.loads((OUT/'meshes.json').read_text())
for entry in (report['world']['materials'] if MODEL=='PortalGunWorld' else report['materials']):
    material = bpy.data.materials[entry['name']]
    material.use_nodes = True
    nodes = material.node_tree.nodes
    nodes.clear()
    output = nodes.new('ShaderNodeOutputMaterial')
    shader = nodes.new('ShaderNodeBsdfPrincipled')
    shader.inputs['Roughness'].default_value = 0.28
    shader.inputs['Metallic'].default_value = 0.15
    texture = nodes.new('ShaderNodeTexImage')
    texture.image = bpy.data.images.load(entry['diffuse'])
    # Source diffuse alpha is packed specular information on the opaque shell.
    # Blender's default alpha association darkens its RGB unless kept separate.
    texture.image.alpha_mode = 'CHANNEL_PACKED'
    material.node_tree.links.new(texture.outputs['Color'],shader.inputs['Base Color'])
    if entry['normal']:
        normal = nodes.new('ShaderNodeTexImage')
        normal.image = bpy.data.images.load(entry['normal'])
        normal.image.colorspace_settings.name = 'Non-Color'
        mapping = nodes.new('ShaderNodeNormalMap')
        material.node_tree.links.new(normal.outputs['Color'],mapping.inputs['Color'])
        material.node_tree.links.new(mapping.outputs['Normal'],shader.inputs['Normal'])
    if entry['properties'].get('$translucent')=='1':
        shader.inputs['Alpha'].default_value = .22
    material.node_tree.links.new(shader.outputs['BSDF'],output.inputs['Surface'])
bpy.context.view_layer.update()
meshes = [o for o in scene.objects if o.type=='MESH']
corners = [o.matrix_world@Vector(v) for o in meshes for v in o.bound_box]
low = Vector([min(v[i] for v in corners) for i in range(3)])
high = Vector([max(v[i] for v in corners) for i in range(3)])
center, radius = (low+high)/2,max(high-low)
scene.render.engine = 'CYCLES'
scene.cycles.samples = 48
scene.cycles.use_denoising = True
scene.world.use_nodes = True
scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (.08,.105,.15,1)
scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value = .45
for position,power in [((-1,-1,2),1200),((0,2,1.5),850),((2,-.5,1),650)]:
    light = bpy.data.lights.new('Inspection softbox','AREA')
    light.energy = power*radius*radius/70
    light.shape = 'DISK'; light.size = radius
    obj = bpy.data.objects.new(light.name,light); scene.collection.objects.link(obj)
    obj.location = center+Vector(position)*radius
    obj.rotation_euler = (center-obj.location).to_track_quat('-Z','Y').to_euler()
data = bpy.data.cameras.new('Inspection camera')
camera = bpy.data.objects.new(data.name,data); scene.collection.objects.link(camera)
camera.location = center+Vector((1.45,-1.65,.85))*radius
camera.rotation_euler = (center-camera.location).to_track_quat('-Z','Y').to_euler()
data.type = 'ORTHO'; data.ortho_scale = radius*1.28
scene.camera = camera
scene.render.resolution_x = 1100; scene.render.resolution_y = 800; scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.view_settings.view_transform = 'AgX'
scene.render.filepath = str(OUT/(MODEL+'-preview.png'))
bpy.ops.render.render(write_still=True)
print('PORTAL_PREVIEW',scene.render.filepath)
