"""Map locally extracted Source effect parameters to native KF2 emitters.

The full original PCF trees are retained in particles.json, alongside a report
of operators that need manual renderer parity work. Never claim byte-identical
Source rendering from a Cascade conversion.
"""
from pathlib import Path
import argparse
import json
import re
import struct
import math

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/source-weapons'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--include-mechanism-animations', action='store_true',
                    help='Enable the unfinished Source animation import with strict frame-count checks.')
args = parser.parse_args()
materials, emitters, sounds, unsupported = [], [], [], {}

def vector(values, factor=1): return dict(zip(('X','Y','Z'), [float(v)*factor for v in values[:3]]))
def ini(value):
    if isinstance(value, dict): return '(' + ','.join(f'{k}={ini(v)}' for k,v in value.items()) + ')'
    if isinstance(value, list): return '(' + ','.join(ini(v) for v in value) + ')'
    if isinstance(value, bool): return 'True' if value else 'False'
    if isinstance(value, str):
        if any(c in value for c in ('"','\r','\n')): raise ValueError('Unsafe config string')
        return '"' + value.replace('\\','/') + '"'
    return str(value)

def vmt_data(path):
    text = re.sub(r'//[^\r\n]*', '', path.read_text(errors='replace'))
    tokens = re.findall(r'(?:"(\$[^"\r\n]+)"|(\$\w+))\s*(?:"([^"\r\n]*)"|(\[[^\]]*\])|([^\s{}]+))', text)
    return {(a or b).lower(): (c or d or e) for a,b,c,d,e in tokens}

def remap(t, start, end): return max(0, min(1, (t-start)/max(0.00001,end-start)))
def smooth(t): return t*t*(3-2*t)
def curve(evaluate):
    return dict(Points=[dict(InVal=i/32,OutVal=evaluate(i/32),InterpMode='CIM_Linear') for i in range(33)])

def material(kind, path, name, particle=False, **extra):
    if any(m['AssetName'] == name for m in materials): return
    vmt = ROOT / 'extract/source-weapons' / kind / 'materials' / path.replace('\\','/')
    values = vmt_data(vmt)
    base = values.get('$basetexture')
    if not base: raise ValueError(f'No texture in {vmt}')
    entry = dict(AssetName=name, TextureFile=str(OUT / 'textures' / (kind + '_' + Path(base).stem + '.tga')),
                 bParticle=particle, bAdditive=values.get('$additive') == '1' or (particle and values.get('$translucent') != '1'),
                 bSelfIllum=values.get('$selfillum') == '1', TilesX=1, TilesY=1)
    if values.get('$bumpmap'):
        entry['NormalFile'] = str(OUT / 'textures' / (kind + '_' + Path(values['$bumpmap']).stem + '.tga'))
    # Original packed sheets use sub-rectangles, not whole-sheet billboards.
    # The Blender texture pass emits repacked sequences with this sidecar.
    sheet = OUT / 'textures' / (kind + '_' + Path(base).stem + '.sheet.json')
    if sheet.exists(): entry.update(json.loads(sheet.read_text())['grid'])
    entry.update(extra)
    materials.append(entry)

material('gravity', 'models/weapons/v_physcannon/v_superphyscannon_sheet.vmt', 'SuperGravityGunMaterial')
material('gravity', 'models/weapons/w_physics/w_physics_sheet2.vmt', 'GravityFrontPlateMaterial')
material('sticky', 'models/weapons/c_models/c_stickybomb_launcher/c_stickybomb_launcher.vmt', 'StickybombLauncherMaterial')
material('sticky', 'models/weapons/w_stickybomb/w_stickybomb_red.vmt', 'StickybombMaterial')

def flatten(tree, delay=0):
    if tree.get('renderers'): yield tree, delay
    for child in tree.get('children', []): yield from flatten(child['child'], delay + child.get('delay',0))

