// Corpse gore that every player sees (Kvasir94, 2026-11-07: plan A on the
// "Corpse Gore Window" page). Stock's "gore on dead bodies" switch already
// lets corpses lose limbs at any age, but after death each machine owns its
// own ragdoll copy and stock stops sending hits (KFPawn Dying.TakeDamage
// plays hits on a dedicated server only on the death frame). A limb a
// player shoots or cuts off a corpse therefore came off on that player's
// machine only.
//
// The hitter's machine notices each new stock dismemberment on a corpse and
// reports it; the server relays it to the other players, whose machines find
// their own copy of that body (same Zed class, nearest death spot) and play
// the same stock PlayDismemberment. Explosions already run on every machine,
// so radial breaks are not reported, and the death-frame gore the server
// already sent is skipped. Each receiver's own switch and gore level still
// decide whether anything plays. Only breaks travel: a few bytes per event,
// capped per player per second.
//
// Held and thrown corpses (Kvasir94, 2026-11-09): the server has no copy of an
// old corpse, so a body a player picked up or threw stayed where it fell on
// everyone else's screen. The holder's machine reports which corpse and which
// bone each hand took; every other machine pulls that bone of its own copy to
// the holder's presented hand (the same tracked pose its avatar is drawn
// from) over a quarter second, the rest of the body hanging on its own
// physics, and throws it with the holder's release speed. A copy further
// than about a metre from the hand is left alone rather than dragged across
// the floor.
class KF2VRNetCorpseGore extends Object;

struct TrackedCorpse
{
    var KFPawn_Monster Pawn;
    var vector DeathSpot;
    var float SeenAt;
    // Zones whose stock dismemberment has played on this machine, reported
    // or relayed. A new bit that is not here is a fresh local break.
    var int Played;
};

// The corpse and bone each of this player's hands holds, as last reported.
struct LocalHold
{
    var KFPawn_Monster Pawn;
    var name Bone;
    // Let go last frame: report the body's speed once the grab code's throw
    // (or drop) has been simulated, so every copy leaves the hand alike.
    var KFPawn_Monster Released;
    var name ReleasedBone;
};

// Another player's hand holding this machine's copy of a corpse.
struct RemoteHold
{
    var KFPawn_Human Holder;
    var KF2VRNetPose Pose;
    var byte Hand;
    var KFPawn_Monster Corpse;
    var name Bone;
    var float Since, LostSince, Pull;
};

var KF2VRNetPlayerController PC;
var array<TrackedCorpse> Corpses;
var float NextScan;
var LocalHold Mine[2];
var array<RemoteHold> Remote;
// Authority, for the player this object belongs to.
var float WindowStart;
var int WindowCount;

const ScanInterval = 0.1;
// The server already sent the killing blow's gore to everyone.
const DeathFrameGrace = 0.3;
// Ragdolls drift apart between machines; death spots stay close.
const MatchRadius = 160.0;
const MaxPerSecond = 12;
// A report about a body this far from the reporter is not believed.
const ReportRange = 5000.0;
// Further than this (about 4 m) from where the holder's copy of the gripped
// bone was, this machine's copy is left where it lies. Measured body to body,
// so the remote hand's network delay does not count against it. Dedicated
// replays (mp/228-held-corpse-online.kfs) found copies 0.7 to 2.5 m apart
// after a kill and a cut: separate ragdolls and per-machine gore impulses.
const HoldReach = 200.0;
// The held bone is pulled in over this long, longer for a copy further away
// (PullSpeed), then follows the hand closely.
const PullTime = 0.25;
const PullSpeed = 400.0;
const HoldTau = 0.06;
const MaxPullSpeed = 1500.0;
// Tracking may drop for this long before a remote hold lets go.
const PoseGrace = 0.5;
const MaxRemoteHolds = 16;

static function KF2VRNetCorpseGore Instance(KF2VRNetPlayerController Owner)
{
    if (Owner.CorpseGore == None)
    {
        Owner.CorpseGore = new(Owner) class'KF2VRNetCorpseGore';
        Owner.CorpseGore.PC = Owner;
    }
    return Owner.CorpseGore;
}

static function bool IsCorpse(KFPawn_Monster M)
{
    return M != None && !M.bDeleteMe && (M.bTearOff || M.bPlayedDeath) && M.Mesh != None && !M.bHidden;
}

static function int PlayedMask(KFPawn_Monster M)
{
    local int I, Mask;
    for (I = 0; I < M.HitZones.Length && I < 32; ++I)
        if (M.HitZones[I].bPlayedInjury) Mask = Mask | (1 << I);
    return Mask;
}

