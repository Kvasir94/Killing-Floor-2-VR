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

// Alyx-style release velocity for this hand throw (VRThrowRelease).
var VRThrowRelease Thrower;

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
    var bool bHaveGripFrame; // preserve the original hand/body relation through gore swaps
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
    var bool bActive;
    // Melee item 10, experimental: a standing hold (VRSM_StandingHold); no
    // body is fixed in the hand and the Zed stays on its feet.
    var bool bStanding;
};

// A released body still flying. It keeps dealing damage to Zeds it meets
// until it comes to rest; a still corpse a Zed walks into does nothing.
struct VRThrownBody
{
    var Actor Owner;
    var KFPawn_Monster Pawn;
    var PrimitiveComponent Component;
    var name BoneName;
    var RB_BodyInstance Body;
    var bool bLiving, bGib;
    var float Since, RestTime, LastSpeed;
    var vector LastVelocity, LastPoint;
    var bool bHavePoint;
};

var VRHandsBridge Bridge;
var VRGrabState Grabs[2];
var array<VRThrownBody> Thrown;

var float GrabRadius;          // palm-to-body acceptance distance
var float GrabNearMissAllowance; // initial Zed contact only; no extra snap or gib reach
var float PalmForward;         // palm point ahead of the tracked hand origin
var float SearchRadius;        // candidate search around the palm
var float RagdollTimeout;      // knockdown request must land within this
var float KnockdownNudge;      // the least velocity stock knockdown accepts
var float BodyRadius;          // held body stops this far off a wall
var float BlockedDrop;         // a wall this far between hand and body...
var float BlockedGrace;        // ...for this long releases the body
var float ThrowScale;          // released body speed per unit of hand speed
var float MinThrowSpeed;       // slower releases just drop
var float MaxThrowSpeed;
var float CorpseThrowScale, MaxCorpseThrowSpeed;
var float GibMass;             // kg for a loose gib, which has no stock pawn mass
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
// Breacher Rend: two hands on one living small or medium Zed, pulled apart past
// its span by this much, tear the limb off and kill it through the stock death
// gore. The perk is matched by class name and the skill by index (KF2Breacher
// compiles separately). Network damage/topology belongs to the authority.
var float RendStretch;
var int RendSkillIndex;
var int Rends;
var float RendWaitUntil;
var float NextDazeCheck;
// Melee item 10, B&S HumanWrist (IK position weight 1): a standing hold on a
// Zed's arm pins the gripped part in the hand. The arm between the held part
// and the shoulder goes to physics like the stock injured-arm ragdoll
// (KFPawn.RagdollArm) and the held body is placed at the palm every tick, so
// the arm follows the hand while the rest of the Zed stays animated. Local
// presentation on the grabber's machine; released if the pin cannot hold.
struct ArmPinSet { var array<name> Bones; var bool bPinned, bSavedReactions; };
var ArmPinSet ArmPinSets[2];
var vector ArmPinOffset[2];
var Quat ArmPinRelative[2];
var matrix ArmPinStart[2];
var float ArmPinTime[2], ArmPinBadSince[2], ArmPinMaxError, ArmPinMaxErrorTime;
var int ArmPins, ArmPinFailures;

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

simulated function bool HoldsActor(Actor A)
{
    return A != None && ((Grabs[0].bActive && Grabs[0].Owner == A) || (Grabs[1].bActive && Grabs[1].Owner == A));
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
        && class'VRPhysicalInteraction'.static.Allowed(Bridge.Human)
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
    B.QueueHandHaptic(1 << Hand, Strength, Duration);
}

// ---------------------------------------------------------------------------
// Eligibility.

// Bosses, boss corpses and boss-origin gore are never grabbable.
simulated function bool IsBossOrigin(KFPawn_Monster M)
{
    return M.IsABoss() || KFPawn_MonsterBoss(M) != None || KFInterface_MonsterBoss(M) != None;
}

simulated function bool IsCorpse(KFPawn_Monster M)
{
    return M.Health <= 0 || M.bPlayedDeath;
}

// Large Zeds normally require an existing knockdown. Overpressure temporarily
// admits new ones in Zed Time, or while enough stored pressure remains. Existing
// holds retain their ordinary release/recovery ownership when eligibility ends.
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
        // large Zed without Overpressure can take.
        return GRAB_Body;
    }
    if (M.IsLargeZed() && !class'VRBreacherPhysics'.static.ExpandedGrab(Bridge.PC)) return GRAB_None;
    if (OwnedByOtherHand(Hand, M)) return GRAB_Living;
    // Admission must fail when the stock move cannot start, including the
    // global five-ragdoll cap.
    return class'VRSM_HeldKnockdown'.static.CanStart(M) ? GRAB_Living : GRAB_None;
}