known = {'Lifetime Random','Radius Random','Alpha Random','Color Random','Position Within Sphere Random',
         'Position Within Box Random','Rotation Random','Sequence Random','Trail Length Random',
         'Movement Basic','Alpha Fade and Decay','Alpha Fade In Random','Alpha Fade Out Random','Radius Scale',
         'Color Fade','Decay','Rotation Spin Roll','Movement Lock to Control Point',
         'Rotation Basic','Position Modify Offset Random','Rotation Speed Random'}
for system, tree in json.loads((OUT / 'particles.json').read_text()).items():
    for part, delay in flatten(tree):
        ops = {i['functionName']: i for key in ('operators','initializers') for i in part.get(key,[])}
        unsupported[part['name']] = [n for n in ops if n not in known]
        texture_name = 'FX_' + re.sub('[^A-Za-z0-9_]','_',part['name'])
        material('sticky', part['material'], texture_name, True)
        props = next(m for m in materials if m['AssetName'] == texture_name)
        life=ops.get('Lifetime Random',{}); size=ops.get('Radius Random',{}); color=ops.get('Color Random',{})
        alpha=ops.get('Alpha Random',{}); fade=ops.get('Alpha Fade and Decay',{}); scale=ops.get('Radius Scale',{})
        sphere=ops.get('Position Within Sphere Random',{}); box=ops.get('Position Within Box Random',{})
        move=ops.get('Movement Basic',{}); colfade=ops.get('Color Fade',{})
        initial_color = color.get('color1',part.get('color',[255,255,255]))
        alternate_color = color.get('color2',initial_color)
        end_color = colfade.get('color_fade',initial_color)
        props.update(bSourceColor=True, ParticleColorA=vector(initial_color,1/255),
                     ParticleColorB=vector(alternate_color,1/255), ParticleColorEnd=vector(end_color,1/255))
        rotation=ops.get('Rotation Random',{}); spin=ops.get('Rotation Speed Random',{})
        spin_roll=ops.get('Rotation Spin Roll',{}); offset=ops.get('Position Modify Offset Random',{})
        trail=ops.get('Trail Length Random',{})
        renderer=next((r for r in part['renderers'] if r['functionName']=='render_sprite_trail'),{})
        sequence=ops.get('Sequence Random',{})
        size_bias=max(.000001,min(.999999,scale.get('scale_bias',.5)))
        def size_at(t):
            f=remap(t,scale.get('start_time',0),scale.get('end_time',1))
            f=smooth(f) if scale.get('ease_in_and_out',False) else f**(math.log(size_bias)/math.log(.5))
            return scale.get('radius_start_scale',1)*(1-f)+scale.get('radius_end_scale',1)*f
        def alpha_at(t):
            into=remap(t,fade.get('start_fade_in_time',0),fade.get('end_fade_in_time',0)) if fade.get('end_fade_in_time',0)>0 else 1
            out=remap(t,fade.get('start_fade_out_time',.7),fade.get('end_fade_out_time',1))
            return (fade.get('start_alpha',0)*(1-into)+into)*(1-out+fade.get('end_alpha',0)*out)
        for spawn in part['emitters']:
            continuous=spawn['functionName'] == 'emit_continuously'
            count=spawn.get('num_to_emit',0)
            duration=spawn.get('emission_duration',0.1)
            entry=dict(SystemName=system, EmitterName=part['name'], MaterialName=texture_name,
                Rate=spawn.get('emission_rate',0) if continuous else 0,
                CountMax=count, CountMin=max(0,spawn.get('num_to_emit_minimum',count)) if spawn.get('num_to_emit_minimum',-1)>=0 else count,
                Duration=duration if duration>0 else 1, Delay=delay+spawn.get('emission_start_time',0),
                bLoop=continuous and duration==0,
                LifetimeMin=life.get('lifetime_min',1), LifetimeMax=life.get('lifetime_max',1),
                SizeMin=size.get('radius_min',part.get('radius',5))*5.08,
                SizeMax=size.get('radius_max',part.get('radius',5))*5.08,
                SizeStart=scale.get('radius_start_scale',1), SizeEnd=scale.get('radius_end_scale',1),
                ColorStart=vector(initial_color,1/255), ColorEnd=vector(end_color,1/255),
                Alpha=alpha.get('alpha_max',255)/255,
                AlphaMin=alpha.get('alpha_min',255)/255,
                SizeCurve=curve(size_at), AlphaCurve=curve(alpha_at),
                bSourceColor=True,
                ColorBlendCurve=curve(lambda t: smooth(remap(t,colfade.get('fade_start_time',0),colfade.get('fade_end_time',1))) if colfade else 0),
                ColorCurve=curve(lambda t: vector([a+(b-a)*smooth(remap(t,colfade.get('fade_start_time',0),colfade.get('fade_end_time',1))) for a,b in zip(initial_color,end_color)],1/255)),
                FadeIn=fade.get('end_fade_in_time',0), FadeOut=fade.get('start_fade_out_time',0.7),
                VelocityMin=vector(sphere.get('speed_in_local_coordinate_system_min',[0,0,0]),2.54),
                VelocityMax=vector(sphere.get('speed_in_local_coordinate_system_max',[0,0,0]),2.54),
                Acceleration=vector(move.get('gravity',[0,0,0]),2.54),
                PositionMin=vector([a+b for a,b in zip(box.get('min',[0]*3),offset.get('offset min',[0]*3))],2.54),
                PositionMax=vector([a+b for a,b in zip(box.get('max',[0]*3),offset.get('offset max',[0]*3))],2.54),
                Radius=sphere.get('distance_max',0)*2.54, RadialSpeed=sphere.get('speed_max',0)*2.54,
                RadiusMin=sphere.get('distance_min',0)*2.54, RadialSpeedMin=sphere.get('speed_min',0)*2.54,
                RotationMin=(rotation.get('rotation_initial',0)+rotation.get('rotation_offset_min',0))/360,
                RotationMax=(rotation.get('rotation_initial',0)+rotation.get('rotation_offset_max',0))/360,
                SpinMin=spin.get('rotation_speed_random_min',spin_roll.get('spin_rate_min',0))/360,
                SpinMax=spin.get('rotation_speed_random_max',spin_roll.get('spin_rate_degrees',0))/360,
                bFlipSpin=spin.get('randomly_flip_direction',False),
                TrailSecondsMin=min(trail.get('length_min',.1),trail.get('length_max',.1)),
                TrailSecondsMax=max(trail.get('length_min',.1),trail.get('length_max',.1)),
                TrailMin=renderer.get('min length',0)*2.54, TrailMax=renderer.get('max length',0)*2.54,
                bVelocityAlign=any(r['functionName']=='render_sprite_trail' for r in part['renderers']),
                UVMin=sequence.get('sequence_min',0), UVMax=sequence.get('sequence_max',0),
                TilesX=props['TilesX'], TilesY=props['TilesY'])
            lock=ops.get('Movement Lock to Control Point',{})
            entry['bLocalSpace']=bool(lock and lock.get('start_fadeout_min',0)>=1 and lock.get('end_fadeout_min',0)>=1)
            for a,b in [('PositionMin','PositionMax'),('VelocityMin','VelocityMax')]:
                low,high=entry[a].copy(),entry[b].copy()
                entry[a]={k:min(low[k],high[k]) for k in low};entry[b]={k:max(low[k],high[k]) for k in low}
            if system=='StickyArm': entry['bLoop']=False; entry['Duration']=0.11
            emitters.append(entry)

