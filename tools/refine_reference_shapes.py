"""Concept-driven physical revisions, applied before wear fields and rigging.

All details are Blender geometry. The live display remains a separate Canvas.
Canonical hand coordinates are centimetres, X along the wrist, Z dorsal.
"""
import math
import random
import bpy
import bmesh
from mathutils import Vector

DISPLAY_SCALE = (1.12, .92)

def refine(g):
    scene=g['scene'];mesh=g['mesh'];box=g['box'];tube=g['tube'];cylinder=g['cylinder']
    plate=g['plate'];text=g['text'];surface=g['surface'];bevel=g['bevel']
    steel=g['steel'];bright=g['bright'];rubber=g['rubber'];web=g['web']
    leather=g['leather'];panel=g['panel'];edge=g['edge'];thread=g['thread']
    # Remove the uniform tablet housing and the flat dorsal strip construction.
    for ob in list(scene.objects):
        if ob.name.startswith(('Watch |','UI ','UI |','Case |','Horzine ','ID plate','Conduit |',
                               'LEFT | continuous scalloped','Dorsal tendon panel','Dorsal wrist welt')):
            bpy.data.objects.remove(ob,do_unlink=True)

    def path(name, pts, radius, mat): return tube(name,pts,radius,mat,True)
    def polyplate(name,xy,z,depth,mat):
        n=len(xy);vv=[(x,y,zz) for zz in [z-depth,z] for x,y in xy]
        ff=[tuple(reversed(range(n))),tuple(range(n,2*n))]
        ff += [(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
        return bevel(mesh(name,vv,ff,mat),.045,3)
    # A stepped left wing and raised right instrument bay, with clipped corners.
    outer=[(-9.72,-2.63),(-9.12,-3.21),(-5.1,-3.21),(-4.62,-3.52),
           (.72,-3.52),(1.78,-2.79),(1.78,2.71),(1.13,3.38),
           (-3.72,3.38),(-4.32,2.97),(-9.15,2.97),(-9.72,2.40)]
    if g['REV']>=30:
        # Lower instrument bay shoulders climb into the centered badge mount.
        # This replaces the long flat ledge beneath the second display.
        outer=[(-9.72,-2.63),(-9.12,-3.21),(-5.1,-3.21),(-4.62,-3.52),
               (-3.08,-3.52),(-2.70,-2.94),(.05,-2.94),(.48,-3.52),
               (.72,-3.52),(1.78,-2.79),(1.78,2.71),(1.13,3.38),
               (-3.72,3.38),(-4.32,2.97),(-9.15,2.97),(-9.72,2.40)]
    if g['REV']>=32:
        outer[:10]=[(-9.72,-2.60),(-9.20,-2.97),(-5.10,-2.97),(-4.65,-3.18),
                    (-3.03,-3.18),(-2.70,-2.77),(.05,-2.77),(.38,-3.18),
                    (.85,-3.18),(1.78,-2.62)]
    if g['REV']>=48:
        # Raised instrument-bay shoulder spans share screen two's x=-1.30 axis.
        outer[12]=(-3.73,3.38)
        outer[13]=(-4.38,2.97)
    polyplate('Watch | stepped shock chassis',outer,3.16,.70,rubber)
    polyplate('Watch | layered armor foundation',outer,3.54,.43,steel)
    # Cut a real opening into the protective rim. Each inner point follows the
    # corresponding ray from the display centre, retaining a continuous rim.
    inner=[]
    for x,y in outer:
        dx=x+3.9;dy=y;t=min(5.20/max(abs(dx),1e-6),2.64/max(abs(dy),1e-6))
        inner.append((-3.9+dx*t,dy*t))
    if g['REV']>=31:
        # Explicit correspondence keeps the concave badge shoulders from
        # folding the lens wall back over itself during radial projection.
        inner=[(-9.10,-2.30),(-8.94,-2.64),(-5.10,-2.64),(-4.62,-2.64),
               (-3.08,-2.64),(-2.70,-2.64),(.05,-2.64),(.48,-2.64),
               (.72,-2.64),(1.30,-2.34),(1.30,2.34),(1.0,2.64),
               (-3.72,2.64),(-4.32,2.64),(-8.94,2.64),(-9.10,2.30)]
        if g['REV']>=48:
            inner[12]=(-3.73,2.64)
            inner[13]=(-4.38,2.64)
    n=len(outer);vv=[]
    for outline,z in [(outer,3.51),(outer,3.94),(inner,3.86),(inner,3.52)]:
        vv.extend((x,y,z) for x,y in outline)
    ff=[]
    for band in range(3):
        for i in range(n):ff.append((band*n+i,band*n+(i+1)%n,(band+1)*n+(i+1)%n,(band+1)*n+i))
    bevel(mesh('Watch | open recessed protective rim',vv,ff,steel),.045,3)
    path('Watch | exposed chamfer metal',[(x,y,3.91) for x,y in outer],.065,bright)
    path('Watch | compressed perimeter seal',[(x,y,3.81) for x,y in inner],.048,rubber)
    plate('Watch | recessed dark lens',-3.9,0,10.27,5.16,3.65,.07,g['glass'],.19)
    box('Watch | central armored mullion',(-3.9,0,3.82),(.18,5.28,.20),steel,.04)
    # Upper retention latch and lower serial/mounting block are major silhouettes.
    plate('Case | top retention mounting',-.72,3.35,3.30,1.03,4.04,.22,steel,.25)
    box('Case | latch opening',(-.72,3.50,4.075),(2.37,.40,.10),rubber,.06)
    box('Case | woven latch feed',(-.72,3.65,4.10),(1.52,.37,.22),web,.08)
    tube('Case | top latch raised bail',[(-2.02,3.50,4.07),(-1.84,3.16,4.19),(.40,3.16,4.19),(.57,3.50,4.07)],.105,bright)
    plate('Case | lower mounting block',-.55,-3.62,3.45,1.45,3.82,.61,steel,.28)
    plate('Case | Horzine serial escutcheon',-.55,-3.28,3.71,1.09,4.02,.22,steel,.25)
    # The concept's maker mark uses a segmented red/silver O, not a plain O.
    text('Horzine maker H','H',-1.77,-3.32,4.05,.49,g['white'])
    text('Horzine maker RZINE','RZINE',-1.09,-3.32,4.05,.49,g['white'])
    red=g['emissive']('Markings | Horzine oxide red',(.43,.027,.022),.12)
    ox=-1.29;oy=-3.15
    cylinder('Horzine emblem dark inset',(ox,oy,4.065),.191,.018,rubber)
    for i in range(12):
        a=(i+.13)*2*math.pi/12;b=(i+.87)*2*math.pi/12
        pp=[(ox+.166*math.cos(a+(b-a)*j/5),oy+.166*math.sin(a+(b-a)*j/5),4.088) for j in range(6)]
        tube('Horzine emblem silver teeth',pp,.020,g['white'])
        pp=[(ox+.123*math.cos(a+(b-a)*j/5),oy+.123*math.sin(a+(b-a)*j/5),4.094) for j in range(6)]
        tube('Horzine emblem red segments',pp,.027,red)
    text('Horzine serial','B I O T E C H',-.55,-3.65,4.05,.21,g['white'],'CENTER')
    for x in [-2.05,.95]:
        cylinder('ID plate recessed rivet',(x,-3.47,4.07),.115,.045,rubber)
        cylinder('ID plate rivet',(x,-3.47,4.10),.070,.035,bright)
    box('Case | lower webbing feed',(-.55,-4.0,3.44),(2.13,.45,.45),web,.08)
    cylinder('Case | lower roller',(-.55,-4.17,3.55),.19,2.53,steel,(1,0,0))
    # Side control tower with protective ears, roller and individually inset bolts.
    box('Case | right control tower',(1.67,0,3.85),(.72,4.74,.53),steel,.11)
    box('Case | roller recess',(1.66,.03,4.04),(.32,1.40,.065),rubber,.065)
    for y in [-.51,-.34,-.17,0,.17,.34,.51]:
        box('Case | ribbed selector',(1.74,y,4.15),(.44,.105,.23),bright,.025)
    for y in [-1.94,1.94]:
        box('Case | protected side key',(1.65,y,4.095),(.55,.62,.23),bright,.08)
        cylinder('Case | slotted button',(1.65,y,4.18),.155,.05,steel)
        box('Case | recessed slot',(1.65,y,4.21),(.20,.03,.015),rubber,.005)
    for y in [-2.25,2.12]:box('Case | left keeper',(-9.42,y,3.84),(.52,.58,.26),steel,.08)
    box('Case | left offset service pod',(-9.57,-.52,3.19),(.78,2.52,.67),steel,.12)
    for y in [-1.20,-.75,-.30,.15]:box('Case | recessed side service vent',(-9.985,y,3.22),(.028,.19,.23),rubber,.015)
    for x in [-7.05,-.6]:
        # Retain the existing real anatomical web straps, add visible top/bottom
        # adjusters and tension tongues where the load enters the housing.
        if x < -2:
            for y in [-3.15,3.0]:
                box('Case | wide strap keeper',(x,y,3.87),(1.76,.52,.31),steel,.10)
                box('Case | inset keeper webbing',(x,y,4.05),(1.12,.30,.09),web,.025)
        for y in [-2.95,2.90]:
            box('Case | attachment lug',(x,y,2.78),(1.48,.65,.43),steel,.10)
    # Conduits have socket collars, bracket clips, and restrained bend radii.
    for x in [-7.35,.35]:
        pts=[(x,-3.47,2.99),(x,-4.04,2.27),(x-.18,-4.28,.72),
             (x-.58,-3.83,-.76),(x-1.03,-3.01,-1.07)]
        tube('Conduit | lower armored return',pts,.155,rubber)
        box('Conduit | bolted port housing',(x,-3.38,2.97),(.73,.44,.69),steel,.10)
        for p in [pts[0],pts[-1]]:
            cylinder('Conduit | machined socket',p,.31,.58,steel,(0,1,0))
            cylinder('Conduit | nickel compression collar',Vector(p)+Vector((0,-.25,0)),.27,.15,bright,(0,1,0))
        cylinder('Conduit | strain relief',pts[1],.225,.47,steel,(0,.5,1))
        cylinder('Conduit | clamp screw',Vector(pts[1])+Vector((0,-.16,.06)),.08,.12,bright,(0,1,0))
    # Visible load-bearing side adjusters on both anatomical wrap straps. These
    # are below the display and face the palm-side edge in a wrist inspection.
    for x in [-7.05,-.60]:
        center=g['cuff_point'](x,math.pi,.72)+Vector((0,-.14,.68))
        for dx in [-.91,.91]:box('Cuff | adjuster long rail',center+Vector((dx,0,0)),(.20,.28,2.10),steel,.065)
        for dz in [-.97,.97]:box('Cuff | adjuster return',center+Vector((0,0,dz)),(1.95,.28,.20),bright,.06)
        box('Cuff | adjuster webbing feed',center+Vector((0,.10,-.18)),(1.50,.13,2.56),web,.04)
        box('Cuff | central tension tongue',center+Vector((0,-.10,-.20)),(1.88,.25,.26),steel,.06)
        for dx in [-.72,.72]:cylinder('Cuff | adjuster pivot',center+Vector((dx,-.24,-.2)),.10,.12,bright,(0,1,0))
    tube('Conduit | upper service loop',[(-7.55,2.71,2.76),(-7.90,3.61,3.08),(-8.24,3.95,3.57),(-8.65,3.51,3.61),(-8.85,2.91,3.04)],.16,rubber)
    for x in [-7.55,-8.85]:cylinder('Conduit | upper socket',(x,2.91,3.01),.23,.46,steel,(0,1,0))
    for x in [-2.4,-1.9,-1.4]:box('Case | cooling port',(x,-3.55,3.21),(.30,.09,.20),rubber,.03)
    # Separated plates, captive rivets and localized chips interrupt the fascia.
    for x in [-8.20,-5.42]:
        plate('Case | upper stepped keeper',x,2.91,1.23,.39,4.035,.12,steel,.10)
        cylinder('Case | keeper rivet',(x+.42,2.92,4.10),.065,.045,bright)
    rng=random.Random(2309)
    for i in range(52):
        edge_i=rng.randrange(len(outer));a=Vector((*outer[edge_i],3.97));b=Vector((*outer[(edge_i+1)%len(outer)],3.97))
        t=rng.uniform(.12,.88);start=a.lerp(b,t);direction=(b-a).normalized()
        tube('Case | broken edge chip',[start,start+direction*rng.uniform(.04,.15)],rng.uniform(.010,.022),bright)
    if g['REV'] >= 27:
        import runpy
        runpy.run_path(str(g['ROOT']/'tools/refine_watch_detail.py'))['refine_watch'](g, outer, inner)
    # Widen and lower the complete device, including its attachments. This
    # leaves the anatomical wrist and original skin/bone coordinates intact.
    if g['REV']>=48:
        scene['upper_bay_center_cm']=-3.9+((outer[11][0]+outer[12][0])*.5+3.9)*DISPLAY_SCALE[0]
    for ob in scene.objects:
        if ob.name.startswith(('Watch |','Case |','Horzine ','ID plate','Conduit |')):
            ob.location.x=-3.9+(ob.location.x+3.9)*DISPLAY_SCALE[0]
            ob.location.y*=DISPLAY_SCALE[1]
            ob.scale.x*=DISPLAY_SCALE[0];ob.scale.y*=DISPLAY_SCALE[1]

    def tailored_patch(name,xy,height=.16,mat=panel):
        # Concentric surface rings keep the hem attached and crown softly padded.
        center=sum((Vector(p) for p in xy),Vector((0,0)))/len(xy)
        verts=[];faces=[];rings=9;n=len(xy)
        for j in range(rings):
            r=1-j/(rings-.2)
            for p in xy:
                q=center.lerp(Vector(p),r);v=Vector(surface(q.x,q.y,.245))
                v.z+=height*(1-r*r);verts.append(v)
        for j in range(rings-1):
            for i in range(n):faces.append((j*n+i,j*n+(i+1)%n,(j+1)*n+(i+1)%n,(j+1)*n+i))
        faces.append(tuple((rings-1)*n+i for i in range(n)))
        ob=mesh(name,verts,faces,mat);sol=ob.modifiers.new('Stitched pad thickness','SOLIDIFY');sol.thickness=.065
        boundary=[Vector(surface(x,y,.27)) for x,y in xy]
        path(name+' rolled seam',boundary,.050,edge)
        path(name+' seam recess',[p-Vector((0,0,.045)) for p in boundary],.082,rubber)
        for i,a in enumerate(boundary):
            b=boundary[(i+1)%n];length=(b-a).length
            for j in range(max(1,int(length/.22))):
                t=(j+.15)/max(1,int(length/.22));p=a.lerp(b,t);q=a.lerp(b,min(1,t+.09/max(length,.1)))
                tube(name+' stitching',[p+Vector((0,0,.04)),q+Vector((0,0,.04))],.016,thread)
        return ob

    # Four domed anatomical crowns, joined by a soft scalloped bridge. The rear
    # edge is curved; there is no longer a straight broad boxing-glove slab.
    nx=32;ny=64;verts=[];faces=[]
    for i in range(nx+1):
        u=i/nx
        for j in range(ny+1):
            v=j/ny;y=-4.18+6.77*v
            rear=5.52+.93*abs(2*v-1)**2
            front=9.67+.23*math.cos((v-.035)*8*math.pi)
            x=rear+(front-rear)*u;p=Vector(surface(x,y,.29))
            domes=sum(math.exp(-((y-yy)/.66)**2-((x-(8.57-.13*abs(yy)))/.83)**2) for yy in [-3.5,-1.62,.25,2.04])
            p.z+=.62*domes*math.sin(math.pi*u)**.4+.11*math.sin(math.pi*u)*math.sin(math.pi*v)
            verts.append(p)
    for i in range(nx):
        for j in range(ny):
            a=i*(ny+1)+j;faces.append((a,a+ny+1,a+ny+2,a+1))
    ob=mesh('LEFT | fitted four crown knuckle shield',verts,faces,panel)
    sol=ob.modifiers.new('Knuckle leather thickness','SOLIDIFY');sol.thickness=.08
    ids=list(range(ny+1))+[i*(ny+1)+ny for i in range(1,nx+1)]+[nx*(ny+1)+j for j in range(ny-1,-1,-1)]+[i*(ny+1) for i in range(nx-1,0,-1)]
    border=[verts[i]+Vector((0,0,.025)) for i in ids]
    path('Knuckle contoured raised welt',border,.048,edge)
    # A second curved welt follows the back of the crown, as on the reference.
    rear=[Vector(surface(5.19+.93*abs(2*j/ny-1)**2,-4.18+6.77*j/ny,.30)) for j in range(ny+1)]
    tube('Knuckle double rear seam',rear,.045,edge)
    for j in range(0,len(border)-2,2):tube('Knuckle saddle stitches',[border[j]+Vector((0,0,.04)),border[j+1]+Vector((0,0,.04))],.018,thread)
    # Curved metacarpal insert and lateral reinforcements replace parallel lines.
    tailored_patch('Dorsal | curved wrist reinforcement',[(1.05,-2.9),(1.3,-1.6),(1.7,-.7),(1.4,.5),(1.05,1.7),(2.0,2.1),(3.4,1.7),(4.8,.8),(5.13,-.3),(4.6,-1.7),(3.4,-2.65),(2,-3.05)],.17,leather)
    # Derive each stall from its real skinned surface, not an XY ray projection
    # that can accidentally hit the neighbouring finger across a web-space.
    for finger in ['Index','Middle','Ring','Pinky','Thumb']:
        base=g['glove'];ob=base.copy();ob.data=base.data.copy();ob.modifiers.clear()
        ob.name='Finger | anatomical '+finger+' reinforcement';scene.collection.objects.link(ob)
        ob.data.materials.clear();ob.data.materials.append(panel)
        bm=bmesh.new();bm.from_mesh(ob.data);bm.normal_update();deform=bm.verts.layers.deform.active
        group=base.vertex_groups.get('LeftHand'+finger+'1_1stP').index
        reject=[]
        for face in bm.faces:
            weight=sum(v[deform].get(group,0) for v in face.verts)/len(face.verts)
            if weight<.65 or face.normal.z<(.12 if finger=='Thumb' else .28):reject.append(face)
        bmesh.ops.delete(bm,geom=reject,context='FACES')
        bmesh.ops.delete(bm,geom=[v for v in bm.verts if not v.link_faces],context='VERTS')
        # Smooth the threshold contour so the stitched hems do not reproduce
        # the jagged triangle selection boundary of the source skin.
        bv=[v for v in bm.verts if any(e.is_boundary for e in v.link_edges)]
        for iteration in range(12):
            moves={}
            for v in bv:
                near=[e.other_vert(v) for e in v.link_edges if e.is_boundary]
                if len(near)==2:moves[v]=v.co.lerp((near[0].co+near[1].co)*.5,.6)
            for v,co in moves.items():v.co=co
        bm.normal_update()
        for v in bm.verts:
            w=v[deform].get(group,0);v.co+=v.normal*(.075+.10*max(0,w-.65)/.35)
        boundary=set(e for e in bm.edges if e.is_boundary)
        while boundary:
            e=boundary.pop();start=e.verts[0];v=e.verts[1];pp=[start.co.copy(),v.co.copy()]
            while v!=start:
                nxt=next((ed for ed in v.link_edges if ed in boundary),None)
                if nxt is None:break
                boundary.remove(nxt);v=nxt.other_vert(v);pp.append(v.co.copy())
            tube('Finger | '+finger+' reinforced hem',pp,.039,edge,v==start)
        bm.to_mesh(ob.data);bm.free()
        so=ob.modifiers.new('Finger pad leather','SOLIDIFY');so.thickness=.04
    # Organic compression folds at the wrist transition, short and asymmetric.
    for j in range(7):
        yy=-2.9+j*.76
        pp=[surface(.75+k*.15,yy+.10*math.sin(k*.55+j),.235+.035*math.sin(k*math.pi/9)) for k in range(10)]
        tube('Glove | wrist compression fold',pp,.045,leather)
    scene['display_size_cm']=[10.24*DISPLAY_SCALE[0],5.12*DISPLAY_SCALE[1]]
    scene['concept_revision']='Stepped landscape chassis, recessed rim, load-bearing hardware, articulated leather crowns'
