"""Author, render, and rig the concept revision in Blender, keeping prior assets."""
import bpy,runpy,os
from pathlib import Path
from mathutils import Vector
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/hand-redesign-20260924'
rev=int(os.environ.get('KF2VR_ART_REVISION','24'))
g=runpy.run_path(str(ROOT/'tools/build_reference_hands.py'),init_globals={'REVISION':rev})
s=bpy.context.scene
runpy.run_path(str(ROOT/'tools/update_reference_watch.py'),init_globals={
    'PREVIEW_REVISION':rev,'SOURCE_SCENE':s.name,'RENDER_PREVIEWS':False,
    'COPY_SCENE':False,'CALIBRATE':False})
for f in bpy.data.fonts:
    if f.filepath and f.filepath!='<builtin>':
        try:f.pack()
        except RuntimeError:pass
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/f'{rev:02d}-horzine-study.blend'))
# Preview calibration is applied to independent material copies. The authoring
# file/rig remain uncalibrated, avoiding double calibration during export.
calibrate=runpy.run_path(str(ROOT/'tools/calibrate_reference_materials.py'))['calibrate']
oldmats={};copies={}
for ob in s.objects:
    if ob.type!='MESH':continue
    oldmats[ob]=list(ob.data.materials)
    for i,ma in enumerate(oldmats[ob]):
        if ma not in copies:
            copies[ma]=ma.copy();calibrate(copies[ma])
        ob.data.materials[i]=copies[ma]
for view,loc,target,scale in [('hero',(5,-31,46),(0,0,0),34),('detail',(-4,-8,33),(-4,0,1),18)]:
    s.camera.location=loc;s.camera.rotation_euler=(Vector(target)-s.camera.location).to_track_quat('-Z','Y').to_euler();s.camera.data.ortho_scale=scale
    s.render.filepath=str(OUT/f'{rev:02d}-{view}.png');bpy.ops.render.render(write_still=True)
for ob,mats in oldmats.items():
    for i,ma in enumerate(mats):ob.data.materials[i]=ma
if rev>=26:
    # The palm-side forearm is checked in neutral clay, independently of maps.
    visible={o:o.hide_render for o in s.objects}
    lights={o:(o.location.copy(),o.rotation_euler.copy()) for o in s.objects if o.type=='LIGHT'}
    skin=next(o for o in s.objects if o.name.startswith('LEFT | anatomical'))
    materials=list(skin.data.materials)
    clay=bpy.data.materials.new('Review | neutral skin topology');clay.use_nodes=True
    clay.node_tree.nodes.get('Principled BSDF').inputs['Base Color'].default_value=(.22,.22,.22,1)
    skin.data.materials.clear();skin.data.materials.append(clay)
    for ob in s.objects:
        if ob.type in {'MESH','CURVE','FONT'}:ob.hide_render=ob!=skin
        if ob.type=='LIGHT':
            ob.location.z=-abs(ob.location.z);ob.rotation_euler=(Vector((-8,0,0))-ob.location).to_track_quat('-Z','Y').to_euler()
    s.camera.location=(-10,-15,-32);s.camera.rotation_euler=(Vector((-8,0,0))-s.camera.location).to_track_quat('-Z','Y').to_euler();s.camera.data.ortho_scale=16
    s.render.filepath=str(OUT/f'{rev:02d}-forearm-clay.png');bpy.ops.render.render(write_still=True)
    for ob,value in visible.items():ob.hide_render=value
    for ob,(loc,rot) in lights.items():ob.location=loc;ob.rotation_euler=rot
    skin.data.materials.clear()
    for ma in materials:skin.data.materials.append(ma)
s.camera.location=(5,-31,46);s.camera.rotation_euler=(-s.camera.location).to_track_quat('-Z','Y').to_euler();s.camera.data.ortho_scale=34
runpy.run_path(str(ROOT/'tools/rig_reference_hands.py'))
pose=bpy.context.scene;pose.frame_set(40)
for ob in pose.objects:
    if ob.name.startswith('Right '):ob.hide_render=True
    elif ob.name.startswith('Left '):ob.location.y=0
pose.camera.location=(5,-31,46);pose.camera.rotation_euler=(-pose.camera.location).to_track_quat('-Z','Y').to_euler();pose.camera.data.ortho_scale=34
pose.render.resolution_y=1050;pose.render.filepath=str(OUT/f'{rev:02d}-grip.png')
bpy.ops.render.render(write_still=True)
print('CONCEPT_ITERATION_COMPLETE',rev,flush=True)
