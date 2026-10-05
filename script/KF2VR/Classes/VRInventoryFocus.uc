// Inventory Focus owns no global dilation and never rewrites stock Zed Time.
// FocusTiming's pinned native seam scales the shared simulation delta AFTER
// real/audio clocks advance and BEFORE simulation clocks, AI and scene physics.
// Only presentation actors are compensated. Pawn/controller movement and
// weapon simulation run at the same speed as the rest of the world.
class VRInventoryFocus extends Object config(Game);

struct LocalCompensation
{
    var Actor Target;
    var float Previous;
    var float Applied;
};
var VRHandsBridge Bridge;
var bool bFocusActive;
var config float FocusSimulationSpeed;
var array<LocalCompensation> LocalActors;
var KFPlayerController FeedbackPC;
var bool bFeedbackActive;
var float FeedbackTime;
var float FeedbackAudioModifier;

function Initialize(VRHandsBridge InBridge)
{
    Bridge = InBridge;
    bFocusActive = false;
    if (!(FocusSimulationSpeed > 0.01 && FocusSimulationSpeed <= 1.0))
        FocusSimulationSpeed = 0.2;
}

function float FocusScalar()
{
    return FClamp(FocusSimulationSpeed, 0.05, 1.0);
}

function bool IsZedTimeActive()
{
    local KFGameInfo KFGI;
    if (Bridge == None || Bridge.WorldInfo == None) return false;
    KFGI = KFGameInfo(Bridge.WorldInfo.Game);
    return KFGI != None && KFGI.IsZedTimeActive();
}

function bool CanFocus()
{
    return Bridge != None && !Bridge.bDeleteMe && Bridge.WorldInfo != None
        && Bridge.WorldInfo.NetMode == NM_Standalone
        && Bridge.WorldInfo.Pauser == None && Bridge.WorldInfo.TimeDilation == 1.0
        && !IsZedTimeActive() && Bridge.PC != None && Bridge.PC.IsLocalController()
        && Bridge.Human != None && Bridge.PC.Pawn == Bridge.Human && Bridge.Human.Health > 0
        && Bridge.NativeConnection != 0 && Bridge.NativeValidMask != 0
        && Bridge.NativeHeadTracked != 0 && Bridge.NativeMenuActive == 0 && FocusScalar() < 1.0;
}

function Update(float DeltaTime)
{
    if (Bridge == None) return;
    // Recompute from live selector state; never OR yesterday's request back in.
    Bridge.NativeFocusRequested = 0;
    if (CanFocus() && Bridge.HandInventory != None && Bridge.HandInventory.Input != None)
        Bridge.NativeFocusRequested = Bridge.HandInventory.Input.NativeFocusRequested;
    if (!CanFocus() || Bridge.NativeFocusRequested == 0) bFocusActive = false;
    UpdateFeedback(bFocusActive);
}

function ReleaseFeedback()
{
    if (bFeedbackActive && FeedbackPC != None && !FeedbackPC.bDeleteMe && FeedbackPC.WorldInfo != None)
    {
        // A real Zed Time transition owns its own entry/exit sound and filter.
        if (!IsZedTimeActive() && FeedbackPC.WorldInfo.TimeDilation == 1.0)
            FeedbackPC.PlaySoundBase(FeedbackPC.ZedTimeExitSound, true);
        FeedbackPC.SetRTPCValue('ZEDTime_Modifier', FMax((1.0 - FeedbackPC.WorldInfo.TimeDilation) * 100.0, 0.0), true);
    }
    bFeedbackActive = false;
    FeedbackPC = None;
    FeedbackAudioModifier = -1;
}

function UpdateFeedback(bool bActive)
{
    local float Now, Dt, Target;
    if (Bridge == None || Bridge.WorldInfo == None) { ReleaseFeedback(); return; }
    Now = Bridge.WorldInfo.RealTimeSeconds;
    Dt = FClamp(Now - FeedbackTime, 0.0, 0.1);
    FeedbackTime = Now;
    if (!bActive || FeedbackPC != Bridge.PC) ReleaseFeedback();
    if (bActive && !bFeedbackActive && Bridge.PC != None)
    {
        FeedbackPC = Bridge.PC;
        bFeedbackActive = true;
        FeedbackPC.PlaySoundBase(FeedbackPC.ZedTimeEnterSound, true);
    }
    if (bFeedbackActive && FeedbackAudioModifier != (1.0 - FocusScalar()) * 100.0)
    {
        FeedbackAudioModifier = (1.0 - FocusScalar()) * 100.0;
        FeedbackPC.SetRTPCValue('ZEDTime_Modifier', (1.0 - FocusScalar()) * 100.0, true);
    }
    Target = bActive ? 1.0 : 0.0;
    Bridge.NativeFocusFX += FClamp(Target - Bridge.NativeFocusFX, -Dt / 0.18, Dt / 0.12);
}

function CaptureLocal(Actor A, float Scalar)
{
    local LocalCompensation Entry;
    if (A == None || A.bDeleteMe || A == Bridge.PC || Projectile(A) != None) return;
    if (!(A.CustomTimeDilation > 0.0 && A.CustomTimeDilation <= 20.0)) return;
    Entry.Target = A;
    Entry.Previous = A.CustomTimeDilation;
    Entry.Applied = Entry.Previous / Scalar;
    LocalActors.AddItem(Entry);
    A.CustomTimeDilation = Entry.Applied;
}

// Called only from the native simulation seam, once per world frame.
function PrepareNativeFrame()
{
    local Actor A;
    local float Scalar;
    FinishNativeFrame();
    if (Bridge == None) { bFocusActive = false; ReleaseFeedback(); return; }
    Bridge.NativeFocusScale = 1.0;
    Update(0.0);
    if (!CanFocus() || Bridge.NativeFocusRequested == 0) return;
    Scalar = FocusScalar();
    if (!(Scalar >= 0.05 && Scalar < 1.0)) return;
    foreach Bridge.DynamicActors(class'Actor', A)
    {
        if (A == Bridge || VRWeaponPresenter(A) != None
            || VRHandSelector(A) != None || VRHUDPanel(A) != None)
            CaptureLocal(A, Scalar);
    }
    Bridge.NativeFocusScale = Scalar;
    bFocusActive = true;
    UpdateFeedback(true);
}

// Restore only captured references still carrying the value WE wrote. Actors
// with a coincidentally equal scalar elsewhere in the world are never touched.
function FinishNativeFrame()
{
    local int I;
    local Actor A;
    for (I = 0; I < LocalActors.Length; ++I)
    {
        A = LocalActors[I].Target;
        if (A != None && !A.bDeleteMe && A.CustomTimeDilation == LocalActors[I].Applied)
            A.CustomTimeDilation = LocalActors[I].Previous;
    }
    LocalActors.Length = 0;
    if (Bridge != None) Bridge.NativeFocusScale = 1.0;
}

function Shutdown()
{
    FinishNativeFrame();
    bFocusActive = false;
    ReleaseFeedback();
    if (Bridge != None) { Bridge.NativeFocusRequested = 0; Bridge.NativeFocusFX = 0; }
}

defaultproperties
{
}