// Resolve a contacted visual bone to a physical body. The grip goes to the
// nearest major body part, not the nearest bone: a tongue, claw or finger has
// a physics body of its own, but it is a thin chain on weak joints, and hit
// zones are exactly the parts worth holding -- head, neck, torso, limbs.
// Distances are to each part's bone line (from its parent joint to its own),
// not to bone origins alone, so a palm on a thigh, upper arm or belly holds
// that part even though the nearest joint is a knee, shoulder or spine (#117).
simulated function bool ResolveBody(KFPawn_Monster M, vector Palm, out name OutBone, out float OutDistance)
{
    local name RBBone, ParentRB, Parent, Best;
    local vector BoneLocation, ParentLocation, Nearest;
    local float Distance, BestDistance, Along, Span;
    local int I;
    OutBone = '';
    BestDistance = GrabRadius * 2.5;
    for (I = 0; I < M.HitZones.Length; ++I)
    {
        if (M.HitZones[I].BoneName == '') continue;
        if (I == HZI_HEAD && M.IsHeadless()) continue;
        RBBone = M.GetRBBoneFromBoneName(M.HitZones[I].BoneName);
        if (RBBone == '' || class'VRBodyHold'.static.BodyFor(M.Mesh,RBBone) == None) continue;
        BoneLocation = M.Mesh.GetBoneLocation(M.HitZones[I].BoneName, 0);
        Distance = VSize(BoneLocation - Palm);
        if (Distance < BestDistance) { BestDistance = Distance; Best = RBBone; }
        // Along the line from the parent joint the palm holds the parent's
        // part (a palm mid-thigh between hip and knee holds the thigh).
        Parent = M.Mesh.GetParentBone(M.HitZones[I].BoneName);
        if (Parent == '') continue;
        ParentLocation = M.Mesh.GetBoneLocation(Parent, 0);
        Span = VSizeSq(BoneLocation - ParentLocation);
        if (Span < 1) continue;
        Along = FClamp(((Palm - ParentLocation) dot (BoneLocation - ParentLocation)) / Span, 0, 1);
        Nearest = ParentLocation + (BoneLocation - ParentLocation) * Along;
        Distance = VSize(Nearest - Palm);
        if (Distance >= BestDistance) continue;
        ParentRB = M.GetRBBoneFromBoneName(Parent);
        if (Along < 0.9 && ParentRB != '' && class'VRBodyHold'.static.BodyFor(M.Mesh, ParentRB) != None)
            RBBone = ParentRB;
        BestDistance = Distance;
        Best = RBBone;
    }
    // Contact: the palm has to be at a part's bone line, or at any bone (a
    // claw or jaw still counts as touching the Zed).
    if (Best == '') return false;
    if (BestDistance > GrabRadius + GrabNearMissAllowance
        && (M.Mesh.FindClosestBone(Palm, BoneLocation) == ''
        || VSize(BoneLocation - Palm) > GrabRadius + GrabNearMissAllowance)) return false;
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
        if (G.GibMeshComp.GetRootBodyInstance() == None) continue;
        // A long gib's origin can sit at one end: measure to its bounds.
        Distance = FMax(0, VSize(G.GibMeshComp.Bounds.Origin - Palm) - G.GibMeshComp.Bounds.SphereRadius * 0.5);
        if (Distance >= OutDistance) continue;
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
    if (M == None && Gib == None)
    {
        ++Rejects;
        if (class'VRSM_HeldKnockdown'.static.EscapeEnabled()) RefuseLarge(Hand, Palm);
        return false;
    }

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
        // Melee item 10: catching the wrist or forearm of a Zed mid-attack
        // interrupts it with the stock parry first, at the fist guard's
        // strength 3 (B&S: a grabbed arm cannot strike).
        if (!Bridge.UseLegacyMelee(Bridge.bLegacyMeleeRegionGrab) && class'VRGrapplePose'.static.RegionForBone(Bone) == class'VRGrapplePose'.const.REGION_LIMB
            && IsArmBone(Bone) && class'VRPhysicalFist'.static.AttackParryable(M, class'VRFistGuard'.default.ParryStrength))
        {
            if (IsNetworkClient()) Bridge.RequestNetworkFistParry(M, Hand);
            else class'VRPhysicalFist'.static.ApplyParry(M, Bridge.Human, class'VRFistGuard'.default.ParryStrength);
            `log("KF2VR_ZEDGRAB action=wrist_parry hand=" $ Hand $ " pawn=" $ M.Class);
        }
        if (StandingWanted(M))
        {
            if (!BeginStanding(Hand, M, Bone)) { ClearGrab(Hand, "standing_refused"); ++Rejects; return false; }
            ++LivingGrabs;
            Pulse(Hand, 1.0, 0.035);
            `log("KF2VR_ZEDGRAB action=grab hand=" $ Hand $ " pawn=" $ M.Class $ " bone=" $ Bone $ " standing=1");
            return true;
        }
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

// Take a body the Ripcord has reeled to the hand: no palm-contact search, the
// cable delivered it. It is already a ragdoll. If its knockdown is ours
// (VRSM_HeldKnockdown, installed before the reel), the hold gates recovery
// like a living grab; otherwise it is a plain body hold. bHead takes the head
// when it is still there: the line pulled the Zed in by it.
simulated function bool GrabPawn(int Hand, KFPawn_Monster M, optional bool bHead)
{
    local name RBBone, Best;
    local vector Palm;
    local float Distance, BestDistance;
    local int I;
    if (!ContextValid() || !Bridge.ZedGrabAllowed()) return false;
    if (!HandValid(Hand) || Grabs[Hand].bActive) return false;
    if (M == None || M.bDeleteMe || M.Mesh == None || M.Mesh.PhysicsAsset == None) return false;
    if (IsBossOrigin(M) || IsCorpse(M) || M.Physics != PHYS_RigidBody) return false;
    if (Bridge.Human.GetTeamNum() == M.GetTeamNum()) return false;
    Palm = PalmPoint(Hand);
    BestDistance = 100000000;
    if (bHead && !M.IsHeadless() && M.HitZones.Length > HZI_HEAD && M.HitZones[HZI_HEAD].BoneName != '')
    {
        RBBone = M.GetRBBoneFromBoneName(M.HitZones[HZI_HEAD].BoneName);
        if (RBBone != '' && class'VRBodyHold'.static.BodyFor(M.Mesh,RBBone) != None) Best = RBBone;
    }
    for (I = 0; Best == '' && I < M.HitZones.Length; ++I)
    {
        if (M.HitZones[I].BoneName == '') continue;
        if (I == HZI_HEAD && M.IsHeadless()) continue;
        RBBone = M.GetRBBoneFromBoneName(M.HitZones[I].BoneName);
        if (RBBone == '' || class'VRBodyHold'.static.BodyFor(M.Mesh,RBBone) == None) continue;
        Distance = VSize(M.Mesh.GetBoneLocation(RBBone, 0) - Palm);
        if (Distance < BestDistance) { BestDistance = Distance; Best = RBBone; }
    }
    if (Best == '') return false;
    ResetGrab(Hand);
    Grabs[Hand].StartTime = WorldInfo.TimeSeconds;
    Grabs[Hand].bActive = true;
    Grabs[Hand].Owner = M;
    Grabs[Hand].Pawn = M;
    Grabs[Hand].Component = M.Mesh;
    Grabs[Hand].BoneName = Best;
    Grabs[Hand].bLiving = class'VRSM_HeldKnockdown'.static.Current(M) != None;
    if (!AttachHold(Hand)) { ClearGrab(Hand, "attach_failed"); ++Rejects; return false; }
    ClaimServerHold(Hand);
    if (Grabs[Hand].bLiving) ++LivingGrabs; else ++CorpseGrabs;
    Pulse(Hand, 1.0, 0.05);
    `log("KF2VR_ZEDGRAB action=grab hand=" $ Hand $ " pawn=" $ M.Class $ " bone=" $ Best $ " living=" $ Grabs[Hand].bLiving $ " source=ripcord");
    return true;
}

// ---------------------------------------------------------------------------
// Breacher Rend.

simulated function bool RendAllowed()
{
    local KFPerk Perk;
    if (Bridge == None || Bridge.Human == None) return false;
    Perk = Bridge.Human.GetPerk();
    if (Perk == None || Perk.Class.Name != 'BreacherPerk') return false;
    if (RendSkillIndex < 0 || RendSkillIndex >= Perk.PerkSkills.Length) return false;
    return Perk.PerkSkills[RendSkillIndex].bActive && Perk.IsPerkLevelAllowed(RendSkillIndex);
}

// The hit zone whose ragdoll body a hand holds, or -1.
simulated function int HeldZone(KFPawn_Monster M, name RBBone)
{
    local int I;
    for (I = 0; I < M.HitZones.Length; ++I)
        if (M.HitZones[I].BoneName != '' && M.GetRBBoneFromBoneName(M.HitZones[I].BoneName) == RBBone) return I;
    return -1;
}

// Two hands on one living Zed, pulled apart: the limb held by this hand comes
// away (the torso stays with the other hand) and the kill goes through the
// stock death gore with the limb as the hit bone, so it detaches exactly as a
// blown-off limb or a decapitation would. Large Zeds and corpses are not torn.
simulated function bool TryRend(int Hand)
{
    local KFPawn_Monster M;
    local class<KFDamageType> Rend;
    local TraceHitInfo HitInfo;
    local int Zone, OtherZone, Other;
    local vector Pull;
    if (!RendAllowed()) return false;
    M = Grabs[Hand].Pawn;
    Other = 1 - Hand;
    if (M == None || M.bDeleteMe || M.Health <= 0 || IsCorpse(M) || M.IsLargeZed() || IsBossOrigin(M)) return false;
    Zone = HeldZone(M, Grabs[Hand].BoneName);
    OtherZone = HeldZone(M, Grabs[Other].BoneName);
    if (Zone < 0 || OtherZone < 0 || Zone == OtherZone) return false;
    // Tear away the part that is not the body: this hand's, unless this hand holds the torso.
    if (M.HitZones[Zone].Limb == BP_Torso && M.HitZones[OtherZone].Limb != BP_Torso) { Zone = OtherZone; Hand = Other; }
    // If both hands are on one limb, sever below the upper grip so each hand
    // owns a different resulting piece, rather than cutting above both hands.
    if (M.Mesh.BoneIsChildOf(Grabs[1 - Hand].BoneName, M.HitZones[Zone].BoneName))
    { Hand = 1 - Hand; Zone = HeldZone(M, Grabs[Hand].BoneName); }
    if (IsNetworkClient())
    {
        // No predicted damage, gore or success pulse. Keep the already claimed
        // hands and stream BOTH desired frames while authority validates Rend.
        // The deadline never renews on a continued pull or a refused attempt.
        if (!Grabs[0].bServerHeld || !Grabs[1].bServerHeld) return false;
        if (RendWaitUntil==0) RendWaitUntil=WorldInfo.RealTimeSeconds+0.75;
        if (WorldInfo.RealTimeSeconds>=RendWaitUntil)
        { ClearGrab(0,"rend_authority_timeout"); ClearGrab(1,"rend_authority_timeout"); return true; }
        return true;
    }
    if (Bridge.Human.Role!=ROLE_Authority) return false;
    Rend = class<KFDamageType>(DynamicLoadObject("KF2Breacher.BreacherDT_Rend", class'Class', true));
    if (Rend == None) return false;
    Pull = Normal(PalmPoint(Hand) - PalmPoint(1 - Hand));
    HitInfo.BoneName = M.HitZones[Zone].ZoneName;
    HitInfo.HitComponent = M.Mesh;
    // Spend the zone's gore health so the death gore detaches this limb, then the kill.
    M.TakeHitZoneDamage(M.HitZones[Zone].GoreHealth + 1, Rend, Zone, PalmPoint(1 - Hand));
    if (M.Health>0 && !M.bPlayedDeath)
        M.TakeDamage(M.Health + 1, Bridge.PC, M.Mesh.GetBoneLocation(Grabs[Hand].BoneName, 0), Pull * 50, Rend, HitInfo, Bridge);
    // Game rules/armour may veto the kill. Keep the ordinary hold and do not
    // report or pulse a successful tear until stock death actually completed.
    if (M.bDeleteMe || M.Health>0 || !M.bPlayedDeath) return false;
    ++Rends;
    Pulse(Hand, 1.0, 0.12);
    Pulse(1 - Hand, 1.0, 0.12);
    `log("KF2VR_ZEDGRAB action=rend pawn=" $ M.Class $ " zone=" $ M.HitZones[Zone].ZoneName $ " other=" $ M.HitZones[OtherZone].ZoneName);
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
simulated function bool AttachHold(int Hand, optional bool bPreserveFrame)
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
    class'VRBodyHold'.static.YieldPins(Grabs[Hand].Component);
    // Pin cleanup is a callback and may rebuild or retire the captured body.
    if (Body.OwnerComponent != Grabs[Hand].Component || !Body.IsValidBodyInstance()) return false;
    if (Grabs[Other].bAttached && Grabs[Other].Component == Grabs[Hand].Component
        && Grabs[Other].Body != None && Grabs[Other].Body.IsValidBodyInstance())
    {
        Grabs[Hand].TwoPointSpan = VSize(MatrixGetOrigin(Body.GetUnrealWorldTM())
            - MatrixGetOrigin(Grabs[Other].Body.GetUnrealWorldTM()));
        Grabs[Other].TwoPointSpan = Grabs[Hand].TwoPointSpan;
    }
    if (!bPreserveFrame || !Grabs[Hand].bHaveGripFrame)
    {
        if (!class'VRBodyHold'.static.Capture(Body, PalmPoint(Hand), HandRotation(Hand),
            Grabs[Hand].OffsetLocal, Grabs[Hand].RelativeQuat)) return false;
        if (!Grabs[Hand].bGib && Grabs[Hand].Pawn != None)
            class'VRBodyHold'.static.SeatInPalm(Hand, Grabs[Hand].BoneName, Grabs[Hand].OffsetLocal);
        Grabs[Hand].bHaveGripFrame = true;
    }
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
    RetireThrownPiece(Hand);
    class'VRGrabOwnership'.static.Update(Bridge.PC,byte(Hand),Grabs[Hand].Owner,Grabs[Hand].BoneName,PalmPoint(Hand));
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
}

// End a hold. Throw is the release velocity for a deliberate let-go; every
// other ending passes none and the body simply drops. Carry is a let-go too
// slow to count as a throw: the local body still leaves with the hand's
// motion instead of stopping dead where it was held (#25).
simulated function ClearGrab(int Hand, string Reason, optional vector Throw, optional vector Carry)
{
    local VRSM_HeldKnockdown Move;
    local VRSM_StandingHold Standing;
    local bool bOwnerLive, bThrown;
    if (Hand < 0 || Hand > 1) return;
    RendWaitUntil=0;
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
    if (Grabs[1 - Hand].bActive && Grabs[1 - Hand].Owner == Grabs[Hand].Owner
        && class'VRBodyHold'.static.SamePiece(Grabs[Hand].Component, Grabs[Hand].BoneName, Grabs[1 - Hand].BoneName))
    { Throw = vect(0,0,0); Carry = vect(0,0,0); }
    // Only authority spends pressure. Clients send their original bounded throw.
    if (!IsZero(Throw) && bOwnerLive && !IsNetworkClient())
        Throw=class'VRBreacherPhysics'.static.EmpowerThrow(Bridge.PC,Grabs[Hand].Owner,PalmPoint(Hand),Throw);
    class'VRGrabOwnership'.static.Release(Bridge.PC,byte(Hand),Throw);
    if (Grabs[Hand].bStanding) EndArmPin(Hand, true);
    if (Grabs[Hand].bStanding && !IsNetworkClient())
    {
        Standing = class'VRSM_StandingHold'.static.Current(Grabs[Hand].Pawn);
        if (Standing != None) Standing.ReleaseHold(byte(Hand));
    }
    bThrown = !IsZero(Throw);
    if (Grabs[Hand].bAttached && bOwnerLive && HeldBodyCurrent(Hand)
        && !(Grabs[1 - Hand].bActive && Grabs[1 - Hand].Body == Grabs[Hand].Body))
        class'VRBodyHold'.static.End(Grabs[Hand].Body, Grabs[Hand].Component, bThrown ? Throw : Carry, Grabs[Hand].BoneName);
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
    if (bThrown && bOwnerLive) AddThrown(Hand, Throw);
    if (Grabs[Hand].bGib && KFGiblet(Grabs[Hand].Owner) != None && bOwnerLive)
        Grabs[Hand].Owner.LifeSpan = 8.0;
    ResetGrab(Hand);
}

simulated function Release(int Hand)
{
    local vector Throw, Carry;
    local float Scale, Limit;
    if (Hand < 0 || Hand > 1 || !Grabs[Hand].bActive) return;
    // Alyx's release: drop the braking frames, average direction at peak speed.
    if (Thrower != None) Grabs[Hand].HandVelocity = Thrower.Release(Hand, WorldInfo.RealTimeSeconds, Grabs[Hand].HandVelocity);
    Scale = Grabs[Hand].bLiving ? ThrowScale : CorpseThrowScale;
    Limit = Grabs[Hand].bLiving ? MaxThrowSpeed : MaxCorpseThrowSpeed;
    // A dead weight leaves at the speed it was following the hand (#25): the
    // hand's speed, up to the most this piece's mass lets it keep up with.
    if (!Grabs[Hand].bLiving && HoldSpeedLimit(Hand) > 0) Limit = FMin(Limit, HoldSpeedLimit(Hand));
    if (Bridge != None && Bridge.bSuperStrength)
    {
        Scale = Grabs[Hand].bLiving ? 1.5 : 0.85;
        Limit = Grabs[Hand].bLiving ? 2200.0 : 1000.0;
    }
    if (Grabs[Hand].bAttached && Grabs[Hand].bHavePalm)
    {
        Carry = Grabs[Hand].HandVelocity * Scale;
        if (VSize(Carry) > Limit) Carry = Normal(Carry) * Limit;
        if (VSize(Grabs[Hand].HandVelocity) * Scale >= MinThrowSpeed) { Throw = Carry; ++Throws; }
    }
    `log("KF2VR_ZEDGRAB action=release hand=" $ Hand $ " throw=" $ int(VSize(Throw)) $ " carry=" $ int(VSize(Carry)) $ " mass=" $ int(HeldMass(Hand)));
    ClearGrab(Hand, "release", Throw, Carry);
    Pulse(Hand, 0.35, 0.035);
}

// Stock pawn mass (kg) shared out by physics-body mass to the connected
// piece in the hand, so a severed limb weighs its share of the Zed.
simulated function float HeldMass(int Hand)
{
    if (Grabs[Hand].bGib || Grabs[Hand].Pawn == None) return GibMass;
    return class'VRBodyHold'.static.PieceMass(Grabs[Hand].Pawn, SkeletalMeshComponent(Grabs[Hand].Component), Grabs[Hand].BoneName);
}

// Fastest this dead hold follows the hand (VRBodyHold.Weigh); 0 for a living
// Zed or super strength, which keep up with any swing.
simulated function float HoldSpeedLimit(int Hand)
{
    if (Grabs[Hand].bLiving || (Bridge != None && Bridge.bSuperStrength)) return 0;
    return class'VRBodyHold'.static.WeightSpeed(HeldMass(Hand));
}

simulated function ReleaseAll()
{
    if (Grabs[0].bActive) ClearGrab(0, "cancelled");
    if (Grabs[1].bActive) ClearGrab(1, "cancelled");
    Thrown.Length = 0;
    ImpactCooldowns.Length = 0;
}

// Gore does not revoke an existing hand's ownership. Destruction, context
// loss and tracking loss still do; a changed physics body is rebound below.
simulated function bool HoldStillValid(int Hand)
{
    local KFPawn_Monster M;
    if (Grabs[Hand].Owner == None || Grabs[Hand].Owner.bDeleteMe) return false;
    if (!ContextValid() || !HandValid(Hand)) return false;
    if (Grabs[Hand].bGib) return Grabs[Hand].Component != None;
    M = Grabs[Hand].Pawn;
    if (M == None || M.Mesh == None || M.Mesh != Grabs[Hand].Component) return false;
    if (!Grabs[Hand].bLiving) return true;
    if (IsCorpse(M)) return false;
    return true;
}

// Keep the exact held part and grip while death or gore rebuilds its physics.
simulated function BeginRegrip(int Hand)
{
    if (Grabs[Hand].bAttached && HeldBodyCurrent(Hand))
        class'VRBodyHold'.static.End(Grabs[Hand].Body, Grabs[Hand].Component);
    Grabs[Hand].bAttached = false;
    Grabs[Hand].Body = None;
    if (IsCorpse(Grabs[Hand].Pawn))
    {
        Grabs[Hand].bLiving = false;
        Grabs[Hand].bHoldCounted = false;
    }
    Grabs[Hand].bRegrip = true;
    Grabs[Hand].RegripSince = WorldInfo.TimeSeconds;
    Grabs[Hand].bMotion = false;
    Grabs[Hand].bHaveSample = false;
}

simulated function UpdateHand(int Hand, float DeltaTime)
{
    local KFPawn_Monster M;
    local VRSM_HeldKnockdown Move;
    if (!Grabs[Hand].bActive) return;
    if (Grabs[Hand].bStanding) { UpdateStanding(Hand); return; }
    M = Grabs[Hand].Pawn;
    if (Grabs[Hand].bAttached)
        class'VRGrabOwnership'.static.Update(Bridge.PC,byte(Hand),Grabs[Hand].Owner,Grabs[Hand].BoneName,PalmPoint(Hand));
    // SwitchToGoreMesh may replace bodies (or the component) before death.
    // Retain the named part, hand frame and knockdown ownership while physics
    // rebuilds. Never silently switch a severed hand to another nearby part.
    if (M != None && !M.bDeleteMe && M.Mesh != None && !Grabs[Hand].bPendingRagdoll
        && (M.Mesh != Grabs[Hand].Component || (!Grabs[Hand].bRegrip
            && class'VRBodyHold'.static.BodyFor(M.Mesh, Grabs[Hand].BoneName) != Grabs[Hand].Body)))
    {
        if (!Grabs[Hand].bRegrip) BeginRegrip(Hand);
        Grabs[Hand].Component = M.Mesh;
    }
    // Killing the Zed in your hand -- by smashing it, or anyone shooting it --
    // keeps the body rather than dropping it.
    if (M != None && Grabs[Hand].bLiving && !Grabs[Hand].bPendingRagdoll && !M.bDeleteMe
        && M.Mesh == Grabs[Hand].Component && IsCorpse(M))
        BeginRegrip(Hand);
    // A severed piece no longer owns the living monster's recovery gate.
    // Keep its physics hold even if the surviving monster stands up.
    if (M != None && Grabs[Hand].bLiving && !M.bDeleteMe
        && class'VRBodyHold'.static.Detached(M.Mesh, Grabs[Hand].BoneName))
    {
        if (Grabs[Hand].bHoldCounted)
        {
            Move = class'VRSM_HeldKnockdown'.static.Current(M);
            if (Move != None) Move.ReleaseHold(false);
        }
        Grabs[Hand].bHoldCounted = false;
        Grabs[Hand].bLiving = false;
    }
    if (!HoldStillValid(Hand)) { ++InvalidDrops; ClearGrab(Hand, "invalid"); return; }
    if (Escaped(Hand)) return;

    if (Grabs[Hand].bRegrip)
    {
        // Keep the existing authority hand lease alive while the local death
        // ragdoll rebuilds. Only the bounded, already-owned hand frame crosses
        // the network; no client corpse transform or new target claim does.
        // Wait for the death to finish: PlayDying re-initialises the ragdoll
        // after the health reaches zero, and a grip taken before that is on
        // bodies about to be replaced.
        if ((!IsCorpse(M) || M.bPlayedDeath)
            && (M.Physics == PHYS_RigidBody || class'VRBodyHold'.static.Detached(M.Mesh, Grabs[Hand].BoneName))
            && AttachHold(Hand, true))
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
        // On a network client the knockdown's new ragdoll can report its
        // bodies far from the Zed for a few frames after PHYS_RigidBody. A
        // grip captured then blended in from that frame and was dropped as a
        // tracking jump a few ticks later (#177: "fell to the floor but I did
        // not grab them"). Wait for the held body to sit by the palm.
        if (M.Physics == PHYS_RigidBody && !RagdollSettledAtPalm(Hand, M))
        {
            if (WorldInfo.TimeSeconds - Grabs[Hand].StartTime > RagdollTimeout)
            { ++TimeoutDrops; ClearGrab(Hand, "ragdoll_far"); }
            return;
        }
        if (M.Physics == PHYS_RigidBody)
        {
            Grabs[Hand].bPendingRagdoll = false;
            if (!AttachHold(Hand)) { ClearGrab(Hand, "attach_failed"); return; }
            `log("KF2VR_ZEDGRAB action=attach hand=" $ Hand $ " waited=" $ (WorldInfo.TimeSeconds - Grabs[Hand].StartTime)
                $ " body_to_palm=" $ VSize(MatrixGetOrigin(Grabs[Hand].StartTM) - PalmPoint(Hand)));
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

    if (M != None && M.Physics != PHYS_RigidBody
        && !class'VRBodyHold'.static.Detached(M.Mesh, Grabs[Hand].BoneName))
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
        if (M != None) { BeginRegrip(Hand); return; }
        ClearGrab(Hand, "body_lost");
        return;
    }
    // Stock gore can unfix an existing instance without replacing it.
    class'VRBodyHold'.static.Begin(Grabs[Hand].Body, Grabs[Hand].Component);
    PlaceHeld(Hand, DeltaTime);
    if (Grabs[Hand].bActive && Grabs[Hand].bGib) Grabs[Hand].Owner.LifeSpan = FMax(Grabs[Hand].Owner.LifeSpan, 8.0);
}

