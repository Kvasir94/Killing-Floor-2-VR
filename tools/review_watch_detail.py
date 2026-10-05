"""Save immutable source snapshots and comparable watch-focused review renders."""
import bpy, os, runpy, shutil, json
from pathlib import Path
from mathutils import Vector

ROOT=Path(__file__).resolve().parents[1]
rev=int(os.environ.get('KF2VR_ART_REVISION','27'))
OUT=ROOT/'build/watch-detail-20260924'/str(rev)
OUT.mkdir(parents=True,exist_ok=True)
(OUT/'source').mkdir(exist_ok=True)
for name in ['build_reference_hands.py','refine_reference_shapes.py','refine_watch_detail.py',
             'review_watch_detail.py','update_reference_watch.py','export_reference_hands.py','generate_watch_glass.py','orient_watch_left_hand.py']:
    shutil.copy2(ROOT/'tools'/name,OUT/'source'/name)
shutil.copy2(ROOT/'script/KF2VR/Classes/VRSpatialHUD.uc',OUT/'source/VRSpatialHUD.uc')
g=runpy.run_path(str(ROOT/'tools/build_reference_hands.py'),init_globals={'REVISION':rev})
s=bpy.context.scene
runpy.run_path(str(ROOT/'tools/update_reference_watch.py'),init_globals={
    'PREVIEW_REVISION':rev,'SOURCE_SCENE':s.name,'RENDER_PREVIEWS':False,
    'COPY_SCENE':False,'CALIBRATE':False})
for f in bpy.data.fonts:
    if f.filepath and f.filepath!='<builtin>':
        try:f.pack()
        except RuntimeError:pass
s.cycles.samples=48
bpy.context.view_layer.update()
def center_x(prefixes):
    xs=[(o.matrix_world@Vector(p)).x for o in s.objects if o.name.startswith(prefixes) for p in o.bound_box]
    return (min(xs)+max(xs))*.5
alignment={
    'second_screen_center_cm':-3.9+(772-512)*.01*1.12,
    'wordmark_center_cm':center_x(('Horzine maker','Horzine emblem')),
    'biotech_center_cm':center_x(('Horzine serial',)),
    'plaque_center_cm':center_x(('Case | badge recessed face',)),
    'hinge_center_cm':center_x(('Case | textured webbing roller',)),
    'upper_mount_center_cm':center_x(('Case | top retention mounting',)),
    'upper_latch_center_cm':center_x(('Case | stamped latch channel',))}
if rev>=49:
    alignment['upper_bay_center_cm']=s['upper_bay_center_cm']
    alignment['right_strap_center_cm']=center_x(('Cuff | webbing band 2',))
if rev>=55:
    alignment['first_screen_center_cm']=-3.9+(250-512)*.01*1.12
    alignment['left_strap_center_cm']=center_x(('Cuff | webbing band 1',))
    alignment['left_keeper_center_cm']=center_x(('Case | wide strap keeper',))
    for key in ['left_strap_center_cm','left_keeper_center_cm']:
        assert abs(alignment[key]-alignment['first_screen_center_cm'])<.025,(key,alignment)
if rev>=48:
    for key in ['wordmark_center_cm','hinge_center_cm','upper_mount_center_cm','upper_latch_center_cm']:
        assert abs(alignment[key]-alignment['second_screen_center_cm'])<.025,(key,alignment)
if rev>=49:
    for key in ['upper_bay_center_cm','right_strap_center_cm']:
        assert abs(alignment[key]-alignment['second_screen_center_cm'])<.025,(key,alignment)
if rev>=50:
    cables=[];clasps=[]
    for ob in s.objects:
        points=[ob.matrix_world@Vector(p) for p in ob.bound_box]
        if not points or (min(p.x for p in points)+max(p.x for p in points))*.5>=-3:continue
        if ob.name.startswith('Conduit |') and max(p.y for p in points)<0:cables.extend(p.x for p in points)
        if ob.name.startswith(('Cuff | sculpted release clasp','Cuff | adjuster','Cuff | central tension','Cuff | clasp captive')):clasps.extend(p.x for p in points)
    alignment['left_conduit_clasp_clearance_cm']=min(cables)-max(clasps)
    assert alignment['left_conduit_clasp_clearance_cm']>.1,alignment
s['watch_alignment_cm']=json.dumps(alignment)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'watch-source.blend'))
if rev>=57:
    runpy.run_path(str(ROOT/'tools/inspect_watch_fit.py'),init_globals={'FIT_RENDER':False})
    s.cycles.samples=48
for view,loc,target,scale in [
    ('front',(-4,-5,38),(-4,-.3,2),17),
    ('oblique',(-8,-19,25),(-3.9,-.5,2.8),17),
    ('badge',(-1,-10,17),(-.2,-2.95,3.8),6.9),
    *([('hand-context',(1.5,0,45),(1.5,0,0),31)] if rev>=59 else [])]:
    s.camera.location=loc;s.camera.rotation_euler=(Vector(target)-s.camera.location).to_track_quat('-Z','Y').to_euler()
    s.camera.data.ortho_scale=scale
    s.render.filepath=str(OUT/(view+'.png'));bpy.ops.render.render(write_still=True)
# A straight top view makes upper/lower alignment reviewable without perspective.
if rev>=48:
    axis=alignment['second_screen_center_cm']
    curve=bpy.data.curves.new('Review centerline','CURVE');curve.dimensions='3D';curve.bevel_depth=.009
    spline=curve.splines.new('POLY');spline.points.add(1)
    for p,y in zip(spline.points,[-4.9,4.4]):p.co=(axis,y,4.55,1)
    guide=bpy.data.objects.new('Review centerline',curve);s.collection.objects.link(guide)
    mat=bpy.data.materials.new('Review centerline');mat.diffuse_color=(.8,.09,.06,1);curve.materials.append(mat)
    s.camera.location=(-4,0,38);s.camera.rotation_euler=(Vector((-4,0,0))-s.camera.location).to_track_quat('-Z','Y').to_euler()
    s.camera.data.ortho_scale=17;s.render.filepath=str(OUT/'alignment.png');bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(guide,do_unlink=True)
(OUT/'iteration.json').write_text(json.dumps({'revision':rev,'source':str(OUT/'watch-source.blend'),
    'visuals':['front.png','oblique.png','badge.png'],'alignment_cm':alignment,
    'scope':'Authoring geometry; sample HUD; not runtime acceptance'},indent=2))
print('WATCH_REVIEW_READY',rev,flush=True)
