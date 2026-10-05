// Runs the production cache/policy in the real UnrealScript VM, without XR.
class VRRenderSettingsTest extends Object;

var int Checks, Failures;

function Check(bool Success, string Label)
{
    ++Checks;
    if (!Success) { ++Failures; `log("KF2VR_RENDER_TEST failed=" $ Label); }
}

function bool Run()
{
    local VRRenderSettings Settings;
    local KFGFxOptionsMenu_Graphics.GFXSettings Sample;
    local int I, Unexpected;
    Settings = new class'VRRenderSettings';
    Check(Settings.NeedsReadback(Sample, 28, false), "first-readback");
    Unexpected = 0;
    for (I = 0; I < 10000; ++I)
        if (Settings.NeedsReadback(Sample, 28, false)) ++Unexpected;
    Check(Unexpected == 0, "unchanged-readbacks-skip-formatting");
    Sample.Resolution.ResX = 1683;
    Check(Settings.NeedsReadback(Sample, 28, false), "resolution-change-visible");
    Check(!Settings.NeedsReadback(Sample, 28, false), "new-snapshot-stabilizes");
    Sample.MotionBlur.MotionBlur = true;
    Check(Settings.NeedsReadback(Sample, 28, false), "restored-blur-visible");
    Check(Settings.NeedsReadback(Sample, 24, false), "verification-failure-visible");
    Check(Settings.NeedsReadback(Sample, 56, false), "preservation-failure-visible");
    Check(Settings.NeedsReadback(Sample, 57, false), "requested-AA-change-visible");
    Check(Settings.NeedsReadback(Sample, 59, false), "requested-screen-effects-visible");
    Check(Settings.NeedsReadback(Sample, 59, true), "repeated-successful-correction-visible");
    Settings.bReadbackCached = false;
    Check(Settings.NeedsReadback(Sample, 59, false), "engine-recovery-visible");
    Check(!Settings.MatchesPolicy(Sample, false, false), "cache-does-not-accept-bad-policy");
    Settings.bDisableReadbackCache = true;
    Unexpected = 0;
    for (I = 0; I < 10000; ++I)
        if (Settings.NeedsReadback(Sample, 59, false)) ++Unexpected;
    Check(Unexpected == 10000, "baseline-formats-every-readback");
    Check(Settings.NeedsReadback(Sample, 59, true), "baseline-forced-correction");
    Settings.bDisableReadbackCache = false;
    Check(!Settings.NeedsReadback(Sample, 59, false), "reenabled-cache-skips-unchanged");
    `log("KF2VR_RENDER_TEST complete checks=" $ Checks @ "failures=" $ Failures);
    return Failures == 0;
}
