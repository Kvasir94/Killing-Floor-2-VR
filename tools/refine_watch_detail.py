"""Physical watch finishing pass; centimetres in the canonical authoring frame.

The badge, screws, hinge and open bezel remain actual exportable geometry.
Weathering is authored in material nodes and baked by the production exporter.
"""
import math
import random
import bpy
import bmesh
from mathutils import Vector


def refine_watch(g, outer, inner):
    scene=g['scene']; mesh=g['mesh']; box=g['box']; tube=g['tube']
    cyl=g['cylinder']; text=g['text']; bevel=g['bevel']; web=g['web']
    rubber=g['rubber']; make=g['material']

    def metal(name, base, worn, rough=.43, metallic=.8):
        ma=make(name,base,rough,metallic,3,.008,worn)
        n=ma.node_tree.nodes; l=ma.node_tree.links; bs=n.get('Principled BSDF')
        co=n.new('ShaderNodeTexCoord')
        grain=n.new('ShaderNodeTexNoise');grain.inputs['Scale'].default_value=72
        grain.inputs['Detail'].default_value=2;l.new(co.outputs['Object'],grain.inputs['Vector'])
        roughness=n.new('ShaderNodeMapRange');roughness.inputs['To Min'].default_value=rough-.12
        roughness.inputs['To Max'].default_value=rough+.17
        l.new(grain.outputs['Fac'],roughness.inputs['Value']);l.new(roughness.outputs[0],bs.inputs['Roughness'])
        # Sparse pits, fine directional grinding and grime change with lighting.
        pit=n.new('ShaderNodeValToRGB');pit.color_ramp.elements[0].position=.31
        pit.color_ramp.elements[1].position=.40;l.new(grain.outputs['Fac'],pit.inputs[0])
        bump=n.new('ShaderNodeBump');bump.inputs['Distance'].default_value=.013
        bump.inputs['Strength'].default_value=.42;l.new(pit.outputs[0],bump.inputs['Height'])
        l.new(bs.inputs['Normal'].links[0].from_socket,bump.inputs['Normal']);l.new(bump.outputs[0],bs.inputs['Normal'])
        return ma

    body=metal('Watch | phosphate charcoal steel',(.023,.028,.025),(.070,.078,.065))
    face=metal('Watch | badge blackened bronze',(.025,.028,.022),(.067,.064,.047),.49,.72)
    if g['REV']>=36:
        bs=face.node_tree.nodes.get('Principled BSDF')
        ramp=bs.inputs['Base Color'].links[0].from_node
        ramp.color_ramp.elements[0].color=(.019,.023,.020,1)
        ramp.color_ramp.elements[1].color=(.051,.057,.046,1)
        rubber=make('Watch | scuffed cable jacket',(.004,.006,.005),.77,0,4,.014,(.036,.033,.024))
    edge=metal('Watch | brushed bevel alloy',(.13,.145,.13),(.29,.30,.255),.31,.87)
    if g['REV']>=35:
        for node in edge.node_tree.nodes:
            if node==edge.node_tree.nodes.get('Principled BSDF').inputs['Base Color'].links[0].from_node:
                node.color_ramp.elements[0].color=(.08,.09,.08,1)
                node.color_ramp.elements[1].color=(.20,.22,.19,1)
    dark=metal('Watch | fastener cavity',(.006,.007,.006),(.020,.023,.019),.61,.45)
    rust=make('Watch | trapped iron oxide',(.055,.027,.013),.88,.15,18,.012,(.16,.088,.037))
    ink=make('Watch | worn ivory badge enamel',(.25,.27,.23),.64,.08,23,.004,(.48,.50,.42))
    red=make('Watch | vermilion badge enamel',(.28,.009,.006),.47,.12,27,.004,(.57,.029,.012))
    if g['REV']>=31:
        n=edge.node_tree.nodes;l=edge.node_tree.links;bs=n.get('Principled BSDF')
        co=n.new('ShaderNodeTexCoord');noise=n.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=8
        noise.inputs['Detail'].default_value=4;l.new(co.outputs['Object'],noise.inputs['Vector'])
        mask=n.new('ShaderNodeValToRGB');mask.color_ramp.elements[0].position=.47
        mask.color_ramp.elements[1].position=.66;l.new(noise.outputs['Fac'],mask.inputs[0])
        worn=n.new('ShaderNodeMixRGB');l.new(mask.outputs[0],worn.inputs[0])
        l.new(bs.inputs['Base Color'].links[0].from_socket,worn.inputs[1]);worn.inputs[2].default_value=(.018,.022,.018,1)
        l.new(worn.outputs[0],bs.inputs['Base Color'])
    if g['REV']>=32:
        for ma in [body,face,edge]:
            n=ma.node_tree.nodes;l=ma.node_tree.links;bs=n.get('Principled BSDF')
            ao=n.new('ShaderNodeAmbientOcclusion');ao.inputs['Distance'].default_value=.32
            ao.samples=16;ao.only_local=g['REV']<35
            grime=n.new('ShaderNodeMixRGB');grime.blend_type='MULTIPLY';grime.inputs[0].default_value=.65
            l.new(bs.inputs['Base Color'].links[0].from_socket,grime.inputs[1]);l.new(ao.outputs['Color'],grime.inputs[2])
            l.new(grime.outputs[0],bs.inputs['Base Color'])
    if g['REV']>=28:
        for ma in [ink,red]:
            n=ma.node_tree.nodes;l=ma.node_tree.links;bs=n.get('Principled BSDF')
            co=n.new('ShaderNodeTexCoord');noise=n.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=94
            noise.inputs['Detail'].default_value=2;l.new(co.outputs['Object'],noise.inputs['Vector'])
            mask=n.new('ShaderNodeValToRGB');mask.color_ramp.elements[0].position=.32;mask.color_ramp.elements[0].color=(1,1,1,1)
            mask.color_ramp.elements[1].position=.41;mask.color_ramp.elements[1].color=(0,0,0,1)
            l.new(noise.outputs['Fac'],mask.inputs[0]);mx=n.new('ShaderNodeMixRGB')
            l.new(mask.outputs[0],mx.inputs[0]);l.new(bs.inputs['Base Color'].links[0].from_socket,mx.inputs[1])
            mx.inputs[2].default_value=(.026,.028,.020,1);l.new(mx.outputs[0],bs.inputs['Base Color'])
    for ob in scene.objects:
        if ob.type not in {'MESH','CURVE','FONT'}:continue
        if ob.name.startswith(('Watch |','Case |','ID plate','Conduit |','Cuff |')):
            for i,ma in enumerate(ob.data.materials):
                if ma==g['steel']:ob.data.materials[i]=body
                elif ma==g['bright']:ob.data.materials[i]=edge
                elif g['REV']>=36 and ma==g['rubber']:ob.data.materials[i]=rubber

    def remove(prefixes):
        for ob in list(scene.objects):
            if ob.name.startswith(prefixes):bpy.data.objects.remove(ob,do_unlink=True)

    def poly(name, xy, z, depth, ma, radius=.026):
        count=len(xy);vv=[(x,y,zz) for zz in (z-depth,z) for x,y in xy]
        ff=[tuple(reversed(range(count))),tuple(range(count,2*count))]
        ff += [(i,(i+1)%count,(i+1)%count+count,i+count) for i in range(count)]
        return bevel(mesh(name,vv,ff,ma),radius,3)

    def ring(name, xy, z, radius, ma):return tube(name,[(x,y,z) for x,y in xy],radius,ma,True)
    def torus(name,x,y,z,major,minor,ma):
        return tube(name,[(x+major*math.cos(i*math.tau/48),y+major*math.sin(i*math.tau/48),z) for i in range(48)],minor,ma,True)

    def screw(name,x,y,z,r=.115):
        cyl(name+' counterbore',(x,y,z-.025),r*1.38,.035,dark,vertices=32)
        torus(name+' beveled bore lip',x,y,z,r*1.16,.007 if g['REV']>=28 else .014,body if g['REV']>=28 else edge)
        cyl(name+' recessed head',(x,y,z-.011),r,.045,body,vertices=32)
        # Six-sided socket, inset in the head, with a worn lip and dark floor.
        cyl(name+' socket bevel',(x,y,z+.014),r*.52,.012,edge,vertices=6)
        cyl(name+' hex socket',(x,y,z+.021),r*.40,.010,dark,vertices=6)

    remove(('Horzine ','ID plate','Case | Horzine serial','Case | lower mounting',
            'Case | lower roller','Case | lower webbing','Watch | exposed chamfer',
            'Case | broken edge chip','Case | ribbed selector','Case | slotted button',
            'Case | recessed slot'))

    # Continuous outer chamfer is a faceted band, not a rounded silver wire.
    center=Vector((-3.9,0)); inset=[]
    for p in outer:
        q=Vector(p);inset.append(tuple(q+(center-q).normalized()*.12))
    count=len(outer);verts=[(x,y,z) for xy,z in [(outer,3.90),(inset,3.955)] for x,y in xy]
    ob=mesh('Watch | machined outer bevel',verts,[(i,(i+1)%count,(i+1)%count+count,i+count) for i in range(count)],edge)
    for p in ob.data.polygons:p.use_smooth=False
    ring('Watch | outer shell separation',outer,3.42,.023,dark)
    # An inset polished wall catches light around the real recessed display.
    ring('Watch | inner glass seating bevel',inner,3.825,.027,edge)
    ring('Watch | bezel dirt line',inner,3.79,.020,dark)
    if g['REV']>=29:
        remove(('Watch | open recessed protective rim',))
        # Successive slopes catch light independently, revealing a deep lens
        # seat without changing the established physical Canvas opening.
        shoulder=[tuple(Vector(p)+(center-Vector(p)).normalized()*.16) for p in outer]
        lip=[tuple(Vector(p)+(Vector(p)-center).normalized()*.085) for p in inner]
        if g['REV']>=32:
            shoulder=[tuple(Vector(a).lerp(Vector(b),.20)) for a,b in zip(outer,inner)]
            lip=[tuple(Vector(b).lerp(Vector(a),.20)) for a,b in zip(outer,inner)]
        outlines=[(outer,3.52),(outer,3.90),(shoulder,3.98),(lip,3.80),(inner,3.73),(inner,3.53)]
        vv=[(x,y,z) for xy,z in outlines for x,y in xy]
        ff=[(b*count+i,b*count+(i+1)%count,(b+1)*count+(i+1)%count,(b+1)*count+i) for b in range(5) for i in range(count)]
        rim=bevel(mesh('Watch | six level bevel housing',vv,ff,body),.018,2)
        rim.data.materials.append(edge);rim.data.materials.append(dark)
        for p in rim.data.polygons:
            band=p.index//count;p.material_index=1 if band in (1,3) else 2 if band==4 else 0;p.use_smooth=False

    # The reference has a trapezoid plaque overhanging a separate hinge bracket.
    xy=[(-2.46,-3.84),(1.32,-3.84),(1.32,-3.23),(.93,-2.86),(-1.95,-2.86),(-2.46,-3.30)]
    poly('Case | badge isolated gasket',xy,4.055,.10,rubber)
    poly('Case | badge bevel perimeter',xy,4.19,.16,edge,.045 if g['REV']>=32 else .026)
    mid=Vector((-.57,-3.37));smaller=[tuple(mid+(Vector(p)-mid)*.964) for p in xy]
    poly('Case | badge recessed face',smaller,4.215,.085,face,.036 if g['REV']>=32 else .017)
    # Small, nearly flush enamel letters: the emblem replaces O inside the word.
    h=text('Horzine maker H','H',-1.77,-3.40,4.218 if g['REV']>=28 else 4.235,.54,ink)
    rz=text('Horzine maker RZINE','RZINE',-1.065,-3.40,4.218 if g['REV']>=28 else 4.235,.54,ink)
    for ob in [h,rz]:ob.data.extrude=.001;ob.data.space_character=1.0
    ox=-1.298;oy=-3.218
    if g['REV']>=36:
        bold=bpy.data.fonts.load('C:/Windows/Fonts/arialbd.ttf');bold.pack()
        h.data.font=bold;rz.data.font=bold
        bpy.context.view_layer.update()
        hbb=[h.matrix_world@Vector(v) for v in h.bound_box]
        cap=(max(v.y for v in hbb)-min(v.y for v in hbb))
        rad=cap*.51 if g['REV']>=37 else .195
        gap=rad+.033
        ox=max(v.x for v in hbb)+gap
        oy=(min(v.y for v in hbb)+max(v.y for v in hbb))*.5
        rbb=[rz.matrix_world@Vector(v) for v in rz.bound_box]
        rz.location.x+=ox+gap-min(v.x for v in rbb)
        if g['REV']>=38:
            # The reference stencil has a muted red strike through I/N/E.
            marked=ink.copy();marked.name='Watch | maker stencil oxide strike';rz.data.materials[0]=marked
            n=marked.node_tree.nodes;l=marked.node_tree.links;bs=n.get('Principled BSDF')
            co=n.new('ShaderNodeTexCoord');sep=n.new('ShaderNodeSeparateXYZ');l.new(co.outputs['Object'],sep.inputs[0])
            def math_node(op,a,b=None):
                node=n.new('ShaderNodeMath');node.operation=op
                for i,value in enumerate([a,b] if b is not None else [a]):
                    if isinstance(value,(int,float)):node.inputs[i].default_value=value
                    else:l.new(value,node.inputs[i])
                return node.outputs[0]
            local=[Vector(v) for v in rz.bound_box];width=max(v.x for v in local)
            wave=math_node('SINE',math_node('MULTIPLY',sep.outputs['X'],8/width))
            center_line=math_node('ADD',math_node('MULTIPLY',wave,cap*.10),cap*.32)
            distance=math_node('ABSOLUTE',math_node('SUBTRACT',sep.outputs['Y'],center_line))
            stripe=math_node('LESS_THAN',distance,cap*.046)
            region=math_node('GREATER_THAN',sep.outputs['X'],width*.53)
            mix=n.new('ShaderNodeMixRGB');l.new(math_node('MULTIPLY',stripe,region),mix.inputs[0])
            l.new(bs.inputs['Base Color'].links[0].from_socket,mix.inputs[1]);mix.inputs[2].default_value=(.17,.012,.009,1)
            l.new(mix.outputs[0],bs.inputs['Base Color'])
        # Reference close-up: a continuous pale O surrounding a compact
        # three-lobed dark red mark, rather than a toothed turbine wheel.
        count_o=64;vv=[(ox+r*math.cos(i*math.tau/count_o),oy+r*math.sin(i*math.tau/count_o),4.242)
                       for r in [rad,rad*.74] for i in range(count_o)]
        mesh('Horzine emblem continuous O',vv,[(i,(i+1)%count_o,(i+1)%count_o+count_o,i+count_o) for i in range(count_o)],ink)
        crimson=make('Watch | compact crimson emblem',(.11,.004,.003),.66,.02,40,.002,(.27,.014,.009))
        for i in range(3):
            a=(90+120*i)*math.pi/180
            pts=[(ox+r*rad/.195*math.cos(a+t),oy+r*rad/.195*math.sin(a+t)) for r,t in
                 [(.146,-.69),(.148,-.30),(.142,.23),(.133,.70),(.085,.42),(.076,-.35)]]
            poly('Horzine emblem crimson triad',pts,4.244,.004,crimson,.001)
    if g['REV']<30:
        cyl('Horzine emblem engraved recess',(ox,oy,4.231),.184,.012,dark,vertices=48)
    # Twelve wedge-shaped teeth create the red/silver cog visible in the concept.
    for i in range(0 if g['REV']>=36 else 12):
        a=(i+.11)*math.tau/12;b=(i+.87)*math.tau/12
        xy2=[]
        for radius,angles in [(.181,[a+(b-a)*j/4 for j in range(5)]),(.144,[b-(b-a)*j/4 for j in range(5)])]:
            xy2.extend((ox+radius*math.cos(t),oy+radius*math.sin(t)) for t in angles)
        poly('Horzine emblem enamel teeth',xy2,4.246,.009,ink,.002)
        # Red inner blades have an angular inward bite, not a second round bead.
        aa=a+.04;bb=b-.025
        pts=[(ox+.143*math.cos(aa),oy+.143*math.sin(aa)),(ox+.143*math.cos(bb),oy+.143*math.sin(bb)),
             (ox+.099*math.cos(bb+.17),oy+.099*math.sin(bb+.17)),(ox+.104*math.cos(aa+.17),oy+.104*math.sin(aa+.17))]
        poly('Horzine emblem red rotor',pts,4.247,.010,red,.002)
    sub=text('Horzine serial','B I O T E C H',-.54,-3.665,4.234,.19,ink,'CENTER');sub.data.extrude=.001
    if g['REV']>=37:sub.data.size=.22
    if g['REV']>=28:
        sub.location.z=4.218
        for ob in scene.objects:
            if ob.name.startswith('Horzine emblem'):ob.location.z-=.022
    for x in [-2.18,1.05]:screw('ID plate captive screw',x,-3.60,4.231,.11)
    # Air gap, split ears and exposed pin make the plaque visibly load-bearing.
    for x in [-2.09,1.00]:
        box('Case | hinge bracket ear',(x,-3.84,3.59),(.33,.64,.88),body,.065)
        cyl('Case | hinge pivot collar',(x,-4.02,3.50),.255,.36,edge,(1,0,0),32)
    cyl('Case | exposed hinge axle',(-.55,-4.02,3.50),.128,3.48,dark,(1,0,0),32)
    cyl('Case | textured webbing roller',(-.55,-4.02,3.50),.205,2.36,web,(1,0,0),40)
    for x in [-1.79,.69]:cyl('Case | roller end ferrule',(x,-4.02,3.50),.22,.13,body,(1,0,0),32)
    box('Case | descending webbing tongue',(-.55,-4.15,3.12),(2.15,.22,.79),web,.035)
    box('Case | hinge bridge below tongue',(-.55,-4.28,2.76),(2.59,.28,.20),body,.045)
    for x in [-1.48,.38]:box('Case | webbing edge binding',(x,-4.285,3.13),(.055,.025,.69),g['thread'],.009)
    if g['REV']>=28:
        yarn=make('Watch | webbing coarse yarn',(.050,.042,.026),.90,0,28,.009,(.13,.111,.078))
        if g['REV']>=37:
            n=yarn.node_tree.nodes;l=yarn.node_tree.links;bs=n.get('Principled BSDF')
            coord=n.new('ShaderNodeTexCoord');noise=n.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=3.3
            noise.inputs['Detail'].default_value=4;l.new(coord.outputs['Object'],noise.inputs['Vector'])
            grime=n.new('ShaderNodeMapRange');grime.inputs['To Min'].default_value=.24;grime.inputs['To Max'].default_value=.95
            l.new(noise.outputs['Fac'],grime.inputs['Value']);shade=n.new('ShaderNodeMixRGB');shade.blend_type='MULTIPLY';shade.inputs[0].default_value=1
            l.new(bs.inputs['Base Color'].links[0].from_socket,shade.inputs[1]);l.new(grime.outputs[0],shade.inputs[2]);l.new(shade.outputs[0],bs.inputs['Base Color'])
        if g['REV']>=34:
            n=yarn.node_tree.nodes;l=yarn.node_tree.links;bs=n.get('Principled BSDF')
            ao=n.new('ShaderNodeAmbientOcclusion');ao.inputs['Distance'].default_value=.08;ao.samples=8;ao.only_local=g['REV']<35
            shade=n.new('ShaderNodeMixRGB');shade.blend_type='MULTIPLY';shade.inputs[0].default_value=.60
            l.new(bs.inputs['Base Color'].links[0].from_socket,shade.inputs[1]);l.new(ao.outputs['Color'],shade.inputs[2])
            l.new(shade.outputs[0],bs.inputs['Base Color'])
        # Interlaced physical yarns on the exposed front half of the roller;
        # evaluated high-to-low normal bake preserves the over/under relief.
        for i in range(68):
            x=-1.68+i*.034
            points=[]
            for j in range(31):
                t=-.16+j*math.pi/30;r=(.207 if g['REV']>=30 else .212)+.003*math.sin(j*math.pi*.61+i*math.pi)
                if g['REV']>=34:
                    r-=.012*math.exp(-((abs(x+.55)-1.09)/.18)**2)
                    r+=.003*math.sin(x*11+t*2.7)
                points.append((x,-4.02-r*math.cos(t),3.50+r*math.sin(t)))
            tube('Case | roller woven weft',points,.014 if g['REV']>=30 else .008,yarn)
        for j in range(20):
            t=-.12+j*math.pi/20;points=[]
            for i in range(137):
                x=-1.69+i*.017;r=(.206 if g['REV']>=30 else .215)+.004*math.cos(i*math.pi/2+j*math.pi)
                if g['REV']>=34:
                    r-=.012*math.exp(-((abs(x+.55)-1.09)/.18)**2)
                    r+=.003*math.sin(x*11+t*2.7)
                points.append((x,-4.02-r*math.cos(t),3.50+r*math.sin(t)))
            tube('Case | roller woven warp',points,.013 if g['REV']>=30 else .006,yarn)
        # Visible top webbing tabs carry compressed crossing fibers as well.
        for cx,cy,width in [(-.72,3.65,1.52),(-7.05,-3.15,1.12),(-7.05,3.0,1.12)]:
            z=4.225 if cx> -2 else 4.10
            for i in range(int(width/.038)):
                x=cx-width/2+.02+i*.038
                tube('Case | keeper woven thread',[(x,cy-.13,z),(x+.02,cy,z+.010),(x,cy+.13,z)],.006,yarn)
            if g['REV']>=34:
                for j in range(9):
                    y=cy-.13+j*.032
                    points=[(cx-width/2+.018+i*.019,y+.003*math.sin(i*.91+j),z+.007+.005*math.cos(i*math.pi/2+j*math.pi)) for i in range(int(width/.019))]
                    tube('Case | keeper compressed cross yarn',points,.011,yarn)
        rng_fiber=random.Random(284)
        for i in range(21):
            x=rng_fiber.choice([-1.70,.60])+rng_fiber.uniform(-.035,.025);z=rng_fiber.uniform(3.32,3.59)
            tube('Case | webbing short frayed fiber',[(x,-4.20,z),(x+rng_fiber.uniform(-.055,.055),-4.245,z+.055),(x+.022,-4.23,z+.10)],.004,yarn)

    # Knurled roller buried in its dark recess and recessed hex fasteners.
    if g['REV']>=51:
        # A transverse axle lets the thumb roll along the tall opening. The
        # old longitudinal stack of rings read as a fixed ribbed switch.
        remove(('Case | roller recess',))
        box('Case | roller recess',(1.68,0,3.985),(.57,1.56,.075),rubber,.08)
        cyl('Case | selector axle',(1.70,0,3.79),.105,.67,dark,(1,0,0),24)
        vv=[];ff=[];steps=128
        for x,scale in [(1.47,.94),(1.50,1),(1.88,1),(1.91,.94)]:
            for i in range(steps):
                a=i*math.tau/steps
                radius=(.573 if i%4 in (0,3) else .60)*scale
                vv.append((x,radius*math.sin(a),3.79+radius*math.cos(a)))
        for row in range(3):
            for i in range(steps):
                j=(i+1)%steps
                ff.append((row*steps+i,row*steps+j,(row+1)*steps+j,(row+1)*steps+i))
        ff.extend([tuple(reversed(range(steps))),tuple(range(3*steps,4*steps))])
        wheel=mesh('Case | selector thumbwheel',vv,[tuple(reversed(f)) for f in ff],body)
        wheel.data.materials.append(edge)
        for p in wheel.data.polygons:
            if p.index<steps*3:p.material_index=1 if p.index%4==1 else 0
        for x in [1.43,1.95]:
            cyl('Case | selector axle collar',(x,0,3.79),.15,.055,edge,(1,0,0),24)
    else:
        cyl('Case | selector barrel',(1.72,0,4.035),.27,1.36,body,(0,1,0),40)
        for j in range(11):
            y=-.61+j*.122
            cyl('Case | selector knurl',(1.72,y,4.035),.282,.037,edge,(0,1,0),32)
    for y in [-1.94,1.94]:screw('Case | control captive bolt',1.65,y,4.23,.145)

    # Broken chips accumulate on exposed edges, never an even all-over overlay.
    rng=random.Random(270924)
    for i in range(146):
        idx=rng.randrange(count);a=Vector((*outer[idx],3.965));b=Vector((*outer[(idx+1)%count],3.965))
        start=a.lerp(b,rng.random());direction=(b-a).normalized()
        offset=Vector((-direction.y,direction.x,0))*rng.uniform(.013,.10)
        start+=offset
        tube('Case | chipped finish',[start,start+direction*rng.uniform(.025,.12)],rng.uniform(.004,.013),edge)
    for i in range(35):
        x=rng.uniform(-2.28,1.18);y=rng.uniform(-3.79,-3.72)
        tube('Case | badge lower lip wear',[(x,y,4.233),(x+rng.uniform(.025,.10),y+.012,4.233)],.0045,edge)
    # Specks lie in actual fascia recesses and beside the mounting ears.
    for i in range(80):
        x=rng.uniform(-9.0,1.0);y=rng.choice([-2.90,2.83])+rng.uniform(-.08,.08)
        if -2.45<x<1.35 and y<0:continue
        r=rng.uniform(.008,.024)
        poly('Case | localized oxide pit',[(x-r,y-r),(x+r,y-r*.5),(x+r*.4,y+r)],3.953,.006,rust,.001)
    if g['REV']>=38:
        remove(('Case | top latch raised bail',))
        # A stamped channel with broad sloping cheeks, not round rod stock.
        channel=[(-2.04,3.66),(-2.22,3.25),(-1.95,3.05),(.53,3.05),(.76,3.28),(.58,3.66),
                 (.43,3.59),(.45,3.40),(.31,3.30),(-1.76,3.30),(-1.91,3.42),(-1.86,3.59)]
        if g['REV']>=48:
            channel=[(-2.04,3.66),(-2.22,3.25),(-1.96,3.05),(.52,3.05),(.78,3.25),(.60,3.66),
                     (.45,3.59),(.45,3.40),(.32,3.30),(-1.76,3.30),(-1.89,3.40),(-1.89,3.59)]
        latch=poly('Case | stamped latch channel',channel,4.235,.105,body if g['REV']>=39 else edge,.025)
        if g['REV']>=39:
            latch.data.materials.append(edge)
            next(m for m in latch.modifiers if m.type=='BEVEL').material=1
        poly('Case | latch recessed landing',[(-1.78,3.29),(.33,3.29),(.41,3.40),(-1.84,3.40)],4.125,.035,body,.018)
        for x in [-1.99,.51]:
            box('Case | latch tool witness',(x,3.22,4.237),(.038,.15,.005),dark,.006)
        # Side clasp faces have concave release cutouts and open strap slots
        # above and below, as on the reference's sculpted metal buckles.
        clasp=[(-.83,-.68),(.83,-.68),(.83,-.37),(.57,-.21),(.57,.21),(.83,.37),(.83,.68),
               (-.83,.68),(-.83,.37),(-.57,.21),(-.57,-.21),(-.83,-.37)]
        if g['REV']>=51:
            # Smooth concave waist of the stamped release buckle.
            def waist(t):
                u=1-t
                return (u**3*.83+3*u*u*t*.48+3*u*t*t*.48+t**3*.83,
                        u**3*(-.47)+3*u*u*t*(-.30)+3*u*t*t*.30+t**3*.47)
            right=[waist(i/20) for i in range(21)]
            clasp=[(-.83,-.68),(.83,-.68)]+right+[(.83,.68),(-.83,.68)]+[(-x,y) for x,y in reversed(right)]
        clasp_metal=metal('Watch | worn clasp steel',(.085,.093,.078),(.16,.175,.148),.52,.45) if g['REV']>=39 else body
        for x in [-7.05,-.60]:
            center=g['cuff_point'](x,math.pi,.72)+Vector((0,-.14,.68))
            plate=poly('Cuff | sculpted release clasp',clasp,.075,.14,clasp_metal,.055)
            if g['REV']>=39:
                plate.data.materials.append(edge);next(m for m in plate.modifiers if m.type=='BEVEL').material=1
            plate.rotation_euler.x=math.pi/2;plate.location=center+Vector((0,-.20,0))
            for dx in [-.52,.52]:
                for dz in [-.49,.49]:
                    cyl('Cuff | clasp captive pin',center+Vector((dx,-.29,dz)),.045,.035,dark,(0,1,0),20)
            z=min(g['cuff_point'](x+off,math.pi*1.5,.55).z for off in [-.9,0,.9])-.2
            plate=poly('Buckle sculpted release face',clasp,.075,.14,clasp_metal,.055)
            plate.rotation_euler.x=math.pi;plate.location=(x,0,z-.17)
        jacket_wear=make('Watch | rubbed cable bends',(.025,.030,.025),.69,0,36,.008,(.065,.061,.046))
        for x in [-7.35,.35]:
            tangent=Vector((0,.5,1)).normalized();origin=Vector((x,-4.04,2.27))
            for k in range(4 if g['REV']>=39 else 6):
                cyl('Conduit | elastomer relief rib',origin+tangent*(k-(1.5 if g['REV']>=39 else 2.5))*.074,
                    .191 if g['REV']>=39 else .237,.024 if g['REV']>=39 else .037,rubber,tangent,28)
            cyl('Conduit | relief end sleeve',origin-tangent*.27,.205 if g['REV']>=39 else .229,.12,body,tangent,28)
            if g['REV']>=39:
                cyl('Conduit | relief compression ferrule',origin-tangent*.245,.210,.035,edge,tangent,28)
            # Irregular rubbed streaks on the outward bend remain shallow.
            for k in range(4):
                dx=(k-1.5)*.038
                tube('Conduit | rubbed bend streak',[(x-.20+dx,-4.432,.82),(x-.28+dx,-4.402,.54),
                     (x-.36+dx,-4.31,.21)],.009 if k%2 else .013,jacket_wear)
        for o in scene.objects:
            if o.name.startswith('Conduit | strain relief'):
                o.data.materials.clear();o.data.materials.append(rubber)
                if g['REV']>=39:o.scale.x*=.80;o.scale.y*=.80
    if g['REV']>=40:
        # Scatter wear in a few irregular clusters, rather than a repeated row.
        remove(('Case | badge lower lip wear',))
        wear_rng=random.Random(400924)
        for i in range(13):
            x=wear_rng.choice([-2.14,-.82,.76])+wear_rng.uniform(-.15,.20)
            y=wear_rng.uniform(-3.80,-3.68);length=wear_rng.uniform(.020,.105)
            angle=wear_rng.uniform(-.42,.46)
            tube('Case | badge lower lip wear',[(x,y,4.227),(x+length*math.cos(angle),y+length*math.sin(angle),4.227)],
                 wear_rng.uniform(.0025,.0045),edge)
        def darken_fabric(original,name,factor):
            mat=original.copy();mat.name=name;n=mat.node_tree.nodes;l=mat.node_tree.links;bs=n.get('Principled BSDF')
            tone=n.new('ShaderNodeMixRGB');tone.blend_type='MULTIPLY';tone.inputs[0].default_value=1
            l.new(bs.inputs['Base Color'].links[0].from_socket,tone.inputs[1]);tone.inputs[2].default_value=(factor,)*3+(1,)
            l.new(tone.outputs[0],bs.inputs['Base Color']);return mat
        pressed=darken_fabric(web,'Watch | compressed dark nylon',.58)
        pressed_yarn=darken_fabric(yarn,'Watch | compressed keeper fibers',.58)
        for o in list(scene.objects):
            if o.name.startswith(('Case | keeper woven','Case | keeper compressed')):
                o.data.materials.clear();o.data.materials.append(pressed_yarn)
                for spline in o.data.splines:
                    for p in spline.points:
                        cx,cy,width=min([(-.72,3.65,1.52),(-7.05,-3.15,1.12),(-7.05,3.0,1.12)],key=lambda c:abs(p.co.y-c[1]))
                        p.co.z+=.010*math.sin(p.co.x*13+p.co.y*7)-.022*math.exp(-((abs(p.co.x-cx)-width*.5)/.10)**2)
            if not o.name.startswith(('Case | inset keeper webbing','Case | woven latch feed','Case | descending webbing tongue','Cuff | adjuster webbing feed')):continue
            top=o.name.startswith(('Case | inset keeper webbing','Case | woven latch feed'))
            if top:o.data.materials.clear();o.data.materials.append(pressed)
            bm=bmesh.new();bm.from_mesh(o.data)
            bmesh.ops.subdivide_edges(bm,edges=list(bm.edges),cuts=7,use_grid_fill=True)
            for v in bm.verts:
                x,y,z=v.co
                if top:v.co.z+=.014*math.sin(x*11+y*8)-.008*math.cos(x*17)
                elif g['REV']>=41:
                    # Pressure gathers around the two edge bindings and where
                    # the tongue enters the hinge, rather than uniform pleats.
                    hx=o.dimensions.x*.5;hz=o.dimensions.z*.5
                    left=math.exp(-((x+hx*.65)/(hx*.38))**2-((z-hz*.65)/(hz*.55))**2)
                    right=math.exp(-((x-hx*.60)/(hx*.32))**2-((z+hz*.42)/(hz*.75))**2)
                    compression=(2.5 if g['REV']>=52 else 1.8) if g['REV']>=51 and o.name.startswith('Cuff | adjuster webbing') else 1
                    v.co.y+=compression*(.080*left*math.sin(z*9+x*4)-.062*right*math.sin(z*13-x*3))
                else:v.co.y+=.052*math.sin(z*12+x*2.2)*(.45+.55*math.cos(x*2.1)**2)
            bm.to_mesh(o.data);bm.free();o.data.update()
            for modifier in o.modifiers:
                if modifier.type=='BEVEL':modifier.limit_method='ANGLE';modifier.angle_limit=.60
        fray_rng=random.Random(403)
        for cx,cy,width in [(-.72,3.65,1.52),(-7.05,-3.15,1.12),(-7.05,3.0,1.12)]:
            z=4.223 if cx>-2 else 4.102
            for k in range(7):
                x=cx+fray_rng.uniform(-width*.48,width*.48);y=cy+fray_rng.choice([-.145,.145])
                tube('Case | keeper short frayed edge',[(x,y,z),(x+fray_rng.uniform(-.025,.025),y+fray_rng.uniform(-.045,.045),z+.01)],.003,pressed_yarn)
    if g['REV']>=41:
        # Folded tabs have rounded, compressed fabric ends, not square cards.
        remove(('Case | inset keeper webbing','Case | woven latch feed'))
        tabs=[(-.72,3.65,1.52,4.225),(-7.05,-3.15,1.12,4.10),(-7.05,3.0,1.12,4.10)]
        for cx,cy,width,z in tabs:
            r=.151;points=[]
            for side in [1,-1]:
                for k in range(13):
                    angle=(-math.pi/2 if side==1 else math.pi/2)+k*math.pi/12
                    points.append((cx+side*(width*.5-r)+r*math.cos(angle),cy+r*math.sin(angle)))
            poly('Case | rounded compressed nylon keeper',points,z-.009,.11,pressed,.028)
        for o in scene.objects:
            if not o.name.startswith(('Case | keeper woven','Case | keeper compressed','Case | keeper short frayed')):continue
            for spline in o.data.splines:
                for p in spline.points:
                    cx,cy,width,z=min(tabs,key=lambda c:abs(p.co.x-c[0])+abs(p.co.y-c[1]))
                    dx=abs(p.co.x-cx);end=max(0,dx-(width*.5-.151))
                    limit=math.sqrt(max(.001,.151**2-end**2))
                    p.co.y=cy+max(-limit,min(limit,p.co.y-cy))
                    p.co.z-=.015*(end/.151)**2
        # Abrasion is strongest at outward-facing bends. Broad, broken patches
        # follow the cable jacket itself, so no detached floating wear strips.
        remove(('Conduit | rubbed bend streak',))
        for o in scene.objects:
            if not o.name.startswith(('Conduit | lower armored return','Conduit | upper service loop')):continue
            mat=rubber.copy();mat.name='Watch | contact-scuffed service jacket';o.data.materials.clear();o.data.materials.append(mat)
            n=mat.node_tree.nodes;l=mat.node_tree.links;bs=n.get('Principled BSDF')
            co=n.new('ShaderNodeTexCoord');sep=n.new('ShaderNodeSeparateXYZ');l.new(co.outputs['Object'],sep.inputs[0])
            noise=n.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=22;noise.inputs['Detail'].default_value=3;l.new(co.outputs['Object'],noise.inputs['Vector'])
            mask=n.new('ShaderNodeValToRGB');mask.color_ramp.elements[0].position=.43;mask.color_ramp.elements[1].position=.69;l.new(noise.outputs['Fac'],mask.inputs[0])
            region=n.new('ShaderNodeMapRange');region.clamp=True
            upper='upper' in o.name
            region.inputs['From Min'].default_value=3.92 if upper else -4.33
            region.inputs['From Max'].default_value=4.12 if upper else -4.47
            l.new(sep.outputs['Y'],region.inputs['Value'])
            multiply=n.new('ShaderNodeMath');multiply.operation='MULTIPLY';l.new(mask.outputs[0],multiply.inputs[0]);l.new(region.outputs[0],multiply.inputs[1])
            shade=n.new('ShaderNodeMixRGB');l.new(multiply.outputs[0],shade.inputs[0]);l.new(bs.inputs['Base Color'].links[0].from_socket,shade.inputs[1]);shade.inputs[2].default_value=(.105,.094,.070,1);l.new(shade.outputs[0],bs.inputs['Base Color'])
            rough=n.new('ShaderNodeMapRange');rough.inputs['To Min'].default_value=.77;rough.inputs['To Max'].default_value=.48;l.new(multiply.outputs[0],rough.inputs['Value']);l.new(rough.outputs[0],bs.inputs['Roughness'])
    if g['REV']>=42:
        # Contact at the exposed case lips interrupts the otherwise uniform
        # black sidewall. Keep the recessed middle dark so its depth survives.
        for o in list(scene.objects):
            if not o.name.startswith(('Watch | stepped shock chassis','Watch | layered armor foundation')):continue
            mat=o.data.materials[0].copy();mat.name='Watch | rubbed layered case edge';o.data.materials[0]=mat
            n=mat.node_tree.nodes;l=mat.node_tree.links;bs=n.get('Principled BSDF')
            co=n.new('ShaderNodeTexCoord');sep=n.new('ShaderNodeSeparateXYZ');l.new(co.outputs['Object'],sep.inputs[0])
            heights=(2.46,3.16) if 'shock' in o.name else (3.11,3.54)
            distances=[]
            for z in heights:
                sub=n.new('ShaderNodeMath');sub.operation='SUBTRACT';l.new(sep.outputs['Z'],sub.inputs[0]);sub.inputs[1].default_value=z
                absolute=n.new('ShaderNodeMath');absolute.operation='ABSOLUTE';l.new(sub.outputs[0],absolute.inputs[0]);distances.append(absolute.outputs[0])
            near=n.new('ShaderNodeMath');near.operation='MINIMUM';l.new(distances[0],near.inputs[0]);l.new(distances[1],near.inputs[1])
            lip=n.new('ShaderNodeMapRange');lip.inputs['From Max'].default_value=.18;lip.inputs['To Min'].default_value=1;lip.inputs['To Max'].default_value=0;l.new(near.outputs[0],lip.inputs['Value'])
            stretch=n.new('ShaderNodeVectorMath');stretch.operation='MULTIPLY';stretch.inputs[1].default_value=(2,2,14);l.new(co.outputs['Object'],stretch.inputs[0])
            noise=n.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=7;noise.inputs['Detail'].default_value=3;l.new(stretch.outputs[0],noise.inputs['Vector'])
            cut=n.new('ShaderNodeValToRGB');cut.color_ramp.elements[0].position=.48;cut.color_ramp.elements[1].position=.68;l.new(noise.outputs['Fac'],cut.inputs[0])
            mask=n.new('ShaderNodeMath');mask.operation='MULTIPLY';l.new(cut.outputs[0],mask.inputs[0]);l.new(lip.outputs[0],mask.inputs[1])
            shade=n.new('ShaderNodeMixRGB');l.new(mask.outputs[0],shade.inputs[0]);l.new(bs.inputs['Base Color'].links[0].from_socket,shade.inputs[1]);shade.inputs[2].default_value=(.14,.145,.119,1) if 'armor' in o.name else (.071,.067,.050,1);l.new(shade.outputs[0],bs.inputs['Base Color'])
        scratch_rng=random.Random(42924)
        for o in list(scene.objects):
            if not o.name.startswith(('Cuff | sculpted release clasp','Buckle sculpted release face')):continue
            bpy.context.view_layer.update()
            for k in range(7):
                x=scratch_rng.choice([-.55,.52])+scratch_rng.uniform(-.10,.09)
                y=scratch_rng.uniform(-.5,.5);length=scratch_rng.uniform(.04,.15)
                scratch=tube('Cuff | clasp contact scratch',[(x,y,.078),(x+length,y+.027,.078)],.0035,edge)
                scratch.matrix_world=o.matrix_world.copy()
    if g['REV']>=43:
        remove(('Cuff | clasp contact scratch',))
        for o in list(scene.objects):
            if not o.name.startswith(('Watch | stepped shock chassis','Cuff | sculpted release clasp','Buckle sculpted release face')):continue
            mat=o.data.materials[0].copy();mat.name='Watch | distributed hardware contact patina';o.data.materials[0]=mat
            n=mat.node_tree.nodes;l=mat.node_tree.links;bs=n.get('Principled BSDF')
            co=n.new('ShaderNodeTexCoord');sep=n.new('ShaderNodeSeparateXYZ');l.new(co.outputs['Object'],sep.inputs[0])
            stretch=n.new('ShaderNodeVectorMath');stretch.operation='MULTIPLY';l.new(co.outputs['Object'],stretch.inputs[0])
            case=o.name.startswith('Watch |')
            stretch.inputs[1].default_value=(1.5,2,12) if case else (7,4,1)
            noise=n.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=3.1;noise.inputs['Detail'].default_value=5;l.new(stretch.outputs[0],noise.inputs['Vector'])
            threshold=n.new('ShaderNodeValToRGB');threshold.color_ramp.elements[0].position=.46;threshold.color_ramp.elements[1].position=.65;l.new(noise.outputs['Fac'],threshold.inputs[0])
            mask=threshold.outputs[0]
            if case and g['REV']>=44:
                macro=n.new('ShaderNodeTexNoise');macro.inputs['Scale'].default_value=.92;macro.inputs['Detail'].default_value=2;l.new(co.outputs['Object'],macro.inputs['Vector'])
                patches=n.new('ShaderNodeValToRGB');patches.color_ramp.elements[0].position=.48;patches.color_ramp.elements[1].position=.63;l.new(macro.outputs['Fac'],patches.inputs[0])
                multiply=n.new('ShaderNodeMath');multiply.operation='MULTIPLY';l.new(mask,multiply.inputs[0]);l.new(patches.outputs[0],multiply.inputs[1]);mask=multiply.outputs[0]
            if not case:
                distances=[]
                for socket,edge_pos in [('X',.82),('X',.57),('Y',.68)]:
                    absolute=n.new('ShaderNodeMath');absolute.operation='ABSOLUTE';l.new(sep.outputs[socket],absolute.inputs[0])
                    sub=n.new('ShaderNodeMath');sub.operation='SUBTRACT';l.new(absolute.outputs[0],sub.inputs[0]);sub.inputs[1].default_value=edge_pos
                    distance=n.new('ShaderNodeMath');distance.operation='ABSOLUTE';l.new(sub.outputs[0],distance.inputs[0]);distances.append(distance.outputs[0])
                nearest=distances[0]
                for distance in distances[1:]:
                    node=n.new('ShaderNodeMath');node.operation='MINIMUM';l.new(nearest,node.inputs[0]);l.new(distance,node.inputs[1]);nearest=node.outputs[0]
                falloff=n.new('ShaderNodeMapRange');falloff.inputs['From Max'].default_value=.14;falloff.inputs['To Min'].default_value=1;falloff.inputs['To Max'].default_value=0;l.new(nearest,falloff.inputs['Value'])
                node=n.new('ShaderNodeMath');node.operation='MULTIPLY';l.new(mask,node.inputs[0]);l.new(falloff.outputs[0],node.inputs[1]);mask=node.outputs[0]
            mix=n.new('ShaderNodeMixRGB');l.new(mask,mix.inputs[0]);l.new(bs.inputs['Base Color'].links[0].from_socket,mix.inputs[1]);mix.inputs[2].default_value=(.052,.051,.039,1) if case else (.26,.25,.21,1);l.new(mix.outputs[0],bs.inputs['Base Color'])
    if g['REV']>=44:
        # The old wave frequency put over a hundred ridges in a centimetre,
        # which vanished into mottling at the export's sampling density. Match
        # the visible thread scale and orient the weave to each cloth surface.
        cloth_materials={ma for o in scene.objects if o.type in {'MESH','CURVE'} for ma in o.data.materials
                         if ma and ma.use_nodes and any(node.type=='TEX_WAVE' for node in ma.node_tree.nodes)}
        for ma in cloth_materials:
            n=ma.node_tree.nodes;l=ma.node_tree.links;bs=n.get('Principled BSDF')
            if not bs or not bs.inputs['Normal'].is_linked:continue
            bump=bs.inputs['Normal'].links[0].from_node
            if bump.type!='BUMP':continue
            co=n.new('ShaderNodeTexCoord');geom=n.new('ShaderNodeNewGeometry')
            absolute=n.new('ShaderNodeVectorMath');absolute.operation='ABSOLUTE';l.new(geom.outputs['True Normal'],absolute.inputs[0])
            sep=n.new('ShaderNodeSeparateXYZ');l.new(absolute.outputs[0],sep.inputs[0]);waves={}
            for axis in ['X','Y','Z']:
                wave=n.new('ShaderNodeTexWave');wave.bands_direction=axis;wave.inputs['Scale'].default_value=(7.0 if g['REV']>=53 else 5.6) if g['REV']>=52 and ma==web else 8.5;wave.inputs['Distortion'].default_value=.35;wave.inputs['Detail Scale'].default_value=1.8;l.new(co.outputs['Object'],wave.inputs['Vector']);waves[axis]=wave.outputs['Color']
            values=[]
            for a,b,normal in [('X','Y','Z'),('X','Z','Y'),('Y','Z','X')]:
                cross=n.new('ShaderNodeMath');cross.operation='MULTIPLY';l.new(waves[a],cross.inputs[0]);l.new(waves[b],cross.inputs[1])
                weighted=n.new('ShaderNodeMath');weighted.operation='MULTIPLY';l.new(cross.outputs[0],weighted.inputs[0]);l.new(sep.outputs[normal],weighted.inputs[1]);values.append(weighted.outputs[0])
            weave=values[0]
            for value in values[1:]:
                add=n.new('ShaderNodeMath');add.operation='ADD';l.new(weave,add.inputs[0]);l.new(value,add.inputs[1]);weave=add.outputs[0]
            l.new(weave,bump.inputs['Height']);bump.inputs['Distance'].default_value=.0055 if g['REV']>=45 else .012;bump.inputs['Strength'].default_value=.45 if g['REV']>=45 else .55
            if g['REV']>=51 and ma==web:
                if g['REV']>=52:
                    bump.inputs['Distance'].default_value=.007 if g['REV']>=53 else .011;bump.inputs['Strength'].default_value=.50 if g['REV']>=53 else .65
                    # Broad stains must not overpower the woven construction.
                    calm=n.new('ShaderNodeMixRGB');calm.inputs[0].default_value=.55
                    l.new(bs.inputs['Base Color'].links[0].from_socket,calm.inputs[1]);calm.inputs[2].default_value=(.10,.083,.052,1)
                    l.new(calm.outputs[0],bs.inputs['Base Color'])
                shade=n.new('ShaderNodeMapRange');shade.inputs['To Min'].default_value=.72 if g['REV']>=53 else .56 if g['REV']>=52 else .86;shade.inputs['To Max'].default_value=1.18 if g['REV']>=53 else 1.30 if g['REV']>=52 else 1.20;l.new(weave,shade.inputs['Value'])
                tint=n.new('ShaderNodeMixRGB');tint.blend_type='MULTIPLY';tint.inputs[0].default_value=1
                l.new(bs.inputs['Base Color'].links[0].from_socket,tint.inputs[1]);l.new(shade.outputs[0],tint.inputs[2]);l.new(tint.outputs[0],bs.inputs['Base Color'])
    if g['REV']>=52:
        # Shallow compressed bends at the strap hardware, using existing
        # contour stations. Fine yarns remain shader/bake detail, not geometry.
        for o in scene.objects:
            if o.type!='MESH' or not o.name.startswith('Cuff | webbing band'):continue
            for v in o.data.vertices:
                a=math.atan2(v.co.z+.3,v.co.y)
                pressure=math.exp(-((abs(v.co.y)-3.15)/.72)**2)
                radial=Vector((0,v.co.y,v.co.z+.3)).normalized()
                v.co+=radial*(.075*pressure*math.sin(a*13+v.co.x*1.8))
    if g['REV']>=30:
        bpy.context.view_layer.update()
        # Center the complete word by its visible bounds, including the emblem.
        letters=[o for o in scene.objects if o.name.startswith(('Horzine maker','Horzine emblem'))]
        xs=[(o.matrix_world@Vector(c)).x for o in letters for c in o.bound_box]
        correction=-.55-(min(xs)+max(xs))*.5
        for o in letters:o.location.x+=correction
        # Pane 2 occupies Canvas x=536..1008, so its authoring centre is -1.30.
        # Move and taper the complete bracket, hinge and lettering as one unit.
        badge_prefixes=('Horzine ','ID plate','Case | badge','Case | hinge',
                        'Case | exposed hinge','Case | textured webbing roller',
                        'Case | descending webbing','Case | roller end','Case | roller woven','Case | webbing')
        for o in scene.objects:
            if o.name.startswith(badge_prefixes):
                o.location.x=-1.30+(o.location.x+.55)*.92
                o.scale.x*=.92
                if g['REV']>=32:o.location.y+=.10
                if g['REV']>=33 and o.name.startswith(('Horzine ','ID plate','Case | badge')):
                    o.location.z-=.16
        # The load-bearing strap follows the relocated bracket, including its
        # underside buckle. The padded cuff saddle remains in its original fit.
        bpy.context.view_layer.update()
        for o in scene.objects:
            if o.name.startswith(('Cuff |','Buckle ','Folded webbing')) and 'saddle' not in o.name:
                xs=[(o.matrix_world@Vector(c)).x for c in o.bound_box]
                right=(min(xs)+max(xs))*.5>-3
                if g['REV']>=49:
                    # Cuff geometry is not stretched with the faceplate. Match
                    # both strap axes to the final stretched attachment centers.
                    o.location.x+=-.388 if right else -.378
                elif right:o.location.x-=.84
        scene['badge_center_canvas_x']=772
    if g['REV']>=48:
        # Move the complete upper assembly, including every cloth strand and
        # the dark recess, from its old -.72 axis onto screen two's -1.30 axis.
        bpy.context.view_layer.update()
        upper=('Case | top retention mounting','Case | latch opening',
               'Case | stamped latch','Case | latch recessed','Case | latch tool')
        cloth=('Case | rounded compressed nylon keeper','Case | keeper woven',
               'Case | keeper compressed','Case | keeper short frayed')
        for ob in scene.objects:
            selected=ob.name.startswith(upper)
            if ob.name.startswith(cloth):
                points=[ob.matrix_world@Vector(p) for p in ob.bound_box]
                selected=min(p.y for p in points)>3 and min(p.x for p in points)>-3
            if selected:ob.location.x-=.58
        scene['upper_bracket_center_canvas_x']=772
    if g['REV']>=50:
        # The aligned left clasp needs a clear cable lane beside its inner edge.
        # Move the full lower conduit, both sockets and strain-relief hardware.
        bpy.context.view_layer.update()
        for ob in scene.objects:
            if not ob.name.startswith('Conduit |'):continue
            points=[ob.matrix_world@Vector(p) for p in ob.bound_box]
            if max(p.y for p in points)<0 and (min(p.x for p in points)+max(p.x for p in points))*.5<-3:
                ob.location.x+=2.70
    if g['REV']>=55:
        # Left display tracks occupy Canvas x=26..474 (centre250). Move the
        # whole rear/forearm strap, its keeper and lower cable lane together.
        # Cuff parts do not receive the later 1.12 display stretch.
        bpy.context.view_layer.update()
        for ob in scene.objects:
            if ob.type not in {'MESH','CURVE','FONT'}:continue
            points=[ob.matrix_world@Vector(p) for p in ob.bound_box]
            cx=(min(p.x for p in points)+max(p.x for p in points))*.5
            if ob.name.startswith(('Cuff |','Buckle ','Folded webbing')) and 'saddle' not in ob.name and cx<-3:
                ob.location.x+=.5936
            elif ob.name.startswith('Case | attachment lug'):
                ob.location.x+=.53 if cx<-3 else -.70
            elif ob.name.startswith(('Case | wide strap keeper','Case | rounded compressed nylon keeper',
                                     'Case | keeper woven','Case | keeper compressed','Case | keeper short frayed')) and cx<-3:
                ob.location.x+=.53
            elif ob.name.startswith(('Case | upper stepped keeper','Case | keeper rivet')) and -6<cx<-4:
                ob.location.x+=.53
            elif ob.name.startswith('Conduit |') and max(p.y for p in points)<0 and cx<-3:
                ob.location.x+=.53
    if g['REV']>=56:
        # Relocated straps must be fitted again to the cuff at their new X,
        # rather than carrying the old anatomical cross-section sideways.
        from mathutils.bvhtree import BVHTree
        bpy.context.view_layer.update()
        dg=bpy.context.evaluated_depsgraph_get()
        saddle=next(o for o in scene.objects if o.name=='Cuff | padded leather saddle')
        evaluated=saddle.evaluated_get(dg);me=evaluated.to_mesh();me.calc_loop_triangles()
        cuff_tree=BVHTree.FromPolygons([saddle.matrix_world@v.co for v in me.vertices],
            [tuple(t.vertices) for t in me.loop_triangles],all_triangles=True)
        evaluated.to_mesh_clear()
        def outer_hit(origin,direction):
            hits=[tree.ray_cast(origin,direction) for tree in (g['bvh'],cuff_tree)]
            return min((h for h in hits if h[0] is not None),key=lambda h:h[3],default=None)
        def fitted_band(point,clearance):
            center=Vector((point.x,0,-.3));radial=Vector((0,point.y,point.z+.3)).normalized()
            hit=outer_hit(center+radial*20,-radial)
            if not hit:return point
            a=math.atan2(radial.z,radial.y)
            if g['REV']>=57:
                # The leather ends at a raised lip. Carry its thickness around
                # that lip with a short smooth ramp; a sudden ray-hit switch
                # from leather to skin otherwise cuts the connecting segment
                # through the leather, despite clearance at its end vertices.
                edge_angle=.21 if radial.y>0 else math.pi-.21
                edge_dir=Vector((0,math.cos(edge_angle),math.sin(edge_angle)))
                outer=cuff_tree.ray_cast(center+edge_dir*20,-edge_dir)
                skin=g['bvh'].ray_cast(center+edge_dir*20,-edge_dir)
                here=g['bvh'].ray_cast(center+radial*20,-radial)
                if outer[0] is not None and skin[0] is not None and here[0] is not None:
                    angle=math.acos(max(-1,min(1,radial.dot(edge_dir))))
                    thickness=max(0,(outer[0]-center).length-(skin[0]-center).length)
                    radius=(here[0]-center).length+thickness*math.exp(-(angle/.32)**2)
                    hit=(center+radial*max((hit[0]-center).length,radius),*hit[1:])
            pressure=.012*math.exp(-((abs(hit[0].y)-3.15)/.72)**2)*math.sin(a*13+point.x*1.8)
            if g['REV']>=58 and point.x<-3:
                # Local allowance under the housing for the cuff's convex
                # diagonal; no increase to exposed side-loop clearance.
                pressure+=.085*math.exp(-((a-.96)/.20)**2)
            return hit[0]+radial*(clearance+pressure)
        for ob in scene.objects:
            if not ob.name.startswith('Cuff | webbing band'):continue
            inv=ob.matrix_world.inverted()
            if ob.type=='MESH':
                for v in ob.data.vertices:v.co=inv@fitted_band(ob.matrix_world@v.co,.215 if g['REV']>=57 else .18)
                ob.data.update()
            elif ob.type=='CURVE':
                for spline in ob.data.splines:
                    for p in spline.points:
                        q=inv@fitted_band(ob.matrix_world@p.co.xyz,.24 if g['REV']>=57 else .205);p.co=(*q,1)
        # Keep the complete thickness of each folded feed outside the saddle.
        # Move paired front/back vertices together so the cloth is not flattened.
        for ob in scene.objects:
            if not ob.name.startswith('Cuff | adjuster webbing feed'):continue
            inv=ob.matrix_world.inverted();columns={}
            for v in ob.data.vertices:
                p=ob.matrix_world@v.co
                columns.setdefault((round(p.x,5),round(p.z,5)),[]).append((v,p))
            for column in columns.values():
                p=column[0][1];hit=outer_hit(Vector((p.x,-20,p.z)),Vector((0,1,0)))
                if not hit:continue
                shift=min(0,hit[0].y-.045-max(p.y for v,p in column))
                for v,p in column:v.co=inv@(p+Vector((0,shift,0)))
            ob.data.update()
    scene['watch_detail_revision']=g['REV']
