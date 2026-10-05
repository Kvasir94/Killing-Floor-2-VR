"""Replace the approved Blender study's placeholder telemetry with watch states.

Run against the saved source scene. These are explicitly sample-data art
previews; VRSpatialHUD owns the live Canvas implementation.
"""
import bpy, json, runpy
from pathlib import Path
from mathutils import Vector

OUT = Path(__file__).resolve().parents[1] / 'build/hand-redesign-20260924'
revision = int(globals().get('PREVIEW_REVISION', 19))
source = bpy.data.scenes[globals().get('SOURCE_SCENE', 'Horzine reference rebuild 07')]
render_previews = globals().get('RENDER_PREVIEWS', True)
copy_scene = globals().get('COPY_SCENE', True)
bpy.context.window.scene = source
scene = source.copy() if copy_scene else source
if copy_scene: scene.name = f'Horzine watch functions {revision:02d}'
bpy.context.window.scene = scene
# Make the editable study independent while sharing unmodified mesh data.
for old in list(scene.objects):
    if not copy_scene:
        if old.name.startswith(('UI ', 'UI |')): bpy.data.objects.remove(old, do_unlink=True)
        continue
    new = old.copy()
    if old.type in {'CAMERA', 'LIGHT'}: new.data = old.data.copy()
    scene.collection.objects.unlink(old)
    scene.collection.objects.link(new)
    if old == source.camera: scene.camera = new
    if old.name.startswith(('UI ', 'UI |')):
        bpy.data.objects.remove(new, do_unlink=True)

def material(name, rgb):
    m=bpy.data.materials.new(name);m.use_nodes=True
    n=m.node_tree.nodes;n.clear();e=n.new('ShaderNodeEmission');e.inputs[0].default_value=(*rgb,1);e.inputs[1].default_value=1.4
    o=n.new('ShaderNodeOutputMaterial');m.node_tree.links.new(e.outputs[0],o.inputs[0]);return m

calibrate=runpy.run_path(str(Path(__file__).resolve().parent/'calibrate_reference_materials.py'))['calibrate']
material_copies={}
for ob in scene.objects:
    if not globals().get('CALIBRATE', True): continue
    if ob.type!='MESH':continue
    ob.data=ob.data.copy()
    for i,ma in enumerate(list(ob.data.materials)):
        if ma not in material_copies:
            new_ma=ma.copy();calibrate(new_ma);material_copies[ma]=new_ma
        ob.data.materials[i]=material_copies[ma]

mats={k:material('Watch sample '+k,v) for k,v in {
    'cyan':(.12,.8,.78),'blue':(.035,.3,1),'amber':(1,.52,.11),
    'backing':(.003,.008,.009),'muted':(.21,.29,.29),'red':(1,.05,.035),'track':(.016,.033,.035)}.items()}
font=bpy.data.fonts.load('C:/Windows/Fonts/consolab.ttf');font.pack()
face=[]
# Same 1024 x 512 coordinates as the live Canvas; no texture/image substitution.
sx,sy=(1.12,.92) if revision >= 21 else (1,1)
def point(x,y): return (-3.9+(x-512)*.01*sx,(256-y)*.01*sy,3.72)
def box(x,y,w,h,mat):
    bpy.ops.mesh.primitive_cube_add(size=1,location=point(x+w/2,y+h/2))
    ob=bpy.context.object;ob.location.z=(3.700 if mat.startswith('backing') else 3.712 if mat.startswith('glass') else 3.720 if mat.startswith('glow') else 3.723 if mat=='track' else 3.736);ob.name='UI live preview | bar';ob.dimensions=(w*.01*sx,h*.01*sy,.012);ob.data.materials.append(mats[mat]);face.append(ob)
def text(s,x,y,w,h,mat='cyan',right=False):
    cu=bpy.data.curves.new('UI live preview | '+s,'FONT');cu.body=s;cu.font=font;cu.size=h*.014
    cu.align_x='RIGHT' if right else 'LEFT'
    ob=bpy.data.objects.new(cu.name,cu);scene.collection.objects.link(ob);ob.location=point(x+w if right else x,y+h*.85);cu.materials.append(mats[mat]);face.append(ob)
    ob.scale.x=sx;ob.scale.y=sy
    bpy.context.view_layer.update()
    if ob.dimensions.x>w*.01*sx: ob.scale.x*=w*.01*sx/ob.dimensions.x
