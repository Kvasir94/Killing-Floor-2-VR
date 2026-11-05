"""Curated VR detail bundles. Independent effects and corpse physics never belong to a tier."""
from pathlib import Path

SYSTEM = "KFSystemSettings.ini", "SystemSettings"
WORLD = "KFGame.ini", "Engine.WorldInfo"
GORE = "KFGame.ini", "KFGame.KFGoreManager"
PAWN = "KFGame.ini", "KFGame.KFPawn"

def bundle(system=None, **sections):
    result = {SYSTEM: system or {}}
    for section, values in sections.items(): result[("KFGame.ini", section.replace("__", "."))] = values
    return result

ENVIRONMENT = (
    bundle(dict(DetailMode="0", AllowLightFunctions="False", DisableCanBecomeDynamicWakeup="True", MakeDynamicCollisionThreshold="200"), Engine__WorldInfo=dict(DestructionLifetimeScale="0.25")),
    bundle(dict(DetailMode="1", AllowLightFunctions="False", DisableCanBecomeDynamicWakeup="False", MakeDynamicCollisionThreshold="200"), Engine__WorldInfo=dict(DestructionLifetimeScale="0.5")),
    bundle(dict(DetailMode="2", AllowLightFunctions="True", DisableCanBecomeDynamicWakeup="False", MakeDynamicCollisionThreshold="150"), Engine__WorldInfo=dict(DestructionLifetimeScale="1")),
    bundle(dict(DetailMode="2", AllowLightFunctions="True", DisableCanBecomeDynamicWakeup="False", MakeDynamicCollisionThreshold="150"), Engine__WorldInfo=dict(DestructionLifetimeScale="1.2")),
)
CHARACTER = tuple(bundle(dict(SkeletalMeshLODBias=str(lod), AllowSubsurfaceScattering=str(sss), KinematicUpdateDistFactorScale=str(scale))) for lod, sss, scale in ((1, False, 3), (0, False, 1.3), (0, True, 1)))
EFFECTS = tuple(bundle(dict(ParticleLODBias=str(lod), DistanceFogQuality=str(fog), Distortion=str(dist), FilteredDistortion=str(dist), DropParticleDistortion=str(not dist)),
    Engine__WorldInfo=dict(EmitterPoolScale=str(pool), bAllowExplosionLights=str(light), MaxExplosionDecals=str(decals)),
    KFGame__KFMuzzleFlash=dict(ShellEjectLifetime=str(shell)), KFGame__KFSprayActor=dict(bAllowSprayLights=str(dist)),
    KFGame__KFWeap_FlameBase=dict(bArePilotLightsAllowed=str(light)), KFGame__KFImpactEffectManager=dict(MaxImpactEffectDecals=str(impact)))
    for lod,fog,dist,pool,light,decals,shell,impact in ((1,0,False,.25,False,8,2,8),(0,0,False,.5,True,12,5,15),(0,1,True,1,True,15,10,20),(0,1,True,2,True,20,20,40)))
SHADOWS = tuple(bundle(dict(zip(("bAllowWholeSceneDominantShadows", "bOverrideMapWholeSceneDominantShadowSetting", "DynamicShadows", "AllowPerObjectShadows", "MaxWholeSceneDominantShadowResolution", "MaxShadowResolution", "ShadowFadeResolution", "MinShadowResolution", "ShadowTexelsPerPixel", "GlobalShadowDistanceScale", "AllowForegroundPreshadows"), map(str, row)))) for row in (
    (False,False,True,False,1204,1024,256,128,.5,.75,False),
    (True,False,True,True,1204,1024,128,64,1,.75,False),
    (True,False,True,True,1280,1024,128,64,1.3,1,True),
    (True,True,True,True,2048,1536,64,32,2,1.5,True)))

def textures(level):
    import vr_graphics
    biases = ((0,1,3,1,1,2,1), (0,0,2,1,1,2,1), (0,0,1,0,0,1,0), (0,0,0,0,0,0,0))[level]
    result = {}
    for key in vr_graphics.TEXTURE_GROUPS:
        kind = key.removeprefix("TEXTUREGROUP_")
        index = (0 if kind.startswith("UI") else 1 if kind == "Shadowmap" else 2 if kind.startswith(("Character", "Creature", "Cosmetic")) else 4 if kind.startswith("Weapon3rd") else 3 if kind.startswith("Weapon") else 6 if kind.startswith("Effects") else 5)
        result[key] = {"LODBias": str(biases[index])}
    return {SYSTEM: result}

