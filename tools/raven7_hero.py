"""Construction traced from the left hero in the supplied 1491x1055 sheet.

Landmarks are image pixels, transformed into the weapon's centimetre frame.
They describe geometry, never a camera-facing image plane. Both sides and the
cross section are built; panel depths are inferred where the sheet is ambiguous.
"""
import math
import bpy
import bmesh
from mathutils import Vector

def build(prism,cut,strip,bolt,mats,scene,parts,rng):
    def xy(p):
        dx,dz=p[0]-285,p[1]-600
        return ((-.96*dx-.28*dz)/29.2,(.28*dx-.96*dz)/29.2)
    def plate(name,pts,slot=2,half=.45,y=0,bevel=.060):
        if slot==1 and not name.startswith('Cloth'):slot=7 # Mechanical ceramic must never inherit fabric.
        coords=[xy(p) for p in pts]
        if name.startswith(('Tracking','Recall luminous','Inductor')):
            cx,cz=xy((438,238));coords=[(x,cz+(z-cz)*1.25) for x,z in coords]
        ob=prism(name,coords,half,slot,y,bevel)
        if name.startswith('Recall luminous'):
            ob.data.materials.append(mats[7])
            for p in ob.data.polygons:
                if abs(p.normal.y)<.8:p.material_index=len(ob.data.materials)-1
        if name=='Pommel tungsten cage':
            # Narrow the terminal and shoulders in thickness without changing
            # the reference footprint; the side coil retains its own projection.
            for v in ob.data.vertices:
                t=(v.co.z-min(z for x,z in coords))/max(.01,max(z for x,z in coords)-min(z for x,z in coords))
                v.co.y*=.64+.36*max(0,math.sin(math.pi*t))**.5
        return ob
    def hole(ob,pts):cut(ob,[xy(p) for p in pts])
    def rail(name,pts,width=3,slot=0,y=.65,half=.025):
        if slot==1:slot=7
        coords=[xy(p) for p in pts]
        if name.startswith(('Tracking','Recall luminous','Inductor')):
            cx,cz=xy((438,238));coords=[(x,cz+(z-cz)*1.25) for x,z in coords]
        return strip(name,coords,width/29.2,slot,y,half)
    def screw(p,r=3,y=.73):
        x,z=xy(p);bolt(x,z,y,r/29.2)
    def ring(name,p,r=3,width=1,slot=3,y=.84):
        pts=[(p[0]+r*math.cos(i*math.tau/16),p[1]+r*math.sin(i*math.tau/16)) for i in range(17)]
        rail(name,pts,width,slot,y,.015)
    def pocket(ob,name,contour,depth,bevel=.16,flare=1.14):
        # Explicit planar chamfers and continuous interior walls. Boolean
        # bevels on tiny concave corners otherwise collapse to almost zero.
        cx=sum(p[0] for p in contour)/len(contour);cz=sum(p[1] for p in contour)/len(contour)
        outer=[(cx+(x-cx)*flare,cz+(z-cz)*flare) for x,z in contour]
        hole(ob,outer)
        vv=[];nn=len(contour)
        for pts,y in ((outer,-depth),(contour,-depth+bevel),(contour,depth-bevel),(outer,depth)):
            vv.extend((xy(p)[0],y,xy(p)[1]) for p in pts)
        ff=[(j*nn+i,j*nn+(i+1)%nn,(j+1)*nn+(i+1)%nn,(j+1)*nn+i) for j in range(3) for i in range(nn)]
        me=bpy.data.meshes.new(name);me.from_pydata(vv,[],ff);me.update()
        po=bpy.data.objects.new(name,me);scene.collection.objects.link(po);parts.append(po)
        me.materials.append(ob.data.materials[0]);me.materials.append(mats[2])
        for p in me.polygons:p.material_index=1 if nn<=p.index<2*nn else 0
        return po
    def structural(name,pts,half,bevel):
        # Explicit perimeter facets keep their authored width even at concave
        # notches; a global bevel modifier clamps every edge to the tiniest one.
        ob=plate(name,pts,0,half,bevel=0)
        pp=[xy(p) for p in pts];n=len(pp)
        sign=1 if sum(pp[i][0]*pp[(i+1)%n][1]-pp[(i+1)%n][0]*pp[i][1] for i in range(n))>0 else -1
        inset=[]
        for i,(x,z) in enumerate(pp):
            ax,az=pp[i-1];bx,bz=pp[(i+1)%n]
            d0=math.hypot(x-ax,z-az);d1=math.hypot(bx-x,bz-z)
            n0=(-sign*(z-az)/d0,sign*(x-ax)/d0);n1=(-sign*(bz-z)/d1,sign*(bx-x)/d1)
            nx,nz=n0[0]+n1[0],n0[1]+n1[1];dd=max(.001,math.hypot(nx,nz));nx/=dd;nz/=dd
            step=min(bevel*2,bevel/max(.5,nx*n1[0]+nz*n1[1]))
            inset.append((x+nx*step,z+nz*step))
        vv=[(x,y,z) for points,y in ((inset,-half),(pp,-half+bevel),(pp,half-bevel),(inset,half)) for x,z in points]
        ff=[tuple(reversed(range(n))),tuple(range(3*n,4*n))]
        ff += [(k*n+i,k*n+(i+1)%n,(k+1)*n+(i+1)%n,(k+1)*n+i) for k in range(3) for i in range(n)]
        ob.data.clear_geometry();ob.data.from_pydata(vv,[],ff);ob.data.update()
        ob.data.materials.append(mats[2])
        for p in ob.data.polygons:
            if 2+n<=p.index<2+2*n:p.material_index=len(ob.data.materials)-1
        bpy.ops.object.select_all(action='DESELECT');ob.select_set(True);bpy.context.view_layer.objects.active=ob
        bpy.ops.object.mode_set(mode='EDIT');bpy.ops.mesh.select_all(action='SELECT');bpy.ops.mesh.normals_make_consistent(inside=False);bpy.ops.object.mode_set(mode='OBJECT')
        return ob
    # Thin asymmetric forged crescent, not a uniform extrusion or broad badge.
    outer=[(194,20),(181,38),(166,69),(155,98),(147,135),(143,176),(145,213),(151,248),(164,282),(180,314),(200,345)]
    inner=[(210,292),(220,250),(212,233),(199,215),(189,191),(187,163),(191,130),(201,102),(215,74),(226,65)]
    def curved(points,steps=4):
        out=[]
        for i in range(len(points)-1):
            p0=points[max(0,i-1)];p1=points[i];p2=points[i+1];p3=points[min(len(points)-1,i+2)]
            for j in range(steps):
                t=j/steps
                out.append(tuple(.5*(2*p1[a]+(-p0[a]+p2[a])*t+(2*p0[a]-5*p1[a]+4*p2[a]-p3[a])*t*t+(-p0[a]+3*p1[a]-3*p2[a]+p3[a])*t*t*t) for a in range(2)))
        return out+[points[-1]]
    outer=curved(outer)
    plate('Forged swept blade',outer+inner,6,.24,bevel=.012)
    # Wedge section: the forged inner shoulder is thick, the whole cutting
    # lip is thin. Retain the bevel's interior vertices rather than an apex hack.
    bladeparts=parts[-1:]
    outer_local=[xy(p) for p in outer];inner_local=[xy(p) for p in inner]
    for v in bladeparts[0].data.vertices:
        do=min(math.hypot(v.co.x-x,v.co.z-z) for x,z in outer_local)
        di=min(math.hypot(v.co.x-x,v.co.z-z) for x,z in inner_local)
        v.co.y*=.20+.80*do/max(.0001,do+di)
    for side in (-1,1):
        rail('Continuous cyan cutting edge',outer,4.0,3,side*.055,.009)
        rail('Blade energy luminous core',outer,1.15,3,side*.073,.008)
        plate('Dark forged inner blade shoulder',[(209,73),(197,111),(188,158),(191,197),(210,235),(216,252),(209,293),(201,330),(206,287),(211,253),(202,233),(184,199),(180,158),(190,108),(202,74)],2,.014,side*.239,.008)
        rail('Blade inner ground shoulder',[(208,79),(192,112),(180,160),(184,204),(204,250),(201,330)],2.0,0,side*.28,.014)
    # Dark interlocking chassis with a small irregular chamfered window.
    chassis=[(216,64),(264,83),(315,106),(381,135),(445,163),(499,190),(511,213),(500,244),(476,265),(437,278),(407,302),(371,312),(345,298),(335,261),(331,230),(310,208),(285,195),(270,195),(254,204),(237,222),(220,247),(207,275),(192,237),(183,200),(181,163),(190,117)]
    main=plate('Carbon ceramic head chassis',chassis,2,.47,bevel=.038)
    window=[(234,91),(248,94),(294,114),(300,123),(293,136),(280,142),(244,125),(239,115)]
    hole(main,window)
    hole(main,[(425,210),(464,218),(475,230),(461,257),(436,275),(408,277),(403,261),(412,229)])
    # Actual armor overlaps define the mechanical structure around the throat.
    for side in (-1,1):
        rail('Head window worn rim',window+[window[0]],2.1,0,side*.51,.018)
        cheek=plate('Blade root ceramic cheek',[(214,83),(229,89),(224,119),(218,143),(217,179),(223,199),(217,218),(207,226),(192,202),(189,170),(196,124)],2,.047,side*.52)
        hole(cheek,[(215,140),(223,142),(217,176),(211,184),(208,179),(210,151)])
        rail('Recessed blade indicator',[(216,147),(214,162),(212,178),(211,190),(210,200)],2.2,3,side*.585,.011)
        for yy in [155,169,183]:rail('Indicator interruption',[(210,yy),(220,yy+2)],2.3,2,side*.605,.018)
        rail('Lower throat reinforcement',[(207,259),(224,231),(244,208),(268,193),(285,191),(316,204),(340,230),(341,267)],5.7,1,side*.52,.07)
        rail('Throat exposed titanium',[(220,235),(244,209),(269,194),(284,193),(313,207),(332,228),(338,258)],1.8,0,side*.60,.019)
        plate('Throat diagonal reinforcement',[(326,230),(335,235),(348,273),(339,293),(332,265)],0,.035,side*.60)
        # A quiet central warning panel with an irregular seam, not a separate badge.
        rail('Central armor seam',[(225,120),(239,141),(273,153),(290,170),(334,189),(361,181)],1,1,side*.505,.008)
    # Tall diagonal structural strut is the near side of the recall frame.
    for side in (-1,1):
        plate('Module dark backing',[(401,171),(466,190),(497,207),(489,243),(474,272),(439,290),(405,307),(367,304),(368,286)],1,.075,side*.19)
        plate('Recall structural left strut',[(397,178),(426,190),(402,281),(384,302),(362,292)],0,.20,side*.71)
        plate('Strut ceramic face',[(398,184),(417,192),(395,277),(381,293),(367,288)],2,.035,side*.925)
        rail('Strut silver side lip',[(398,184),(375,282),(381,293)],1.5,0,side*.972,.014)
        # Separate right/bottom frame has a changing width and several steps.
        rim=[(429,193),(470,204),(489,217),(480,249),(466,270),(444,278),(434,291),(403,300),(399,289),(429,282),(437,271),(460,259),(469,244),(475,222),(464,216),(427,204)]
        plate('Recall offset right and lower rim',rim,0,.10,side*.78)
        rail('Module inner right wall',[(475,222),(469,244),(460,259),(437,271),(429,282)],4.1,2,side*.53,.23)
        plate('Recall rim dark upper inlay',[(451,204),(470,211),(479,219),(473,229),(465,226),(465,218),(450,213)],2,.025,side*.90)
        # Recessed core: offset tracks, folded metal, black cavity and status LED.
        plate('Tracking unit outer housing',[(433,217),(456,224),(466,234),(457,258),(439,269),(425,260),(423,246)],2,.17,side*.63,.07)
        plate('Tracking unit beveled central body',[(438,226),(454,231),(454,253),(443,262),(432,255),(432,239)],2,.11,side*.81,.06)
        plate('Tracking unit recessed front',[(440,234),(450,237),(449,253),(442,257),(436,252)],7,.035,side*.93,.025)
        plate('Tracking angular upper hood',[(432,221),(444,218),(456,225),(451,232),(440,229),(431,226)],2,.105,side*.91,.065)
        plate('Tracking folded left cover',[(432,233),(437,235),(435,251),(431,256),(427,253),(428,241)],2,.080,side*.91,.040)
        rail('Tracking cover bright facet',[(432,233),(437,235),(435,251)],1.2,0,side*1.015,.018)
        rail('Tracking hood dark vent',[(440,222),(450,226)],1.7,7,side*1.025,.015)
        # The signature cyan piece is a large recessed prismatic coil on the
        # left of the tracking unit, not an outline surrounding a flat badge.
        plate('Recall luminous inductor',[(424,216),(435,220),(426,249),(415,247),(416,236)],3,.14,side*.72,.060)
        plate('Recall luminous lower connector',[(414,248),(421,251),(427,260),(419,259),(412,253)],3,.085,side*.71,.018)
        rail('Inductor black casing',[(424,214),(436,218),(429,247),(427,250)],2.7,2,side*.85,.05)
        rail('Inductor left rim',[(420,219),(412,244),(412,252),(419,260)],2.5,2,side*.82,.04)
        for a,b in [((418,228),(421,229)),((415,241),(419,242))]:rail('Inductor ceramic interruption',[a,b],1.8,7,side*.89,.023)
        plate('Recall luminous long window',[(427,222),(432,223),(425,246),(420,247)],3,.025,side*.89,.015)
        for a,b in [((423,224),(421,231)),((419,237),(417,244))]:rail('Inductor reflected slit',[a,b],1.0,5,side*.90,.010)
        for a,b in [((424,215),(434,218)),((412,249),(420,252))]:rail('Inductor silver terminal',[a,b],2.4,0,side*.86,.035)
        plate('Tracking top machined support',[(433,214),(445,218),(443,225),(433,226),(429,223)],0,.075,side*.90,.027)
        rail('Tracking right machined support',[(455,227),(462,232),(460,240)],2.9,0,side*.925,.04)
        rail('Tracking lower folded support',[(430,256),(438,263),(451,259)],2.6,0,side*.87,.035)
        ring('Tracking status LED',(443,254),3.2,1.2,3,side*.982)
        for p in [(442,241),(441,246)]:ring('Tracking dark sensor',p,1.0,.7,2,side*.975)
    for p,r,y in [((410,192),4.5,.98),((381,284),4.8,.98),((480,218),3,.91),((475,240),3.5,.91),((465,258),3,.91),((417,290),3.8,.91),((453,205),2,.95)]:screw(p,r,y)
    # Spine is a stepped channel with offset latches and long red insets.
    spine=[(210,55),(248,77),(302,96),(352,120),(400,141),(453,163),(510,188),(523,208),(508,218),(450,188),(398,165),(348,145),(299,122),(246,97),(218,79)]
    spine_ob=plate('Spine titanium channel',spine,0,.59,bevel=.085)
    hole(spine_ob,window)
    for side in (-1,1):
        rail('Spine dark slot',[(223,68),(260,87),(310,109),(359,130),(404,151),(456,174),(508,198)],4,1,side*.62,.021)
        for start,end in [((254,83),(274,91)),((299,103),(319,112)),((350,126),(370,135)),((442,166),(462,175)),((482,184),(508,195))]:
            rail('Spine locking shoe',[start,end],7,2,side*.66,.057)
        for start,end in [((380,137),(423,155)),((465,174),(494,187))]:rail('Recessed red spine key',[start,end],2.2,4,side*.729,.012)
        for p in [(273,91),(324,113),(362,130),(433,159)]:
            ring('Spine socket',p,2.8,1,0,side*.728)
    # Rear spike is a three-plane wedge with a recessed ferrule.
    collar=[(510,207),(527,214),(536,234),(529,256),(515,268),(493,259),(500,228)]
    plate('Rear spike ferrule',collar,1,.64)
    for side in (-1,1):
        rail('Ferrule raised rib',[(519,214),(526,229),(521,251),(513,260)],4.8,2,side*.68,.04)
    plate('Piercing spike',[(533,225),(605,282),(523,263)],0,.14,bevel=.008)
    for side in (-1,1):
        plate('Spike faceted steel plane',[(536,237),(605,282),(523,263)],0,.04,side*.19,bevel=.008)
        rail('Spike center ridge',[(536,237),(605,282)],1.3,0,side*.25,.015)
        for p in [(547,251),(564,262)]:ring('Spike shallow socket',p,1.3,.6,1,side*.254)
    # Neck: two joined structural planes, with real machined wall sections.
    neck_start=len(parts)
    neck=structural('Titanium neck front frame',[(344,294),(370,305),(393,299),(414,290),(415,310),(401,349),(381,366),(371,396),(352,443),(323,427),(321,399),(330,351)],.67,.18)
    pocket(neck,'Neck triangular pocket walls',[(354,321),(379,327),(368,352),(362,349)],.67,.20)
    pocket(neck,'Neck elongated pocket walls',[(341,365),(351,369),(345,393),(337,399),(333,393),(336,375)],.67,.18)
    pocket(neck,'Neck lower side socket walls',[(355,408),(362,400),(356,422),(351,428),(349,421)],.67,.13)
    # Rotate the exposed thickness into a side face; it must not add a second
    # face-width to the narrow main shaft seen in the concept.
    left_start=len(parts)
    left=structural('Neck left box member',[(340,303),(348,308),(329,354),(320,403),(325,430),(303,421),(294,415),(302,376),(308,340),(326,320)],.66,.17)
    pocket(left,'Neck deep side recess',[(310,349),(322,337),(315,377),(306,389),(303,382)],.66,.15)
    # Only the pocket's inset walls survive. The shaft itself supplies the
    # sidewall and corner; there is no separate projecting side plate/fin.
    parts.remove(left);bpy.data.objects.remove(left,do_unlink=True)
    def corner_x(z):
        points=[xy(p) for p in [(323,427),(321,399),(330,351),(344,294)]]
        for (x0,z0),(x1,z1) in zip(points,points[1:]):
            if z<=z1:return x0+(x1-x0)*(z-z0)/(z1-z0)
        return points[-1][0]
    def to_side(po):
        for v in po.data.vertices:
            x,y,z=v.co;corner=corner_x(z)
            v.co.x=corner+(y-.66)*.20
            v.co.y=.67-(x-corner)*1.1
    for po in parts[left_start:]:to_side(po)
    # Cut the shaft behind the side-facing recess rather than covering a
    # solid slab with a decorative holed panel.
    channel=[(310,349),(322,337),(315,377),(306,389),(303,382)]
    cx=sum(p[0] for p in channel)/len(channel);cy=sum(p[1] for p in channel)/len(channel)
    channel=[(cx+(x-cx)*1.14,cy+(y-cy)*1.14) for x,y in channel]
    cutter=plate('Neck side channel cutting tool',channel,2,4,bevel=0)
    to_side(cutter)
    bpy.ops.object.select_all(action='DESELECT');neck.select_set(True);bpy.context.view_layer.objects.active=neck
    mod=neck.modifiers.new('Side-facing shaft recess','BOOLEAN');mod.operation='DIFFERENCE';mod.solver='EXACT';mod.object=cutter
    bpy.ops.object.modifier_apply(modifier=mod.name)
    parts.remove(cutter);bpy.data.objects.remove(cutter,do_unlink=True)
    # Solid shoulder and heel seat both front walls into their neighbors.
    plate('Neck upper mounting shoulder',[(345,288),(373,304),(404,289),(412,286),(405,310),(378,318),(351,313),(336,305)],2,.54,bevel=.075)
    for side in (-1,1):
        plate('Neck inset upper shaft',[(353,324),(377,330),(369,350),(360,347)],7,.035,side*.08,.01)
        plate('Neck recessed side mechanism',[(396,313),(404,310),(393,345),(383,354),(380,349)],2,.10,side*.60,.025)
        for p0 in [(398,318),(389,339)]:
            x,z=p0
            plate('Neck discrete side latch',[(x-2,z-4),(x+2,z-3),(x,z+4),(x-3,z+3)],0,.045,side*.72,.025)
    for pt in [(346,315),(352,361),(329,409),(372,368)]:screw(pt,2.2,.69)
    # The shoulder narrows into a shaft smaller than the cloth grip. Preserve
    # its centerline while removing width inherited from the perspective trace.
    for po in parts[neck_start:]:
        for v in po.data.vertices:
            axis=.25-.05*min(1,max(0,(v.co.z-5.3)/5.5))
            taper=min(1,max(0,(v.co.z-5.8)/3.4))
            v.co.x=axis+(v.co.x-axis)*(.82+.30*(1-taper))
            v.co.z=max(5.8,v.co.z)
    head_assembly=list(parts)
    def shaft_center(z):
        intersections=[]
        for edge in neck.data.edges:
            a,b=(neck.data.vertices[i].co for i in edge.vertices)
            if min(a.z,b.z)<=z<=max(a.z,b.z) and abs(b.z-a.z)>1e-6:
                intersections.append(a.x+(b.x-a.x)*(z-a.z)/(b.z-a.z))
        if not intersections:raise RuntimeError('Missing neck alignment cross section')
        return Vector(((min(intersections)+max(intersections))*.5,0,z))
    shaft_root=shaft_center(6.15);shaft_upper=shaft_center(8.3)
    # Loft the grip along the reference's slightly bent shaft. A flattened
    # ellipse gives the VR palm real volume; thin asymmetric cloth overlaps.
    grip_top=xy((321,451));grip_bottom=xy((243,773))
    def center(t):return (grip_bottom[0]*(1-t)+grip_top[0]*t+.09*math.sin(t*math.pi),grip_bottom[1]*(1-t)+grip_top[1]*t)
    # A continuous load-bearing haft must join both sockets. Cloth is a skin,
    # not the only geometry connecting the head and the pommel.
    hv=[];hf=[]
    for t,rx,ry in ((-.055,.82,.60),(0,1.00,.70),(.50,1.12,.73),(1.015,.98,.69),(1.09,.61,.61)):
        cx,cz=center(t)
        for j in range(24):
            a=j*math.tau/24;hv.append((cx+rx*math.cos(a),ry*math.sin(a),cz))
    for k in range(4):
        for j in range(24):hf.append((k*24+j,k*24+(j+1)%24,(k+1)*24+(j+1)%24,(k+1)*24+j))
    hf.extend((tuple(reversed(range(24))),tuple(range(96,120))))
    hm=bpy.data.meshes.new('Continuous handle tang');hm.from_pydata(hv,[],hf);hm.update()
    ho=bpy.data.objects.new('Continuous handle tang',hm);scene.collection.objects.link(ho);hm.materials.append(mats[7]);parts.append(ho)
    # Continuous closed socket, with no projecting sheet-like collar tabs.
    cv=[];cf=[]
    for t,rx,ry in ((.99,1.06,.74),(1.025,.94,.70),(1.06,.67,.65)):
        cx,cz=center(t)
        for j in range(12):
            a=j*math.tau/12;cv.append((cx+rx*math.cos(a),ry*math.sin(a),cz))
    for k in range(2):
        for j in range(12):cf.append((k*12+j,k*12+(j+1)%12,(k+1)*12+(j+1)%12,(k+1)*12+j))
    cf.extend((tuple(reversed(range(12))),tuple(range(24,36))))
    cm=bpy.data.meshes.new('Closed neck socket');cm.from_pydata(cv,[],cf);cm.update()
    co=bpy.data.objects.new('Neck closed grip socket',cm);scene.collection.objects.link(co);cm.materials.append(mats[1]);parts.append(co)
    # Eleven wide turns, each overlapping the previous one under a raised
    # leading edge: the reference tape is coarse and chunky, not a tight
    # thin helix with the tang showing between turns.
    steps=11*32;rows=5;verts=[];faces=[]
    for i in range(steps+1):
        t=i/steps+.004*math.sin(i/43)+.002*math.sin(i/127);theta=i/32*math.tau;cx,cz=center(t)
        compression=.014*math.sin(i/33)+.010*math.sin(i/14.7)
        rx=(1.10+.16*math.sin(t*math.pi)+compression)
        ry=.78+.07*math.sin(t*math.pi)+compression*.6
        for j in range(rows):
            cross=[0,.06,.14,.62,1][j];b=[.10,.11,0,0,-.035][j]+.006*math.sin(theta*12+i/37)
            z=cz+cross*(2.0+.14*math.sin(i/39))+.40*math.cos(theta+.7)+.07*math.sin(theta*3.4)
            z=min(z,grip_top[1]+.20)
            verts.append((cx+(rx+b)*math.cos(theta),(ry+b)*math.sin(theta),z))
    for i in range(steps):
        for j in range(rows-1):
            a=i*rows+j;faces.append((a,a+rows,a+rows+1,a+1))
    me=bpy.data.meshes.new('Reference cloth wrap');me.from_pydata(verts,[],faces);me.update()
    ob=bpy.data.objects.new('Compressed overlapping fabric grip',me);scene.collection.objects.link(ob);me.materials.append(mats[1]);parts.append(ob)
    for p in me.polygons:p.use_smooth=True
    # A few thin reverse overlaps interrupt the regular helical seam. These
    # are tape edges, not individual fibers; fine fraying stays in texture maps.
    for t0,phase in ((.24,.3),(.49,1.4),(.72,2.1)):
        sv=[];sf=[]
        for j in range(41):
            a=j/40*math.tau+phase;t=t0-(j/40-.5)*.035
            cx,cz=center(t);rx=1.10+.16*math.sin(t*math.pi)+.07;ry=.78+.07*math.sin(t*math.pi)+.065
            for edge in (0,1):sv.append((cx+rx*math.cos(a),ry*math.sin(a),cz+edge*.09+.07*math.sin(a*2.7)))
        for j in range(40):sf.append((j*2,j*2+2,j*2+3,j*2+1))
        sm=bpy.data.meshes.new('Thin reverse cloth overlap');sm.from_pydata(sv,[],sf);sm.update()
        so=bpy.data.objects.new('Irregular cloth overlap',sm);scene.collection.objects.link(so);sm.materials.append(mats[1]);parts.append(so)
        for p in sm.polygons:p.use_smooth=True
    # Thin cords lash the tape below the collar (a crossing pair) and above
    # the heel, as the reference shows; tubes ride just proud of the wrap.
    for t0,tilt,phase in ((.66,.11,0.0),(.705,-.11,1.3),(.11,.06,2.4)):
        cv=[];cf=[];around=32;tube=6
        cx,cz=center(t0);rx=1.10+.16*math.sin(t0*math.pi)+.13;ry=.78+.07*math.sin(t0*math.pi)+.11
        for j in range(around):
            a=j/around*math.tau
            lp=(cx+rx*math.cos(a),ry*math.sin(a),cz+tilt*rx*math.cos(a+phase))
            nx,ny=math.cos(a),math.sin(a)*(ry/rx)
            for k in range(tube):
                b=k/tube*math.tau;r=.07
                cv.append((lp[0]+r*math.cos(b)*nx,lp[1]+r*math.cos(b)*ny,lp[2]+r*math.sin(b)))
        for j in range(around):
            for k in range(tube):
                cf.append((j*tube+k,((j+1)%around)*tube+k,((j+1)%around)*tube+(k+1)%tube,j*tube+(k+1)%tube))
        cm=bpy.data.meshes.new('Lashing cord');cm.from_pydata(cv,[],cf);cm.update()
        co=bpy.data.objects.new('Lashing cord',cm);scene.collection.objects.link(co);cm.materials.append(mats[1]);parts.append(co)
        for p in cm.polygons:p.use_smooth=True
    # Conforming cuff under the neck, not a pair of camera-facing fabric tabs.
    cv=[];cf=[]
    for layer,t in enumerate((.93,.995,1.07)):
        cx,cz=center(t)
        for j in range(32):
            a=j*math.tau/32
            cv.append((cx+(1.13,1.065,.65)[layer]*math.cos(a),(.81,.77,.64)[layer]*math.sin(a),cz+(.20,.13,0)[layer]*math.cos(a+.7)))
    for layer in range(2):
        for j in range(32):
            n=(j+1)%32;cf.append((layer*32+j,layer*32+n,(layer+1)*32+n,(layer+1)*32+j))
    cm=bpy.data.meshes.new('Conforming neck cuff');cm.from_pydata(cv,[],cf);cm.update()
    co=bpy.data.objects.new('Neck cloth overlaps',cm);scene.collection.objects.link(co);cm.materials.append(mats[1]);parts.append(co)
    for p in cm.polygons:p.use_smooth=True
    # The broad red-printed top cuff and metallic retaining bands interrupt wrap.
    for side in (-1,1):
        # Printed red cuff markings are in the fabric texture; no raised logo.
        rail('Upper cuff retaining ring',[(278,502),(341,523),(349,516)],6,2,side*.84,.055)
        for p in [(286,507),(311,515),(338,522)]:ring('Cuff fastener',p,2.7,1.5,0,side*.912)
        rail('Lower grip ferrule',[(211,759),(260,778),(268,785)],5,2,side*.70,.045)
    # A single closed pommel housing with recessed pockets and one side rail.
    pommel_outline=[(209,762),(267,785),(278,802),(270,828),(252,862),(245,895),(231,926),(214,953),(207,966),(190,956),(123,883),(130,860),(153,824),(175,791),(186,767)]
    pommel_start=len(parts)
    pm=structural('Pommel integrated titanium housing',pommel_outline,.76,.31)
    pocket(pm,'Pommel upper side cavity',[(188,784),(199,783),(193,801),(176,825),(170,828),(173,815)],.76,.21)
    pocket(pm,'Pommel upper milled channel',[(205,797),(218,796),(232,804),(216,836),(201,847),(187,841),(189,830)],.76,.22)
    socket=[(176,853),(191,854),(209,877),(205,892),(187,909),(176,909),(156,885),(157,873)]
    pocket(pm,'Pommel continuous polygonal aperture',socket,.76,.30,1.28)
    end_socket=[(189,943),(198,947),(214,958),(207,963),(197,958),(188,949)]
    pocket(pm,'Pommel recessed terminal light cavity',end_socket,.76,.15,1.08)
    plate('Pommel terminal dark chamber',end_socket,7,.48,bevel=.01)
    # Through-cavity remains open. Two inner ribs cross only the sidewalls;
    # there is no smaller polygonal back cap pretending to be pocket depth.
    plate('Pommel upper channel mechanism',[(203,805),(222,808),(209,836),(198,840),(194,833)],2,.32,bevel=.04)
    for yy in (813,819,825,831):
        xx=212-(yy-813)*.48
        rail('Pommel mechanism inset rib',[(xx-4,yy),(xx+4,yy+2)],1.2,0,.365,.025)
        rail('Pommel mechanism inset rib',[(xx-4,yy),(xx+4,yy+2)],1.2,0,-.365,.025)
    plate('Pommel single outboard coil housing',[(269,829),(280,835),(270,867),(256,899),(241,925),(233,919),(246,891),(254,862)],2,.60,bevel=.075)
    # Front armor is seated into the housing, not floating above a second rim.
    for side in (-1,1):
        plate('Pommel broad dark face',[(237,786),(263,797),(269,805),(252,845),(236,875),(231,897),(219,918),(208,917),(216,894),(218,876),(198,849),(212,830)],2,.045,side*.775,.045)
        plate('Pommel lower dark cheek',[(133,860),(150,858),(146,878),(151,891),(186,930),(182,939),(127,882)],2,.035,side*.78,.035)
        # A real channel in a thick outboard guard, supported at both ends.
        rail('Pommel recessed cyan coil',[(271,850),(260,876),(250,897)],5.0,3,side*.625,.014)
        rail('Pommel coil silver outer wall',[(277,842),(273,855),(262,882),(252,904)],3.8,0,side*.64,.065)
        for pts in [[(270,835),(280,839),(276,851),(266,847)],[(248,897),(257,901),(249,917),(240,913)]]:
            plate('Pommel coil terminal block',pts,0,.12,side*.62,.035)
        plate('Pommel status recessed socket',[(200,920),(206,919),(209,925),(206,931),(200,930),(197,925)],7,.006,side*.763,.006)
        ring('Pommel recall LED',(204,925),3.2,1.2,3,side*.805)
        plate('Pommel angled end emitter',[(190,945),(197,948),(210,958),(206,960),(199,956)],3,.016,side*.52,.01)
    plate('Pommel integrated lower end block',[(230,928),(241,938),(220,967),(204,965),(209,947)],0,.77,bevel=.10)
    plate('Pommel grip socket collar',[(202,754),(265,777),(277,791),(267,800),(204,777),(187,776)],2,.72,bevel=.075)
    for pt in [(251,802),(238,833),(146,868),(225,947),(198,784)]:screw(pt,1.65,.83)
    # The perspective trace includes the visible sidewall; avoid interpreting
    # all of that projected width as a second full-width front face.
    center_x=xy((209,861))[0]
    for po in parts[pommel_start:]:
        # Fold the broad left field into a sloped side plane. The source
        # perspective shows that plane beside the front frame, not coplanar.
        bm=bmesh.new();bm.from_mesh(po.data);bmesh.ops.triangulate(bm,faces=list(bm.faces));bm.to_mesh(po.data);bm.free()
        for v in po.data.vertices:
            px=285+29.2*(-.96*v.co.x+.28*v.co.z)
            py=600+29.2*(-.28*v.co.x-.96*v.co.z)
            front_edge=216-.53*(py-780)
            fold=min(1,max(0,(front_edge-px)/32))
            v.co.y*=1-.42*fold
            v.co.x=center_x+(v.co.x-center_x)*.90
    head_detail_start=len(parts)
    # Authored typography lies on the central armor face, small and subordinate.
    def text(body,p,size,slot=5):
        x,z=xy(p)
        for side in (-1,1):
            cu=bpy.data.curves.new(body,'FONT');cu.body=body;cu.size=size/29.2;cu.extrude=.001
            ob=bpy.data.objects.new('Armor stencil '+body,cu);scene.collection.objects.link(ob)
            ob.location=(x,side*.51,z);ob.rotation_euler=(math.pi/2,0,math.pi if side>0 else 0)
            cu.materials.append(mats[slot]);bpy.ops.object.select_all(action='DESELECT');ob.select_set(True);bpy.context.view_layer.objects.active=ob
            bpy.ops.object.convert(target='MESH');parts.append(bpy.context.object)
    text('CAUTION',(310,163),12)
    text('MAGNETIC RECALL CORE',(310,174),4.4)
    for side in (-1,1):
        rail('Warning icon',[(302,149),(292,167),(310,172),(302,149)],2.3,4,side*.52,.009)
        rail('Warning icon break',[(301,149),(304,142)],2,4,side*.53,.009)
    for p in [(211,77),(231,158),(230,178),(284,94),(359,236),(373,184),(316,194)]:screw(p,2.5,.56)
    # Register the complete head assembly to the actual handle axis. Tracing
    # projected contours independently had offset the head relative to its haft.
    handle_axis=Vector((grip_top[0]-grip_bottom[0],0,grip_top[1]-grip_bottom[1])).normalized()
    head_axis=(shaft_upper-shaft_root).normalized()
    rotation=head_axis.rotation_difference(handle_axis)
    target=Vector((grip_top[0]+handle_axis.x/handle_axis.z*(shaft_root.z-grip_top[1]),0,shaft_root.z))
    for po in head_assembly+parts[head_detail_start:]:
        matrix=po.matrix_world.copy();inverse=matrix.inverted()
        for v in po.data.vertices:v.co=inverse@(target+rotation@(matrix@v.co-shaft_root))
    scene['neck_alignment_source']=list(shaft_root)
    scene['neck_alignment_target']=list(target)
    scene['neck_alignment_rotation_degrees']=math.degrees(rotation.angle)
    # All stains and fine wear belong to the texture set, never droplet meshes.
    return xy