// The knocked-down Zed's held body is where the hand closed on it, not still
// at an uninitialised ragdoll frame.
simulated function bool RagdollSettledAtPalm(int Hand, KFPawn_Monster M)
{
    local RB_BodyInstance Body;
    Body = class'VRBodyHold'.static.BodyFor(M.Mesh, Grabs[Hand].BoneName);
    return Body != None && Body.IsValidBodyInstance()
        && VSize(MatrixGetOrigin(Body.GetUnrealWorldTM()) - PalmPoint(Hand)) <= SearchRadius;
}

// Melee item 11, mirroring the authority's timer in VRSM_HeldKnockdown: a
// held living Zed breaks the second hand of a two-handed hold after 2 s and
// the whole hold after 5 s (scaled by class), with a shove-back pulse.
simulated function bool Escaped(int Hand)
{
    local float Held, Scale;
    local int Other;
    local VRSM_HeldKnockdown Move;
    if (!Grabs[Hand].bLiving || Grabs[Hand].bPendingRagdoll || Grabs[Hand].Pawn == None
        || !class'VRSM_HeldKnockdown'.static.EscapeEnabled()) return false;
    Move = class'VRSM_HeldKnockdown'.static.Current(Grabs[Hand].Pawn);
    if (Move != None && Move.RecoveringFromImpact()) return false;
    Scale = class'VRSM_HeldKnockdown'.static.EscapeScale(Grabs[Hand].Pawn);
    Other = 1 - Hand;
    Held = WorldInfo.TimeSeconds - Grabs[Hand].StartTime;
    if (Grabs[Other].bActive && Grabs[Other].bLiving && Grabs[Other].Pawn == Grabs[Hand].Pawn)
        Held = FMax(Held, WorldInfo.TimeSeconds - Grabs[Other].StartTime);
    if (Held >= class'VRSM_HeldKnockdown'.default.EscapeFull * Scale)
    {
        ClearGrab(Hand, "escaped");
        Pulse(Hand, 0.8, 0.06);
        return true;
    }
    // One hand frees: the later of two hands on the same Zed lets go.
    if (Held >= class'VRSM_HeldKnockdown'.default.EscapeOneHand * Scale
        && Grabs[Other].bActive && Grabs[Other].Pawn == Grabs[Hand].Pawn
        && Grabs[Hand].StartTime >= Grabs[Other].StartTime && Hand != Other)
    {
        if (Grabs[Hand].StartTime == Grabs[Other].StartTime && Hand == 0) return false;
        ClearGrab(Hand, "escaped_hand");
        Pulse(Hand, 0.6, 0.05);
        return true;
    }
    return false;
}

