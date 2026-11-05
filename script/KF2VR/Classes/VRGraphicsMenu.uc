// Stock movie, labels, quality presets and apply/revert flow. Display dimensions
// belong to OpenXR and the comfort policy is applied before any settings write.
class VRGraphicsMenu extends KFGFxOptionsMenu_Graphics;

// Stock Options can still request this widget. Queue the VR quality page on
// the viewport tick rather than closing GFx while its widget initializes.
function OnOpen()
{
    local PlayerController PC;
    local VRGameViewportClient V;
    PC = GetPC();
    if (PC == None || LocalPlayer(PC.Player) == None) return;
    V = VRGameViewportClient(LocalPlayer(PC.Player).ViewportClient);
    if (V != None && V.VRSession != None) V.VRSession.bGraphicsMenuRequested = true;
}

static function ApplyComfortPolicy(out GFXSettings S, PlayerController PC)
{
    local GFXSettings Current;
    local VRGameViewportClient V;
    local int PolicyFlags;
    PolicyFlags = int(class'VRHandsBridge'.default.bVRPostProcessAA)
        + 2 * int(class'VRHandsBridge'.default.bVRScreenEffects);
    if (PC != None && LocalPlayer(PC.Player) != None)
        V = VRGameViewportClient(LocalPlayer(PC.Player).ViewportClient);
    if (V != None && V.VRSession != None)
        PolicyFlags = V.VRSession.RenderPolicyFlags();
    GetCurrentNativeSettings(Current);
    S.Resolution = Current.Resolution;
    S.Display = Current.Display;
    if (V == None || V.VRSession == None || !V.VRSession.bCinematicMotionBlur)
    {
    S.MotionBlur.MotionBlur = false;
    S.MotionBlur.MotionBlurQuality = 0;
    }
    if (V == None || V.VRSession == None || !V.VRSession.bCinematicDepthOfField)
    {
    S.DepthOfField.DepthOfField = false;
    S.DepthOfField.DepthOfFieldQuality = 0;
    }
    S.AntiAliasing.PostProcessAA = (PolicyFlags & 1) != 0;
    S.VSync.VSync = false;
    S.VariableFPS.VariableFrameRate = true;
    if ((PolicyFlags & 2) == 0)
    {
        S.AmbientOcclusion.AmbientOcclusion = false;
        S.AmbientOcclusion.HBAO = false;
        S.RealtimeReflections.bAllowScreenSpaceReflections = false;
        S.LensFlares.bAllowLensFlares = false;
        S.FilmGrain.FilmGrainScale = class'VRRenderSettings'.const.MIN_FILM_GRAIN_SCALE;
    }
}

function GetModifiedGFXSettings(out GFXSettings S)
{
    Super.GetModifiedGFXSettings(S);
    ApplyComfortPolicy(S, GetPC());
}

function SetGFXSettings(GFXSettings NewSettings)
{
    ApplyComfortPolicy(NewSettings, GetPC());
    RevertedGFXSettings = CurrentGFXSettings;
    SetNativeSettings(NewSettings);
    SetScriptSettings(NewSettings);
    CurrentGFXSettings = NewSettings;
}

// VR settings use the launcher's dedicated persisted profile. GSA is the
// desktop preference store and must not receive OpenXR eye dimensions.
static function UpdateGSA(GFXSettings InSettings) {}

// The spatial shell exposes only editable VR-safe quality options. Read native
// and script state for the current value; preserve the remainder when applying.
static function int VisualCharacterIndex(CharacterDetailSetting S)
{
    local int I;
    local CharacterDetailSetting P;
    for (I = 0; I < default.CharacterDetailPresets.Length; ++I)
    {
        P = default.CharacterDetailPresets[I];
        P.MaxDeadBodies = S.MaxDeadBodies; P.MaxBodyWoundDecals = S.MaxBodyWoundDecals;
        P.ShouldCorpseCollideWithDead = S.ShouldCorpseCollideWithDead;
        P.ShouldCorpseCollideWithLiving = S.ShouldCorpseCollideWithLiving;
        P.ShouldCorpseCollideWithDeadAfterSleep = S.ShouldCorpseCollideWithDeadAfterSleep;
        P.bAllowPhysics = S.bAllowPhysics;
        if (S == P) return I;
    }
    return -1;
}