for name,path in [('GravityGlowMaterial','sprites/blueflare1_noz.vmt'),('GravityCoreMaterial','effects/fluttercore.vmt'),('GravityBeamMaterial','sprites/lgtning_noz.vmt')]:
    material('gravity',path,name,True)
def gravity(system,mat,size,life,loop=True,count=0,beam=False,noise=0):
    props=next(m for m in materials if m['AssetName']==mat)
    emitters.append(dict(SystemName=system,EmitterName=system,MaterialName=mat,Rate=20 if loop else 0,Duration=life,
        CountMax=count,CountMin=count,bLoop=loop,LifetimeMin=life,LifetimeMax=life,SizeMin=size,SizeMax=size,
        SizeStart=1,SizeEnd=1 if loop else 2,ColorStart=vector([1,1,1]),ColorEnd=vector([1,1,1]),
        Alpha=0.5 if loop else 1,FadeIn=0,FadeOut=0.8,bBeam=beam,Noise=noise,
        AlphaMin=0.5 if loop else 1, bLocalSpace=loop and not beam,
        TilesX=props['TilesX'],TilesY=props['TilesY']))
gravity('GravityGlow','GravityGlowMaterial',5,0.12)
gravity('GravityCore','GravityCoreMaterial',12,0.12)
gravity('GravityArc','GravityBeamMaterial',0.65,0.08,beam=True,noise=4)
gravity('GravityLaunchBeam','GravityBeamMaterial',5.08,0.1,False,1,True,22)
gravity('GravityImpact','GravityCoreMaterial',25,0.2,False,5)