static function bool IsArmBone(name Bone)
{
    local string S;
    S = Locs(string(Bone));
    return InStr(S, "arm") >= 0 || InStr(S, "hand") >= 0 || InStr(S, "wrist") >= 0;
}

// A standing hold seen on a machine that never installed VRSM_StandingHold
// runs the stock stun, whose dazed effect would hover over a choked Zed.
// The replicated hold flag identifies it; switch that effect off.
simulated function HideHoldDazes()
{
    if (WorldInfo.NetMode == NM_DedicatedServer || WorldInfo.RealTimeSeconds < NextDazeCheck) return;
    NextDazeCheck = WorldInfo.RealTimeSeconds + 0.2;
    class'VRSM_StandingHold'.static.PrepareViewer(WorldInfo);
}

// Melee item 10, experimental standing holds (VRSM_StandingHold).
simulated function bool StandingWanted(KFPawn_Monster M)
{
    return class'VRExperimentalPolicy'.static.StandingHoldsEnabled()
        && Bridge.ExperimentalInteractionsEnabled() && Bridge.bExperimentalStandingHolds && M != None && !M.IsLargeZed()
        && class'VRSM_StandingHold'.static.Install(M) && class'VRSM_StandingHold'.static.CanStart(M);
}

simulated function bool BeginStanding(int Hand, KFPawn_Monster M, name Bone)
{
    Grabs[Hand].bStanding = true;
    Grabs[Hand].StartTime = WorldInfo.TimeSeconds;
    if (!IsNetworkClient())
        return class'VRSM_StandingHold'.static.Begin(M, Bridge.Human, Bone, Hand, PalmPoint(Hand));
    if (!Bridge.RequestNetworkGrabHold(M, Bone, Hand, PalmPoint(Hand), HandRotation(Hand), true)) return false;
    Grabs[Hand].bServerHeld = true;
    return true;
}

