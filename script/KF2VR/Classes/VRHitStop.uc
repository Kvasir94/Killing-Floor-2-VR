// Melee hit-stop: a struck Zed's animation is slowed for a few frames, so it
// visibly sticks on the fist. Only the victim's mesh is slowed; the player,
// camera and world keep real time, which is what keeps this comfortable in VR.
//
// Animation only, not the actor clock. CustomTimeDilation is not replicated:
// on a network client it slowed only the local proxy while server positions
// kept arriving (a frozen pose sliding), and on a listen host it slowed the
// real Zed for every player. GlobalAnimRateScale, which stock KF2 never
// touches, is purely presentational, so solo, host and client all see the
// same stick and the AI, movement and damage are unchanged.
// Switched by VRHandsBridge.bMeleeHitStop (KFGame.ini); durations below. Every
// frozen Zed is restored by Update, Clear and Shutdown, so turning the switch
// off mid-freeze or tearing the adapter down never leaves a Zed slowed.
class VRHitStop extends Object;

struct VRFrozen
{
    var Actor Victim;
    var SkeletalMeshComponent Mesh;
    var float Original;
    var float Until;
};

var VRHandsBridge Bridge;
var array<VRFrozen> Frozen;
var int Freezes;

var float Dilation;          // Victim animation rate while stopped.
var float LightDuration;     // Real seconds, for the lightest landed punch.
var float HeavyDuration;     // A full-speed punch.
var float ChargedDuration;   // A charged punch.
var float ImpactDuration;    // A held or thrown body striking a Zed.
var float MaximumDuration;

function Initialize(VRHandsBridge B)
{
    Bridge = B;
}

function bool Enabled()
{
    return Bridge != None && Bridge.bMeleeHitStop;
}

// Light-to-heavy duration for a hit of the given strength (0..1).
function float PunchDuration(float Alpha)
{
    return LightDuration + (HeavyDuration - LightDuration) * FClamp(Alpha, 0, 1);
}

function Freeze(Actor Victim, float Duration)
{
    local KFPawn P;
    local VRFrozen F;
    local SkeletalMeshComponent Mesh;
    local int I;
    local float Now;
    if (!Enabled() || Victim == None || Victim.bDeleteMe || Duration <= 0) return;
    // A dead or ragdolled body is physics, not animation; dilating it only
    // makes the death fall stutter.
    P = KFPawn(Victim);
    if (P == None || P.Health <= 0 || P.bPlayedDeath || P.Physics == PHYS_RigidBody) return;
    Mesh = P.Mesh;
    if (Mesh == None) return;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    Duration = FMin(Duration, MaximumDuration);
    for (I = 0; I < Frozen.Length; ++I)
        if (Frozen[I].Victim == Victim)
        {
            Frozen[I].Until = FMax(Frozen[I].Until, Now + Duration);
            return;
        }
    F.Victim = Victim;
    F.Mesh = Mesh;
    F.Original = Mesh.GlobalAnimRateScale;
    F.Until = Now + Duration;
    Frozen.AddItem(F);
    Mesh.GlobalAnimRateScale = F.Original * Dilation;
    ++Freezes;
}

function Restore(int I)
{
    if (Frozen[I].Victim != None && !Frozen[I].Victim.bDeleteMe && Frozen[I].Mesh != None)
        Frozen[I].Mesh.GlobalAnimRateScale = Frozen[I].Original;
    Frozen.Remove(I, 1);
}

function Update()
{
    local int I;
    local float Now;
    if (Frozen.Length == 0) return;
    if (!Enabled()) { Clear(); return; }
    Now = Bridge.WorldInfo.RealTimeSeconds;
    for (I = Frozen.Length - 1; I >= 0; --I)
    {
        if (Frozen[I].Victim == None || Frozen[I].Victim.bDeleteMe || Now >= Frozen[I].Until
            || (KFPawn(Frozen[I].Victim) != None && KFPawn(Frozen[I].Victim).Physics == PHYS_RigidBody))
            Restore(I);
    }
}

function Clear()
{
    while (Frozen.Length > 0) Restore(Frozen.Length - 1);
}

function Shutdown()
{
    Clear();
    Bridge = None;
}

defaultproperties
{
    Dilation=0.05
    LightDuration=0.06
    HeavyDuration=0.11
    ChargedDuration=0.15
    ImpactDuration=0.07
    MaximumDuration=0.20
}
