// Fist guard: both empty, clenched fists brought up and held in front of the
// face. Raising the guard opens a short parry window; a Zed in reach, facing
// the player and caught in an interruptible attack -- a swing, or a reach to
// grab -- inside that window is parried the stock way (VRPhysicalFist
// ApplyParry: a stumble, or the Berserker knockdown). Holding the guard does
// not renew the window: lower the fists and raise them again.
//
// The guard parries; it does not block damage. Stock blocking reduces damage
// in the held weapon's AdjustDamage, which empty hands never reach.
class VRFistGuard extends Object;

var bool bGuarding;
var float Dwell, NextGuardTime, WindowEnd, LastTime;
var vector LastHand[2];
var bool bHaveHands;
var array<Pawn> ParriedThisWindow;
var int Guards, Parries;

var float SettleTime;     // both fists held in the pose this long raise the guard
var float ParryWindow;    // parry window from the moment the guard is raised
var float ResetTime;      // a dropped guard re-arms after this long
var float EntrySpeed;     // fists slower than this may raise the guard (uu/s)
var float HoldSpeed;      // and faster than this drop it
var float Reach;          // Zed centre within this of the player
var float ZedFacingDot;   // the Zed must face the player at least this much
var byte ParryStrength;

function Cancel(optional string Reason)
{
    if (bGuarding) LogGuard(Reason != "" ? Reason : "cancelled");
    bGuarding = false;
    Dwell = 0;
    bHaveHands = false;
    ParriedThisWindow.Length = 0;
}