// The authority steers the Zed toward this palm; a network client streams it.
// The hold ends when the Zed dies, is knocked down, breaks free or the hold
// move ends for any other reason.
simulated function UpdateStanding(int Hand)
{
    local KFPawn_Monster M;
    local VRSM_StandingHold Move;
    M = Grabs[Hand].Pawn;
    if (M == None || M.bDeleteMe || IsCorpse(M) || !ContextValid() || !HandValid(Hand))
    { ClearGrab(Hand, "standing_lost"); return; }
    if (Escaped(Hand)) return;
    // The pin waits for the hold to be running so the struggle pose is set.
    if (!ArmPinSets[Hand].bPinned && M.IsDoingSpecialMove(SM_Stunned) && M.Physics != PHYS_RigidBody) StartArmPin(Hand);
    if (ArmPinSets[Hand].bPinned && (M.Physics == PHYS_RigidBody || M.IsDoingSpecialMove(SM_Knockdown))) EndArmPin(Hand, false);
    UpdateArmPin(Hand);
    if (IsNetworkClient())
    {
        if (M.IsDoingSpecialMove(SM_Knockdown))
        {
            // The server converts its own half when it sees the fall.
            EndArmPin(Hand, false);
            Grabs[Hand].bStanding = false;
            Grabs[Hand].bPendingRagdoll = true;
            Grabs[Hand].bKnockdownSeen = true;
            Grabs[Hand].StartTime = WorldInfo.TimeSeconds;
            return;
        }
        // The server's move lands a round trip later.
        if (!M.IsDoingSpecialMove(SM_Stunned) && WorldInfo.TimeSeconds - Grabs[Hand].StartTime > 0.6)
        { ClearGrab(Hand, "standing_ended"); return; }
        return;
    }
    Move = class'VRSM_StandingHold'.static.Current(M);
    if (Move == None)
    {
        if (!FallToKnockdown(Hand, M)) ClearGrab(Hand, "standing_ended");
        return;
    }
    Move.SetTarget(Hand, PalmPoint(Hand));
}

