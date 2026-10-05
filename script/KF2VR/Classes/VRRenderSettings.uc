// Local VR clarity policy, applied at ControllerTick before eye-resolution work.
// The caller MUST opt in only for a launcher-created, isolated configuration:
// SCALE SET saves the active SYSTEMSETTINGSINI. It does not update NVIDIA GSA.
class VRRenderSettings extends Object;

const RENDER_SETTINGS_REVISION = 2;

// The stock slider's minimum is 0.5; the VR menu uses the underlying system
// scalar's zero value. Native readback must confirm this before verification.
const MIN_FILM_GRAIN_SCALE = 0.0;

var transient string LastReadback;
var transient float NextApplyTime;
var transient bool bPreservationFailure;
var transient bool bReadbackCached;
var transient bool bDisableReadbackCache;
var transient KFGFxOptionsMenu_Graphics.GFXSettings CachedReadbackSettings;
var transient int CachedReadbackFlags;

// Keep live policy enforcement every tick, but avoid dozens of VM string
// concatenations when the complete readback and its evidence are unchanged.
function bool NeedsReadback(KFGFxOptionsMenu_Graphics.GFXSettings Settings,
    int EvidenceFlags, bool bForce)
{
    // A/B control: rebuild the same diagnostic string each tick, as before.
    // The existing LastReadback comparison still suppresses duplicate logs.
    if (bDisableReadbackCache) return true;
    if (!bForce && bReadbackCached && EvidenceFlags == CachedReadbackFlags
        && Settings == CachedReadbackSettings) return false;
    CachedReadbackSettings = Settings;
    CachedReadbackFlags = EvidenceFlags;
    bReadbackCached = true;
    return true;
}

// Effects that are a function of the screen, the lens or the previous frame
// cannot be correct in sequential stereo while both eyes share one native
// view state. bScreenEffects retains them for an A/B comparison instead.
static function bool MatchesScreenEffectPolicy(
    KFGFxOptionsMenu_Graphics.GFXSettings Settings)
{
    return !Settings.AmbientOcclusion.AmbientOcclusion
        && !Settings.AmbientOcclusion.HBAO
        && !Settings.RealtimeReflections.bAllowScreenSpaceReflections
        && !Settings.LensFlares.bAllowLensFlares
        && Settings.FilmGrain.FilmGrainScale ~= MIN_FILM_GRAIN_SCALE;
}

static function bool MatchesPolicy(KFGFxOptionsMenu_Graphics.GFXSettings Settings,
    bool bPostProcessAA, bool bScreenEffects)
{
    return !Settings.MotionBlur.MotionBlur
        && Settings.MotionBlur.MotionBlurQuality == 0
        && !Settings.DepthOfField.DepthOfField
        && Settings.DepthOfField.DepthOfFieldQuality == 0
        && Settings.AntiAliasing.PostProcessAA == bPostProcessAA
        && !Settings.VSync.VSync
        && Settings.VariableFPS.VariableFrameRate
        && (bScreenEffects || MatchesScreenEffectPolicy(Settings));
}

static function bool UnrelatedSettingsPreserved(
    KFGFxOptionsMenu_Graphics.GFXSettings Before,
    KFGFxOptionsMenu_Graphics.GFXSettings After)
{
    // Exclude only the policy's fields from comparison. This is readback
    // verification, never a whole-structure settings write.
    After.MotionBlur = Before.MotionBlur;
    After.DepthOfField = Before.DepthOfField;
    After.AntiAliasing = Before.AntiAliasing;
    After.VSync = Before.VSync;
    After.VariableFPS = Before.VariableFPS;
    After.AmbientOcclusion = Before.AmbientOcclusion;
    After.RealtimeReflections = Before.RealtimeReflections;
    After.LensFlares = Before.LensFlares;
    After.FilmGrain = Before.FilmGrain;
    return After == Before;
}

