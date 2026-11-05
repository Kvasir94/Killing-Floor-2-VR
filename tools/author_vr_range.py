"""Author KF-VRRange BSP import and a matching non-destructive Blender scene.

Run with Python for the SDK T3D, or execute in Blender for the editable layout.
Stock KF2 references stay external; no extracted game content is redistributed.
"""
from pathlib import Path
import json
import math

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/range'
MATERIALS = {
    'floor': 'ENV_BioticsLab_MAT.lobby.Floor.ENV_BioticsLab_Floor1_MIC',
    'wall': 'ENV_BioticsLab_MAT.lobby.Wall.ENV_BioticsLab_Wall2_Tiled_MIC',
    'steel': 'ENV_BioticsLab_MAT.lab.ENV_BioticsLab_LabMetal_MIC',
    'ceiling': 'ENV_BioticsLab_MAT.lobby.Ceiling.ENV_BioticsLab_Ceiling1_MIC',
    'boundary': 'ENV_BioticsLab_TWO_MAT.Glow.Env_BioticsLab_Red_Emissive_Bright_MIC',
}
COLORS = {'floor': (.25,.27,.25,1), 'wall': (.53,.55,.51,1),
          'steel': (.12,.16,.17,1), 'ceiling': (.32,.34,.32,1), 'boundary': (1,.015,.01,1)}
BOXES = []
VOLUMES = []
PROPS = []
LABELS = []


def box(name, xyz, size, material='steel'):
    BOXES.append(dict(name=name, xyz=xyz, size=size, material=material))


