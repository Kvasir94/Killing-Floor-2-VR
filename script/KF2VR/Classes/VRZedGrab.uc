// Hold-to-grab for empty VR hands. A fresh squeeze near a Zed, a corpse or a
// gib takes hold of the nearest real physics body and puts it in the hand:
// the gripped body is made kinematic and placed in the hand's frame every
// tick (VRBodyHold), so it stays exactly at the controller and turns with the
// wrist, and the rest of the ragdoll hangs off it. A living ordinary Zed goes
// limp in place -- a stock knockdown with no shove -- and stays down while
// either hand holds it; letting go drops it, and letting go while moving
// throws it at the hand's speed.
//
// A held body is a weapon. Two held Zeds brought together, a held body swung
// into another Zed, a held Zed driven into a wall or the floor, and a thrown
// body, corpse or gib that hits a Zed before it comes to rest all deal blunt
// damage scaled by impact speed. The pawn is never attached to a controller.
class VRZedGrab extends Actor;

struct VRGrabState
{
    var Actor Owner;                  // the pawn or gib being held
    var KFPawn_Monster Pawn;          // None for a gib
    var PrimitiveComponent Component; // the mesh whose body is held
    var name BoneName;                // '' for a gib's single body
    var RB_BodyInstance Body;
    var bool bGib;
    // A living hold owns a knockdown gate; a corpse or gib hold owns none.
    var bool bLiving;
    // Knockdown was requested but the pawn has not reached PHYS_RigidBody yet.
    var bool bPendingRagdoll;
    // The knockdown move has been observed locally. On a client this is the
    // proof the request survived its round trip, and it restarts the clock so
    // the local ragdoll transition is not charged for server latency.
    var bool bKnockdownSeen;
    var bool bHoldCounted;
    // The server has been told to hold this body and holds its own copy.
    var bool bServerHeld;
    // The body is fixed and being placed in the hand.
    var bool bAttached;
    var bool bOwnsKinematicUpdate, bSavedKinematicUpdate;
    // A living hold whose Zed just died keeps the body: the death re-inits the
    // ragdoll, so the body is gripped again once it settles into the corpse.
    var bool bRegrip;
    var float StartTime, AttachTime, RegripSince;
    var float TwoPointSpan; // captured when the second distinct body attaches
    // Grip frame captured at attach, and where the catch blend starts.
    var vector OffsetLocal;
    var Quat RelativeQuat;
    var matrix StartTM;
    // Where the held body was last placed, for the world sweep.
    var vector Placed;
    // Held apart from the hand by a wall since this time; 0 while not.
    var float BlockedSince;
    // Hand velocity, smoothed, for the throw.
    var vector LastPalm, HandVelocity;
    var bool bHavePalm;
    // Impact sampling: the gripped body and the held Zed's head, with their
    // world velocities. bMotion is false until two clean samples exist.
    var vector GripPoint, HeadPoint, GripVelocity, HeadVelocity;
    var bool bMotion, bHaveSample;
    var float NextMoveSend;
    var bool bActive;
};

// A released body still flying. It keeps dealing damage to Zeds it meets
// until it comes to rest; a still corpse a Zed walks into does nothing.
struct VRThrownBody
{
    var Actor Owner;
    var KFPawn_Monster Pawn;
    var PrimitiveComponent Component;
    var name BoneName;
    var bool bLiving, bGib;
    var float Since, RestTime, LastSpeed;
    var vector LastVelocity;
};

var VRHandsBridge Bridge;
var VRGrabState Grabs[2];
var array<VRThrownBody> Thrown;

var float GrabRadius;          // palm-to-body acceptance distance
var float PalmForward;         // palm point ahead of the tracked hand origin
var float SearchRadius;        // candidate search around the palm
var float RagdollTimeout;      // knockdown request must land within this
var float KnockdownNudge;      // the least velocity stock knockdown accepts
var float MoveSendInterval;    // grip-frame streaming period on a client
var float BodyRadius;          // held body stops this far off a wall
var float BlockedDrop;         // a wall this far between hand and body...
var float BlockedGrace;        // ...for this long releases the body
var float ThrowScale;          // released body speed per unit of hand speed
var float MinThrowSpeed;       // slower releases just drop
var float MaxThrowSpeed;
var float RestSpeed;           // a thrown body slower than this is settling
var float RestTime;            // settling this long ends its damage
var float ThrownLifetime;
var float GibDamageScale;
var int LivingGrabs, CorpseGrabs, GibGrabs, Rejects, Throws;
var int TimeoutDrops, BlockedDrops, InvalidDrops, PhysicsDrops;

struct VRImpactCooldown
{
    var Actor Victim;
    var float Until;
};
var array<VRImpactCooldown> ImpactCooldowns;
var float LastImpactSample;
var float MinImpactSpeed;      // slower contacts are touches, not hits
var float FullImpactSpeed;     // impact speed that deals MaxImpactDamage
var float MinImpactDamage, MaxImpactDamage;
var float HeadSmashScale;      // head-to-head smash multiplier
var float HeldSelfDamageScale; // a living Zed used as a club takes this share
var float ContactRadius;       // held point to a victim hit-zone bone
var float ImpactCooldown;      // per victim, so one contact is one hit
var float MaximumImpactStep;   // a larger per-sample move is a teleport
var int Smashes, SwingHits, WorldSmashes, ThrownHits;
var float SwingHumSpeed;       // hand speed where the held-body hum starts
var float SwingHumMaxStrength; // 0 turns the hum off

// Contact classification. UnrealScript refuses a bool out parameter, so the
// eligibility result is an int kind rather than a pair of flags.
const GRAB_None = 0;    // not grabbable
const GRAB_Body = 1;    // corpse, or a zed already down from something else
const GRAB_Living = 2;  // ordinary living zed; this feature knocks it down
const GRAB_Gib = 3;     // a loose gore chunk

simulated function bool Initialize(VRHandsBridge B)
{
    if (B == None || B.Human == None || !B.IsLocalVRContext()) return false;
    Bridge = B;
    Instigator = B.Human;
    return true;
}

simulated function bool IsHolding(int Hand)
{
    return Hand >= 0 && Hand < 2 && Grabs[Hand].bActive;
}

simulated function bool IsHoldingAny()
{
    return Grabs[0].bActive || Grabs[1].bActive;
}

// Both hands of the one owning player may hold the same pawn; a pawn already
// held by this player is not a new owner, and no other owner exists locally.
simulated function bool OwnedByOtherHand(int Hand, KFPawn_Monster M)
{
    local int Other;
    Other = 1 - Hand;
    return Grabs[Other].bActive && Grabs[Other].Pawn == M;
}

simulated function bool ContextValid()
{
    return Bridge != None && !Bridge.bDeleteMe && Bridge.Human != None
        && Bridge.Human.Health > 0 && !Bridge.Human.bDeleteMe
        && Bridge.PC != None && Bridge.PC.Pawn == Bridge.Human
        && Bridge.IsLocalVRContext()
        && Bridge.NativeConnection > 0 && Bridge.NativeControlsEnabled != 0
        && Bridge.NativeMenuActive == 0 && Bridge.PC.UsingFirstPersonCamera();
}

// A hold on a client is only ever half a hold: the body the player sees is a
// local simulation and the one that matters lives on the server.
simulated function bool IsNetworkClient()
{
    return Bridge != None && Bridge.Human != None
        && Bridge.Human.Role < ROLE_Authority;
}

