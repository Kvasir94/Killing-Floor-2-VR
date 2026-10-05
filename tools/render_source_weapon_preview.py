"""Render the actual converted weapon geometry for visual inspection in Blender."""
from pathlib import Path
import math
import json
import bpy
from mathutils import Vector, Quaternion

root=Path(__file__).resolve().parents[1]/'build/source-weapons'
for name in ('SuperGravityGun','StickybombLauncher','Stickybomb'):
    bpy.ops.wm.open_mainfile(filepath=str(root/(name+'.blend')))
    if name == 'SuperGravityGun':
        rig = next(o for o in bpy.context.scene.objects if o.type == 'ARMATURE')
        for bone, pose in json.loads(rig.get('source_claw_closed', '{}')).items():
            rig.pose.bones[bone].location = Vector(pose['position'])
            rig.pose.bones[bone].rotation_mode = 'QUATERNION'
            rig.pose.bones[bone].rotation_quaternion = Quaternion(pose['rotation'])
        bpy.context.view_layer.update()
    scene=bpy.context.scene
    scene.render.engine='CYCLES'
    scene.cycles.samples=48
    scene.cycles.use_denoising=True
    meshes=[o for o in scene.objects if o.type=='MESH']
    corners=[o.matrix_world@Vector(v) for o in meshes for v in o.bound_box]
    minimum=Vector([min(v[i] for v in corners) for i in range(3)])
    maximum=Vector([max(v[i] for v in corners) for i in range(3)])
    center=(minimum+maximum)/2
    radius=max(maximum-minimum)
    scene.world.color=(0.12,0.12,0.12)
    scene.world.use_nodes=True
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value=(0.11,0.14,0.19,1)
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value=0.45
    for location,power,size in [((-1,-1,2),1000,1.2),((0,2,1.5),700,1),((2,-0.5,1),600,0.8)]:
        data=bpy.data.lights.new('Preview softbox','AREA')
        data.energy=power*radius*radius/70; data.shape='DISK'; data.size=radius*size
        obj=bpy.data.objects.new(data.name,data); scene.collection.objects.link(obj)
        obj.location=center+Vector(location)*radius
        obj.rotation_euler=(center-obj.location).to_track_quat('-Z','Y').to_euler()
    data=bpy.data.cameras.new('Asset inspection camera')
    camera=bpy.data.objects.new(data.name,data); scene.collection.objects.link(camera)
    camera.location=center+Vector((1.45,-1.65,0.85))*radius
    camera.rotation_euler=(center-camera.location).to_track_quat('-Z','Y').to_euler()
    data.type='ORTHO'; data.ortho_scale=radius*1.28
    scene.camera=camera
    scene.render.resolution_x=1100;scene.render.resolution_y=800;scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG'
    scene.render.film_transparent=False
    scene.view_settings.view_transform='AgX'
    scene.render.filepath=str(root/(name+'-preview.png'))
    bpy.ops.render.render(write_still=True)
    print('SOURCE_PREVIEW',scene.render.filepath)
    if name != 'Stickybomb':
        scene.render.resolution_x=512; scene.render.resolution_y=512
        scene.render.film_transparent=True
        scene.render.image_settings.file_format='TARGA'
        scene.render.image_settings.color_mode='RGBA'
        scene.render.filepath=str(root/('GravityIcon.tga' if name == 'SuperGravityGun' else 'StickyIcon.tga'))
        bpy.ops.render.render(write_still=True)
    if name == 'SuperGravityGun':
        scene.render.resolution_x=1100; scene.render.resolution_y=800
        scene.render.film_transparent=False
        scene.render.image_settings.file_format='PNG'
        for label, offset in [('rear',(1.45,1.65,0.85)), ('underside',(-1.45,-1.65,-0.65))]:
            camera.location=center+Vector(offset)*radius
            camera.rotation_euler=(center-camera.location).to_track_quat('-Z','Y').to_euler()
            scene.render.filepath=str(root/(name+'-'+label+'.png'))
            bpy.ops.render.render(write_still=True)