static function int VisualFXIndex(FXQualitySetting S)
{
    local int I;
    local FXQualitySetting P;
    for (I = 0; I < default.FXQualityPresets.Length; ++I)
    {
        P = default.FXQualityPresets[I];
        P.AllowFootstepSounds = S.AllowFootstepSounds;
        P.AllowRagdollAndGoreOnDeadBodies = S.AllowRagdollAndGoreOnDeadBodies;
        P.GoreFXLifetimeMultiplier = S.GoreFXLifetimeMultiplier;
        P.MaxBloodEffects = S.MaxBloodEffects; P.MaxGoreEffects = S.MaxGoreEffects;
        P.AllowSecondaryBloodEffects = S.AllowSecondaryBloodEffects;
        P.AllowBloodSplatterDecals = S.AllowBloodSplatterDecals;
        P.MaxPersistentSplatsPerFrame = S.MaxPersistentSplatsPerFrame;
        if (S == P) return I;
    }
    return -1;
}

static function string QualityLabel(int Option, GFXSettings S)
{
    local int Index;
    local string Label;
    local array<string> Values;
    switch (Option)
    {
        case 0: Label = "ENVIRONMENT DETAIL"; Values = default.EnvironmentDetailsStringOptions;
            Index = FindEnvironmentDetailIndex(S.EnvironmentDetail, default.EnvironmentDetailPresets); break;
        case 1: Label = "CHARACTER DETAIL"; Values = default.CharacterDetailStringOptions;
            Index = VisualCharacterIndex(S.CharacterDetail); break;
        case 2: Label = "EFFECTS QUALITY"; Values = default.FXStringOptions;
            Index = VisualFXIndex(S.FX); break;
        case 3: Label = "TEXTURE QUALITY"; Values = default.TextureResolutionStringOptions;
            Index = FindTextureResolutionSettingIndex(S.TextureResolution, default.TextureResolutionPresets); break;
        case 4: Label = "TEXTURE FILTERING"; Values = default.TextureFilteringStringOptions;
            Index = FindTextureFilterSettingIndex(S.TextureFiltering, default.TextureFilterPresets); break;
        case 5: Label = "SHADOW QUALITY"; Values = default.ShadowsStringOptions;
            Index = FindShadowQualityIndex(S.Shadows, default.ShadowQualityPresets); break;
        case 6: Label = "BLOOM"; Values = default.BloomStringOptions;
            Index = FindBloomSettingIndex(S.Bloom, default.BloomPresets); break;
        case 7: Label = "VOLUMETRIC LIGHTING"; Values = default.OffOnStringOptions;
            Index = FindVolumetricLightingSettingIndex(S.VolumetricLighting, default.VolumetricLightingPresets); break;
        case 8: Label = "LIGHT SHAFTS"; Values = default.OffOnStringOptions;
            Index = FindLightShaftsSettingIndex(S.LightShafts, default.LightShaftsPresets); break;
        default: return "";
    }
    return Label $ ": " $ ((Index >= 0 && Index < Values.Length) ? Caps(Values[Index]) : "CUSTOM");
}