simulated function bool FiniteVector(vector V)
{
    return V.X == V.X && V.Y == V.Y && V.Z == V.Z
        && Abs(V.X) < 100000000 && Abs(V.Y) < 100000000 && Abs(V.Z) < 100000000;
}

simulated function bool HandValid(int Hand)
{
    return Hand >= 0 && Hand < 2 && Bridge != None
        && (Bridge.NativeValidMask & (1 << Hand)) != 0
        && FiniteVector(Bridge.Hands[Hand].Position);
}

simulated function rotator HandRotation(int Hand)
{
    return Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation;
}

simulated function vector PalmPoint(int Hand)
{
    return Bridge.PalmPosition(Hand)
        + QuatRotateVector(QuatFromRotator(HandRotation(Hand)), vect(1,0,0) * PalmForward);
}

simulated function Pulse(int Hand, float Strength, float Duration)
{
    local VRHandsBridge B;
    if (Bridge == None || Hand < 0 || Hand > 1) return;
    B = Bridge.RootBridge != None ? Bridge.RootBridge : Bridge;
    if (B.NativeHapticMask == 0) { B.NativeHapticStrength = 0; B.NativeHapticDuration = 0; }
    B.NativeHapticMask = B.NativeHapticMask | (1 << Hand);
    B.NativeHapticStrength = FMax(B.NativeHapticStrength, Strength);
    B.NativeHapticDuration = FMax(B.NativeHapticDuration, Duration);
}

// ---------------------------------------------------------------------------
// Eligibility.

// Bosses, boss corpses and boss-origin gore are never grabbable.
simulated function bool IsBossOrigin(KFPawn_Monster M)
{
    return KFPawn_MonsterBoss(M) != None || KFInterface_MonsterBoss(M) != None;
}

simulated function bool IsCorpse(KFPawn_Monster M)
{
    return M.Health <= 0 || M.bPlayedDeath;
}

// Large zeds (Scrake, Fleshpound, Quarter Pound) may be grabbed only when a
// knockdown this feature did not cause already has them on the ground.
simulated function int Classify(int Hand, KFPawn_Monster M)
{
    if (M == None || M.bDeleteMe || M.Mesh == None || M.Mesh.PhysicsAsset == None) return GRAB_None;
    if (IsBossOrigin(M)) return GRAB_None;
    if (IsCorpse(M))
    {
        // A corpse hold never enters living affliction or recovery logic.
        return M.Physics == PHYS_RigidBody ? GRAB_Body : GRAB_None;
    }
    if (Bridge.Human.GetTeamNum() == M.GetTeamNum()) return GRAB_None;
    // Stock knockdown refuses a headless pawn and kills an injured one at
    // recovery, so a living hold must never begin on either.
    if (M.IsHeadless() || M.HasInjuredHitZones()) return GRAB_None;
    if (M.Physics == PHYS_RigidBody)
    {
        // Already down from something outside this feature. Take the body but
        // claim no knockdown gate of our own. This is also the only path a
        // large zed is allowed to take.
        return GRAB_Body;
    }
    if (M.IsLargeZed()) return GRAB_None;
    if (OwnedByOtherHand(Hand, M)) return GRAB_Living;
    // Admission must fail when the stock move cannot start, including the
    // global five-ragdoll cap.
    return M.CanDoSpecialMove(SM_Knockdown) ? GRAB_Living : GRAB_None;
}

// Resolve a contacted visual bone to a physical body. The grip goes to the
// nearest major body part, not the nearest bone: a tongue, claw or finger has
// a physics body of its own, but it is a thin chain on weak joints, and hit
// zones are exactly the parts worth holding -- head, neck, torso, limbs.
simulated function bool ResolveBody(KFPawn_Monster M, vector Palm, out name OutBone, out float OutDistance)
{
    local name Closest, RBBone, Best;
    local vector BoneLocation;
    local float Distance, BestDistance;
    local int I;
    OutBone = '';
    // Contact: the palm has to be at the body at all.
    Closest = M.Mesh.FindClosestBone(Palm, BoneLocation);
    if (Closest == '') return false;
    if (VSize(BoneLocation - Palm) > GrabRadius) return false;
    BestDistance = GrabRadius * 2.5;
    for (I = 0; I < M.HitZones.Length; ++I)
    {
        if (M.HitZones[I].BoneName == '') continue;
        if (I == HZI_HEAD && M.IsHeadless()) continue;
        RBBone = M.GetRBBoneFromBoneName(M.HitZones[I].BoneName);
        if (RBBone == '' || M.Mesh.FindBodyInstanceNamed(RBBone) == None) continue;
        Distance = VSize(M.Mesh.GetBoneLocation(RBBone, 0) - Palm);
        if (Distance < BestDistance)
        {
            BestDistance = Distance;
            Best = RBBone;
        }
    }
    if (Best == '') return false;
    OutDistance = BestDistance;
    OutBone = Best;
    return true;
}

simulated function KFPawn_Monster FindTarget(int Hand, vector Palm, out name OutBone, out int OutKind, out float OutDistance)
{
    local KFPawn_Monster M, Best;
    local name Bone, BestBone;
    local float Distance;
    local int Kind, BestKind;
    OutDistance = 100000000;
    BestKind = GRAB_None;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster', M, Palm, SearchRadius)
    {
        Kind = Classify(Hand, M);
        if (Kind == GRAB_None) continue;
        if (!ResolveBody(M, Palm, Bone, Distance)) continue;
        if (Distance >= OutDistance) continue;
        Best = M;
        BestBone = Bone;
        OutDistance = Distance;
        BestKind = Kind;
    }
    OutBone = BestBone;
    OutKind = BestKind;
    return Best;
}

// Loose gore. Gibs are spawned locally on every machine and belong to nobody,
// so they are held and thrown here without any server claim.
simulated function KFGiblet FindGib(vector Palm, out float OutDistance)
{
    local KFGiblet G, Best;
    local float Distance;
    OutDistance = GrabRadius * 1.5;
    foreach DynamicActors(class'KFGiblet', G)
    {
        if (G.bDeleteMe || G.GibMeshComp == None || G.Physics != PHYS_RigidBody) continue;
        Distance = VSize(G.Location - Palm);
        if (Distance >= OutDistance) continue;
        if (G.GibMeshComp.GetRootBodyInstance() == None) continue;
        Best = G;
        OutDistance = Distance;
    }
    return Best;
}

// ---------------------------------------------------------------------------
// Grabbing.

simulated function ResetGrab(int Hand)
{
    local VRGrabState Empty;
    Grabs[Hand] = Empty;
}

