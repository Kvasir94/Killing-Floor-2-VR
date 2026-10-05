"""Render the exported geometry with the matching Blender-authored Canvas study."""
import bpy,os
from pathlib import Path
from mathutils import Vector
OUT=Path(__file__).resolve().parents[1]/'build/hand-redesign-20260924'
rev=int(os.environ.get('KF2VR_ART_REVISION','24'))
tag=int(os.environ.get('KF2VR_ART_RENDER_TAG',str(rev)))
s=bpy.context.scene
with bpy.data.libraries.load(str(OUT/f'{rev:02d}-horzine-study.blend'),link=False) as (src,dst):
    dst.objects=[n for n in src.objects if n.startswith('UI live preview')]
for ob in dst.objects:s.collection.objects.link(ob)
for view,loc,target,scale in [('runtime-baked',(5,-31,46),(0,0,0),34),('runtime-detail',(-4,-8,33),(-4,0,1),18)]:
    s.camera.location=loc;s.camera.rotation_euler=(Vector(target)-s.camera.location).to_track_quat('-Z','Y').to_euler();s.camera.data.ortho_scale=scale
    s.render.filepath=str(OUT/f'{tag:02d}-{view}.png');bpy.ops.render.render(write_still=True)
s.camera.location=(5,-31,46);s.camera.rotation_euler=(-s.camera.location).to_track_quat('-Z','Y').to_euler();s.camera.data.ortho_scale=34
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'runtime/Horzine-runtime-preview.blend'))