function int Find(KFPawn_Monster M)
{
    local int I;
    for (I = 0; I < Corpses.Length; ++I)
        if (Corpses[I].Pawn == M) return I;
    return INDEX_NONE;
}

function int Track(KFPawn_Monster M)
{
    local TrackedCorpse C;
    // Keep state for every surviving corpse. Evicting a live entry makes
    // Refresh re-track it, swallowing fresh breaks and moving its death spot.
    // The game's corpse lifetime/limit bounds the set; Refresh prunes deletions.
    C.Pawn = M;
    C.DeathSpot = M.Location;
    C.SeenAt = PC.WorldInfo.TimeSeconds;
    C.Played = PlayedMask(M);
    Corpses.AddItem(C);
    return Corpses.Length - 1;
}

// Forget destroyed corpses and start tracking new ones.
function Refresh()
{
    local KFPawn_Monster M;
    local KFGoreManager GoreManager;
    local int I;
    for (I = Corpses.Length - 1; I >= 0; --I)
        if (Corpses[I].Pawn == None || Corpses[I].Pawn.bDeleteMe) Corpses.Remove(I, 1);
    // Stock's own ragdoll corpse list (KFGoreManager.AddCorpse at death),
    // bounded by the player's body limit. Only these can lose limbs or be
    // held, and walking it costs nothing next to scanning every actor.
    GoreManager = KFGoreManager(PC.WorldInfo.MyGoreEffectManager);
    if (GoreManager == None) return;
    for (I = 0; I < GoreManager.CorpsePool.Length; ++I)
    {
        M = KFPawn_Monster(GoreManager.CorpsePool[I]);
        if (IsCorpse(M) && Find(M) == INDEX_NONE) Track(M);
    }
}

// This machine's copy of a body another machine named: same Zed class,
// nearest death spot.
function int MatchCorpse(class<KFPawn_Monster> ZedClass, vector Spot)
{
    local int I, Best;
    local float Distance, BestDistance;
    Refresh();
    Best = INDEX_NONE;
    BestDistance = MatchRadius;
    for (I = 0; I < Corpses.Length; ++I)
    {
        if (Corpses[I].Pawn == None || Corpses[I].Pawn.Class != ZedClass || !IsCorpse(Corpses[I].Pawn)) continue;
        Distance = VSize(Corpses[I].DeathSpot - Spot);
        if (Distance < BestDistance) { BestDistance = Distance; Best = I; }
    }
    return Best;
}

// Shared per-player rate cap for every relayed corpse event.
function bool Admit()
{
    local float Now;
    Now = PC.WorldInfo.TimeSeconds;
    if (Now - WindowStart >= 1.0) { WindowStart = Now; WindowCount = 0; }
    WindowCount += 1;
    return WindowCount <= MaxPerSecond;
}

// Local player's machine, every frame in network games.
function Tick()
{
    if (PC == None || PC.WorldInfo.NetMode == NM_Standalone || PC.WorldInfo.NetMode == NM_DedicatedServer) return;
    TickLocalHolds();
    TickRemoteHolds();
    if (PC.WorldInfo.TimeSeconds < NextScan) return;
    NextScan = PC.WorldInfo.TimeSeconds + ScanInterval;
    ScanGore();
}

// ----------------------------------------------------------------- gore