// A lifted standing hold fell (VRSM_StandingHold.Fall): keep the hand and
// continue as the ordinary knockdown hold once the ragdoll exists.
simulated function bool FallToKnockdown(int Hand, KFPawn_Monster M)
{
    if (M == None || !M.IsDoingSpecialMove(SM_Knockdown) || class'VRSM_HeldKnockdown'.static.Current(M) == None) return false;
    EndArmPin(Hand, false);
    Grabs[Hand].bStanding = false;
    Grabs[Hand].bPendingRagdoll = true;
    Grabs[Hand].bKnockdownSeen = true;
    Grabs[Hand].StartTime = WorldInfo.TimeSeconds;
    `log("KF2VR_ZEDGRAB action=standing_fall hand=" $ Hand $ " pawn=" $ M.Class);
    return true;
}

simulated function bool StartArmPin(int Hand)
{
    local KFPawn_Monster M;
    local RB_BodyInstance Body;
    local name Bone, Parent;
    local string S;
    local int Guard;
    M = Grabs[Hand].Pawn;
    if (ArmPinSets[Hand].bPinned || Bridge.UseLegacyMelee(Bridge.bLegacyMeleeArmPin) || M == None || M.Mesh == None || M.Mesh.PhysicsAssetInstance == None
        || class'VRSM_StandingHold'.static.ArmSide(Grabs[Hand].BoneName) == 0) return false;
    // Never pin over the other hand's pin on the same Zed.
    if (ArmPinSets[1 - Hand].bPinned && Grabs[1 - Hand].Pawn == M) return false;
    Bone = M.GetRBBoneFromBoneName(Grabs[Hand].BoneName);
    Body = class'VRBodyHold'.static.BodyFor(M.Mesh, Bone);
    if (Body == None || !Body.IsValidBodyInstance()) return false;
    ArmPinSets[Hand].Bones.Length = 0;
    // The held part and its parents up to, not including, the shoulder.
    while (Bone != '' && Guard++ < 4)
    {
        S = Locs(string(Bone));
        if (InStr(S, "shoulder") >= 0 || InStr(S, "clav") >= 0 || InStr(S, "spine") >= 0 || InStr(S, "neck") >= 0) break;
        ArmPinSets[Hand].Bones.AddItem(Bone);
        Parent = M.GetRBBoneFromBoneName(M.Mesh.GetParentBone(Bone));
        if (Parent == Bone) break;
        Bone = Parent;
    }
    if (ArmPinSets[Hand].Bones.Length == 0) return false;
    if (M.PhysicsImpactBlendTimeToGo > 0) M.StopPhysicsBodyImpact();
    ArmPinSets[Hand].bSavedReactions = M.bCanPlayPhysicsHitReactions;
    M.bCanPlayPhysicsHitReactions = false;
    M.Mesh.PhysicsAssetInstance.SetNamedBodiesFixed(false, ArmPinSets[Hand].Bones, M.Mesh, false, true);
    if (M.Mesh.PhysicsWeight < 1.f) M.InitPartialKinematics();
    if (!class'VRBodyHold'.static.Capture(Body, PalmPoint(Hand), HandRotation(Hand), ArmPinOffset[Hand], ArmPinRelative[Hand]))
    {
        EndArmPin(Hand, true);
        return false;
    }
    class'VRBodyHold'.static.SeatInPalm(Hand, Grabs[Hand].BoneName, ArmPinOffset[Hand]);
    ArmPinStart[Hand] = Body.GetUnrealWorldTM();
    ArmPinTime[Hand] = WorldInfo.TimeSeconds;
    ArmPinBadSince[Hand] = 0;
    ArmPinSets[Hand].bPinned = true;
    ++ArmPins;
    return true;
}

simulated function UpdateArmPin(int Hand)
{
    local KFPawn_Monster M;
    local RB_BodyInstance Body;
    local matrix Target;
    local name Bone;
    M = Grabs[Hand].Pawn;
    if (!ArmPinSets[Hand].bPinned) return;
    Bone = M.GetRBBoneFromBoneName(Grabs[Hand].BoneName);
    Body = class'VRBodyHold'.static.BodyFor(M.Mesh, Bone);
    if (Body == None || !Body.IsValidBodyInstance()) { EndArmPin(Hand, true); return; }
    Target = class'VRBodyHold'.static.Blend(ArmPinStart[Hand],
        class'VRBodyHold'.static.TargetFor(PalmPoint(Hand), HandRotation(Hand), ArmPinOffset[Hand], ArmPinRelative[Hand]),
        (WorldInfo.TimeSeconds - ArmPinTime[Hand]) / FMax(class'VRBodyHold'.default.CatchTime, 0.01));
    // If the arm cannot reach (the Zed was carried off, an animation fights
    // the pin) let it go rather than stretch or flail.
    if (WorldInfo.TimeSeconds - ArmPinTime[Hand] > class'VRBodyHold'.default.CatchTime
        && class'VRBodyHold'.static.PositionError(Body, Target) > ArmPinMaxError)
    {
        if (ArmPinBadSince[Hand] == 0) ArmPinBadSince[Hand] = WorldInfo.TimeSeconds;
        else if (WorldInfo.TimeSeconds - ArmPinBadSince[Hand] > ArmPinMaxErrorTime)
        {
            ++ArmPinFailures;
            `log("KF2VR_ZEDGRAB action=arm_pin_released hand=" $ Hand $ " pawn=" $ M.Class);
            EndArmPin(Hand, true);
            return;
        }
    }
    else ArmPinBadSince[Hand] = 0;
    class'VRBodyHold'.static.Move(M.Mesh, Bone, Target);
}

// bRefix returns the arm to its animation; a Zed falling into the knockdown
// keeps its bodies free for the ragdoll.
simulated function EndArmPin(int Hand, bool bRefix)
{
    local KFPawn_Monster M;
    if (!ArmPinSets[Hand].bPinned && ArmPinSets[Hand].Bones.Length == 0) return;
    M = Grabs[Hand].Pawn;
    if (M != None && !M.bDeleteMe && M.Mesh != None && M.Mesh.PhysicsAssetInstance != None)
    {
        if (bRefix && M.Health > 0 && !M.bPlayedDeath && M.Physics != PHYS_RigidBody && ArmPinSets[Hand].Bones.Length > 0)
            M.Mesh.PhysicsAssetInstance.SetNamedBodiesFixed(true, ArmPinSets[Hand].Bones, M.Mesh, false, true);
        M.bCanPlayPhysicsHitReactions = ArmPinSets[Hand].bSavedReactions;
    }
    ArmPinSets[Hand].bPinned = false;
    ArmPinSets[Hand].Bones.Length = 0;
}