gravity_sounds={'GravityPickup':'physcannon_pickup','GravityLaunch':'superphys_launch1','GravityDry':'physcannon_dryfire',
    'GravityDrop':'physcannon_drop','GravityHold':'superphys_hold_loop','GravityZap':'superphys_small_zap1',
    'GravityOpen':'physcannon_claws_open','GravityClose':'physcannon_claws_close'}
sticky_sounds={'StickyFire':'stickybomblauncher_shoot','StickyDetonate':'stickybomblauncher_det','StickyCharge':'stickybomblauncher_charge_up',
    'StickyBoltBack':'stickybomblauncher_boltback','StickyBoltForward':'stickybomblauncher_boltforward','StickyReload':'stickybomblauncher_worldreload','StickyExplosion':'explode1'}
for kind,mapping,subpath in [('gravity',gravity_sounds,'weapons/physcannon'),('sticky',sticky_sounds,'weapons')]:
    for name,file in mapping.items():
        path=ROOT/'extract/source-weapons'/kind/'sound'/subpath/(file+'.wav')
        if not path.exists(): raise ValueError(f'Original sound missing: {path}')
        sounds.append(dict(AssetName=name,WaveFile=str(path),bLoop=name=='GravityHold'))
animations = []
# The playable integration still uses its existing KF animation set. Keep the
# separate Source mechanism importer opt-in until its multi-take timing is fixed.
if args.include_mechanism_animations:
    animation_build = json.loads((OUT/'animations/build.json').read_text())
    animations = [dict(TakeName=name,Frames=entry['frames'],FPS=entry['fps'])
                  for name,entry in animation_build['actions'].items()]
    assert len(animation_build['exported_animation_stacks']) == len(animations) == 7
lines=['[SourceAssetTools.VRSourceAssetCommandlet]', 'MeshRoot='+str(OUT).replace('\\','/')]
for key,entries in [('Materials',materials),('Sounds',sounds),('Emitters',emitters),('Animations',animations)]:
    lines.extend(key+'='+ini(entry) for entry in entries)
(OUT/'assets.ini').write_text('\n'.join(lines)+'\n')
(OUT/'conversion-report.json').write_text(json.dumps({'materials':len(materials),'emitters':len(emitters),'sounds':len(sounds),
    'unmapped_operators':{k:v for k,v in unsupported.items() if v},
    'renderer_parity_pending': ['Source spritecard lighting and TF2 lightwarp shading',
        'Movement Basic drag', 'Partial movement lock on muzzle embers',
        'Sprite trail growth during its fade-in', 'Random rotation direction distribution']},indent=2))
print(json.dumps({'materials':len(materials),'emitters':len(emitters),'sounds':len(sounds),'unmapped':{k:v for k,v in unsupported.items() if v}}))