function Update(PlayerController PC, bool bPostProcessAA, bool bScreenEffects)
{
    local Engine GameEngine;
    local KFGFxOptionsMenu_Graphics.GFXSettings Before, After;
    local bool bChanged, bResolutionPreserved, bUnrelatedPreserved, bVerified;
    local string Readback;
    local float Now;
    local int EvidenceFlags;

    if (PC == None || PC.WorldInfo == None) return;
    GameEngine = class'Engine'.static.GetEngine();
    if (GameEngine == None)
    {
        bReadbackCached = false;
        if (LastReadback != "engine-unavailable")
            `log("KF2VR_RENDER rev=" $ RENDER_SETTINGS_REVISION
                @ "phase=readback verified=False reason=engine-unavailable");
        LastReadback = "engine-unavailable";
        return;
    }

    class'KFGFxOptionsMenu_Graphics'.static.GetCurrentNativeSettings(Before);
    After = Before;
    Now = PC.WorldInfo.RealTimeSeconds;
    // Two different failures share this path and must not share a policy.
    //   Policy mismatch (blur/DOF back on, nothing else disturbed): retryable.
    //     A driver or GSA override re-enabling an effect is exactly what the
    //     once-a-second retry exists to beat, so it keeps writing forever.
    //   Preservation failure (resolution, display or an unrelated setting
    //     moved): NOT retryable. It means a narrow SCALE SET did something
    //     wider than advertised, and the only safe response is to stop writing
    //     for the session. Retrying it used to clear the flag, which let the
    //     already-damaged settings become the new baseline and a later pass
    //     report verified without ever having preserved the originals.
    if (!bPreservationFailure
        && !MatchesPolicy(Before, bPostProcessAA, bScreenEffects)
        && Now >= NextApplyTime)
    {
        // One attempt per second bounds failed-command retries. Steady state
        // performs only native readback; no console calls, saves or render flush.
        NextApplyTime = Now + 1.0;
        bChanged = true;

        // Do not use SetNativeSettings: the stock menu setter also saves Engine
        // config, unconditionally resizes the viewport, and folds custom texture
        // group LODs into menu presets. SCALE SET changes only its named field,
        // preserves the full FSystemSettings, and only resizes for display edits.
        // It flushes render work: never call this from viewport Draw/Canvas.
        if (Before.MotionBlur.MotionBlur)
            PC.ConsoleCommand("scale set MotionBlur False", false);
        if (Before.MotionBlur.MotionBlurQuality != 0)
            PC.ConsoleCommand("scale set MotionBlurQuality 0", false);
        if (Before.DepthOfField.DepthOfField)
            PC.ConsoleCommand("scale set DepthOfField False", false);
        if (Before.DepthOfField.DepthOfFieldQuality != 0)
            PC.ConsoleCommand("scale set DepthOfFieldQuality 0", false);
        if (Before.AntiAliasing.PostProcessAA != bPostProcessAA)
            PC.ConsoleCommand("scale set PostProcessAA " $ string(bPostProcessAA), false);
        if (Before.VSync.VSync)
            PC.ConsoleCommand("scale set UseVsync False", false);

        // Screen-space, lens and per-frame-noise effects. Each eye renders the
        // whole viewport separately, so these resolve differently per eye and
        // the two images cannot fuse. Names are FSystemSettings INI keys.
        if (!bScreenEffects)
        {
            if (Before.AmbientOcclusion.AmbientOcclusion)
                PC.ConsoleCommand("scale set AmbientOcclusion False", false);
            if (Before.AmbientOcclusion.HBAO)
                PC.ConsoleCommand("scale set HBAO False", false);
            if (Before.RealtimeReflections.bAllowScreenSpaceReflections)
                PC.ConsoleCommand("scale set AllowScreenSpaceReflections False", false);
            if (Before.LensFlares.bAllowLensFlares)
                PC.ConsoleCommand("scale set LensFlares False", false);
            if (!(Before.FilmGrain.FilmGrainScale ~= MIN_FILM_GRAIN_SCALE))
                PC.ConsoleCommand("scale set ImageGrainScaler "
                    $ string(MIN_FILM_GRAIN_SCALE), false);
        }

        // Public SDK property; update the live engine without SaveConfig or
        // changing its class defaults. Native VariableFPS readback verifies it.
        if (!Before.VariableFPS.VariableFrameRate)
            GameEngine.bSmoothFrameRate = false;

        class'KFGFxOptionsMenu_Graphics'.static.GetCurrentNativeSettings(After);
    }

    bResolutionPreserved = Before.Resolution == After.Resolution
        && Before.Display == After.Display;
    bUnrelatedPreserved = UnrelatedSettingsPreserved(Before, After);
    // Sticky for the session, deliberately. Nothing clears this: once a write
    // has been observed to reach past its named field, every later readback
    // stays unverified rather than measuring against the damaged state.
    bPreservationFailure = bPreservationFailure
        || !bResolutionPreserved || !bUnrelatedPreserved;
    bVerified = MatchesPolicy(After, bPostProcessAA, bScreenEffects)
        && !bPreservationFailure;
    EvidenceFlags = int(bPostProcessAA) | (int(bScreenEffects) << 1)
        | (int(bVerified) << 2) | (int(bResolutionPreserved) << 3)
        | (int(bUnrelatedPreserved) << 4) | (int(bPreservationFailure) << 5);
    if (!NeedsReadback(After, EvidenceFlags, bChanged && bVerified)) return;
    Readback = "motionBlur=" $ After.MotionBlur.MotionBlur
        @ "motionBlurQuality=" $ After.MotionBlur.MotionBlurQuality
        @ "depthOfField=" $ After.DepthOfField.DepthOfField
        @ "depthOfFieldQuality=" $ After.DepthOfField.DepthOfFieldQuality
        @ "postProcessAA=" $ After.AntiAliasing.PostProcessAA
        @ "vsync=" $ After.VSync.VSync
        @ "smoothFrameRate=" $ (!After.VariableFPS.VariableFrameRate)
        @ "ambientOcclusion=" $ After.AmbientOcclusion.AmbientOcclusion
        @ "hbao=" $ After.AmbientOcclusion.HBAO
        @ "screenSpaceReflections=" $ After.RealtimeReflections.bAllowScreenSpaceReflections
        @ "lensFlares=" $ After.LensFlares.bAllowLensFlares
        @ "filmGrainScale=" $ After.FilmGrain.FilmGrainScale
        @ "requestedPostProcessAA=" $ bPostProcessAA
        @ "requestedScreenEffects=" $ bScreenEffects
        @ "verified=" $ bVerified
        @ "resolutionPreserved=" $ bResolutionPreserved
        @ "unrelatedPreserved=" $ bUnrelatedPreserved
        @ "preservationFailure=" $ bPreservationFailure
        @ "resX=" $ After.Resolution.ResX @ "resY=" $ After.Resolution.ResY;

    // Repeated successful enforcement is useful evidence of another settings
    // writer. Log failures/state changes too, so latest readback governs success.
    if ((bChanged && bVerified) || Readback != LastReadback)
        `log("KF2VR_RENDER rev=" $ RENDER_SETTINGS_REVISION
            @ "phase=readback" @ Readback @ "changed=" $ bChanged);
    LastReadback = Readback;
}