def outline(x,y,w,h,mat):
    for a,b,c,d in [(x,y,w,6),(x,y+h-6,w,6),(x,y,6,h),(x+w-6,y,6,h)]:box(a,b,c,d,mat)

def soft_glow(x,y,w,h,mat):
    key='glow-mask-'+mat
    if key not in mats:
        im=bpy.data.images.get('Watch soft glow atlas')
        if im is None:
            path=runpy.run_path(str(Path(__file__).with_name('generate_watch_glass.py')))['generate_glow'](OUT/f'{revision:02d}-watch-glow.tga')
            im=bpy.data.images.load(str(path));im.name='Watch soft glow atlas';im.pack()
        ma=bpy.data.materials.new(key);ma.use_nodes=True;n=ma.node_tree.nodes;n.clear();l=ma.node_tree.links
        tex=n.new('ShaderNodeTexImage');tex.image=im
        emission=n.new('ShaderNodeEmission');emission.inputs[0].default_value=mats[mat].node_tree.nodes.get('Emission').inputs[0].default_value
        emission.inputs[1].default_value=1.4
        clear=n.new('ShaderNodeBsdfTransparent');mix=n.new('ShaderNodeMixShader')
        l.new(tex.outputs['Alpha'],mix.inputs[0]);l.new(clear.outputs[0],mix.inputs[1]);l.new(emission.outputs[0],mix.inputs[2])
        out=n.new('ShaderNodeOutputMaterial');l.new(mix.outputs[0],out.inputs[0]);mats[key]=ma
    xy=[(x-8,y-8),(x-8,y+h+8),(x+w+8,y+h+8),(x+w+8,y-8)]
    verts=[(*point(a,b)[:2],3.718) for a,b in xy]
    me=bpy.data.meshes.new('UI live preview | soft glow');me.from_pydata(verts,[],[(0,1,2,3)]);me.update()
    uv=me.uv_layers.new();oy=128 if h>100 else 0
    coords=[(0,1-oy/1024),(0,1-(oy+h+16)/1024),((w+16)/1024,1-(oy+h+16)/1024),((w+16)/1024,1-oy/1024)]
    for i,co in enumerate(coords):uv.data[i].uv=co
    ob=bpy.data.objects.new(me.name,me);scene.collection.objects.link(ob);me.materials.append(mats[key]);face.append(ob)

def clipped_outline(x,y,w,h,mat):
    if revision>=35:soft_glow(x,y,w,h,mat)
    elif revision>=32:
        color=mats[mat].node_tree.nodes.get('Emission').inputs[0].default_value
        for i in range(3,0,-1):
            key='glow-'+mat+str(i)
            if key not in mats:mats[key]=material(key,tuple(c/(i*3)**2.2 for c in color[:3]))
            xx=x-i*2;yy=y-i*2;ww=w+i*4;hh=h+i*4
            strokes=([(x+12,y-i*2,w-24,2),(x+12,y+h+i*2-2,w-24,2),
                      (x-i*2,y+12,2,h-24),(x+w+i*2-2,y+12,2,h-24)] if revision>=33 else
                     [(xx,yy,ww,3),(xx,yy+hh-3,ww,3),(xx,yy+3,3,hh-6),(xx+ww-3,yy+3,3,hh-6)])
            for a,b,c,d in strokes:box(a,b,c,d,key)
    elif revision>=28:
        key='glow-'+mat
        if key not in mats:
            color=mats[mat].node_tree.nodes.get('Emission').inputs[0].default_value
            mats[key]=material(key,tuple(c*.032 for c in color[:3]))
        for a,b,c,d in [(x-3,y-3,w+6,9),(x-3,y+h-6,w+6,9),(x-3,y+6,9,h-12),(x+w-6,y+6,9,h-12)]:box(a,b,c,d,key)
    for a,b,c,d in [(x+12,y,w-24,5),(x+12,y+h-5,w-24,5),(x,y+12,5,h-24),(x+w-5,y+12,5,h-24)]:box(a,b,c,d,mat)
    for i in range(0,12,2):
        for a,b in [(x+12-i,y+i),(x+w-17+i,y+i),(x+i,y+h-17+i),(x+w-5-i,y+h-17+i)]:box(a,b,5,5,mat)

