// Physical throw for the held deployables (C4, Sentinel, HRG Bombardier), the
// same gesture as the chest grenade with the trigger in place of grip, since
// grip is already holding the item: squeeze the trigger, swing, and let go.
// The release throws from the hand at its measured velocity; letting go at
// rest places it at the hand. X/A + trigger still detonates (SecondaryFireMode).
// The throw itself is VRDeployableThrow, validated by the server online.
class VRDeployableHold extends Object;

var VRDualHandInput InputOwner;
var VRHandsBridge Bridge;
var KFWeapon Held[2];
var int Samples[2];
var float LastTime[2], LastThrowTime[2];
var vector LastPosition[2], LastPawnPosition[2], ThrowVelocity[2];
var float ThrowInterval;

function Initialize(VRDualHandInput I)
{
    InputOwner = I; Bridge = I.Bridge;
    LastThrowTime[0] = -1000; LastThrowTime[1] = -1000;
}

function bool IsHeld(int Hand) { return Hand >= 0 && Hand < 2 && Held[Hand] != None; }

function bool Ready(int Hand, KFWeapon W)
{
    return W != None && !W.bDeleteMe && W.AmmoCount[0] > 0
        && Bridge.WorldInfo.TimeSeconds - LastThrowTime[Hand] >= ThrowInterval
        && InputOwner.Inventory.Registry.GetPrimary(Hand) != None
        && InputOwner.Inventory.Registry.GetPrimary(Hand).Item == W
        && (Bridge.NativeValidMask & (1 << Hand)) != 0 && Bridge.NativeHeadTracked != 0
        && TurretReady(W);
}

// Replicated from the stock weapon: a new drone replaces the old one only once
// the old one has landed and deployed.
function bool TurretReady(KFWeapon W)
{
    if (KFWeap_AutoTurret(W) != None)
        return KFWeap_AutoTurret(W).NumDeployedTurrets < KFWeap_AutoTurret(W).MaxTurretsDeployed
            || KFWeap_AutoTurret(W).bTurretReadyToUse;
    if (KFWeap_HRG_Warthog(W) != None)
        return KFWeap_HRG_Warthog(W).NumDeployedTurrets < KFWeap_HRG_Warthog(W).MaxTurretsDeployed
            || KFWeap_HRG_Warthog(W).bTurretReadyToUse;
    return true;
}

// The trigger edge that stock would have spent on WeaponThrowing. Always
// consumed for a deployable, so an empty or cooling item never falls back to
// the stock view-aimed throw.
function Begin(int Hand, KFWeapon W)
{
    if (Hand < 0 || Hand > 1) return;
    Cancel(Hand, true);
    if (!Ready(Hand, W)) { InputOwner.Grenade.PulseRefused(Hand); return; }
    Held[Hand] = W;
    LastPosition[Hand] = Bridge.PalmPosition(Hand); LastPawnPosition[Hand] = Bridge.Human.Location;
    LastTime[Hand] = Bridge.WorldInfo.RealTimeSeconds; Samples[Hand] = 0; ThrowVelocity[Hand] = vect(0,0,0);
    InputOwner.Grenade.Pulse(Hand, 0.10, 0.020);
}

function Cancel(int Hand, optional bool bSilent)
{
    if (!IsHeld(Hand)) return;
    if (!bSilent) InputOwner.Grenade.Pulse(Hand, 0.18, 0.050);
    Held[Hand] = None; Samples[Hand] = 0;
}

function Release(int Hand)
{
    local KFWeapon W;
    local vector Position, HitLocation, HitNormal;
    local bool Thrown;
    if (!IsHeld(Hand)) return;
    W = Held[Hand];
    if (Samples[Hand] < 3 || !Ready(Hand, W)) { Cancel(Hand); return; }
    Position = Bridge.PalmPosition(Hand);
    if (Bridge.Trace(HitLocation, HitNormal, Position, Bridge.HeadPosition, false) == None)
    {
        Thrown = Bridge.RequestNetworkDeployable(W, Hand, Position, ThrowVelocity[Hand]);
        if (!Thrown) Thrown = class'VRDeployableThrow'.static.Launch(Bridge, Bridge.Human, W, Hand,
            Position, ThrowVelocity[Hand], Bridge.HeadPosition);
    }
    Held[Hand] = None; Samples[Hand] = 0;
    if (!Thrown) { InputOwner.Grenade.PulseRefused(Hand); return; }
    LastThrowTime[Hand] = Bridge.WorldInfo.TimeSeconds;
    InputOwner.Inventory.Pulse(Hand);
}

function Update(float Delta)
{
    local int Hand;
    local float Now, Elapsed;
    local vector Position, Velocity;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (!IsHeld(Hand)) continue;
        Elapsed = Now - LastTime[Hand];
        if (!InputOwner.ContextValid() || InputOwner.IsSelectorOpen(0) || InputOwner.IsSelectorOpen(1)
            || !Ready(Hand, Held[Hand]) || Elapsed < 0 || Elapsed > 0.1) { Cancel(Hand); continue; }
        if (Elapsed <= 0) continue;
        Position = Bridge.PalmPosition(Hand);
        // Positions and RealTimeSeconds are sampled together; locomotion is
        // removed so walking forward does not add to the throw.
        Velocity = (Position - LastPosition[Hand] - (Bridge.Human.Location - LastPawnPosition[Hand])) / Elapsed;
        if (VSize(Velocity) > 1800) { Cancel(Hand); continue; }
        ThrowVelocity[Hand] = Velocity * 0.65 + ThrowVelocity[Hand] * 0.35;
        LastPosition[Hand] = Position; LastPawnPosition[Hand] = Bridge.Human.Location;
        LastTime[Hand] = Now; ++Samples[Hand];
    }
}

function Shutdown()
{
    Held[0] = None; Held[1] = None;
    InputOwner = None; Bridge = None;
}

defaultproperties
{
    // Stock ConsumeSpareAmmoDelay: the next charge is in hand a second later.
    ThrowInterval=1.0
}
