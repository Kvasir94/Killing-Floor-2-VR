// Open-palm shove (melee roadmap item 13). A fast, open, empty hand driven
// into a Zed's head or torso pushes it back with a stock stumble through
// VRDT_PalmShove: token damage, no knockdown or stun. It makes space in a
// horde and pairs with fists, which need a clenched grip. Blade & Sorcery's
// Punch push thresholds start at 2 m/s; this uses 4 m/s (200 uu/s) so normal
// reaching never shoves. VRHandsBridge.bLegacyMeleePalmShove disables it.
class VRPalmShove extends Object;

var vector LastPalm[2];
var float LastTime[2], NextShove[2];
var byte bHave[2];
var float MinSpeed, Reach, Cooldown, Damage, Momentum;
var int Shoves;

function Cancel(int Hand)
{
    bHave[Hand] = 0;
}

// Open: no grip and the hand pose mostly uncurled (VRPhysicalFist closes at
// grip or 0.35 curl).
static function bool IsHandOpen(VRHandsBridge Bridge, int Hand)
{
    if ((Bridge.NativeGripMask & (1 << Hand)) != 0) return false;
    return Bridge.FreeHandPose == None || Bridge.FreeHandPose.Amount[Hand] < 0.2;
}

static function bool IsTorsoOrHead(name Zone)
{
    return Zone == 'head' || Zone == 'neck' || Zone == 'chest' || Zone == 'heart' || Zone == 'stomach'
        || Zone == 'abdomen' || Zone == 'lshoulder' || Zone == 'rshoulder';
}

function Update(VRHandsBridge Bridge, int FreeMask)
{
    local int Hand;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (Bridge == None || Bridge.UseLegacyMelee(Bridge.bLegacyMeleePalmShove) || (FreeMask & (1 << Hand)) == 0
            || !IsHandOpen(Bridge, Hand)
            || (Bridge.NativeValidMask & (1 << Hand)) == 0 || Bridge.NativeMenuActive != 0
            || !class'VRPhysicalInteraction'.static.Allowed(Bridge.Human))
        {
            Cancel(Hand);
            continue;
        }
        UpdateHand(Bridge, Hand);
    }
}

function UpdateHand(VRHandsBridge Bridge, int Hand)
{
    local vector Palm, Velocity, Bone, Dir;
    local float Now, Delta;
    local KFPawn_Monster M;
    local int I;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    Palm = Bridge.PalmPosition(Hand) - Bridge.Human.Location;
    Delta = Now - LastTime[Hand];
    if (bHave[Hand] == 0 || !(Delta > 0) || Delta > 0.1)
    {
        bHave[Hand] = 1; LastPalm[Hand] = Palm; LastTime[Hand] = Now;
        return;
    }
    // Body-relative, so walking into a Zed does not count as a shove.
    Velocity = (Palm - LastPalm[Hand]) / Delta;
    LastPalm[Hand] = Palm; LastTime[Hand] = Now;
    if (VSize(Velocity) < MinSpeed || Now < NextShove[Hand]) return;
    Dir = Normal(Velocity);
    foreach Bridge.WorldInfo.AllPawns(class'KFPawn_Monster', M, Bridge.Human.Location + Palm, 120)
    {
        if (M.bDeleteMe || M.Health <= 0 || M.Mesh == None || M.GetTeamNum() == Bridge.Human.GetTeamNum()) continue;
        for (I = 0; I < M.HitZones.Length; ++I)
        {
            if (!IsTorsoOrHead(M.HitZones[I].ZoneName)) continue;
            Bone = M.Mesh.GetBoneLocation(M.HitZones[I].BoneName, 0);
            if (VSize(Bone - (Bridge.Human.Location + Palm)) > Reach || ((Bone - Bridge.Human.Location) dot Dir) <= 0) continue;
            Shove(Bridge, Hand, M, Bone, Dir, M.HitZones[I].BoneName);
            NextShove[Hand] = Now + Cooldown;
            return;
        }
    }
}

function Shove(VRHandsBridge Bridge, int Hand, KFPawn_Monster M, vector At, vector Dir, name BoneName)
{
    local TraceHitInfo HitInfo;
    Dir.Z = FMax(Dir.Z, 0.1);
    ++Shoves;
    `log("KF2VR_MELEE kind=shove hand=" $ Hand $ " zed=" $ M.Class.Name);
    if (Bridge.Human.Role == ROLE_Authority)
    {
        HitInfo.BoneName = BoneName;
        M.TakeDamage(int(Damage), Bridge.PC, At, Normal(Dir) * Momentum, class'VRDT_PalmShove', HitInfo, Bridge.Human);
    }
    else Bridge.RequestNetworkPhysicalDamage(M, Damage, At, Normal(Dir) * Momentum, class'VRDT_PalmShove', BoneName, Hand, Bridge.BeginPhysicalSwing(Hand));
    if (Bridge.HandInventory != None && Bridge.HandInventory.HapticClips != None && Bridge.HandInventory.HapticClips.Enabled())
        Bridge.HandInventory.HapticClips.Play(1 << Hand, 0.6);
    else Bridge.QueueHandHaptic(1 << Hand, 0.6, 0.05);
}

defaultproperties
{
    MinSpeed=200
    Reach=22
    Cooldown=0.5
    Damage=1
    Momentum=600
}