// Report fresh local breaks.
function ScanGore()
{
    local KFPawn_Monster M;
    local int I, Fresh, Zone;
    local vector Dir;
    Refresh();
    for (I = 0; I < Corpses.Length; ++I)
    {
        M = Corpses[I].Pawn;
        if (!IsCorpse(M)) continue;
        Fresh = PlayedMask(M) & ~Corpses[I].Played;
        if (Fresh == 0) continue;
        Corpses[I].Played = Corpses[I].Played | Fresh;
        if (PC.WorldInfo.TimeSeconds - Corpses[I].SeenAt < DeathFrameGrace
            || M.HitFxInfo.DamageType == None || M.HitFxInfo.bRadialDamage) continue;
        Dir = M.DecodeUnitVector(M.HitFxInfo.EncodedHitDirection);
        for (Zone = 0; Zone < 32; ++Zone)
            if ((Fresh & (1 << Zone)) != 0)
            {
                `log("KF2VR_CORPSE action=gore-sent pawn=" $ M.Class.Name @ "zone=" $ Zone @ "dt=" $ M.HitFxInfo.DamageType.Name);
                PC.ServerCorpseGore(M.Class, Corpses[I].DeathSpot, Zone, M.HitFxInfo.DamageType, Dir);
            }
    }
}

// Authority: check one player's report and pass it to everyone else.
function Relay(class<KFPawn_Monster> ZedClass, vector Spot, byte Zone, class<KFDamageType> DamageType, vector Dir)
{
    local KF2VRNetPlayerController Other;
    if (ZedClass == None || DamageType == None || Zone >= 32 || PC.Pawn == None
        || VSize(PC.Pawn.Location - Spot) > ReportRange || !Admit()) return;
    Dir = Normal(Dir);
    foreach PC.WorldInfo.AllControllers(class'KF2VRNetPlayerController', Other)
    {
        if (Other == PC) continue;
        if (Other.IsLocalPlayerController()) Instance(Other).Apply(ZedClass, Spot, Zone, DamageType, Dir);
        else Other.ClientCorpseGore(ZedClass, Spot, Zone, DamageType, Dir);
    }
}

// Receiving machine: play the reported break on this machine's copy.
function Apply(class<KFPawn_Monster> ZedClass, vector Spot, byte Zone, class<KFDamageType> DamageType, vector Dir)
{
    local KFPawn_Monster M;
    local int Best;
    if (PC == None || PC.WorldInfo.NetMode == NM_DedicatedServer || ZedClass == None || DamageType == None) return;
    Best = MatchCorpse(ZedClass, Spot);
    if (Best == INDEX_NONE) { `log("KF2VR_CORPSE action=gore-skip reason=no-match pawn=" $ ZedClass); return; }
    M = Corpses[Best].Pawn;
    if (Zone >= M.HitZones.Length || M.HitZones[Zone].bPlayedInjury) { `log("KF2VR_CORPSE action=gore-skip reason=played zone=" $ Zone); return; }
    // Stock's own rule for this player's "gore on dead bodies" switch.
    if (!M.bAllowRagdollAndGoreOnDeadBodies && PC.WorldInfo.TimeSeconds - M.TimeOfDeath > 3.0) { `log("KF2VR_CORPSE action=gore-skip reason=switch-off"); return; }
    `log("KF2VR_CORPSE action=gore-apply pawn=" $ M.Class.Name @ "zone=" $ Zone @ "played=" $ M.PlayDismemberment(Zone, DamageType, Dir));
    // Dependent breaks came with it; none of them is a fresh local break.
    Corpses[Best].Played = PlayedMask(M);
}

// ---------------------------------------------------------------- holds

// Report when one of this player's hands takes or lets go of a corpse.
function TickLocalHolds()
{
    local VRHandsBridge Bridge;
    local VRZedGrab Grab;
    local KFPawn_Monster M;
    local RB_BodyInstance Body;
    local vector At;
    local name Bone;
    local int H, I;
    Bridge = VRHandsBridge(PC.LocalVRBridge);
    if (Bridge != None && Bridge.HandInventory != None) Grab = Bridge.HandInventory.ZedGrab;
    for (H = 0; H < 2; ++H)
    {
        M = None;
        Bone = '';
        if (Grab != None && !Grab.Grabs[H].bGib && !Grab.Grabs[H].bStanding && Grab.Grabs[H].BoneName != ''
            && IsCorpse(Grab.Grabs[H].Pawn))
        {
            M = Grab.Grabs[H].Pawn;
            Bone = Grab.Grabs[H].BoneName;
        }
        if (Mine[H].Released != None) SendRelease(H);
        if (M == Mine[H].Pawn && Bone == Mine[H].Bone) continue;
        if (Mine[H].Pawn != None)
        {
            Mine[H].Released = Mine[H].Pawn;
            Mine[H].ReleasedBone = Mine[H].Bone;
            // A new grab this frame needs the release first.
            if (M != None) SendRelease(H);
        }
        Mine[H].Pawn = M;
        Mine[H].Bone = Bone;
        if (M == None) continue;
        Refresh();
        I = Find(M);
        if (I == INDEX_NONE) I = Track(M);
        if (!BonePoint(M, Bone, Body, At)) At = M.Location;
        `log("KF2VR_CORPSE action=hold-sent hand=" $ H @ "pawn=" $ M.Class.Name @ "bone=" $ Bone @ "spot=" $ Corpses[I].DeathSpot);
        PC.ServerCorpseHold(H, M.Class, Corpses[I].DeathSpot, Bone, At);
    }
}

