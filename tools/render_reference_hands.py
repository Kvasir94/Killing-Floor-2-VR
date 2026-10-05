"""Render the authored scene without replacing or editing the source .blend."""
import bpy
from pathlib import Path
from mathutils import Vector
scene=bpy.context.scene
rev=int(scene.name.rsplit(' ',1)[-1])
out=Path(bpy.data.filepath).parent
camera=scene.camera
light_locations={o.name:o.location.copy() for o in scene.objects if o.type=='LIGHT'}
for view,location,target,scale in [
    ('hero',(5,-31,46),(0,0,0),34),
    ('palm',(4,-19,-46),(0,0,-.5),34),
    ('detail',(-4,-8,33),(-4,0,1),16),
]:
    for ob in scene.objects:
        if ob.type=='LIGHT':
            ob.location=light_locations[ob.name].copy()
            if view=='palm':ob.location.z=-abs(ob.location.z)
            ob.rotation_euler=(-ob.location).to_track_quat('-Z','Y').to_euler()
    for ob in scene.objects:
        if ob.name.startswith('Review | shadow floor'):ob.hide_render=view=='palm'
    camera.location=location
    camera.rotation_euler=(Vector(target)-camera.location).to_track_quat('-Z','Y').to_euler()
    camera.data.ortho_scale=scale
    scene.render.filepath=str(out/f'{rev:02d}-{view}.png')
    bpy.ops.render.render(write_still=True)