static function bool CycleQuality(PlayerController PC, int Option, optional int Target=-1)
{
    local GFXSettings S, Before, After;
    local int Index;
    if (PC == None) return false;
    GetCurrentGFXSettings(S);
    Before = S;
    switch (Option)
    {
        case 0:
            if (default.EnvironmentDetailPresets.Length == 0) return false;
            Index = Target >= 0 ? Target : (FindEnvironmentDetailIndex(S.EnvironmentDetail, default.EnvironmentDetailPresets) + 1) % default.EnvironmentDetailPresets.Length;
            S.EnvironmentDetail = default.EnvironmentDetailPresets[Index]; break;
        case 1:
            if (default.CharacterDetailPresets.Length == 0) return false;
            Index = Target >= 0 ? Target : (VisualCharacterIndex(S.CharacterDetail) + 1) % default.CharacterDetailPresets.Length;
            S.CharacterDetail = default.CharacterDetailPresets[Index]; break;
        case 2:
            if (default.FXQualityPresets.Length == 0) return false;
            Index = Target >= 0 ? Target : (VisualFXIndex(S.FX) + 1) % default.FXQualityPresets.Length;
            S.FX = default.FXQualityPresets[Index]; break;
        case 3:
            if (default.TextureResolutionPresets.Length == 0) return false;
            Index = Target >= 0 ? Target : (FindTextureResolutionSettingIndex(S.TextureResolution, default.TextureResolutionPresets) + 1) % default.TextureResolutionPresets.Length;
            S.TextureResolution = default.TextureResolutionPresets[Index]; break;
        case 4:
            if (default.TextureFilterPresets.Length == 0) return false;
            Index = Target >= 0 ? Target : (FindTextureFilterSettingIndex(S.TextureFiltering, default.TextureFilterPresets) + 1) % default.TextureFilterPresets.Length;
            S.TextureFiltering = default.TextureFilterPresets[Index]; break;
        case 5:
            if (default.ShadowQualityPresets.Length == 0) return false;
            Index = Target >= 0 ? Target : (FindShadowQualityIndex(S.Shadows, default.ShadowQualityPresets) + 1) % default.ShadowQualityPresets.Length;
            S.Shadows = default.ShadowQualityPresets[Index]; break;
        case 6:
            if (default.BloomPresets.Length == 0) return false;
            Index = Target >= 0 ? Target : (FindBloomSettingIndex(S.Bloom, default.BloomPresets) + 1) % default.BloomPresets.Length;
            S.Bloom = default.BloomPresets[Index]; break;
        case 7:
            if (default.VolumetricLightingPresets.Length == 0) return false;
            Index = Target >= 0 ? Target : (FindVolumetricLightingSettingIndex(S.VolumetricLighting, default.VolumetricLightingPresets) + 1) % default.VolumetricLightingPresets.Length;
            S.VolumetricLighting = default.VolumetricLightingPresets[Index]; break;
        case 8:
            if (default.LightShaftsPresets.Length == 0) return false;
            Index = Target >= 0 ? Target : (FindLightShaftsSettingIndex(S.LightShafts, default.LightShaftsPresets) + 1) % default.LightShaftsPresets.Length;
            S.LightShafts = default.LightShaftsPresets[Index]; break;
        default: return false;
    }
    S.CharacterDetail.MaxDeadBodies = Before.CharacterDetail.MaxDeadBodies;
    S.CharacterDetail.MaxBodyWoundDecals = Before.CharacterDetail.MaxBodyWoundDecals;
    S.CharacterDetail.ShouldCorpseCollideWithDead = Before.CharacterDetail.ShouldCorpseCollideWithDead;
    S.CharacterDetail.ShouldCorpseCollideWithLiving = Before.CharacterDetail.ShouldCorpseCollideWithLiving;
    S.CharacterDetail.ShouldCorpseCollideWithDeadAfterSleep = Before.CharacterDetail.ShouldCorpseCollideWithDeadAfterSleep;
    S.CharacterDetail.bAllowPhysics = Before.CharacterDetail.bAllowPhysics;
    S.FX.AllowFootstepSounds = Before.FX.AllowFootstepSounds;
    S.FX.AllowRagdollAndGoreOnDeadBodies = Before.FX.AllowRagdollAndGoreOnDeadBodies;
    S.FX.GoreFXLifetimeMultiplier = Before.FX.GoreFXLifetimeMultiplier;
    S.FX.MaxBloodEffects = Before.FX.MaxBloodEffects;
    S.FX.MaxGoreEffects = Before.FX.MaxGoreEffects;
    S.FX.AllowSecondaryBloodEffects = Before.FX.AllowSecondaryBloodEffects;
    S.FX.AllowBloodSplatterDecals = Before.FX.AllowBloodSplatterDecals;
    S.FX.MaxPersistentSplatsPerFrame = Before.FX.MaxPersistentSplatsPerFrame;
    // SCALE SET preserves texture group overrides and avoids resizing the
    // OpenXR viewport when the player changes a non-texture quality option.
    switch (Option)
    {
    case 0:
        PC.ConsoleCommand("scale set DetailMode " $ string(S.EnvironmentDetail.DetailMode), false);
        PC.ConsoleCommand("scale set AllowLightFunctions " $ string(S.EnvironmentDetail.AllowLightFunctions), false);
        PC.ConsoleCommand("scale set DisableCanBecomeDynamicWakeup " $ string(S.EnvironmentDetail.bDisableCanBecomeDynamicWakeup), false);
        PC.ConsoleCommand("scale set MakeDynamicCollisionThreshold " $ string(S.EnvironmentDetail.MakeDynamicCollisionThreshold), false);
        SetScriptEnvironmentDetailSettings(S.EnvironmentDetail);
        break;
    case 1:
        PC.ConsoleCommand("scale set SkeletalMeshLODBias " $ string(S.CharacterDetail.SkeletalMeshLODBias), false);
        PC.ConsoleCommand("scale set AllowSubsurfaceScattering " $ string(S.CharacterDetail.AllowSubsurfaceScattering), false);
        PC.ConsoleCommand("scale set KinematicUpdateDistFactorScale " $ string(S.CharacterDetail.KinematicUpdateDistFactorScale), false);
        PC.ConsoleCommand("scale set ShouldCorpseCollideWithDead " $ string(S.CharacterDetail.ShouldCorpseCollideWithDead), false);
        PC.ConsoleCommand("scale set ShouldCorpseCollideWithLiving " $ string(S.CharacterDetail.ShouldCorpseCollideWithLiving), false);
        PC.ConsoleCommand("scale set ShouldCorpseCollideWithDeadAfterSleep " $ string(S.CharacterDetail.ShouldCorpseCollideWithDeadAfterSleep), false);
        SetScriptCharacterDetailSettings(S.CharacterDetail);
        break;
    case 2:
        PC.ConsoleCommand("scale set ParticleLODBias " $ string(S.FX.ParticleLODBias), false);
        PC.ConsoleCommand("scale set DistanceFogQuality " $ string(S.FX.DistanceFogQuality), false);
        PC.ConsoleCommand("scale set Distortion " $ string(S.FX.Distortion), false);
        PC.ConsoleCommand("scale set FilteredDistortion " $ string(S.FX.FilteredDistortion), false);
        PC.ConsoleCommand("scale set DropParticleDistortion " $ string(S.FX.DropParticleDistortion), false);
        PC.ConsoleCommand("scale set AllowSecondaryBloodEffects " $ string(S.FX.AllowSecondaryBloodEffects), false);
        SetScriptFXQualitySettings(S.FX);
        break;
    case 5:
        PC.ConsoleCommand("scale set bAllowWholeSceneDominantShadows " $ string(S.Shadows.bAllowWholeSceneDominantShadows), false);
        PC.ConsoleCommand("scale set bOverrideMapWholeSceneDominantShadowSetting " $ string(S.Shadows.bOverrideMapWholeSceneDominantShadowSetting), false);
        PC.ConsoleCommand("scale set DynamicShadows " $ string(S.Shadows.bAllowDynamicShadows), false);
        PC.ConsoleCommand("scale set AllowPerObjectShadows " $ string(S.Shadows.bAllowPerObjectShadows), false);
        PC.ConsoleCommand("scale set MaxWholeSceneDominantShadowResolution " $ string(S.Shadows.MaxWholeSceneDominantShadowResolution), false);
        PC.ConsoleCommand("scale set MaxShadowResolution " $ string(S.Shadows.MaxShadowResolution), false);
        PC.ConsoleCommand("scale set ShadowFadeResolution " $ string(S.Shadows.ShadowFadeResolution), false);
        PC.ConsoleCommand("scale set MinShadowResolution " $ string(S.Shadows.MinShadowResolution), false);
        PC.ConsoleCommand("scale set ShadowTexelsPerPixel " $ string(S.Shadows.ShadowTexelsPerPixel), false);
        PC.ConsoleCommand("scale set GlobalShadowDistanceScale " $ string(S.Shadows.GlobalShadowDistanceScale), false);
        PC.ConsoleCommand("scale set AllowForegroundPreshadows " $ string(S.Shadows.AllowForegroundPreshadows), false);
        break;
    case 6:
        PC.ConsoleCommand("scale set Bloom " $ string(S.Bloom.Bloom), false);
        PC.ConsoleCommand("scale set BloomQuality " $ string(S.Bloom.BloomQuality), false);
        break;
    case 7:
        PC.ConsoleCommand("scale set LightCones " $ string(S.VolumetricLighting.bAllowLightCones), false);
        break;
    case 8:
        PC.ConsoleCommand("scale set bAllowLightShafts " $ string(S.LightShafts.bAllowLightShafts), false);
        break;
    case 3: case 4:
        // Texture quality/filtering deliberately selects stock grouped presets.
        // A filter edit must not flatten nonuniform texture LOD biases to -1.
        if (Option == 4 && (S.TextureResolution.UIBias < 0 || S.TextureResolution.ShadowmapBias < 0
            || S.TextureResolution.CharacterBias < 0 || S.TextureResolution.Weapon1stBias < 0
            || S.TextureResolution.Weapon3rdBias < 0 || S.TextureResolution.EnvironmentBias < 0
            || S.TextureResolution.FXBias < 0)) return false;
        ApplyComfortPolicy(S, PC);
        SetNativeSettings(S);
        break;
    }
    GetCurrentGFXSettings(After);
    `log("KF2VR_MENU quality=" $ Option $ " verified=" $ (After == S));
    return After == S;
}

static function AdjustShadowTuning(PlayerController PC, int Option, int Direction)
{
    local GFXSettings S;
    local string Key, Value;
    if (PC == None || Direction == 0) return;
    GetCurrentGFXSettings(S);
    switch (Option)
    {
        case 0: Key = "MaxWholeSceneDominantShadowResolution"; Value = string(Clamp(S.Shadows.MaxWholeSceneDominantShadowResolution + Direction * 256, 256, 8192)); break;
        case 1: Key = "MaxShadowResolution"; Value = string(Clamp(S.Shadows.MaxShadowResolution + Direction * 256, 256, 8192)); break;
        case 2: Key = "ShadowTexelsPerPixel"; Value = string(FClamp(S.Shadows.ShadowTexelsPerPixel + Direction * 0.25, 0.25, 8)); break;
        case 3: Key = "GlobalShadowDistanceScale"; Value = string(FClamp(S.Shadows.GlobalShadowDistanceScale + Direction * 0.25, 0.25, 4)); break;
        default: return;
    }
    PC.ConsoleCommand("scale set " $ Key $ " " $ Value, false);
}

static function int PresetIndex()
{
    local GFXSettings S;
    local int I, Environment, Character, FX, Textures, Shadows, Lighting;
    GetCurrentGFXSettings(S);
    for (I = 0; I < 3; ++I)
    {
        Environment = I == 0 ? 3 : (I == 1 ? 1 : 0);
        Character = I == 0 ? 2 : 1;
        FX = I == 0 ? 3 : (I == 1 ? 1 : 0);
        Textures = I == 0 ? 3 : 2;
        Shadows = I == 0 ? 3 : (I == 1 ? 1 : 0);
        Lighting = I == 0 ? 1 : 0;
        if (S.EnvironmentDetail == default.EnvironmentDetailPresets[Environment]
            && VisualCharacterIndex(S.CharacterDetail) == Character
            && VisualFXIndex(S.FX) == FX
            && S.TextureResolution == default.TextureResolutionPresets[Textures]
            && S.TextureFiltering == default.TextureFilterPresets[3]
            && ShadowsMatch(S.Shadows, default.ShadowQualityPresets[Shadows])
            && S.VolumetricLighting == default.VolumetricLightingPresets[Lighting]
            && S.LightShafts == default.LightShaftsPresets[Lighting]
            && S.AmbientOcclusion.HBAO == (I == 0)
            && S.RealtimeReflections.bAllowScreenSpaceReflections == (I == 0)) return I;
    }
    return -1;
}
// The groups that keep the live settings from matching preset Tier, for
// diagnosing a CUSTOM label (#136); "match" when none do. Mirrors PresetIndex.
static function string PresetReport(int Tier)
{
    local GFXSettings S;
    local string Out;
    GetCurrentGFXSettings(S);
    if (S.EnvironmentDetail != default.EnvironmentDetailPresets[Tier == 0 ? 3 : (Tier == 1 ? 1 : 0)]) Out @= "environment";
    if (VisualCharacterIndex(S.CharacterDetail) != (Tier == 0 ? 2 : 1)) Out @= "character";
    if (VisualFXIndex(S.FX) != (Tier == 0 ? 3 : (Tier == 1 ? 1 : 0))) Out @= "fx";
    if (S.TextureResolution != default.TextureResolutionPresets[Tier == 0 ? 3 : 2]) Out @= "textures";
    if (S.TextureFiltering != default.TextureFilterPresets[3])
        Out @= "filtering(" $ S.TextureFiltering.MinMagFilter $ "," $ S.TextureFiltering.MipFilter $ "," $ S.TextureFiltering.MaxAnisotropy $ ")";
    if (!ShadowsMatch(S.Shadows, default.ShadowQualityPresets[Tier == 0 ? 3 : (Tier == 1 ? 1 : 0)]))
        Out @= "shadows(" $ ShadowText(S.Shadows) $ " want " $ ShadowText(default.ShadowQualityPresets[Tier == 0 ? 3 : (Tier == 1 ? 1 : 0)]) $ ")";
    if (S.VolumetricLighting != default.VolumetricLightingPresets[Tier == 0 ? 1 : 0]) Out @= "volumetric";
    if (S.LightShafts != default.LightShaftsPresets[Tier == 0 ? 1 : 0]) Out @= "lightshafts";
    if (S.AmbientOcclusion.HBAO != (Tier == 0)) Out @= "hbao";
    if (S.RealtimeReflections.bAllowScreenSpaceReflections != (Tier == 0)) Out @= "reflections";
    return Out == "" ? "match" : Mid(Out, 1);
}
// The engine reads per-object shadows back as off even with AllowPerObjectShadows=True
// in the INI, so every QUALITY or BALANCED launch read CUSTOM (#136, replay probe
// on 20261105-034409). The tiers differ in every other shadow field anyway.
static function bool ShadowsMatch(ShadowQualitySetting Live, ShadowQualitySetting Preset)
{
    Live.bAllowPerObjectShadows = Preset.bAllowPerObjectShadows;
    return Live == Preset;
}
static function string ShadowText(ShadowQualitySetting Q)
{
    return int(Q.bAllowWholeSceneDominantShadows) $ int(Q.bOverrideMapWholeSceneDominantShadowSetting)
        $ int(Q.bAllowDynamicShadows) $ int(Q.bAllowPerObjectShadows) $ int(Q.AllowForegroundPreshadows)
        $ "/" $ Q.MaxWholeSceneDominantShadowResolution $ "/" $ Q.MaxShadowResolution $ "/" $ Q.ShadowFadeResolution
        $ "/" $ Q.MinShadowResolution $ "/" $ Q.ShadowTexelsPerPixel $ "/" $ Q.GlobalShadowDistanceScale;
}
static function string PresetLabel()
{
    switch (PresetIndex()) { case 0: return "QUALITY"; case 1: return "BALANCED"; case 2: return "PERFORMANCE"; }
    return "CUSTOM";
}
static function ApplyDetailPreset(PlayerController PC, int Tier)
{
    if (PC == None) return;
    CycleQuality(PC, 0, Tier == 0 ? 3 : (Tier == 1 ? 1 : 0));
    CycleQuality(PC, 1, Tier == 0 ? 2 : 1);
    CycleQuality(PC, 2, Tier == 0 ? 3 : (Tier == 1 ? 1 : 0));
    CycleQuality(PC, 3, Tier == 0 ? 3 : 2);
    CycleQuality(PC, 4, 3);
    CycleQuality(PC, 5, Tier == 0 ? 3 : (Tier == 1 ? 1 : 0));
    CycleQuality(PC, 7, Tier == 0 ? 1 : 0);
    CycleQuality(PC, 8, Tier == 0 ? 1 : 0);
    PC.ConsoleCommand("scale set AmbientOcclusion " $ string(Tier == 0), false);
    PC.ConsoleCommand("scale set HBAO " $ string(Tier == 0), false);
    PC.ConsoleCommand("scale set AllowScreenSpaceReflections " $ string(Tier == 0), false);
}

static function ToggleEffect(PlayerController PC, int Option)
{
    local GFXSettings S;
    if (PC == None) return;
    GetCurrentGFXSettings(S);
    if (Option == 0)
    {
        PC.ConsoleCommand("scale set AmbientOcclusion " $ string(!S.AmbientOcclusion.HBAO), false);
        PC.ConsoleCommand("scale set HBAO " $ string(!S.AmbientOcclusion.HBAO), false);
    }
    if (Option == 1) PC.ConsoleCommand("scale set AllowScreenSpaceReflections " $ string(!S.RealtimeReflections.bAllowScreenSpaceReflections), false);
}

static function TogglePhysics(PlayerController PC, int Option)
{
    local GFXSettings S;
    local KFPawn P;
    if (PC == None) return;
    GetCurrentGFXSettings(S);
    if (Option == 0)
    {
        class'KFPawn'.default.bAllowAlwaysOnPhysics = !class'KFPawn'.default.bAllowAlwaysOnPhysics;
        foreach PC.WorldInfo.AllPawns(class'KFPawn', P) P.bAllowAlwaysOnPhysics = class'KFPawn'.default.bAllowAlwaysOnPhysics;
        class'KFPawn'.static.StaticSaveConfig();
    }
    if (Option == 1) PC.ConsoleCommand("scale set ShouldCorpseCollideWithDead " $ string(!S.CharacterDetail.ShouldCorpseCollideWithDead), false);
    if (Option == 2) PC.ConsoleCommand("scale set ShouldCorpseCollideWithLiving " $ string(!S.CharacterDetail.ShouldCorpseCollideWithLiving), false);
    if (Option == 3) PC.ConsoleCommand("scale set ShouldCorpseCollideWithDeadAfterSleep " $ string(!S.CharacterDetail.ShouldCorpseCollideWithDeadAfterSleep), false);
}