function LogGuard(string Reason)
{
    `log("KF2VR_MELEE kind=guard reason=" $ Reason $ " parried=" $ ParriedThisWindow.Length
        $ " guards=" $ Guards $ " parries=" $ Parries);
}

function bool IsFistClosed(VRHandsBridge Bridge, int Hand)
{
    if ((Bridge.NativeGripMask & (1 << Hand)) != 0) return true;
    return Bridge.FreeHandPose != None && Bridge.FreeHandPose.Amount[Hand] >= 0.35;
}

// In front of the face, measured in the body's facing like the Riot Shield
// raise. Wider limits once guarding, so a guard held at the edge stays up.
function bool InPose(VRHandsBridge Bridge, int Hand)
{
    local rotator Facing;
    local vector Rel;
    Facing.Yaw = Bridge.Human.Rotation.Yaw;
    Rel = (Bridge.PalmPosition(Hand) - Bridge.HeadPosition) << Facing;
    return Rel.X >= 4 && Rel.X <= (bGuarding ? 45 : 38)
        && Abs(Rel.Y) <= (bGuarding ? 32 : 26)
        && Rel.Z >= (bGuarding ? -40 : -32) && Rel.Z <= (bGuarding ? 12 : 8);
}

// FreeMask: the hands VRHandInventory lets punch this tick.
function Update(VRHandsBridge Bridge, int FreeMask)
{
    local float Now, Delta, Speed[2];
    local int Hand;
    local bool bPose;
    if (Bridge == None || Bridge.Human == None || Bridge.Human.Health <= 0
        || Bridge.PC == None || Bridge.PC.Pawn != Bridge.Human
        || Bridge.NativeConnection <= 0 || Bridge.NativeControlsEnabled == 0
        || Bridge.NativeMenuActive != 0 || !Bridge.PC.UsingFirstPersonCamera()
        || (FreeMask & 3) != 3 || (Bridge.NativeValidMask & 3) != 3)
    {
        Cancel("ineligible");
        return;
    }
    Now = Bridge.WorldInfo.RealTimeSeconds;
    Delta = Now - LastTime;
    LastTime = Now;
    if (!bHaveHands || Delta <= 0 || Delta > 0.1)
    {
        LastHand[0] = Bridge.PalmPosition(0);
        LastHand[1] = Bridge.PalmPosition(1);
        bHaveHands = true;
        return;
    }
    bPose = true;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        // Pawn motion is not hand motion: a guard walks forward intact.
        Speed[Hand] = VSize((Bridge.PalmPosition(Hand) - LastHand[Hand]) / Delta
            - Bridge.Human.Velocity);
        LastHand[Hand] = Bridge.PalmPosition(Hand);
        bPose = bPose && IsFistClosed(Bridge, Hand) && InPose(Bridge, Hand);
    }
    if (bGuarding)
    {
        if (!bPose || Speed[0] > HoldSpeed || Speed[1] > HoldSpeed)
        {
            LogGuard("lowered");
            bGuarding = false;
            Dwell = 0;
            ParriedThisWindow.Length = 0;
            NextGuardTime = Now + ResetTime;
            return;
        }
        if (Now < WindowEnd) ParryAttackers(Bridge);
        return;
    }
    if (!bPose || Speed[0] > EntrySpeed || Speed[1] > EntrySpeed || Now < NextGuardTime)
    {
        Dwell = 0;
        return;
    }
    Dwell += Delta;
    if (Dwell < SettleTime) return;
    bGuarding = true;
    WindowEnd = Now + ParryWindow;
    ParriedThisWindow.Length = 0;
    ++Guards;
    class'VRMeleeControls'.static.Pulse(Bridge, 3, 0.30, 0.03);
    ParryAttackers(Bridge);
}

function ParryAttackers(VRHandsBridge Bridge)
{
    local KFPawn_Monster M;
    local vector ToPlayer, Forward;
    local rotator Facing;
    local int Hand;
    local bool bParried;
    Facing.Yaw = Bridge.Human.Rotation.Yaw;
    Forward = vector(Facing);
    foreach Bridge.WorldInfo.AllPawns(class'KFPawn_Monster', M, Bridge.Human.Location, Reach)
    {
        if (M.bDeleteMe || M.Health <= 0 || M.GetTeamNum() == Bridge.Human.GetTeamNum()
            || ParriedThisWindow.Find(M) != INDEX_NONE) continue;
        ToPlayer = Normal2D(Bridge.Human.Location - M.Location);
        // Stock blocks within 85 degrees of the defender's facing; the Zed
        // must also be attacking this way, not at a teammate beside us.
        if ((Forward dot -ToPlayer) < 0.087 || (vector(M.Rotation) dot ToPlayer) < ZedFacingDot
            || !class'VRPhysicalFist'.static.AttackParryable(M, ParryStrength)) continue;
        ParriedThisWindow.AddItem(M);
        // The server checks the reporting hand is empty and near the Zed.
        Hand = VSizeSq(Bridge.Hands[0].Position - M.Location) <= VSizeSq(Bridge.Hands[1].Position - M.Location) ? 0 : 1;
        if (Bridge.Human.Role == ROLE_Authority)
            bParried = class'VRPhysicalFist'.static.ApplyParry(M, Bridge.Human, ParryStrength);
        else bParried = Bridge.RequestNetworkFistParry(M, Hand);
        if (!bParried) continue;
        ++Parries;
        `log("KF2VR_MELEE kind=parry source=guard zed=" $ M.Class.Name);
        Feedback(Bridge, M);
    }
}

function Feedback(VRHandsBridge Bridge, KFPawn_Monster M)
{
    local VRPhysicalFist Fist;
    local vector Between;
    Between = (Bridge.Hands[0].Position + Bridge.Hands[1].Position) * 0.5;
    if (Bridge.HandInventory != None)
    {
        Fist = Bridge.HandInventory.PhysicalFists[0];
        if (Fist == None) Fist = Bridge.HandInventory.PhysicalFists[1];
        if (Bridge.HandInventory.HitStop != None)
            Bridge.HandInventory.HitStop.Freeze(M, Bridge.HandInventory.HitStop.ChargedDuration);
    }
    if (Fist != None)
    {
        Fist.PlayFistSound(Bridge, Fist.ParrySound, Between + Normal(M.Location - Between) * 12);
        Fist.Pulse(Bridge, 0, 1.0, 0.07);
        Fist.Pulse(Bridge, 1, 1.0, 0.07);
    }
    else class'VRMeleeControls'.static.Pulse(Bridge, 3, 1.0, 0.07);
}

defaultproperties
{
    SettleTime=0.05
    ParryWindow=0.45
    ResetTime=0.35
    EntrySpeed=80
    HoldSpeed=180
    Reach=190
    ZedFacingDot=0.5
    ParryStrength=3
}
