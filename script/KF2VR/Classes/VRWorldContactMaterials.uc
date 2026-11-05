// Classify the actual struck zone before stock damage can remove its armor.
class VRWorldContactMaterials extends Object;

const SURFACE_UNKNOWN=0;
const SURFACE_ORGANIC=1;
const SURFACE_METAL=2;
const SURFACE_ARMOR=3;

static function byte PhysicalKind(PhysicalMaterial Material)
{
    local PhysicalMaterialPropertyBase P;
    if (Material == None) return SURFACE_UNKNOWN;
    P = Material.GetPhysicalMaterialProperty(class'KFPhysicalMaterialProperty');
    if (P == None) return SURFACE_UNKNOWN;
    switch (P.MaterialType)
    {
    case EMT_Metal: case EMT_MetalHollow: return SURFACE_METAL;
    case EMT_MetalArmor: return SURFACE_ARMOR;
    case EMT_Flesh: return SURFACE_ORGANIC;
    }
    return SURFACE_UNKNOWN;
}

static function byte ResolveTarget(KFPawn_Monster Victim, name Zone, vector Point,
    vector Incoming, PhysicalMaterial BodyMaterial)
{
    local int Index;
    local byte BodyKind, MeshKind;
    local KFSkinTypeEffects Skin;
    local string Path;
    if (Victim == None || Victim.Mesh == None) return SURFACE_UNKNOWN;
    Index = Victim.GetHitZoneIndex(Zone);
    // Stock DAR/boss virtual mappings also admit their special armor index.
    if (Index < 0) return SURFACE_UNKNOWN;
    if (Victim.ArmorInfo != None)
    {
        Index = Victim.ArmorInfo.GetArmorZoneIndex(Zone,Point - Normal(Incoming) * 64.0);
        if (Index >= 0 && Index < Victim.ArmorInfo.ArmorZones.Length
            && Victim.ArmorInfo.ArmorZones[Index].ArmorHealth > 0) return SURFACE_ARMOR;
    }
    BodyKind = PhysicalKind(BodyMaterial);
    if (BodyKind >= SURFACE_METAL) return BodyKind;
    // Use the virtual per-zone mapping (DARs and bosses override it).
    Skin = Victim.GetHitZoneSkinTypeEffects(Victim.GetHitZoneIndex(Zone));
    // Cloaking changes the visual hit effect, not the limb's material.
    Index = Victim.GetHitZoneIndex(Zone);
    if (Skin != None && Caps(PathName(Skin)) == "FX_IMPACTS_ARCH.SKINTYPES.PATRIARCH_CLOAKED"
        && Victim.CharacterArch != None && Index >= 0 && Index < Victim.HitZones.Length
        && Victim.HitZones[Index].SkinID < Victim.CharacterArch.ImpactSkins.Length)
        Skin = Victim.CharacterArch.ImpactSkins[Victim.HitZones[Index].SkinID];
    Path = Caps(PathName(Skin));
    switch (Path)
    {
    case "FX_IMPACTS_ARCH.SKINTYPES.METAL":
    case "FX_IMPACTS_ARCH.SKINTYPES.MACHINE": return SURFACE_METAL;
    case "FX_IMPACTS_ARCH.SKINTYPES.ARMOR_MACHINE": return SURFACE_ARMOR;
    case "FX_IMPACTS_ARCH.SKINTYPES.FLESH":
    case "FX_IMPACTS_ARCH.SKINTYPES.TOUGH_FLESH":
    case "FX_IMPACTS_ARCH.SKINTYPES.HUMAN_FLESH": return SURFACE_ORGANIC;
    case "FX_IMPACTS_ARCH.SKINTYPES.SKULL": return SURFACE_ORGANIC;
    }
    MeshKind = PhysicalKind(Victim.Mesh.PhysMaterialOverride);
    if (MeshKind != SURFACE_UNKNOWN) return MeshKind;
    return BodyKind;
}

static simulated function PresentImpact(Actor Context, vector Point, vector Normal,
    bool bSharp, byte SurfaceKind)
{
    local KFImpactEffectInfo Table;
    local KFImpactEffectInfo.MaterialImpactEffect Effect;
    local int I;
    local EMaterialTypes Material;
    if (Context == None || Context.WorldInfo.NetMode == NM_DedicatedServer
        || SurfaceKind < SURFACE_ORGANIC) return;
    if (bSharp) Table = KFImpactEffectInfo'FX_Impacts_ARCH.Bladed_melee_impact';
    else Table = KFImpactEffectInfo'FX_Impacts_ARCH.Blunted_melee_impact';
    if (SurfaceKind == SURFACE_ORGANIC) Material = EMT_Flesh;
    else if (SurfaceKind == SURFACE_ARMOR) Material = EMT_MetalArmor;
    else Material = EMT_Metal;
    for (I = 0; I < Table.ImpactEffects.Length; ++I)
        if (Table.ImpactEffects[I].MaterialType == Material)
        {
            Effect = Table.ImpactEffects[I];
            if (Effect.Sound != None) Context.PlaySoundBase(Effect.Sound,true,,,Point);
            // TakeDamage already owns flesh blood and hit reactions. Supply
            // the missing stock blade/bash sound without duplicating blood.
            if (SurfaceKind != SURFACE_ORGANIC && Effect.ParticleTemplate != None && Context.WorldInfo.MyEmitterPool != None)
                Context.WorldInfo.MyEmitterPool.SpawnEmitter(Effect.ParticleTemplate,Point,rotator(Normal));
            return;
        }
}