// The released bone's speed on this machine, as the grab code left it.
function SendRelease(int H)
{
    local RB_BodyInstance Body;
    local vector Point, Velocity;
    if (IsCorpse(Mine[H].Released) && BonePoint(Mine[H].Released, Mine[H].ReleasedBone, Body, Point))
        Velocity = Body.GetUnrealWorldVelocity();
    `log("KF2VR_CORPSE action=release-sent hand=" $ H @ "speed=" $ int(VSize(Velocity)));
    PC.ServerCorpseRelease(H, Velocity);
    Mine[H].Released = None;
    Mine[H].ReleasedBone = '';
}

// Give every body of the released piece the holder's release velocity, so a
// drop falls where the hand let go and a throw flies the same way, whatever
// the servo was doing a frame earlier.
static function SetPieceVelocity(SkeletalMeshComponent Mesh, name Bone, vector Velocity)
{
    local RB_BodyInstance Body;
    local name Candidate;
    local int I;
    if (Mesh == None || Mesh.PhysicsAsset == None || Mesh.PhysicsAssetInstance == None) return;
    for (I = 0; I < Mesh.PhysicsAsset.BodySetup.Length; ++I)
    {
        Candidate = Mesh.PhysicsAsset.BodySetup[I].BoneName;
        if (class'VRBodyHold'.static.Consumed(Mesh, Candidate) || !class'VRBodyHold'.static.SamePiece(Mesh, Bone, Candidate)) continue;
        Body = Mesh.FindBodyInstanceNamed(Candidate);
        if (Body == None || !Body.IsValidBodyInstance() || Body.IsFixed()) continue;
        Mesh.AddImpulse(Velocity - Body.GetUnrealWorldVelocity(), MatrixGetOrigin(Body.GetUnrealWorldTM()), Candidate, true);
    }
}

// Authority: check a grab report and pass it on.
function RelayHold(byte Hand, class<KFPawn_Monster> ZedClass, vector Spot, name Bone, vector At)
{
    local KF2VRNetPlayerController Other;
    local KFPawn_Human Holder;
    Holder = KFPawn_Human(PC.Pawn);
    if (Hand > 1 || ZedClass == None || Bone == '' || Holder == None || Holder.Health <= 0
        || VSize(Holder.Location - Spot) > ReportRange || VSize(Holder.Location - At) > ReportRange || !Admit())
    {
        `log("KF2VR_CORPSE action=relay-hold refused=true hand=" $ Hand @ "pawn=" $ ZedClass);
        return;
    }
    `log("KF2VR_CORPSE action=relay-hold hand=" $ Hand @ "pawn=" $ ZedClass.Name @ "bone=" $ Bone);
    foreach PC.WorldInfo.AllControllers(class'KF2VRNetPlayerController', Other)
    {
        if (Other == PC) continue;
        if (Other.IsLocalPlayerController()) Instance(Other).BeginRemote(Holder, Hand, ZedClass, Spot, Bone, At);
        else Other.ClientCorpseHold(Holder, Hand, ZedClass, Spot, Bone, At);
    }
}

// Authority: a release is never refused (a lost one would leave the body
// pinned to a hand on other screens); its speed is bounded.
function RelayRelease(byte Hand, vector Throw)
{
    local KF2VRNetPlayerController Other;
    local KFPawn_Human Holder;
    local float Limit;
    Holder = KFPawn_Human(PC.Pawn);
    if (Hand > 1 || Holder == None) return;
    if (Throw != Throw) Throw = vect(0,0,0);
    Limit = class'VRZedGrab'.default.MaxCorpseThrowSpeed * 1.25;
    if (VSize(Throw) > Limit) Throw = Normal(Throw) * Limit;
    foreach PC.WorldInfo.AllControllers(class'KF2VRNetPlayerController', Other)
    {
        if (Other == PC) continue;
        if (Other.IsLocalPlayerController()) Instance(Other).EndRemote(Holder, Hand, Throw);
        else Other.ClientCorpseRelease(Holder, Hand, Throw);
    }
}

function KF2VRNetPose PoseFor(KFPawn_Human Holder)
{
    local KF2VRNetPose P;
    foreach PC.DynamicActors(class'KF2VRNetPose', P)
        if (P.TargetPawn == Holder) return P;
    return None;
}

static function bool BonePoint(KFPawn_Monster M, name Bone, out RB_BodyInstance Body, out vector Point)
{
    if (M == None || M.Mesh == None || M.Mesh.MatchRefBone(Bone) == INDEX_NONE) return false;
    Body = class'VRBodyHold'.static.BodyFor(M.Mesh, Bone);
    if (Body == None || !Body.IsValidBodyInstance()) return false;
    Point = MatrixGetOrigin(Body.GetUnrealWorldTM());
    return true;
}

// Receiving machine: another player took a corpse in one hand.
function BeginRemote(KFPawn_Human Holder, byte Hand, class<KFPawn_Monster> ZedClass, vector Spot, name Bone, vector At)
{
    local RemoteHold R;
    local RB_BodyInstance Body;
    local string Reason;
    local vector Point, Palm;
    local int I;
    if (PC.WorldInfo.NetMode == NM_DedicatedServer || Holder == None || Hand > 1) return;
    EndRemote(Holder, Hand, vect(0,0,0), true);
    I = MatchCorpse(ZedClass, Spot);
    if (I == INDEX_NONE || Remote.Length >= MaxRemoteHolds)
    {
        `log("KF2VR_CORPSE action=hold-skip reason=" $ (I == INDEX_NONE ? "no-match" : "full") @ "pawn=" $ ZedClass
            @ "corpses=" $ Corpses.Length);
        return;
    }
    R.Holder = Holder;
    R.Hand = Hand;
    R.Corpse = Corpses[I].Pawn;
    R.Bone = Bone;
    R.Pose = PoseFor(Holder);
    if (R.Pose == None) Reason = "no-pose";
    else if (!R.Pose.PresentedHand(Hand, Palm)) Reason = "no-hand";
    else if (!BonePoint(R.Corpse, Bone, Body, Point)) Reason = "no-bone";
    else if (VSize(Point - At) > HoldReach) Reason = "far";
    if (Reason != "")
    {
        `log("KF2VR_CORPSE action=hold-skip reason=" $ Reason @ "dist=" $ int(VSize(Point - At)) @ "bone=" $ Bone);
        return;
    }
    R.Pull = FClamp(VSize(Point - At) / PullSpeed, PullTime, 0.6);
    `log("KF2VR_CORPSE action=hold-begin hand=" $ Hand @ "pawn=" $ R.Corpse.Class.Name @ "bone=" $ Bone @ "dist=" $ int(VSize(Point - At)) @ "hand=" $ int(VSize(Point - Palm)));
    R.Since = PC.WorldInfo.TimeSeconds;
    Remote.AddItem(R);
    R.Corpse.Mesh.WakeRigidBody();
}

