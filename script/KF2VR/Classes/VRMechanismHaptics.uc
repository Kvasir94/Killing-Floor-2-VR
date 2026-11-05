// Mechanical signatures use separate attacks, gaps and settling impulses.
// Continuous spring pressure is a short-lived request, never a latched rumble.
class VRMechanismHaptics extends Object;

const SlideRear=0;
const SlideForward=1;
const PumpRear=2;
const PumpForward=3;
const BoltRear=4;
const BoltClose=5;
const CylinderClose=6;
const GunImpact=7;
const Contact=8;
const ChestSlideRear=9;
const ChestSlideForward=10;

struct Step
{
    var int Pattern;
    var float At, Level, Length;
};
struct Playing
{
    var int Pattern, Next;
    var float Start;
    var bool bActive;
};
var array<Step> Steps;
var Playing Hands[2];
var VRHandsBridge Bridge;
var float ForceUntil[2], ForceStrength[2], ForceLength[2], NextForce[2], NextDrag[2];

static function VRMechanismHaptics ForBridge(VRHandsBridge B)
{
    if (B != None && B.RootBridge != None) B = B.RootBridge;
    return (B != None && B.HandInventory != None) ? B.HandInventory.MechanismHaptics : None;
}

static function Emit(VRHandsBridge B, int Pattern, int Mask)
{
    local VRMechanismHaptics H;
    H = ForBridge(B);
    if (H != None) H.Play(Pattern, Mask);
}

function Play(int Pattern, int Mask)
{
    local int I;
    if (Bridge == None) return;
    for (I = 0; I < 2; ++I)
    {
        if ((Mask & (1 << I)) == 0) continue;
        // A light contact must not replace an impact's settling beats.
        if (Hands[I].bActive && ((Pattern == Contact && Hands[I].Pattern != Contact)
            || (Hands[I].Pattern == GunImpact && Pattern != GunImpact))) continue;
        Hands[I].Pattern = Pattern; Hands[I].Next = 0;
        Hands[I].Start = Bridge.WorldInfo.RealTimeSeconds; Hands[I].bActive = true;
        ForceUntil[I] = 0;
    }
    Update();
}

function Spring(int Mask, optional bool bChest)
{
    local int I;
    if (Bridge == None) return;
    for (I = 0; I < 2; ++I)
        if ((Mask & (1 << I)) != 0)
        {
            ForceUntil[I] = Bridge.WorldInfo.RealTimeSeconds + 0.035;
            ForceStrength[I] = bChest ? 0.25 : 0.10;
            ForceLength[I] = bChest ? 0.018 : 0.009;
        }
}

function Drag(int Mask, optional float ChestPull=-1)
{
    local int I;
    local float Time;
    if (Bridge == None) return;
    Time = Bridge.WorldInfo.RealTimeSeconds;
    for (I = 0; I < 2; ++I)
        if ((Mask & (1 << I)) != 0 && Time >= NextDrag[I])
        {
            // Chest contact transmits resistance into the gun hand. Give it
            // a felt movement pulse, rising toward the stop; preserve the
            // light texture used for a palm or another gun.
            Bridge.QueueHandHaptic(1 << I, ChestPull >= 0 ? 0.45 + 0.25 * FClamp(ChestPull, 0, 1) : 0.22,
                ChestPull >= 0 ? 0.020 : 0.006);
            NextDrag[I] = Time + (ChestPull >= 0 ? 0.045 : 0.028);
        }
}

function Update()
{
    local int I, N;
    local float Time, Elapsed;
    if (Bridge == None) return;
    Time = Bridge.WorldInfo.RealTimeSeconds;
    for (I = 0; I < 2; ++I)
    {
        if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << I)) == 0)
        { Hands[I].bActive = false; ForceUntil[I] = 0; continue; }
        if (Hands[I].bActive)
        {
            Elapsed = Time - Hands[I].Start;
            for (N = Hands[I].Next; N < Steps.Length; ++N)
            {
                if (Steps[N].Pattern != Hands[I].Pattern) continue;
                if (Steps[N].At > Elapsed) break;
                // A frame stall must not replay a burst of overdue impacts.
                if (Elapsed - Steps[N].At < 0.04)
                    Bridge.QueueHandHaptic(1 << I, Steps[N].Level, Steps[N].Length);
            }
            Hands[I].Next = N;
            if (N >= Steps.Length) Hands[I].bActive = false;
        }
        if (ForceUntil[I] > Time && Time >= NextForce[I])
        {
            Bridge.QueueHandHaptic(1 << I, ForceStrength[I], ForceLength[I]);
            NextForce[I] = Time + 0.045;
        }
    }
}

function Shutdown()
{
    Hands[0].bActive = false; Hands[1].bActive = false;
    ForceUntil[0] = 0; ForceUntil[1] = 0; Bridge = None;
}

defaultproperties
{
    // Rear impact and catch; forward snap and short spring/body resonance.
    Steps(0)=(Pattern=0,At=0,Level=0.95,Length=0.024)
    Steps(1)=(Pattern=0,At=0.038,Level=0.40,Length=0.009)
    Steps(2)=(Pattern=1,At=0,Level=0.65,Length=0.008)
    Steps(3)=(Pattern=1,At=0.018,Level=1,Length=0.026)
    Steps(4)=(Pattern=1,At=0.060,Level=0.25,Length=0.012)
    // Pump travel ends in a heavier, broader mechanical stop.
    Steps(5)=(Pattern=2,At=0,Level=0.82,Length=0.033)
    Steps(6)=(Pattern=2,At=0.045,Level=0.35,Length=0.016)
    Steps(7)=(Pattern=3,At=0,Level=1,Length=0.040)
    Steps(8)=(Pattern=3,At=0.055,Level=0.48,Length=0.018)
    // Bolt/lever rear stop and a two-part closing/latching signature.
    Steps(9)=(Pattern=4,At=0,Level=0.78,Length=0.018)
    Steps(10)=(Pattern=4,At=0.030,Level=0.48,Length=0.012)
    Steps(11)=(Pattern=5,At=0,Level=0.65,Length=0.020)
    Steps(12)=(Pattern=5,At=0.040,Level=0.90,Length=0.016)
    Steps(13)=(Pattern=6,At=0,Level=0.90,Length=0.022)
    Steps(14)=(Pattern=6,At=0.032,Level=0.55,Length=0.010)
    // Gun strike: hard contact, lower body resonance, then decay.
    Steps(15)=(Pattern=7,At=0,Level=1,Length=0.045)
    Steps(16)=(Pattern=7,At=0.060,Level=0.65,Length=0.025)
    Steps(17)=(Pattern=7,At=0.105,Level=0.25,Length=0.018)
    Steps(18)=(Pattern=8,At=0,Level=0.28,Length=0.009)
    Steps(19)=(Pattern=8,At=0.021,Level=0.12,Length=0.006)
    // A one-handed chest rack needs a distinct stop in the holding hand,
    // followed by body resonance; the spring return has its own snap.
    Steps(20)=(Pattern=9,At=0,Level=1,Length=0.065)
    Steps(21)=(Pattern=9,At=0.085,Level=0.45,Length=0.020)
    Steps(22)=(Pattern=10,At=0,Level=0.65,Length=0.012)
    Steps(23)=(Pattern=10,At=0.026,Level=1,Length=0.065)
    Steps(24)=(Pattern=10,At=0.110,Level=0.30,Length=0.020)
}