def draw(mode):
    for ob in face: bpy.data.objects.remove(ob,do_unlink=True)
    face.clear()
    if revision>=29:
        path=runpy.run_path(str(Path(__file__).with_name('generate_watch_glass.py')))['generate'](OUT/f'{revision:02d}-watch-glass.tga')
        m=mats['backing'];nt=m.node_tree;n=nt.nodes
        tex=n.new('ShaderNodeTexImage');tex.image=bpy.data.images.load(str(path));tex.image.pack()
        coord=n.new('ShaderNodeTexCoord');nt.links.new(coord.outputs['Generated'],tex.inputs['Vector'])
        nt.links.new(tex.outputs['Color'],n.get('Emission').inputs[0])
        box(0,0,1024,512,'backing')
    elif revision>=28:
        def linear(v):
            s=v/255
            return s/12.92 if s<=.04045 else ((s+.055)/1.055)**2.4
        for row in range(128):
            tone=int(max(0,1-abs(row-38)/62)*11)
            key='backing-'+str(tone)
            if key not in mats:mats[key]=material(key,tuple(linear(v) for v in (8+tone,17+tone,19+tone)))
            box(0,row*4,1024,4,key)
            key='glass-scan-'+str(tone)
            if key not in mats:mats[key]=material(key,tuple(linear(v) for v in (10+tone,20+tone,22+tone)))
            box(0,row*4,1024,1,key)
        mats['glass-matrix']=material('glass-matrix',tuple(linear(v) for v in (12,22,24)))
        for x in range(4,1024,8):box(x,0,1,512,'glass-matrix')
    else:box(0,0,1024,512,'backing')
    critical=mode=='critical';health=23 if critical else 96;armor=0 if critical else 84
    tint='red' if critical else 'cyan'
    if revision >= 21:
        clipped_outline(26,80,448,88,tint);clipped_outline(26,232,448,88,'blue')
        clipped_outline(536,16,472,480,'red' if critical else 'amber')
    else:
        outline(16,16,472,480,tint);outline(536,16,472,480,'red' if critical else 'amber')
    text('HEALTH',40,38,292,38,tint);text(str(health),338,80,122,78,tint,True)
    for i in range(14):box(40+i*20,98,16,42,tint if i<int(14*health/100+.5) else 'track')
    text('ARMOR',40,190,292,38,'blue');text(str(armor),338,232,122,78,'blue',True)
    box(40,250,276,42,'track')
    if armor:box(40,250,276*armor/100,42,'blue')
    text('SYRINGE',40,344,206,34,'cyan');text('38%' if critical else 'READY',252,334,211,52,'cyan',True)
    box(40,418,420,24,'track');box(40,418,420*(.38 if critical else 1),24,'cyan')
    if mode=='trader':
        text('TRADER OPEN',560,40,420,38,'amber');text('0:47',560,100,420,86)
        text('DOSH 4,250',560,218,420,58,'amber');text('TRADER: 32m',560,300,420,30,'muted');text('TURN LEFT | HIGHER',560,346,420,32)
    else:
        text('WAVE 7 / 10',560,40,420,38,'amber');text('ZEDS LEFT',560,112,420,34,'muted')
        text('18',560,164,420,104);text('GRENADES',560,298,304,30,'muted');text('3',874,302,106,64,'cyan',True)
    box(560,402,420,2,'track')
    if critical:text('LOW HEALTH',560,428,420,36,'red')

scene.render.resolution_x=1600;scene.render.resolution_y=1050
scene.cycles.samples=40
cam=scene.camera;cam.location=(-4,-8,33);cam.rotation_euler=(Vector((-4,0,1))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=16
for mode in (['combat','trader','critical'] if render_previews else []):
    draw(mode);scene.render.filepath=str(OUT/f'{revision:02d}-{mode}.png');bpy.ops.render.render(write_still=True)
draw('combat')
cam.location=(5,-31,46);cam.rotation_euler=(-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=34
if render_previews:
    scene.render.filepath=str(OUT/f'{revision:02d}-hero.png');bpy.ops.render.render(write_still=True)
scene['status']='Approved functions, sample values. Live behavior implemented by VRSpatialHUD.'
if render_previews:
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT/f'{revision:02d}-watch-functions.blend'))
    (OUT/f'{revision:02d}-functions.json').write_text(json.dumps({'display_only':True,'persistent':['health','armor','syringe charge / ready'],'combat':['wave','zeds left / boss health','grenades'],'trader':['countdown','dosh','bearing / distance / elevation'],'alerts':['hazard','low health','low armor'],'sample_data_only':True},indent=2))