// A fresh squeeze arms this; a fist that was already closed stays a fist.
simulated function bool TryGrab(int Hand)
{
    local KFPawn_Monster M;
    local KFGiblet Gib;
    local name Bone;
    local int Kind;
    local float PawnDistance, GibDistance;
    local vector Palm;
    if (!ContextValid() || !Bridge.ZedGrabAllowed()) return false;
    if (!HandValid(Hand) || Grabs[Hand].bActive) return false;
    Palm = PalmPoint(Hand);
    M = FindTarget(Hand, Palm, Bone, Kind, PawnDistance);
    Gib = FindGib(Palm, GibDistance);
    if (Gib != None && (M == None || GibDistance < PawnDistance)) { M = None; Kind = GRAB_Gib; }
    if (M == None && Gib == None) { ++Rejects; return false; }

    ResetGrab(Hand);
    Grabs[Hand].StartTime = WorldInfo.TimeSeconds;
    Grabs[Hand].bActive = true;
    if (Kind == GRAB_Gib)
    {
        Grabs[Hand].Owner = Gib;
        Grabs[Hand].Component = Gib.GibMeshComp;
        Grabs[Hand].bGib = true;
        if (!AttachHold(Hand)) { ClearGrab(Hand, "attach_failed"); ++Rejects; return false; }
        ++GibGrabs;
        Pulse(Hand, 0.55, 0.05);
        `log("KF2VR_ZEDGRAB action=grab hand=" $ Hand $ " gib=" $ Gib.Class);
        return true;
    }

    Grabs[Hand].Owner = M;
    Grabs[Hand].Pawn = M;
    Grabs[Hand].Component = M.Mesh;
    Grabs[Hand].BoneName = Bone;
    Grabs[Hand].bLiving = Kind == GRAB_Living;
    if (Grabs[Hand].bLiving && M.Physics != PHYS_RigidBody)
    {
        if (!RequestKnockdown(M))
        {
            ClearGrab(Hand, "knockdown_refused");
            ++Rejects;
            return false;
        }
        Grabs[Hand].bPendingRagdoll = true;
    }
    else if (!AttachHold(Hand))
    {
        ClearGrab(Hand, "attach_failed");
        ++Rejects;
        return false;
    }
    // A body already on the ground skips the knockdown round trip entirely,
    // so the authority hold is claimed here rather than waiting for one.
    ClaimServerHold(Hand);

    if (Grabs[Hand].bLiving) ++LivingGrabs;
    else ++CorpseGrabs;
    // A hard clamp; the swing hum in PlaceHeld carries the weight after it.
    Pulse(Hand, 1.0, 0.035);
    `log("KF2VR_ZEDGRAB action=grab hand=" $ Hand $ " pawn=" $ M.Class $ " bone=" $ Bone $ " living=" $ Grabs[Hand].bLiving);
    return true;
}

// Stock knockdown with no shove: the least velocity it accepts, straight down,
// and no spin, so the Zed goes limp where it stands and the hand catches it
// there rather than chasing a body already falling away. No point or radial
// impulse is supplied, so no hit zone is consulted and no health, armor or
// gore state is touched.
simulated function bool RequestKnockdown(KFPawn_Monster M)
{
    local vector Nudge;
    if (!class'VRSM_HeldKnockdown'.static.Install(M)) return false;
    Nudge = vect(0,0,-1) * KnockdownNudge;
    if (IsNetworkClient())
    {
        Bridge.RequestNetworkKnockdown(M, Nudge);
        return true;
    }
    M.Knockdown(Nudge, vect(0,0,0));
    return M.IsDoingSpecialMove(SM_Knockdown);
}

// Fix the gripped body and capture where it sits in the hand. The body is
// then brought into that frame over VRBodyHold.CatchTime.
simulated function bool AttachHold(int Hand)
{
    local RB_BodyInstance Body;
    local int Other;
    Other = 1 - Hand;
    if (Grabs[Hand].Component == None) return false;
    if (Grabs[Hand].bGib) Body = Grabs[Hand].Component.GetRootBodyInstance();
    else Body = class'VRBodyHold'.static.BodyFor(Grabs[Hand].Component, Grabs[Hand].BoneName);
    if (Body == None || !Body.IsValidBodyInstance()) return false;
    // Two controllers cannot independently fix the same rigid body.
    if (Grabs[Other].bAttached && Grabs[Other].Body == Body) return false;
    if (Grabs[Other].bAttached && Grabs[Other].Component == Grabs[Hand].Component
        && Grabs[Other].Body != None && Grabs[Other].Body.IsValidBodyInstance())
    {
        Grabs[Hand].TwoPointSpan = VSize(MatrixGetOrigin(Body.GetUnrealWorldTM())
            - MatrixGetOrigin(Grabs[Other].Body.GetUnrealWorldTM()));
        Grabs[Other].TwoPointSpan = Grabs[Hand].TwoPointSpan;
    }
    if (!class'VRBodyHold'.static.Capture(Body, PalmPoint(Hand), HandRotation(Hand),
        Grabs[Hand].OffsetLocal, Grabs[Hand].RelativeQuat)) return false;
    Grabs[Hand].Body = Body;
    Grabs[Hand].StartTM = Body.GetUnrealWorldTM();
    Grabs[Hand].Placed = MatrixGetOrigin(Grabs[Hand].StartTM);
    Grabs[Hand].AttachTime = WorldInfo.TimeSeconds;
    Grabs[Hand].BlockedSince = 0;
    Grabs[Hand].bHavePalm = false;
    Grabs[Hand].bAttached = true;
    if (SkeletalMeshComponent(Grabs[Hand].Component) != None)
    {
        if (!Grabs[Hand].bOwnsKinematicUpdate)
        {
            Grabs[Hand].bSavedKinematicUpdate = (Grabs[Other].bOwnsKinematicUpdate
                && Grabs[Other].Component == Grabs[Hand].Component)
                ? Grabs[Other].bSavedKinematicUpdate : SkeletalMeshComponent(Grabs[Hand].Component).bUpdateKinematicBonesFromAnimation;
            Grabs[Hand].bOwnsKinematicUpdate = true;
        }
    }
    class'VRBodyHold'.static.Begin(Body, Grabs[Hand].Component);
    Grabs[Hand].Component.WakeRigidBody();
    if (Grabs[Hand].bLiving) CountHold(Hand);
    return true;
}

simulated function CountHold(int Hand)
{
    local VRSM_HeldKnockdown Move;
    if (Grabs[Hand].bHoldCounted || !Grabs[Hand].bLiving) return;
    Move = class'VRSM_HeldKnockdown'.static.Current(Grabs[Hand].Pawn);
    if (Move == None) return;
    Move.AddHold();
    Grabs[Hand].bHoldCounted = true;
}

// Tell the authority this hand holds this body. Without it the server's
// VRSM_HeldKnockdown carries HoldCount 0 and its stock rest test stands the
// Zed straight back up however long the client keeps squeezing. The same
// call gives the server the bone and the hand frame to hold its own copy by.
simulated function ClaimServerHold(int Hand)
{
    if (!Grabs[Hand].bActive || Grabs[Hand].bServerHeld || Grabs[Hand].bGib) return;
    if (!IsNetworkClient()) return;
    if (!Bridge.RequestNetworkGrabHold(Grabs[Hand].Pawn, Grabs[Hand].BoneName,
        Hand, PalmPoint(Hand), HandRotation(Hand))) return;
    Grabs[Hand].bServerHeld = true;
    Grabs[Hand].NextMoveSend = WorldInfo.TimeSeconds + MoveSendInterval;
}

// Grip frames are a stream, not a fact: a dropped one is corrected by the
// next, so this is unreliable on purpose.
simulated function StreamServerGrip(int Hand, vector Palm)
{
    if (!Grabs[Hand].bServerHeld) return;
    if (WorldInfo.TimeSeconds < Grabs[Hand].NextMoveSend) return;
    Grabs[Hand].NextMoveSend = WorldInfo.TimeSeconds + MoveSendInterval;
    Bridge.RequestNetworkGrabMove(Hand, Palm, HandRotation(Hand));
}

// End a hold. Throw is the release velocity for a deliberate let-go; every
// other ending passes none and the body simply drops.
simulated function ClearGrab(int Hand, string Reason, optional vector Throw)
{
    local VRSM_HeldKnockdown Move;
    local bool bOwnerLive, bThrown;
    if (Hand < 0 || Hand > 1) return;
    // Everything except a deliberate release is a failure the player felt but
    // could not diagnose. Release logs itself.
    // An empty hand has nothing to drop; menus cancel both hands every frame.
    if (Reason != "release" && Grabs[Hand].bActive)
        `log("KF2VR_ZEDGRAB action=drop hand=" $ Hand $ " reason=" $ Reason
            $ " living=" $ Grabs[Hand].bLiving $ " pending=" $ Grabs[Hand].bPendingRagdoll
            $ " held=" $ (WorldInfo.TimeSeconds - Grabs[Hand].StartTime));
    bOwnerLive = Grabs[Hand].Owner != None && !Grabs[Hand].Owner.bDeleteMe;
    // The other hand may still hold the same Zed by another part: nothing is
    // thrown out of a grip that is still closed, and a body the other hand
    // holds by the very same bone stays fixed.
    if (Grabs[1 - Hand].bActive && Grabs[1 - Hand].Owner == Grabs[Hand].Owner) Throw = vect(0,0,0);
    bThrown = !IsZero(Throw);
    if (Grabs[Hand].bAttached && bOwnerLive
        && !(Grabs[1 - Hand].bActive && Grabs[1 - Hand].Body == Grabs[Hand].Body))
        class'VRBodyHold'.static.End(Grabs[Hand].Body, Grabs[Hand].Component, Throw);
    if (Grabs[Hand].bOwnsKinematicUpdate && bOwnerLive
        && !(Grabs[1 - Hand].bOwnsKinematicUpdate && Grabs[1 - Hand].Component == Grabs[Hand].Component))
        SkeletalMeshComponent(Grabs[Hand].Component).bUpdateKinematicBonesFromAnimation =
            (Grabs[Hand].Pawn != None && IsCorpse(Grabs[Hand].Pawn)) ? false : Grabs[Hand].bSavedKinematicUpdate;
    if (Grabs[Hand].bHoldCounted)
    {
        Move = class'VRSM_HeldKnockdown'.static.Current(Grabs[Hand].Pawn);
        // A thrown Zed is left to land: the stock rest test gets it up once
        // it stops, rather than a get-up starting in mid-air.
        if (Move != None) Move.ReleaseHold(bThrown);
    }
    // The authority half is released on its own flag: a corpse hold never
    // counts a knockdown, so bHoldCounted cannot stand in for it.
    if (Grabs[Hand].bServerHeld && IsNetworkClient())
        Bridge.RequestNetworkReleaseGrab(Grabs[Hand].Pawn, Hand, Throw);
    if (bThrown && bOwnerLive) AddThrown(Hand);
    if (Grabs[Hand].bGib && KFGiblet(Grabs[Hand].Owner) != None && bOwnerLive)
        Grabs[Hand].Owner.LifeSpan = 8.0;
    ResetGrab(Hand);
}

simulated function Release(int Hand)
{
    local vector Throw;
    if (Hand < 0 || Hand > 1 || !Grabs[Hand].bActive) return;
    if (Grabs[Hand].bAttached && Grabs[Hand].bHavePalm
        && VSize(Grabs[Hand].HandVelocity) * ThrowScale >= MinThrowSpeed)
    {
        Throw = Grabs[Hand].HandVelocity * ThrowScale;
        if (VSize(Throw) > MaxThrowSpeed) Throw = Normal(Throw) * MaxThrowSpeed;
        ++Throws;
    }
    `log("KF2VR_ZEDGRAB action=release hand=" $ Hand $ " throw=" $ int(VSize(Throw)));
    ClearGrab(Hand, "release", Throw);
    Pulse(Hand, 0.35, 0.035);
}

simulated function ReleaseAll()
{
    if (Grabs[0].bActive) ClearGrab(0, "cancelled");
    if (Grabs[1].bActive) ClearGrab(1, "cancelled");
    Thrown.Length = 0;
    ImpactCooldowns.Length = 0;
}

// Death, dismemberment, destruction, possession change and tracking loss all
// drop the grab.
simulated function bool HoldStillValid(int Hand)
{
    local KFPawn_Monster M;
    if (Grabs[Hand].Owner == None || Grabs[Hand].Owner.bDeleteMe) return false;
    if (!ContextValid() || !HandValid(Hand)) return false;
    if (Grabs[Hand].bGib) return Grabs[Hand].Component != None;
    M = Grabs[Hand].Pawn;
    if (M.Mesh != Grabs[Hand].Component) return false;
    if (!Grabs[Hand].bLiving) return true;
    // Only a living hold cares: stock knockdown refuses a headless pawn and
    // kills an injured one at recovery.
    if (M.IsHeadless() || M.HasInjuredHitZones()) return false;
    if (IsCorpse(M)) return false;
    return true;
}

// The nearest remaining major body part to the palm, for a grip whose own
// part was destroyed. No contact test: the hand is already closed on this Zed.
simulated function bool RebindBody(int Hand)
{
    local KFPawn_Monster M;
    local RB_BodyInstance Candidate;
    local name RBBone, Best;
    local float Distance, BestDistance;
    local vector Palm;
    local int I;
    M = Grabs[Hand].Pawn;
    if (M == None || M.Mesh == None) return false;
    Palm = PalmPoint(Hand);
    BestDistance = 120;
    for (I = 0; I < M.HitZones.Length; ++I)
    {
        if (M.HitZones[I].BoneName == '') continue;
        if (I == HZI_HEAD && M.IsHeadless()) continue;
        RBBone = M.GetRBBoneFromBoneName(M.HitZones[I].BoneName);
        if (RBBone == '' || RBBone == Grabs[Hand].BoneName) continue;
        Candidate = M.Mesh.FindBodyInstanceNamed(RBBone);
        if (Candidate == None || !Candidate.IsValidBodyInstance()) continue;
        Distance = VSize(M.Mesh.GetBoneLocation(RBBone, 0) - Palm);
        if (Distance < BestDistance)
        {
            BestDistance = Distance;
            Best = RBBone;
        }
    }
    if (Best == '') return false;
    Grabs[Hand].BoneName = Best;
    return true;
}

// The Zed died in the hand. Its knockdown move is over, so the hold stops
// counting against it, and the body is let go so the death ragdoll can
// re-initialise before it is gripped again as a corpse.
simulated function BeginRegrip(int Hand)
{
    if (Grabs[Hand].bAttached) class'VRBodyHold'.static.End(Grabs[Hand].Body, Grabs[Hand].Component);
    Grabs[Hand].bAttached = false;
    Grabs[Hand].Body = None;
    Grabs[Hand].bLiving = false;
    Grabs[Hand].bHoldCounted = false;
    Grabs[Hand].bRegrip = true;
    Grabs[Hand].RegripSince = WorldInfo.TimeSeconds;
    Grabs[Hand].bMotion = false;
    Grabs[Hand].bHaveSample = false;
}

simulated function UpdateHand(int Hand, float DeltaTime)
{
    local KFPawn_Monster M;
    if (!Grabs[Hand].bActive) return;
    M = Grabs[Hand].Pawn;
    // Killing the Zed in your hand -- by smashing it, or anyone shooting it --
    // keeps the body rather than dropping it.
    if (M != None && Grabs[Hand].bLiving && !Grabs[Hand].bPendingRagdoll && !M.bDeleteMe
        && M.Mesh == Grabs[Hand].Component && IsCorpse(M))
        BeginRegrip(Hand);
    if (!HoldStillValid(Hand)) { ++InvalidDrops; ClearGrab(Hand, "invalid"); return; }

    if (Grabs[Hand].bRegrip)
    {
        // The part that was held may be gone with the kill -- a smashed head
        // leaves no head body -- so the grip moves to the nearest part left.
        // Wait for the death to finish: PlayDying re-initialises the ragdoll
        // after the health reaches zero, and a grip taken before that is on
        // bodies about to be replaced.
        if (M.bPlayedDeath && M.Physics == PHYS_RigidBody
            && (AttachHold(Hand) || (RebindBody(Hand) && AttachHold(Hand))))
        {
            Grabs[Hand].bRegrip = false;
            `log("KF2VR_ZEDGRAB action=regrip hand=" $ Hand $ " pawn=" $ M.Class);
        }
        else if (WorldInfo.TimeSeconds - Grabs[Hand].RegripSince > 1.5)
            ClearGrab(Hand, "regrip_failed");
        return;
    }

    if (Grabs[Hand].bPendingRagdoll)
    {
        if (M.Physics == PHYS_RigidBody)
        {
            Grabs[Hand].bPendingRagdoll = false;
            if (!AttachHold(Hand)) { ClearGrab(Hand, "attach_failed"); return; }
            ClaimServerHold(Hand);
        }
        // Two waits, not one. On a client the knockdown request costs a round
        // trip before the move even starts, and the local ragdoll transition
        // costs more after it. Seeing the move start is proof the request
        // landed, so the physics transition gets its own clock.
        else if (!Grabs[Hand].bKnockdownSeen && M.IsDoingSpecialMove(SM_Knockdown))
        {
            Grabs[Hand].bKnockdownSeen = true;
            Grabs[Hand].StartTime = WorldInfo.TimeSeconds;
            ClaimServerHold(Hand);
        }
        else if (WorldInfo.TimeSeconds - Grabs[Hand].StartTime > RagdollTimeout)
        {
            ++TimeoutDrops;
            ClearGrab(Hand, Grabs[Hand].bKnockdownSeen ? "ragdoll_timeout" : "knockdown_timeout");
        }
        return;
    }

    if (M != None && M.Physics != PHYS_RigidBody)
    {
        // A corpse briefly leaves physics while its death ragdoll is rebuilt;
        // that is a re-grip, not a drop. A living Zed leaving it is getting up.
        if (IsCorpse(M)) { BeginRegrip(Hand); return; }
        ++PhysicsDrops;
        ClearGrab(Hand, "left_ragdoll");
        return;
    }
    // A ragdoll re-initialised under the hold (death, gore) has new bodies.
    if (Grabs[Hand].Body == None || !Grabs[Hand].Body.IsValidBodyInstance())
    {
        if (M != None && !Grabs[Hand].bLiving) { Grabs[Hand].bAttached = false; Grabs[Hand].bRegrip = true; Grabs[Hand].RegripSince = WorldInfo.TimeSeconds; return; }
        ClearGrab(Hand, "body_lost");
        return;
    }
    PlaceHeld(Hand, DeltaTime);
    if (Grabs[Hand].bActive && Grabs[Hand].bGib) Grabs[Hand].Owner.LifeSpan = FMax(Grabs[Hand].Owner.LifeSpan, 8.0);
}

// Put the held body in the hand for this tick. The body is kinematic, so it
// would pass straight through a wall; the path from where it was to where the
// hand wants it is swept against the world instead, and a body that meets
// the world stops at the surface. A living Zed driven into it takes the hit.
// A faint buzz while a held body is swung, rising with hand speed, so it reads
// as mass on the end of the arm. Haptic only: the body still tracks the hand
// exactly, and a hand at rest is silent.
simulated function SwingHum(int Hand)
{
    local float Alpha;
    if (Grabs[Hand].bGib || SwingHumMaxStrength <= 0) return;
    Alpha = (VSize(Grabs[Hand].HandVelocity) - SwingHumSpeed) / FMax(FullImpactSpeed * 1.5 - SwingHumSpeed, 1);
    if (Alpha <= 0) return;
    Pulse(Hand, SwingHumMaxStrength * FMin(0.3 + Alpha, 1.0), 0.03);
}

simulated function matrix DesiredFrame(int Hand)
{
    return class'VRBodyHold'.static.Blend(Grabs[Hand].StartTM,
        class'VRBodyHold'.static.TargetFor(PalmPoint(Hand), HandRotation(Hand), Grabs[Hand].OffsetLocal, Grabs[Hand].RelativeQuat),
        (WorldInfo.TimeSeconds - Grabs[Hand].AttachTime) / FMax(class'VRBodyHold'.default.CatchTime, 0.01));
}

simulated function PlaceHeld(int Hand, float DeltaTime)
{
    local vector Palm, Want, Direction, HitLocation, HitNormal, Surface, Eye;
    local matrix Target;
    local float Distance, Speed;
    local int Other;
    local Actor Wall;
    Palm = PalmPoint(Hand);
    if (Grabs[Hand].bHavePalm && DeltaTime > 0 && DeltaTime <= 0.1)
        Grabs[Hand].HandVelocity = Grabs[Hand].HandVelocity * 0.5 + ((Palm - Grabs[Hand].LastPalm) / DeltaTime) * 0.5;
    else Grabs[Hand].HandVelocity = vect(0,0,0);
    Grabs[Hand].LastPalm = Palm;
    Grabs[Hand].bHavePalm = true;
    SwingHum(Hand);

    Target = DesiredFrame(Hand);
    Want = MatrixGetOrigin(Target);
    Other = 1 - Hand;
    // Release before the kinematic bodies stretch the ragdoll's joints.
    if (Grabs[Other].bAttached && Grabs[Other].Component == Grabs[Hand].Component
        && VSize(Want - MatrixGetOrigin(DesiredFrame(Other))) > Grabs[Hand].TwoPointSpan + class'VRBodyHold'.default.GripReach * 2)
    {
        ClearGrab(Hand, "two_point_stretch");
        return;
    }
    // A tracking jump must not yank a bone across the room or deal damage.
    if (!FiniteVector(Want) || VSize(Want - Grabs[Hand].Placed) > MaximumImpactStep)
    {
        ClearGrab(Hand, "tracking_jump");
        return;
    }

    Direction = Want - Grabs[Hand].Placed;
    Distance = VSize(Direction);
    Surface = Want;
    if (Distance > 0.01)
    {
        Direction /= Distance;
        Wall = Trace(HitLocation, HitNormal, Want + Direction * BodyRadius, Grabs[Hand].Placed, false);
        if (Wall != None)
        {
            Surface = HitLocation + HitNormal * BodyRadius;
            // How hard the hand is driving it in, not the gap to the wall: a
            // hand resting inside a wall is not a string of fresh impacts.
            Speed = Grabs[Hand].HandVelocity dot -HitNormal;
            WorldImpact(Hand, Surface, HitNormal, Speed);
        }
    }
    // The sweep starts at the body, and a body resting on a surface can start
    // it inside that surface and miss it. The player's own eye never is, so a
    // body the eye cannot see past the world to is on the far side of it.
    if (Surface == Want)
    {
        Eye = Bridge.Human.Location + vect(0,0,1) * Bridge.Human.BaseEyeHeight;
        if (Trace(HitLocation, HitNormal, Want, Eye, false) != None)
        {
            Surface = HitLocation + HitNormal * BodyRadius;
            WorldImpact(Hand, Surface, HitNormal, Grabs[Hand].HandVelocity dot -HitNormal);
        }
    }
    if (Surface != Want) Target = MakeRotationTranslationMatrix(Surface, MatrixGetRotator(Target));
    class'VRBodyHold'.static.Move(Grabs[Hand].Component, Grabs[Hand].BoneName, Target);
    Grabs[Hand].Placed = Surface;

    // Walked away with the body pinned behind a wall: let it go rather than
    // leave it stuck there on an invisible rope.
    if (VSize(Palm - Surface) > BlockedDrop && !FastTrace(Palm, Surface))
    {
        if (Grabs[Hand].BlockedSince <= 0) Grabs[Hand].BlockedSince = WorldInfo.TimeSeconds;
        else if (WorldInfo.TimeSeconds - Grabs[Hand].BlockedSince > BlockedGrace)
        {
            ++BlockedDrops;
            ClearGrab(Hand, "blocked");
            return;
        }
    }
    else Grabs[Hand].BlockedSince = 0;

    // Sustain the gate for a hand that grabbed a body the other hand of the
    // same player knocked down.
    CountHold(Hand);
    ClaimServerHold(Hand);
    StreamServerGrip(Hand, Palm);
}

simulated function Update()
{
    local int I;
    local float DeltaTime;
    if (!ContextValid() || !Bridge.ZedGrabAllowed())
    {
        ReleaseAll(); Thrown.Length = 0; ImpactCooldowns.Length = 0; return;
    }
    DeltaTime = WorldInfo.TimeSeconds - LastImpactSample;
    LastImpactSample = WorldInfo.TimeSeconds;
    for (I = 0; I < 2; ++I) UpdateHand(I, DeltaTime);
    UpdateImpacts(DeltaTime);
    UpdateThrown();
}

simulated event Destroyed()
{
    local int I;
    for (I = 0; I < 2; ++I) if (Grabs[I].bActive) ClearGrab(I, "destroyed");
    Bridge = None;
    Super.Destroyed();
}

// ---------------------------------------------------------------------------
// Held bodies as weapons.

simulated function bool Holding(int Hand)
{
    return Grabs[Hand].bActive && Grabs[Hand].bAttached && !Grabs[Hand].bPendingRagdoll && !Grabs[Hand].bRegrip
        && Grabs[Hand].Owner != None && !Grabs[Hand].Owner.bDeleteMe;
}

simulated function name HeadBone(KFPawn P)
{
    if (P == None || P.HitZones.Length <= HZI_HEAD) return '';
    return P.HitZones[HZI_HEAD].BoneName;
}

simulated function SampleMotion(int Hand, float Delta)
{
    local vector Grip, Head, GripStep, HeadStep;
    local name Bone;
    local RB_BodyInstance HeadBody;
    if (!Holding(Hand)) { Grabs[Hand].bMotion = false; Grabs[Hand].bHaveSample = false; return; }
    Grip = MatrixGetOrigin(Grabs[Hand].Body.GetUnrealWorldTM());
    Head = Grip;
    if (Grabs[Hand].Pawn != None)
    {
        Bone = HeadBone(Grabs[Hand].Pawn);
        if (Bone != '' && !Grabs[Hand].Pawn.IsHeadless())
        {
            HeadBody = class'VRBodyHold'.static.BodyFor(Grabs[Hand].Component, Grabs[Hand].Pawn.GetRBBoneFromBoneName(Bone));
            if (HeadBody != None && HeadBody.IsValidBodyInstance()) Head = MatrixGetOrigin(HeadBody.GetUnrealWorldTM());
        }
    }
    if (!FiniteVector(Grip) || !FiniteVector(Head))
    {
        Grabs[Hand].bMotion = false;
        Grabs[Hand].bHaveSample = false;
        return;
    }
    GripStep = Grip - Grabs[Hand].GripPoint;
    HeadStep = Head - Grabs[Hand].HeadPoint;
    // No subtraction of the player's own motion: running a held Zed into a
    // crowd is a real impact. A teleport is not, and neither is a bad frame.
    Grabs[Hand].bMotion = Grabs[Hand].bHaveSample && Delta > 0 && Delta <= 0.1
        && VSize(GripStep) <= MaximumImpactStep && VSize(HeadStep) <= MaximumImpactStep;
    if (Grabs[Hand].bMotion)
    {
        Grabs[Hand].GripVelocity = GripStep / Delta;
        Grabs[Hand].HeadVelocity = HeadStep / Delta;
    }
    Grabs[Hand].GripPoint = Grip;
    Grabs[Hand].HeadPoint = Head;
    Grabs[Hand].bHaveSample = true;
}

simulated function bool CoolingDown(Actor Victim)
{
    local int I;
    for (I = ImpactCooldowns.Length - 1; I >= 0; --I)
    {
        if (ImpactCooldowns[I].Victim == None || ImpactCooldowns[I].Until <= WorldInfo.TimeSeconds)
        {
            ImpactCooldowns.Remove(I, 1);
            continue;
        }
        if (ImpactCooldowns[I].Victim == Victim) return true;
    }
    return false;
}

simulated function StartCooldown(Actor Victim)
{
    local VRImpactCooldown C;
    C.Victim = Victim;
    C.Until = WorldInfo.TimeSeconds + ImpactCooldown;
    if (ImpactCooldowns.Length < 32) ImpactCooldowns.AddItem(C);
}

// Nearest hit zone to a point. KFPawn.TakeDamage matches HitInfo.BoneName
// against ZoneName, so the zone name is what a hit must carry to count as a
// head hit and pick up its multiplier.
simulated function float NearestZone(KFPawn P, vector Point, out name Zone, out vector ZoneLocation)
{
    local int I;
    local float Distance, Best;
    local vector L;
    Best = 100000000;
    Zone = '';
    if (P == None || P.Mesh == None) return Best;
    for (I = 0; I < P.HitZones.Length; ++I)
    {
        if (P.HitZones[I].BoneName == '') continue;
        if (I == HZI_HEAD && P.IsHeadless()) continue;
        L = P.Mesh.GetBoneLocation(P.HitZones[I].BoneName, 0);
        if (!FiniteVector(L)) continue;
        Distance = VSize(L - Point);
        if (Distance < Best)
        {
            Best = Distance;
            Zone = P.HitZones[I].ZoneName;
            ZoneLocation = L;
        }
    }
    return Best;
}

simulated function float ImpactDamage(float Speed)
{
    local float Alpha;
    Alpha = FClamp((Speed - MinImpactSpeed) / FMax(FullImpactSpeed - MinImpactSpeed, 1), 0, 1);
    return MinImpactDamage + (MaxImpactDamage - MinImpactDamage) * Alpha;
}

simulated function bool CanHit(KFPawn P)
{
    return P != None && !P.bDeleteMe && P.Health > 0 && !P.bPlayedDeath && P.bCanBeDamaged
        && P.Mesh != None && Bridge.Human != None && P != Bridge.Human
        && P.GetTeamNum() != Bridge.Human.GetTeamNum();
}

// Same delivery as a fist: applied here, and on a network client also sent
// to the authority, which re-checks the victim is alive.
simulated function DealImpact(KFPawn Victim, float Amount, vector HitLocation, vector Direction, name Zone)
{
    local TraceHitInfo Info;
    if (!ContextValid() || !Bridge.ZedGrabAllowed() || !CanHit(Victim) || Amount <= 0) return;
    Info.BoneName = Zone;
    Victim.TakeDamage(int(Amount), Bridge.Human.Controller, HitLocation,
        Direction * 600, class'VRDT_ZedSlam', Info, Bridge.Human);
    if (IsNetworkClient())
        Bridge.RequestNetworkGrabDamage(Victim, int(Amount), HitLocation, Direction * 600, Zone);
    StartCooldown(Victim);
    if (Bridge.HandInventory != None && Bridge.HandInventory.HitStop != None)
        Bridge.HandInventory.HitStop.Freeze(Victim, Bridge.HandInventory.HitStop.ImpactDuration);
}

simulated function UpdateImpacts(float Delta)
{
    local int I;
    for (I = 0; I < 2; ++I) SampleMotion(I, Delta);
    TrySmash();
    for (I = 0; I < 2; ++I) TrySwing(I);
}

// A held Zed driven into a wall or the floor. Its body stopped at the surface
// this tick; the speed is how fast the hand was driving it in.
simulated function WorldImpact(int Hand, vector Surface, vector Normal, float Speed)
{
    local KFPawn_Monster M;
    local name Zone;
    local vector ZoneLocation;
    local float Amount;
    M = Grabs[Hand].Pawn;
    if (Speed < MinImpactSpeed || M == None || !Grabs[Hand].bLiving || !CanHit(M) || CoolingDown(M)) return;
    if (NearestZone(M, Surface, Zone, ZoneLocation) > ContactRadius * 2) return;
    Amount = ImpactDamage(Speed);
    DealImpact(M, Amount, Surface, -Normal, Zone);
    ++WorldSmashes;
    Pulse(Hand, 1.0, 0.08);
    `log("KF2VR_ZEDGRAB action=world_smash hand=" $ Hand $ " pawn=" $ M.Class $ " zone=" $ Zone
        $ " speed=" $ int(Speed) $ " damage=" $ int(Amount));
}

// Two different Zeds, one in each hand, brought together. Head to head is the
// headline move and hits both heads harder; any other contact between the two
// bodies still hits both where they met.
simulated function TrySmash()
{
    local KFPawn_Monster A, B;
    local name ZoneA, ZoneB;
    local vector LocA, LocB, Direction, Closing;
    local float Distance, Speed, Amount;
    local bool bHeads;
    if (!Holding(0) || !Holding(1) || !Grabs[0].bMotion || !Grabs[1].bMotion) return;
    A = Grabs[0].Pawn;
    B = Grabs[1].Pawn;
    if (A == None || B == None || A == B || (!CanHit(A) && !CanHit(B)) || CoolingDown(A) || CoolingDown(B)) return;
    bHeads = HeadBone(A) != '' && HeadBone(B) != '' && !A.IsHeadless() && !B.IsHeadless()
        && VSize(Grabs[0].HeadPoint - Grabs[1].HeadPoint) <= ContactRadius * 1.4;
    if (bHeads)
    {
        LocA = Grabs[0].HeadPoint;
        LocB = Grabs[1].HeadPoint;
        ZoneA = A.HitZones[HZI_HEAD].ZoneName;
        ZoneB = B.HitZones[HZI_HEAD].ZoneName;
        Closing = Grabs[0].HeadVelocity - Grabs[1].HeadVelocity;
    }
    else
    {
        // Where A's swinging head or grip met B's body.
        LocA = Grabs[0].HeadPoint;
        Closing = Grabs[0].HeadVelocity - Grabs[1].GripVelocity;
        Distance = NearestZone(B, LocA, ZoneB, LocB);
        if (Distance > ContactRadius)
        {
            LocA = Grabs[0].GripPoint;
            Closing = Grabs[0].GripVelocity - Grabs[1].GripVelocity;
            Distance = NearestZone(B, LocA, ZoneB, LocB);
        }
        if (Distance > ContactRadius) return;
        if (NearestZone(A, LocB, ZoneA, LocA) > ContactRadius * 1.6) return;
    }
    Direction = Normal(LocB - LocA);
    if (VSizeSq(Direction) < 0.01) return;
    Speed = Closing dot Direction;
    if (Speed < MinImpactSpeed) return;
    Amount = ImpactDamage(Speed);
    if (bHeads) Amount *= HeadSmashScale;
    DealImpact(B, Amount, LocB, Direction, ZoneB);
    DealImpact(A, Amount, LocA, -Direction, ZoneA);
    ++Smashes;
    Pulse(0, 1.0, 0.09);
    Pulse(1, 1.0, 0.09);
    `log("KF2VR_ZEDGRAB action=smash heads=" $ bHeads $ " a=" $ A.Class $ " b=" $ B.Class
        $ " speed=" $ int(Speed) $ " damage=" $ int(Amount));
}

// Any Zed near a moving point, other than the ones excluded. Returns the Zed
// hit and the impact, or None.
simulated function KFPawn_Monster FindStruck(vector Point, vector PointVelocity, Actor ExcludeA, Actor ExcludeB,
    out name Zone, out vector ZoneLocation, out vector Direction, out float Speed)
{
    local KFPawn_Monster Victim;
    local int Count;
    if (VSize(PointVelocity) < MinImpactSpeed) return None;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster', Victim, Point, 160)
    {
        if (Victim == ExcludeA || Victim == ExcludeB || !CanHit(Victim) || CoolingDown(Victim)) continue;
        if (++Count > 16) break;
        if (NearestZone(Victim, Point, Zone, ZoneLocation) > ContactRadius) continue;
        Direction = Normal(ZoneLocation - Point);
        if (VSizeSq(Direction) < 0.01) Direction = Normal(PointVelocity);
        Speed = PointVelocity dot Direction;
        if (Speed < MinImpactSpeed) continue;
        return Victim;
    }
    return None;
}

// A held body, living, dead or a gib, swung into any other Zed. A living Zed
// used as the club takes a share of the blow as well.
simulated function TrySwing(int Hand)
{
    local KFPawn_Monster Held, Victim;
    local Actor Other;
    local vector Point, PointVelocity, ZoneLocation, Direction, HeldLocation;
    local name Zone, HeldZone;
    local float Speed, Amount;
    local int P;
    if (!Holding(Hand) || !Grabs[Hand].bMotion) return;
    Held = Grabs[Hand].Pawn;
    Other = None;
    if (Holding(1 - Hand)) Other = Grabs[1 - Hand].Owner;
    for (P = 0; P < 2; ++P)
    {
        Point = Grabs[Hand].HeadPoint;
        PointVelocity = Grabs[Hand].HeadVelocity;
        if (P == 1)
        {
            Point = Grabs[Hand].GripPoint;
            PointVelocity = Grabs[Hand].GripVelocity;
        }
        // The other hand's Zed belongs to TrySmash.
        Victim = FindStruck(Point, PointVelocity, Grabs[Hand].Owner, Other, Zone, ZoneLocation, Direction, Speed);
        if (Victim == None) continue;
        Amount = ImpactDamage(Speed);
        if (Grabs[Hand].bGib) Amount *= GibDamageScale;
        DealImpact(Victim, Amount, ZoneLocation, Direction, Zone);
        if (Grabs[Hand].bLiving && CanHit(Held) && !CoolingDown(Held))
        {
            NearestZone(Held, ZoneLocation, HeldZone, HeldLocation);
            DealImpact(Held, Amount * HeldSelfDamageScale, HeldLocation, -Direction, HeldZone);
        }
        ++SwingHits;
        Pulse(Hand, 0.95, 0.07);
        `log("KF2VR_ZEDGRAB action=swing_hit hand=" $ Hand $ " held=" $ Grabs[Hand].Owner.Class
            $ " living=" $ Grabs[Hand].bLiving $ " victim=" $ Victim.Class
            $ " speed=" $ int(Speed) $ " damage=" $ int(Amount));
        // One victim per point per frame keeps a single swing honest.
    }
}

// ---------------------------------------------------------------------------
// Thrown bodies.

simulated function AddThrown(int Hand)
{
    local VRThrownBody T;
    T.Owner = Grabs[Hand].Owner;
    T.Pawn = Grabs[Hand].Pawn;
    T.Component = Grabs[Hand].Component;
    T.BoneName = Grabs[Hand].BoneName;
    T.bLiving = Grabs[Hand].bLiving;
    T.bGib = Grabs[Hand].bGib;
    T.Since = WorldInfo.TimeSeconds;
    if (Thrown.Length >= 8) Thrown.Remove(0, 1);
    Thrown.AddItem(T);
}

simulated function vector ThrownPoint(int I, out vector PointVelocity)
{
    local RB_BodyInstance Body;
    if (Thrown[I].bGib) Body = Thrown[I].Component.GetRootBodyInstance();
    else Body = class'VRBodyHold'.static.BodyFor(Thrown[I].Component, Thrown[I].BoneName);
    if (Body == None || !Body.IsValidBodyInstance()) { PointVelocity = vect(0,0,0); return vect(0,0,0); }
    PointVelocity = Body.GetUnrealWorldVelocity();
    return MatrixGetOrigin(Body.GetUnrealWorldTM());
}

// Until a thrown body comes to rest it hits every Zed it meets, and a living
// one thrown into a wall takes the wall. Once it settles it is just a body.
simulated function UpdateThrown()
{
    local int I;
    local vector Point, PointVelocity, RootVelocity, ZoneLocation, Direction, HitLocation, HitNormal;
    local name Zone;
    local float Speed, ImpactSpeed, Amount;
    local KFPawn_Monster Victim;
    local RB_BodyInstance Root;
    for (I = Thrown.Length - 1; I >= 0; --I)
    {
        if (Thrown[I].Owner == None || Thrown[I].Owner.bDeleteMe || Thrown[I].Component == None
            || WorldInfo.TimeSeconds - Thrown[I].Since > ThrownLifetime)
        {
            Thrown.Remove(I, 1);
            continue;
        }
        Point = ThrownPoint(I, PointVelocity);
        Root = Thrown[I].Component.GetRootBodyInstance();
        RootVelocity = PointVelocity;
        if (Root != None && Root.IsValidBodyInstance()) RootVelocity = Root.GetUnrealWorldVelocity();
        Speed = FMax(VSize(PointVelocity), VSize(RootVelocity));
        if (Speed < RestSpeed)
        {
            Thrown[I].RestTime += WorldInfo.DeltaSeconds;
            if (Thrown[I].RestTime > RestTime) { Thrown.Remove(I, 1); continue; }
        }
        else Thrown[I].RestTime = 0;

        Victim = FindStruck(Point, PointVelocity, Thrown[I].Owner, None, Zone, ZoneLocation, Direction, ImpactSpeed);
        if (Victim == None && Thrown[I].Pawn != None && Root != None && Root.IsValidBodyInstance())
            Victim = FindStruck(MatrixGetOrigin(Root.GetUnrealWorldTM()), RootVelocity, Thrown[I].Owner, None,
                Zone, ZoneLocation, Direction, ImpactSpeed);
        if (Victim != None)
        {
            Amount = ImpactDamage(ImpactSpeed);
            if (Thrown[I].bGib) Amount *= GibDamageScale;
            DealImpact(Victim, Amount, ZoneLocation, Direction, Zone);
            if (Thrown[I].bLiving && CanHit(Thrown[I].Pawn) && !CoolingDown(Thrown[I].Pawn))
                DealImpact(Thrown[I].Pawn, Amount * HeldSelfDamageScale, Point, -Direction, Zone);
            ++ThrownHits;
            `log("KF2VR_ZEDGRAB action=thrown_hit thrown=" $ Thrown[I].Owner.Class $ " living=" $ Thrown[I].bLiving
                $ " victim=" $ Victim.Class $ " speed=" $ int(ImpactSpeed) $ " damage=" $ int(Amount));
        }
        // A living Zed thrown into a wall: a sudden stop right against the
        // world, from a speed worth a hit.
        if (Thrown[I].bLiving && CanHit(Thrown[I].Pawn) && !CoolingDown(Thrown[I].Pawn)
            && Thrown[I].LastSpeed >= MinImpactSpeed && Speed < Thrown[I].LastSpeed * 0.5
            && Trace(HitLocation, HitNormal, Point + Normal(Thrown[I].LastVelocity) * (BodyRadius + 20), Point, false) != None)
        {
            NearestZone(Thrown[I].Pawn, HitLocation, Zone, ZoneLocation);
            Amount = ImpactDamage(Thrown[I].LastSpeed);
            DealImpact(Thrown[I].Pawn, Amount, HitLocation, -HitNormal, Zone);
            ++WorldSmashes;
            `log("KF2VR_ZEDGRAB action=thrown_world_hit pawn=" $ Thrown[I].Pawn.Class $ " zone=" $ Zone
                $ " speed=" $ int(Thrown[I].LastSpeed) $ " damage=" $ int(Amount));
        }
        Thrown[I].LastSpeed = Speed;
        Thrown[I].LastVelocity = RootVelocity;
        if (VSize(PointVelocity) >= VSize(RootVelocity)) Thrown[I].LastVelocity = PointVelocity;
    }
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    TickGroup=TG_PreAsyncWork

    GrabRadius=22.0
    PalmForward=4.0
    SearchRadius=220.0
    // Per phase, not for the whole request: the knockdown round trip and the
    // ragdoll transition each get this long. See UpdateHand.
    RagdollTimeout=1.50
    // The least velocity KFSM_RagdollKnockdown accepts without a warning.
    KnockdownNudge=2.0
    // 20 Hz. Enough for the authority's copy, which only decides where the
    // Zed gets up and what it can be hit through.
    MoveSendInterval=0.05
    BodyRadius=8.0
    BlockedDrop=90.0
    BlockedGrace=0.4
    // A little over the hand: a throw that only matched the hand felt weak.
    ThrowScale=1.25
    MinThrowSpeed=160.0
    MaxThrowSpeed=2200.0
    RestSpeed=90.0
    RestTime=0.25
    ThrownLifetime=5.0
    GibDamageScale=0.6

    // Held-body impacts. A deliberate swing of a held body runs roughly
    // 300-900 UU/s; below MinImpactSpeed a contact is a nudge.
    MinImpactSpeed=220.0
    FullImpactSpeed=750.0
    MinImpactDamage=25.0
    MaxImpactDamage=160.0
    HeadSmashScale=1.6
    HeldSelfDamageScale=0.5
    ContactRadius=30.0
    ImpactCooldown=0.35
    MaximumImpactStep=100.0
    SwingHumSpeed=350.0
    SwingHumMaxStrength=0.35
}