def filtering(level):
    import vr_graphics
    return {SYSTEM: {"MaxAnisotropy": str((1,1,4,16)[level]), **{k: {"MinMagFilter": "aniso" if level > 1 else "linear", "MipFilter": "point" if level == 0 else "linear"} for k in vr_graphics.TEXTURE_GROUPS}}}

BUNDLES = {
    "EnvironmentDetail": ENVIRONMENT, "CharacterDetail": CHARACTER, "EffectsQuality": EFFECTS,
    "TextureQuality": tuple(textures(n) for n in range(4)), "TextureFiltering": tuple(filtering(n) for n in range(4)),
    "ShadowQuality": SHADOWS,
    "Bloom": tuple(bundle(dict(Bloom=str(n > 0), BloomQuality=str(n))) for n in range(3)),
    "VolumetricLighting": tuple(bundle(dict(LightCones=str(on))) for on in (False,True)),
    "LightShafts": tuple(bundle(dict(bAllowLightShafts=str(on))) for on in (False,True)),
}
TIERS = {
    "quality": dict(EnvironmentDetail="3", CharacterDetail="2", EffectsQuality="3", TextureQuality="3", TextureFiltering="3", ShadowQuality="3", VolumetricLighting="1", LightShafts="1"),
    "balanced": dict(EnvironmentDetail="1", CharacterDetail="1", EffectsQuality="1", TextureQuality="2", TextureFiltering="3", ShadowQuality="1", VolumetricLighting="0", LightShafts="0"),
    "performance": dict(EnvironmentDetail="0", CharacterDetail="1", EffectsQuality="0", TextureQuality="2", TextureFiltering="3", ShadowQuality="0", VolumetricLighting="0", LightShafts="0"),
}
GORE_DEFAULTS = {GORE: dict(MaxDeadBodies="12", MaxBloodEffects="25", MaxGoreEffects="10", GoreFXLifetimeMultiplier="1", MaxPersistentSplatsPerFrame="75", MaxBodyWoundDecals="5", bAllowBloodSplatterDecals="True"),
    PAWN: dict(bAllowRagdollAndGoreOnDeadBodies="True", bAllowAlwaysOnPhysics="True", bAllowFootstepSounds="True"),
    SYSTEM: dict(ShouldCorpseCollideWithDead="True", ShouldCorpseCollideWithLiving="True", ShouldCorpseCollideWithDeadAfterSleep="False", AllowSecondaryBloodEffects="True")}
FIELDS = {"Gamma": (("KFEngine.ini","Engine.Engine"),"2.2"), "MaxDeadBodies": (GORE,"12"), "bAllowRagdollAndGoreOnDeadBodies": (PAWN,"True"), "bAllowAlwaysOnPhysics": (PAWN,"True"),
    "ShouldCorpseCollideWithDead": (SYSTEM,"True"), "ShouldCorpseCollideWithLiving": (SYSTEM,"True"), "ShouldCorpseCollideWithDeadAfterSleep": (SYSTEM,"False"),
    "MaxBloodEffects": (GORE,"25"), "MaxGoreEffects": (GORE,"10"), "GoreFXLifetimeMultiplier": (GORE,"1"), "MaxPersistentSplatsPerFrame": (GORE,"75"), "MaxBodyWoundDecals": (GORE,"5")}

GORE_DEFAULTS[GORE].update(BodyWoundDecalLifetime="30",BloodSplatterLifetime="10",BloodPoolLifetime="20",GibletLifetime="10",MaxBloodSplatterDecals="20",MaxBloodPoolDecals="20")
FIELDS.update({key:(GORE,value) for key,value in GORE_DEFAULTS[GORE].items() if key in ("BodyWoundDecalLifetime","BloodSplatterLifetime","BloodPoolLifetime","GibletLifetime","MaxBloodSplatterDecals","MaxBloodPoolDecals")})
FIELDS.update({key:(SYSTEM,value) for key,value in dict(MaxWholeSceneDominantShadowResolution="2048",MaxShadowResolution="1536",ShadowTexelsPerPixel="2",GlobalShadowDistanceScale="1.5").items()})

def merge(target, additions):
    for (filename, section), values in additions.items():
        dest = target.setdefault(filename, {}).setdefault(section, {})
        for key, value in values.items():
            if isinstance(value, dict): dest.setdefault(key, {}).update(value)
            else: dest[key] = value
    return target