// A Scrake, Fleshpound or boss shrugs off a fresh grab at once: a shove-back
// pulse instead of a silent miss.
simulated function bool RefuseLarge(int Hand, vector Palm)
{
    local KFPawn_Monster M;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster', M, Palm, GrabRadius + 20)
    {
        if (M.bDeleteMe || IsCorpse(M) || M.Physics == PHYS_RigidBody || Bridge.Human.GetTeamNum() == M.GetTeamNum()) continue;
        if (!M.IsLargeZed() && !IsBossOrigin(M)) continue;
        Pulse(Hand, 0.8, 0.06);
        `log("KF2VR_ZEDGRAB action=refused hand=" $ Hand $ " pawn=" $ M.Class);
        return true;
    }
    return false;
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
    if (RendWaitUntil!=0)
    {
        if (Grabs[Hand].Pawn==None || Grabs[Hand].Pawn.Health<=0 || IsCorpse(Grabs[Hand].Pawn)) RendWaitUntil=0;
        else if (!RendAllowed())
        { ClearGrab(0,"rend_perk_changed"); ClearGrab(1,"rend_perk_changed"); return; }
        // A genuinely relaxed pair cancels the attempt and resumes the normal
        // hold. Hysteresis requires a new pull before another deadline starts.
        else if (Grabs[1-Hand].bAttached && Grabs[1-Hand].Pawn==Grabs[Hand].Pawn
            && VSize(MatrixGetOrigin(DesiredFrame(Hand))-MatrixGetOrigin(DesiredFrame(1-Hand)))
            <= Grabs[Hand].TwoPointSpan+RendStretch*0.5) RendWaitUntil=0;
        else if (WorldInfo.RealTimeSeconds>=RendWaitUntil)
        { ClearGrab(0,"rend_authority_timeout"); ClearGrab(1,"rend_authority_timeout"); return; }
    }
    Palm = PalmPoint(Hand);
    if (Grabs[Hand].bHavePalm && DeltaTime > 0 && DeltaTime <= 0.1)
    {
        Grabs[Hand].HandVelocity = Grabs[Hand].HandVelocity * 0.5 + ((Palm - Grabs[Hand].LastPalm) / DeltaTime) * 0.5;
        if (Thrower != None) Thrower.Add(Hand, (Palm - Grabs[Hand].LastPalm) / DeltaTime, WorldInfo.RealTimeSeconds);
    }
    else
    {
        Grabs[Hand].HandVelocity = vect(0,0,0);
        if (Thrower == None) Thrower = new(self) class'VRThrowRelease'; Thrower.Reset(Hand);
    }
    Grabs[Hand].LastPalm = Palm;
    Grabs[Hand].bHavePalm = true;
    SwingHum(Hand);

    Target = DesiredFrame(Hand);
    Want = MatrixGetOrigin(Target);
    Other = 1 - Hand;
    // Reject a tracking jump before it can be interpreted as a Rend pull.
    if (!FiniteVector(Want) || VSize(Want - Grabs[Hand].Placed) > MaximumImpactStep)
    {
        ClearGrab(Hand, "tracking_jump");
        return;
    }
    // A Breacher with Rend tears the Zed apart a hair past its span; everyone
    // else releases before the kinematic bodies stretch the ragdoll's joints.
    if (Grabs[Other].bAttached && Grabs[Other].Component == Grabs[Hand].Component
        && Grabs[Other].Body != Grabs[Hand].Body
        && VSize(Want - MatrixGetOrigin(DesiredFrame(Other))) > Grabs[Hand].TwoPointSpan + RendStretch
        && TryRend(Hand))
        return;
    if (Grabs[Other].bAttached && Grabs[Other].Component == Grabs[Hand].Component
        && class'VRBodyHold'.static.SamePiece(Grabs[Hand].Component, Grabs[Hand].BoneName, Grabs[Other].BoneName)
        && VSize(Want - MatrixGetOrigin(DesiredFrame(Other))) > Grabs[Hand].TwoPointSpan + class'VRBodyHold'.default.GripReach * 2)
    {
        ClearGrab(Hand, "two_point_stretch");
        return;
    }
    // A dead body has weight: it trails a fast swing instead of riding the
    // palm exactly, and the release continues at the speed it was moving.
    if (HoldSpeedLimit(Hand) > 0 && Grabs[Hand].bHavePalm)
    {
        Want = class'VRBodyHold'.static.Weigh(Grabs[Hand].Placed, Want, HeldMass(Hand), DeltaTime);
        Target = MakeRotationTranslationMatrix(Want, MatrixGetRotator(Target));
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
    // Damage and optional impact callbacks can terminate the rigid body while
    // leaving its pooled RB_BodyInstance object alive. Rebind next update; do
    // not move or sample the pre-impact body again in this frame.
    RefreshImpactHolds();
    if (!Holding(Hand)) return;
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
    HideHoldDazes();
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

// RB_BodyInstance objects are pooled; object existence alone is not a live
// PhysX actor. Check the current named body and component before native reads.
simulated function bool HeldBodyCurrent(int Hand)
{
    local RB_BodyInstance Current;
    if (Grabs[Hand].Component == None || Grabs[Hand].Body == None
        || Grabs[Hand].Body.OwnerComponent != Grabs[Hand].Component) return false;
    if (Grabs[Hand].Pawn != None && (Grabs[Hand].Pawn.bDeleteMe
        || Grabs[Hand].Pawn.Mesh != Grabs[Hand].Component)) return false;
    if (Grabs[Hand].bGib) Current = Grabs[Hand].Component.GetRootBodyInstance();
    else Current = class'VRBodyHold'.static.BodyFor(Grabs[Hand].Component, Grabs[Hand].BoneName);
    return Current == Grabs[Hand].Body && Current.IsValidBodyInstance();
}

// TakeDamage can destroy/rebuild either held pawn before UpdateHand runs
// again (death, gore, knockdown recovery). Preserve the grip, not its body.
simulated function RefreshImpactHolds()
{
    local int Hand;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (!Grabs[Hand].bActive || !Grabs[Hand].bAttached || Grabs[Hand].bStanding) continue;
        if (Grabs[Hand].Owner == None || Grabs[Hand].Owner.bDeleteMe)
            ClearGrab(Hand, "impact_destroyed");
        else if (!HeldBodyCurrent(Hand)
            || (Grabs[Hand].bLiving && IsCorpse(Grabs[Hand].Pawn)))
        {
            if (Grabs[Hand].Pawn != None) BeginRegrip(Hand);
            else ClearGrab(Hand, "impact_body_lost");
        }
    }
}

simulated function bool Holding(int Hand)
{
    return Grabs[Hand].bActive && Grabs[Hand].bAttached && !Grabs[Hand].bPendingRagdoll && !Grabs[Hand].bRegrip
        && Grabs[Hand].Owner != None && !Grabs[Hand].Owner.bDeleteMe
        && HeldBodyCurrent(Hand);
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
            if (HeadBody != None && HeadBody.IsValidBodyInstance()
                && class'VRBodyHold'.static.SamePiece(Grabs[Hand].Component, Grabs[Hand].BoneName,
                    Grabs[Hand].Pawn.GetRBBoneFromBoneName(Bone))) Head = MatrixGetOrigin(HeadBody.GetUnrealWorldTM());
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
    if (!ContextValid() || !Bridge.ZedGrabAllowed()
        || (!CanHit(Victim) && !class'VRCorpseContact'.static.Eligible(Victim)) || Amount <= 0) return;
    Info.BoneName = Zone;
    Victim.TakeDamage(int(Amount), Bridge.Human.Controller, HitLocation,
        Direction * 600, class'VRDT_ZedSlam', Info, Bridge.Human);
    if (IsNetworkClient() && !Victim.bPlayedDeath)
        Bridge.RequestNetworkGrabDamage(Victim, int(Amount), HitLocation, Direction * 600, Zone);
    RefreshImpactHolds();
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
    if (Speed < MinImpactSpeed || M == None || CoolingDown(M)) return;
    if (NearestZone(M, Surface, Zone, ZoneLocation) > ContactRadius * 2) return;
    Amount = ImpactDamage(Speed);
    if (CanHit(M) || class'VRCorpseContact'.static.Eligible(M))
        DealImpact(M, Amount, Surface, -Normal, Zone);
    class'VRBreacherCharge'.static.Report(Bridge,M,Grabs[Hand].BoneName,None,Surface,-Normal,Speed,Amount);
    StartCooldown(M);
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
    if (A == None || B == None || A == B || CoolingDown(A) || CoolingDown(B)) return;
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
    class'VRBreacherCharge'.static.Report(Bridge,A,Grabs[0].BoneName,B,LocB,Direction,Speed,Amount);
    class'VRBreacherCharge'.static.Report(Bridge,B,Grabs[1].BoneName,A,LocA,-Direction,Speed,Amount);
    StartCooldown(A);
    StartCooldown(B);
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
        if (!Holding(Hand) || !Grabs[Hand].bMotion) return;
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
        class'VRBreacherCharge'.static.Report(Bridge,Grabs[Hand].Owner,Grabs[Hand].BoneName,
            Victim,ZoneLocation,Direction,Speed,Amount);
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

simulated function RetireThrownPiece(int Hand)
{
    local int I;
    for (I = Thrown.Length - 1; I >= 0; --I)
        if (Thrown[I].Owner == Grabs[Hand].Owner
            && (Grabs[Hand].bGib || class'VRBodyHold'.static.SamePiece(
                Grabs[Hand].Component, Thrown[I].BoneName, Grabs[Hand].BoneName)))
            Thrown.Remove(I, 1);
}

simulated function AddThrown(int Hand, vector ReleaseVelocity)
{
    local VRThrownBody T;
    local RB_BodyInstance Body;
    RetireThrownPiece(Hand);
    T.Owner = Grabs[Hand].Owner;
    T.Pawn = Grabs[Hand].Pawn;
    T.Component = Grabs[Hand].Component;
    T.BoneName = Grabs[Hand].BoneName;
    T.bLiving = Grabs[Hand].bLiving;
    T.bGib = Grabs[Hand].bGib;
    T.Since = WorldInfo.TimeSeconds;
    // The first physics tick can already be the collision. Seed the incoming
    // motion at release instead of requiring one freely flying sample first.
    T.LastVelocity = ReleaseVelocity;
    T.LastSpeed = VSize(ReleaseVelocity);
    Body = Grabs[Hand].Body;
    if (Body == None || !Body.IsValidBodyInstance() || Body.OwnerComponent != T.Component) return;
    T.Body = Body;
    T.LastPoint = MatrixGetOrigin(Body.GetUnrealWorldTM());
    T.bHavePoint = true;
    if (Thrown.Length >= 8) Thrown.Remove(0, 1);
    Thrown.AddItem(T);
}

simulated function bool ThrownBodyCurrent(int I)
{
    local RB_BodyInstance Body;
    if (I < 0 || I >= Thrown.Length || Thrown[I].Owner == None || Thrown[I].Owner.bDeleteMe
        || Thrown[I].Component == None || (Thrown[I].Pawn != None
            && (Thrown[I].Pawn.bDeleteMe || Thrown[I].Pawn.Mesh != Thrown[I].Component))) return false;
    if (Thrown[I].bGib) Body = Thrown[I].Component.GetRootBodyInstance();
    else Body = class'VRBodyHold'.static.BodyFor(Thrown[I].Component, Thrown[I].BoneName);
    return Body != None && Body == Thrown[I].Body && Body.OwnerComponent == Thrown[I].Component
        && Body.IsValidBodyInstance();
}

simulated function bool ThrownPoint(int I, out vector Point, out vector PointVelocity)
{
    if (!ThrownBodyCurrent(I)) return false;
    PointVelocity = Thrown[I].Body.GetUnrealWorldVelocity();
    Point = MatrixGetOrigin(Thrown[I].Body.GetUnrealWorldTM());
    return FiniteVector(Point) && FiniteVector(PointVelocity);
}

// Sweep the released part against world geometry and blocking props. Pawns
// belong to the body-to-body path, and the source ragdoll cannot hit itself.
simulated function bool ThrownSurface(Actor Source, vector Start, vector End,
    out vector HitLocation, out vector HitNormal)
{
    local Actor A;
    local vector SurfacePoint, SurfaceNormal;
    local TraceHitInfo Info;
    local float Best, Distance;
    local bool Found;
    Best = 100000000;
    // BSP/world geometry is queried separately from dynamic props, matching
    // the held-body collision path.
    if (Trace(HitLocation, HitNormal, End, Start, false, vect(1,1,1) * BodyRadius) != None)
    {
        Best = VSizeSq(HitLocation - Start);
        Found = true;
    }
    foreach TraceActors(class'Actor', A, SurfacePoint, SurfaceNormal, End, Start,
        vect(1,1,1) * BodyRadius, Info)
    {
        if (A == None || A == Source || A == Bridge.Human || Pawn(A) != None
            || (!A.bWorldGeometry && !A.bBlockActors)) continue;
        Distance = VSizeSq(SurfacePoint - Start);
        if (Distance >= Best) continue;
        Best = Distance; HitLocation = SurfacePoint; HitNormal = SurfaceNormal; Found = true;
    }
    return Found;
}

// Until a thrown body comes to rest it hits every Zed it meets, and a living
// one thrown into a wall takes the wall. Once it settles it is just a body.
simulated function UpdateThrown()
{
    local int I;
    local vector Point, PointVelocity, RootVelocity, ZoneLocation, Direction, HitLocation, HitNormal, SourceLocation;
    local name Zone, SourceZone;
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
        // A removed/rebuilt part has no continuous trajectory. Never turn a
        // failed sample into a sweep toward world origin with old velocity.
        if (!ThrownPoint(I, Point, PointVelocity))
        { Thrown.Remove(I, 1); continue; }
        Root = Thrown[I].Component.GetRootBodyInstance();
        RootVelocity = PointVelocity;
        if (Root != None && Root.IsValidBodyInstance() && (Thrown[I].Pawn == None
            || class'VRBodyHold'.static.SamePiece(Thrown[I].Component, Thrown[I].BoneName, Thrown[I].Pawn.Mesh.GetBoneName(0))))
            RootVelocity = Root.GetUnrealWorldVelocity();
        Speed = FMax(VSize(PointVelocity), VSize(RootVelocity));
        if (Speed < RestSpeed)
        {
            Thrown[I].RestTime += WorldInfo.DeltaSeconds;
            if (Thrown[I].RestTime > RestTime) { Thrown.Remove(I, 1); continue; }
        }
        else Thrown[I].RestTime = 0;

        Victim = FindStruck(Point, PointVelocity, Thrown[I].Owner, None, Zone, ZoneLocation, Direction, ImpactSpeed);
        if (Victim == None && Thrown[I].Pawn != None && Root != None && Root.IsValidBodyInstance()
            && class'VRBodyHold'.static.SamePiece(Thrown[I].Component, Thrown[I].BoneName, Thrown[I].Pawn.Mesh.GetBoneName(0)))
            Victim = FindStruck(MatrixGetOrigin(Root.GetUnrealWorldTM()), RootVelocity, Thrown[I].Owner, None,
                Zone, ZoneLocation, Direction, ImpactSpeed);
        if (Victim != None)
        {
            Amount = ImpactDamage(ImpactSpeed);
            if (Thrown[I].bGib) Amount *= GibDamageScale;
            DealImpact(Victim, Amount, ZoneLocation, Direction, Zone);
            if (Thrown[I].bLiving && CanHit(Thrown[I].Pawn) && !CoolingDown(Thrown[I].Pawn))
            {
                NearestZone(Thrown[I].Pawn, Point, SourceZone, SourceLocation);
                DealImpact(Thrown[I].Pawn, Amount * HeldSelfDamageScale, SourceLocation, -Direction, SourceZone);
            }
            class'VRBreacherCharge'.static.Report(Bridge,Thrown[I].Owner,Thrown[I].BoneName,
                Victim,ZoneLocation,Direction,ImpactSpeed,Amount);
            ++ThrownHits;
            `log("KF2VR_ZEDGRAB action=thrown_hit thrown=" $ Thrown[I].Owner.Class $ " living=" $ Thrown[I].bLiving
                $ " victim=" $ Victim.Class $ " speed=" $ int(ImpactSpeed) $ " damage=" $ int(Amount));
        }
        // Self-damage above can rebuild this source's ragdoll or remove the
        // released limb in the same iteration, before the wall sweep.
        if (!ThrownBodyCurrent(I)) { Thrown.Remove(I, 1); continue; }
        // Carry the incoming part's swept contact across release. Waiting for
        // a 50% whole-ragdoll speed drop missed glancing/head impacts, props,
        // and collisions on the first tick after letting go.
        if (Thrown[I].Pawn!=None && !CoolingDown(Thrown[I].Pawn)
            && Thrown[I].bHavePoint && Thrown[I].LastSpeed >= MinImpactSpeed
            && ThrownSurface(Thrown[I].Owner, Thrown[I].LastPoint,
                Point + Normal(Thrown[I].LastVelocity) * BodyRadius, HitLocation, HitNormal)
            && (Thrown[I].LastVelocity dot -HitNormal) >= MinImpactSpeed
            && NearestZone(Thrown[I].Pawn, HitLocation, Zone, ZoneLocation) <= ContactRadius * 2)
        {
            ImpactSpeed = Thrown[I].LastVelocity dot -HitNormal;
            Amount = ImpactDamage(ImpactSpeed);
            if (CanHit(Thrown[I].Pawn) || class'VRCorpseContact'.static.Eligible(Thrown[I].Pawn))
                DealImpact(Thrown[I].Pawn, Amount, HitLocation, -HitNormal, Zone);
            class'VRBreacherCharge'.static.Report(Bridge,Thrown[I].Owner,Thrown[I].BoneName,
                None,HitLocation,-HitNormal,Thrown[I].LastSpeed,Amount);
            StartCooldown(Thrown[I].Pawn);
            ++WorldSmashes;
            `log("KF2VR_ZEDGRAB action=thrown_world_hit pawn=" $ Thrown[I].Pawn.Class $ " zone=" $ Zone
                $ " speed=" $ int(Thrown[I].LastSpeed) $ " damage=" $ int(Amount));
        }
        Thrown[I].LastSpeed = Speed;
        Thrown[I].LastVelocity = PointVelocity;
        Thrown[I].LastPoint = Point;
        Thrown[I].bHavePoint = true;
    }
}

defaultproperties
{
    RendStretch=5.0       // uu past the captured two-hand span, about 10 cm
    RendSkillIndex=4      // BreacherPerk.EBreacherRend
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    TickGroup=TG_PreAsyncWork

    GrabRadius=26.0
    GrabNearMissAllowance=2.0 // modest 9% contact margin; keep body-selection and release limits
    PalmForward=4.0
    SearchRadius=220.0
    // Per phase, not for the whole request: the knockdown round trip and the
    // ragdoll transition each get this long. See UpdateHand.
    RagdollTimeout=1.50
    // The least velocity KFSM_RagdollKnockdown accepts without a warning.
    KnockdownNudge=2.0
    ArmPinMaxError=22
    ArmPinMaxErrorTime=0.3
    BodyRadius=8.0
    BlockedDrop=90.0
    BlockedGrace=0.4
    ThrowScale=0.65
    MinThrowSpeed=160.0
    MaxThrowSpeed=600.0
    // Dead bodies carry weight; preserve living swing-to-release impacts.
    CorpseThrowScale=1.0
    MaxCorpseThrowSpeed=600.0
    // 65 kg Clot ~0.30, 130 kg Scrake ~0.19, 200 kg Fleshpound ~0.14,
    // a 5 kg forearm ~0.60 of hand speed.
    GibMass=3.0
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