def layout():
    box('ConcreteSlab', (350,400,-32), (5300,4400,64), 'floor')
    box('WestWall', (-2332,400,325), (64,4528,650), 'wall')
    box('EastBackstop', (3032,400,325), (64,4528,650), 'wall')
    box('SouthWall', (350,-1832,325), (5300,64,650), 'wall')
    box('NorthWall', (350,2632,325), (5300,64,650), 'wall')
    box('Roof', (350,400,682), (5428,4528,64), 'ceiling')
    # The red perimeter matches the native zed-only collision walls. Human
    # players, bullets and thrown props can cross the visible boundary.
    for name,xyz,size in [('West',(-300,1500,325),(12,1624,650)),
                          ('East',(2600,1500,325),(12,1624,650)),
                          ('South',(1150,700,325),(2912,12,650)),
                          ('North',(1150,2300,325),(2912,12,650))]:
        VOLUMES.append(dict(name='ArenaContainment'+name,xyz=xyz,size=size,material='boundary'))
        box('ArenaRedLine'+name,(xyz[0],xyz[1],1),
            (max(size[0],18),max(size[1],18),2),'boundary')
    box('GunWall', (-2160,200,150), (40,3400,300))
    box('NorthGunWall', (250,2500,150), (4700,40,300))
    box('EastGunWall', (2850,1415,150), (40,1650,300))
    for z in (55,140,225):
        box('NorthRackRail_%d'%z, (250,2475,z), (4700,12,8))
        box('EastRackRail_%d'%z, (2825,1415,z), (12,1650,8))
    for y in range(-1400,1901,300):
        box('RackUpright_%d' % y, (-2128,y,150), (24,12,300))
    for z in (55,140,225):
        box('RackRail_%d' % z, (-2110,200,z), (12,3300,8))
    for x in (-2250,-700,850,2400,2950):
        box('RoofBeam_%d' % x, (x,400,610), (32,4400,60))
    # Ballistic lane dividers leave the main central circulation route clear.
    for y in (-420,-140,140,420):
        box('LaneDivider_%d' % y, (600,y,110), (380,16,220))
    for y in (-280,0,280):
        box('FiringShelf_%d' % y, (620,y,95), (70,240,12))
        box('TargetBacker_%d' % y, (2790,y,155), (24,175,240), 'wall')
        box('TargetPlate_%d' % y, (2773,y,160), (10,55,90))
    for x in (1000,1500,2000,2500):
        box('DistanceLine_%d' % x, (x,0,1), (4,820,2))
        LABELS.append((str((x-500)//100)+' m', (x,-435,10), 0))
    # Reload bench with a shallow catch tray and open knee space.
    box('ReloadBench', (-500,-1550,90), (700,150,12))
    for x in (-800,-200):
        for y in (-1600,-1500):
            box('BenchLeg_%d_%d' % (x,y), (x,y,42), (12,12,84))
    for y in (-1625,-1475):
        box('CatchTrayEdge_%d' % y, (-500,y,104), (700,8,20))
    for x in (-850,-150):
        box('CatchTrayEnd_%d' % x, (x,-1550,104), (8,150,20))
    # Low-cover/movement corner, clear of the zed spawn area.
    for i in range(6):
        box('Stair_%d' % i, (1800+i*45,-1450,(i+1)*9), (45,180,(i+1)*18), 'floor')
    box('StairLanding', (2120,-1450,54), (190,180,108), 'floor')
    box('AccessRamp', (2120,-1200,54), (190,320,108), 'floor')
    BOXES[-1]['ramp'] = True
    box('LowCover', (1600,-900,48), (320,36,96), 'wall')
    for x in (2400,2550):
        box('DoorPost_%d' % x, (x,-1100,145), (28,50,290), 'wall')
    box('DoorLintel', (2475,-1100,280), (178,50,30), 'wall')
    for i,z in enumerate((55,95,135,175)):
        box('ReachShelf_%d' % i, (2700,-1660+i*160,z), (140,75,8))
    # Visible boundaries define stations without obstructing interactions.
    for name,x,y in [('Dummy',-900,-1100),('Toss',900,-1100)]:
        for dx in (-150,150):
            box(name+'MarkX'+str(dx),(x+dx,y,1),(4,300,2))
        for dy in (-150,150):
            box(name+'MarkY'+str(dy),(x,y+dy,1),(300,4,2))
    for x in (-1600,0,1600):
        for y in (-1100,400,1900):
            PROPS.append(dict(name='CeilingFixture_%d_%d' % (x,y), xyz=(x,y,615),
                mesh='ENV_BioticsLab_MESH.monitor_room.ENV_BioticsLab_MonitorRoom_Ceiling_Light'))
    LABELS.extend([('VR ARMORY',(-2070,200,330),math.pi/2),
                   ('LIVE FIRE', (700,500,330),0),
                   ('ZED ARENA',(500,2450,350),0),
                   ('RELOAD BENCH',(-500,-1750,260),0),
                   ('PARTNER LAB',(-900,-1750,280),0),
                   ('CATCH PRACTICE',(900,-1750,280),0),
                   ('MOVEMENT / REACH',(2200,-1750,350),0)])
    # Keep controls at y=-1750 unobstructed by work surfaces or exercise props.
    for b in BOXES:
        if b['name'].startswith(('ReloadBench','BenchLeg','CatchTray')):
            b['xyz']=(b['xyz'][0],b['xyz'][1]+300,b['xyz'][2])
        elif b['name'].startswith(('Stair','AccessRamp','ReachShelf')):
            b['xyz']=(b['xyz'][0],b['xyz'][1]+250,b['xyz'][2])


def vec(v):
    return '(X=%.4f,Y=%.4f,Z=%.4f)' % tuple(v)


def brush(b, volume=False):
    name=b['name']; sx,sy,sz=[n/2 for n in b['size']]
    points=[(-sx,-sy,-sz),(sx,-sy,-sz),(sx,sy,-sz),(-sx,sy,-sz),
            (-sx,-sy,sz),(sx,-sy,sz),(sx,sy,sz),(-sx,sy,sz)]
    if b.get('ramp'):
        points[6]=(sx,sy,-sz+1);points[7]=(-sx,sy,-sz+1)
    faces=[((0,3,2,1),(0,0,-1)),((4,5,6,7),(0,0,1)),
           ((0,1,5,4),(0,-1,0)),((3,7,6,2),(0,1,0)),
           ((0,4,7,3),(-1,0,0)),((1,2,6,5),(1,0,0))]
    actor_class='KFPawnBlockingVolume' if volume else 'Brush'
    lines=[f'Begin Actor Class={actor_class} Name={name}',f'    Begin Brush Name={name}Model','        Begin PolyList']
    for indices,n in faces:
        if b.get('ramp') and indices==(4,5,6,7):
            length=math.hypot(2*sz-1,2*sy)
            n=(0,(2*sz-1)/length,2*sy/length)
        u=(1,0,0) if not n[0] else (0,1,0)
        v=(0,1,0) if n[2] else (0,0,-1)
        lines.extend([f'            Begin Polygon Texture={MATERIALS[b["material"]]} Flags=0',
                      '                Origin '+','.join('%.4f'%p for p in points[indices[0]]),
                      '                Normal '+','.join('%.4f'%p for p in n),
                      '                TextureU '+','.join('%.4f'%p for p in u),
                      '                TextureV '+','.join('%.4f'%p for p in v)])
        for idx in indices:
            lines.append('                Vertex '+','.join('%.4f'%p for p in points[idx]))
        lines.append('            End Polygon')
    lines.extend(['        End PolyList','    End Brush', f"    Brush=Model'{name}Model'",
                  '    CsgOper='+('CSG_Active' if volume else 'CSG_Add'), '    PolyFlags=0', '    Location='+vec(b['xyz']),
                  '    Begin Object Class=BrushComponent Name=BrushComponent0', f"        Brush=Model'{name}Model'"])
    if volume:
        lines.extend(['        BlockRigidBody=False','        BlockZeroExtent=False',
                      '        BlockNonZeroExtent=True'])
    lines.extend(['    End Object', '    BrushComponent=BrushComponent0',
                  '    CollisionComponent=BrushComponent0','    Components(0)=BrushComponent0'])
    if volume:
        lines.extend(['    bBlockPlayers=False','    bBlockZedPlayers=True',
                      '    bBlockMonsters=True','    BlockRigidBody=False','    bBlockCamera=False'])
    lines.append('End Actor')
    return '\n'.join(lines)


def t3d():
    parts=['Begin Map','Begin Level NAME=PersistentLevel',
        "Begin Actor Class=WorldInfo Name=WorldInfo_0\n    Begin Object Class=KFMapInfo Name=KFMapInfo_0\n    End Object\n    MyMapInfo=KFMapInfo_0\n    bForceNoPrecomputedLighting=True\n    KillZ=-1000\nEnd Actor"]
    # UE3 reserves the first brush as its editor builder brush. Keep a separate
    # empty builder so the first authored solid (the floor) participates in CSG.
    parts.append("Begin Actor Class=Brush Name=BuilderBrush\n    Begin Brush Name=BuilderModel\n        Begin PolyList\n        End PolyList\n    End Brush\n    Brush=Model'BuilderModel'\n    CsgOper=CSG_Active\n    Begin Object Class=BrushComponent Name=BrushComponent0\n        Brush=Model'BuilderModel'\n    End Object\n    BrushComponent=BrushComponent0\nEnd Actor")
    parts.extend(brush(b) for b in BOXES)
    parts.extend(brush(b,volume=True) for b in VOLUMES)
    for i in range(6):
        parts.append(f'Begin Actor Class=KFPlayerStart Name=PlayerStart_{i}\n    Location={vec((-1500+(i%2)*150,(i//2)*150,100))}\nEnd Actor')
    parts.append("Begin Actor Class=SkeletalMeshActor Name=TraderPod Archetype=SkeletalMeshActor'GP_Trader_ARCH.TraderPod'\n    Location="+vec((-1750,-1450,0))+"\n    Rotation=(Pitch=0,Yaw=16384,Roll=0)\nEnd Actor")
    parts.append("Begin Actor Class=KFTraderTrigger Name=RangeTrader\n    TraderMeshActor=SkeletalMeshActor'TraderPod'\n    Location="+vec((-1750,-1400,100))+'\nEnd Actor')
    for p in PROPS:
        parts.append(f"Begin Actor Class=StaticMeshActor Name={p['name']}\n    Begin Object Class=StaticMeshComponent Name=StaticMeshComponent0\n        StaticMesh=StaticMesh'{p['mesh']}'\n        bUsePrecomputedShadows=False\n        BlockActors=False\n        CollideActors=False\n    End Object\n    StaticMeshComponent=StaticMeshComponent0\n    Components(0)=StaticMeshComponent0\n    Location={vec(p['xyz'])}\nEnd Actor")
    for i,(x,y) in enumerate(( (x,y) for x in (-1600,0,1600) for y in (-1100,400,1900) )):
        parts.append(f'Begin Actor Class=PointLightMovable Name=WorkLight_{i}\n    Begin Object Class=PointLightComponent Name=PointLightComponent0\n        Brightness=1.2\n        Radius=1750\n        CastShadows=False\n        LightColor=(R=235,G=243,B=255,A=255)\n    End Object\n    LightComponent=PointLightComponent0\n    CollisionComponent=None\n    Location={vec((x,y,510))}\nEnd Actor')
    # Navigation grid is for the SDK path builder; no scripted runtime probes.
    for x in range(-1700,2801,500):
        for y in range(-1000,2401,500):
            parts.append(f'Begin Actor Class=KFPathnode Name=Nav_{x}_{y}\n    Location={vec((x,y,60))}\nEnd Actor')
    parts.extend(['End Level','Begin Surface','End Surface','End Map'])
    return '\n'.join(parts)+'\n'


def blender_scene(save=True):
    import bpy
    scene=bpy.data.scenes.new('KF-VRRange Authoring')
    scene.unit_settings.system='METRIC'
    scene.unit_settings.scale_length=.01
    collection=scene.collection
    mats={}
    for key,color in COLORS.items():
        m=bpy.data.materials.new('VRRange_'+key);m.diffuse_color=color
        m['kf2_material']=MATERIALS[key];mats[key]=m
    for b in BOXES:
        sx,sy,sz=[n/2 for n in b['size']]
        mesh=bpy.data.meshes.new(b['name'])
        points=[(-sx,-sy,-sz),(sx,-sy,-sz),(sx,sy,-sz),(-sx,sy,-sz),
                (-sx,-sy,sz),(sx,-sy,sz),(sx,sy,sz),(-sx,sy,sz)]
        if b.get('ramp'):
            points[6]=(sx,sy,-sz+1);points[7]=(-sx,sy,-sz+1)
        mesh.from_pydata(points,[],
                        [(0,3,2,1),(4,5,6,7),(0,1,5,4),(3,7,6,2),(0,4,7,3),(1,2,6,5)])
        o=bpy.data.objects.new(b['name'],mesh);collection.objects.link(o)
        o.location=b['xyz'];mesh.materials.append(mats[b['material']])
        o['kf2_material']=MATERIALS[b['material']]
        # Hide roof in authoring viewport so the station layout stays visible.
        if b['name']=='Roof': o.hide_viewport=True
    for label,xyz,angle in LABELS:
        data=bpy.data.curves.new(label,'FONT');data.body=label;data.size=35;data.align_x='CENTER'
        o=bpy.data.objects.new(label,data);collection.objects.link(o);o.location=xyz
        o.rotation_euler=(math.pi/2,0,angle)
    # SDK assets remain external; authoring markers keep their exact references.
    for prop in PROPS:
        o=bpy.data.objects.new(prop['name'],None);collection.objects.link(o)
        o.location=prop['xyz'];o.empty_display_type='CUBE';o.empty_display_size=35
        o['kf2_static_mesh']=prop['mesh']
    trader=bpy.data.objects.new('StockTraderPod',None);collection.objects.link(trader)
    trader.location=(-1750,-1450,0);trader.empty_display_type='CUBE';trader.empty_display_size=90
    trader['kf2_archetype']='GP_Trader_ARCH.TraderPod'
    scene['kf2_map']='KF-VRRange';scene['kf2_units_per_metre']=100
    # Save a copy; preserve the user's active file and all preexisting scenes.
    if save:
        window=bpy.context.window
        previous=window.scene if window else None
        try:
            if window: window.scene=scene
            bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'KF-VRRange.blend'),copy=True)
        finally:
            if window: window.scene=previous
    return scene.name


def main():
    layout();OUT.mkdir(parents=True,exist_ok=True)
    (OUT/'KF-VRRange.t3d').write_text(t3d(),encoding='utf-8')
    manifest={'map':'KF-VRRange','units_per_metre':100,'floor_z':0,
        'bounds':[-2300,3000,-1800,2600], 'materials':MATERIALS,
        'stock_props':PROPS,'boxes':BOXES,'station_labels':LABELS,
        'arena_bounds':[-300,2600,700,2300],'zed_blocking_volumes':VOLUMES,
        'spawn':[-1500,0,100],'dummy':[-900,-1100,100],'toss':[900,-1100,100],
        'gun_wall':{'x':-2100,'y_min':-1400,'y_max':1900},
        'trader':[-1750,-1400,100]}
    (OUT/'layout.json').write_text(json.dumps(manifest,indent=2)+'\n')
    try: import bpy
    except ImportError: pass
    else: blender_scene()
    print(f'Authored {len(BOXES)} brushes: {OUT / "KF-VRRange.t3d"}')


if __name__=='__main__': main()