// Receiving machine: that hand let go, dropping or throwing the body.
function EndRemote(KFPawn_Human Holder, byte Hand, vector Throw, optional bool bKeepMotion)
{
    local int I;
    for (I = Remote.Length - 1; I >= 0; --I)
    {
        if (Remote[I].Holder != Holder || Remote[I].Hand != Hand) continue;
        `log("KF2VR_CORPSE action=hold-end hand=" $ Hand @ "throw=" $ int(VSize(Throw)));
        if (IsCorpse(Remote[I].Corpse))
        {
            if (!bKeepMotion) SetPieceVelocity(Remote[I].Corpse.Mesh, Remote[I].Bone, Throw);
            Remote[I].Corpse.Mesh.WakeRigidBody();
        }
        Remote.Remove(I, 1);
    }
}

// Pull each remotely held bone onto its holder's presented hand: a velocity
// servo on that one body, so the rest of the corpse hangs and swings freely.
function TickRemoteHolds()
{
    local RB_BodyInstance Body;
    local vector Palm, Point, Want;
    local float Now, Limit;
    local int I;
    Now = PC.WorldInfo.TimeSeconds;
    for (I = Remote.Length - 1; I >= 0; --I)
    {
        if (Remote[I].Holder == None || Remote[I].Holder.bDeleteMe || Remote[I].Holder.Health <= 0
            || !IsCorpse(Remote[I].Corpse) || Remote[I].Pose == None || Remote[I].Pose.bDeleteMe
            || !BonePoint(Remote[I].Corpse, Remote[I].Bone, Body, Point))
        {
            `log("KF2VR_CORPSE action=hold-end reason=gone hand=" $ Remote[I].Hand);
            Remote.Remove(I, 1);
            continue;
        }
        if (!Remote[I].Pose.PresentedHand(Remote[I].Hand, Palm))
        {
            if (Remote[I].LostSince == 0) Remote[I].LostSince = Now;
            if (Now - Remote[I].LostSince > PoseGrace)
            {
                `log("KF2VR_CORPSE action=hold-end reason=tracking-lost hand=" $ Remote[I].Hand);
                Remote.Remove(I, 1);
            }
            continue;
        }
        Remote[I].LostSince = 0;
        Want = (Palm - Point) / HoldTau;
        Limit = MaxPullSpeed * FClamp((Now - Remote[I].Since) / Remote[I].Pull, 0.2, 1.0);
        if (VSize(Want) > Limit) Want = Normal(Want) * Limit;
        Remote[I].Corpse.Mesh.AddImpulse(Want - Body.GetUnrealWorldVelocity(), Point, Remote[I].Bone, true);
        Remote[I].Corpse.Mesh.WakeRigidBody();
    }
}