def baseline(preset):
    result = merge({}, GORE_DEFAULTS)
    for key, value in dict(TIERS.get(preset, TIERS["quality"]), Bloom="2").items(): merge(result, BUNDLES[key][int(value)])
    return result

def read(root, preset="quality"):
    import vr_graphics
    result = baseline(preset)
    saved = vr_graphics.clean_values(vr_graphics.read_record(Path(root) / vr_graphics.PROFILE_FILE).get("values"))
    for filename, sections in saved.items():
        for section, values in sections.items(): merge(result, {(filename,section):values})
    return result

def values(root, preset="quality"):
    state = read(root, preset)
    result = {}
    for key, choices in BUNDLES.items():
        result[key] = "custom"
        for i, target in enumerate(choices):
            matches = True
            for (filename, section), entries in target.items():
                actual = state.get(filename, {}).get(section, {})
                for name, expected in entries.items():
                    if isinstance(expected, dict): matches &= all(actual.get(name, {}).get(k) == v for k,v in expected.items())
                    else:
                        try: matches &= float(actual.get(name)) == float(expected)
                        except (TypeError,ValueError): matches &= actual.get(name, "").lower() == expected.lower()
            if matches: result[key] = str(i); break
    for key, ((filename,section), default) in FIELDS.items(): result[key] = state.get(filename,{}).get(section,{}).get(key,default)
    return result

def save(edits, root):
    import vr_graphics
    path = Path(root) / vr_graphics.PROFILE_FILE
    record = vr_graphics.read_record(path)
    result = vr_graphics.clean_values(record.get("values"))
    for key, value in edits.items():
        if key in BUNDLES: merge(result, BUNDLES[key][int(value)])
        else:
            pair, _ = FIELDS[key]
            merge(result, {pair: {key:str(value)}})
    vr_graphics.write_record(path, {"schema":vr_graphics.SCHEMA, "defaults_revision":record.get("defaults_revision",0), "values":vr_graphics.clean_values(result)})

def independent_values(saved):
    """Explicit detail selection clears only owned overrides, retaining Bloom and gore."""
    import copy
    result = copy.deepcopy(saved)
    for key in TIERS["quality"]:
        for (filename,section), entries in BUNDLES[key][0].items():
            destination = result.get(filename,{}).get(section,{})
            for name, value in entries.items():
                if isinstance(value,dict):
                    for member in value: destination.get(name,{}).pop(member,None)
                    if not destination.get(name): destination.pop(name,None)
                else: destination.pop(name,None)
    return result


def apply_baseline(configs, preset):
    from launch_support import read_ini, set_ini
    import vr_graphics
    for filename, sections in baseline(preset).items():
        path = Path(configs) / filename
        text = read_ini(path) if path.exists() else ""
        for section, entries in sections.items():
            existing = {k.lower(): v for k,v in vr_graphics.PAIRS.findall(__import__("vr_config").section_body(text,section))}
            edits = dict(entries)
            for key,value in entries.items():
                if not isinstance(value,dict): continue
                members = vr_graphics.texture_members(existing.get(key.lower(), ""))
                if not members:
                    members = dict(minlodsize="1", maxlodsize="4096", lodbias="0", minmagfilter="aniso", mipfilter="linear")
                members.update({k.lower():v for k,v in value.items()})
                edits[key] = "(" + ",".join(f"{k}={v}" for k,v in members.items()) + ")"
            text = set_ini(text,section,edits)
        path.write_text(text,encoding="utf-16")


def legacy_independent(configs, root):
    """Migrate existing players' stock gore/Bloom before introducing complete detail bundles."""
    import vr_graphics
    root=Path(root)
    if not (root / "KFGame.ini").exists() or vr_graphics.read_record(root / vr_graphics.PROFILE_FILE).get("defaults_revision",0)>=1:
        return {}
    current=vr_graphics.capture(configs)
    retained={}
    for (filename,section), defaults in GORE_DEFAULTS.items():
        source=current.get(filename,{}).get(section,{})
        merge(retained,{(filename,section):{key:source[key] for key in defaults if key in source}})
    native=current.get("KFSystemSettings.ini",{}).get("SystemSettings",{})
    merge(retained,{SYSTEM:{key:native[key] for key in ("Bloom","BloomQuality") if key in native}})
    return retained
