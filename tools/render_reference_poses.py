"""Neutral and articulated presentation of both Blender authoring hands."""
import bpy
import runpy
from pathlib import Path
from mathutils import Vector
s=bpy.context.scene;rev=int(s.name.rsplit(' ',1)[-1]);out=Path(bpy.data.filepath).parent
runpy.run_path(str(Path(__file__).with_name('audit_reference_hands.py')),run_name='asset_audit')
cam=s.camera
lights={o.name:o.location.copy() for o in s.objects if o.type=='LIGHT'}
for view,frame,loc in [('pair',1,(8,-48,66)),('open',20,(8,-48,66)),('grip',40,(8,-48,66)),('open-palm',20,(8,-38,-66))]:
    s.frame_set(frame)
    cam.location=loc;cam.rotation_euler=(-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=44
    for ob in s.objects:
        if ob.type=='LIGHT':
            ob.location=lights[ob.name].copy()
            if view=='open-palm':ob.location.z=-abs(ob.location.z)
            ob.rotation_euler=(-ob.location).to_track_quat('-Z','Y').to_euler()
    s.render.filepath=str(out/f'{rev:02d}-{view}.png');bpy.ops.render.render(write_still=True)
