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

static function ApplyComfortPolicy(out GFXSettings S)
{
    local GFXSettings Current;
    GetCurrentNativeSettings(Current);
    S.Resolution = Current.Resolution;
    S.Display = Current.Display;
    S.MotionBlur.MotionBlur = false;
    S.MotionBlur.MotionBlurQuality = 0;
    S.DepthOfField.DepthOfField = false;
    S.DepthOfField.DepthOfFieldQuality = 0;
    S.AntiAliasing.PostProcessAA = false;
    S.VSync.VSync = false;
    S.VariableFPS.VariableFrameRate = true;
    S.AmbientOcclusion.AmbientOcclusion = false;
    S.AmbientOcclusion.HBAO = false;
    S.RealtimeReflections.bAllowScreenSpaceReflections = false;
    S.LensFlares.bAllowLensFlares = false;
    S.FilmGrain.FilmGrainScale = class'VRRenderSettings'.const.MIN_FILM_GRAIN_SCALE;
}

function GetModifiedGFXSettings(out GFXSettings S)
{
    Super.GetModifiedGFXSettings(S);
    ApplyComfortPolicy(S);
}

function SetGFXSettings(GFXSettings NewSettings)
{
    ApplyComfortPolicy(NewSettings);
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
            Index = FindCharacterDetailIndex(S.CharacterDetail, default.CharacterDetailPresets); break;
        case 2: Label = "EFFECTS QUALITY"; Values = default.FXStringOptions;
            Index = FindFXQualityIndex(S.FX, default.FXQualityPresets); break;
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

static function bool CycleQuality(PlayerController PC, int Option)
{
    local GFXSettings S, After;
    local int Index;
    if (PC == None) return false;
    GetCurrentGFXSettings(S);
    switch (Option)
    {
        case 0:
            if (default.EnvironmentDetailPresets.Length == 0) return false;
            Index = (FindEnvironmentDetailIndex(S.EnvironmentDetail, default.EnvironmentDetailPresets) + 1) % default.EnvironmentDetailPresets.Length;
            S.EnvironmentDetail = default.EnvironmentDetailPresets[Index]; break;
        case 1:
            if (default.CharacterDetailPresets.Length == 0) return false;
            Index = (FindCharacterDetailIndex(S.CharacterDetail, default.CharacterDetailPresets) + 1) % default.CharacterDetailPresets.Length;
            S.CharacterDetail = default.CharacterDetailPresets[Index]; break;
        case 2:
            if (default.FXQualityPresets.Length == 0) return false;
            Index = (FindFXQualityIndex(S.FX, default.FXQualityPresets) + 1) % default.FXQualityPresets.Length;
            S.FX = default.FXQualityPresets[Index]; break;
        case 3:
            if (default.TextureResolutionPresets.Length == 0) return false;
            Index = (FindTextureResolutionSettingIndex(S.TextureResolution, default.TextureResolutionPresets) + 1) % default.TextureResolutionPresets.Length;
            S.TextureResolution = default.TextureResolutionPresets[Index]; break;
        case 4:
            if (default.TextureFilterPresets.Length == 0) return false;
            Index = (FindTextureFilterSettingIndex(S.TextureFiltering, default.TextureFilterPresets) + 1) % default.TextureFilterPresets.Length;
            S.TextureFiltering = default.TextureFilterPresets[Index]; break;
        case 5:
            if (default.ShadowQualityPresets.Length == 0) return false;
            Index = (FindShadowQualityIndex(S.Shadows, default.ShadowQualityPresets) + 1) % default.ShadowQualityPresets.Length;
            S.Shadows = default.ShadowQualityPresets[Index]; break;
        case 6:
            if (default.BloomPresets.Length == 0) return false;
            Index = (FindBloomSettingIndex(S.Bloom, default.BloomPresets) + 1) % default.BloomPresets.Length;
            S.Bloom = default.BloomPresets[Index]; break;
        case 7:
            if (default.VolumetricLightingPresets.Length == 0) return false;
            Index = (FindVolumetricLightingSettingIndex(S.VolumetricLighting, default.VolumetricLightingPresets) + 1) % default.VolumetricLightingPresets.Length;
            S.VolumetricLighting = default.VolumetricLightingPresets[Index]; break;
        case 8:
            if (default.LightShaftsPresets.Length == 0) return false;
            Index = (FindLightShaftsSettingIndex(S.LightShafts, default.LightShaftsPresets) + 1) % default.LightShaftsPresets.Length;
            S.LightShafts = default.LightShaftsPresets[Index]; break;
        default: return false;
    }
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
        ApplyComfortPolicy(S);
        SetNativeSettings(S);
        break;
    }
    GetCurrentGFXSettings(After);
    `log("KF2VR_MENU quality=" $ Option $ " verified=" $ (After == S));
    return After == S;
}
