// Experimental standing Zed holds (melee roadmap item 10), the Blade &
// Sorcery way: a grabbed NPC stays on its feet, struggling, and is steered by
// the hand that holds it (Interactable_Human* moveStep, stepSpeedMultiplier 3
// for neck and torso, 1 for the wrist, none for the legs) and turned to face
// the grabber (bodyTurnDirection PartDirection / GrabberPosition). While held
// it cannot attack; it breaks free on the BrainModuleGrabbed timers
// (VRSM_HeldKnockdown.EscapeFull, scaled by class).
//
// Installed per pawn in the stock SM_Stunned slot, like VRSM_HeldKnockdown.
// A stock stun on an installed pawn (special move flags 0) behaves exactly
// as KFSM_Stunned. A hold starts with flags HOLD_FLAG, which replicate with
// the move, so every machine that has the class installed plays the struggle
// without the dazed effect. The authority owns steering, facing and the
// escape timer; pawn movement replicates as usual. Off unless
// VRHandsBridge.bExperimentalStandingHolds; the fallback is the knockdown hold.
class VRSM_StandingHold extends KFSM_Stunned;

const HOLD_FLAG = 2;
const REGION_NECK = 1;
const REGION_SKULL = 2;
const REGION_SHOULDER = 3;
const REGION_LIMB = 4;
const REGION_LEGS = 5;

var bool bHoldMode;
var Pawn Grabber;
var name HeldBone;
var byte Region;
var vector Target[2];
var float StartZ[2];
var byte bHeld[2];
// Each holding hand's own bone and region: the body's behaviour combines
// them (any leg anchors it, any neck or torso turns it to face the grabber,
// the fastest step multiplier wins) and a lift falls by the lifted hand's part.
var name HandBone[2];
var byte HandRegion[2];
// B&S liftBehaviour: lifting a held neck or leg makes the NPC fall
// (Interactable_HumanHeadNeck / HumanLegs "Fall"); the hold then continues
// as the knockdown hold. Lifting a wrist or torso does nothing here.
var float LiftHeight;
var bool bFreeHandAttacks;
var int SwipeCount;
var float NextSwipe, SwipeHitTime, SwipeInterval, SwipeHitFraction, SwipeReach;
var bool bFell;
var float HoldStarted;
// Base follow speed in uu/s before the B&S step multiplier, and the slack
// left between the held part and the hand before the body steps.
var float StepSpeed, FollowSlack, TurnRate, MaxStepPerTick;

// Staged by Begin on the authority for the SpecialMoveStarted it triggers.
var Pawn StagedGrabber;
var name StagedBone;
var byte StagedRegion, StagedHand;
var vector StagedPalm;

static function byte RegionFor(name Bone)
{
    local string S;
    S = Locs(string(Bone));
    if (InStr(S, "neck") >= 0 || InStr(S, "head") >= 0 || InStr(S, "jaw") >= 0) return REGION_NECK;
    if (InStr(S, "thigh") >= 0 || InStr(S, "calf") >= 0 || InStr(S, "leg") >= 0 || InStr(S, "foot") >= 0
        || InStr(S, "knee") >= 0 || InStr(S, "toe") >= 0) return REGION_LEGS;
    if (InStr(S, "forearm") >= 0 || InStr(S, "hand") >= 0 || InStr(S, "wrist") >= 0) return REGION_LIMB;
    return REGION_SHOULDER;
}

static function bool Install(KFPawn_Monster M)
{
    if (M == None || M.bDeleteMe || M.SpecialMoveHandler == None) return false;
    if (M.SpecialMoveHandler.SpecialMoveClasses.Length <= SM_Stunned) return false;
    if (M.SpecialMoveHandler.SpecialMoveClasses[SM_Stunned] == class'VRSM_StandingHold') return true;
    if (M.IsDoingSpecialMove(SM_Stunned)) return false;
    M.SpecialMoveHandler.SpecialMoveClasses[SM_Stunned] = class'VRSM_StandingHold';
    if (M.SpecialMoves.Length > SM_Stunned) M.SpecialMoves[SM_Stunned] = None;
    return true;
}

static function VRSM_StandingHold Current(KFPawn_Monster M)
{
    local VRSM_StandingHold Move;
    if (M == None || M.bDeleteMe || !M.IsDoingSpecialMove(SM_Stunned) || M.SpecialMoves.Length <= SM_Stunned) return None;
    Move = VRSM_StandingHold(M.SpecialMoves[SM_Stunned]);
    return (Move != None && Move.bHoldMode) ? Move : None;
}

// A standing hold only begins on a living, upright, ordinary Zed that is free
// to start a stun now (the stock rules also refuse mid-grapple and the like).
static function bool CanStart(KFPawn_Monster M)
{
    return M != None && !M.bDeleteMe && M.Health > 0 && !M.bPlayedDeath && M.Physics != PHYS_RigidBody
        && !M.IsHeadless() && M.CanDoSpecialMove(SM_Stunned, true);
}

// Authority only. Starts the hold, or adds this hand to a running one.
static function bool Begin(KFPawn_Monster M, Pawn InGrabber, name Bone, byte Hand, vector Palm)
{
    local VRSM_StandingHold Move;
    if (!class'VRExperimentalPolicy'.static.StandingHoldsEnabled()
        || M == None || M.Role != ROLE_Authority || InGrabber == None || Hand > 1) return false;
    Move = Current(M);
    if (Move != None)
    {
        if (Move.Grabber != InGrabber) return false;
        Move.AddHold(Hand, Palm, Bone);
        return true;
    }
    if (!Install(M) || !CanStart(M)) return false;
    // CanDoSpecialMove has verified/created this pawn's move instance.
    // Transient staged data belongs there, not in shared class defaults.
    Move = VRSM_StandingHold(M.SpecialMoves[SM_Stunned]);
    if (Move == None) return false;
    Move.StagedGrabber = InGrabber;
    Move.StagedBone = Bone;
    Move.StagedRegion = RegionFor(Bone);
    Move.StagedHand = Hand;
    Move.StagedPalm = Palm;
    M.DoSpecialMove(SM_Stunned, true, None, HOLD_FLAG);
    Move.StagedGrabber = None;
    return Current(M) != None;
}

// B&S BrainModuleGrabbed freeOneHand: after 2 s (scaled by class) a held
// NPC fights back with its free hand while still held. Here the Zed plays one
// of its own upper-body melee attacks every SwipeInterval and, on the swing,
// deals its stock melee damage to the grabber if still within reach. The
// swing count rides in the replicated special move flags above HOLD_FLAG, so
// every installed machine plays the same animation.
// Every viewing machine (VR clients through VRZedGrab, desktop clients
// through KF2VRNetRemoteBody) installs the class ahead of any hold, so a hold
// shows the struggle and free-hand swings instead of the stock stun's dazed
// effect and wake-ups. A stun with no hold stays stock (flags 0 or 1). A Zed
// already stunned when first seen keeps its effect off by the hold flag.
static function PrepareViewer(WorldInfo WI)
{
    local KFPawn_Monster M;
    local KFSM_Stunned Stun;
    if (WI == None || WI.NetMode == NM_DedicatedServer) return;
    foreach WI.AllPawns(class'KFPawn_Monster', M)
    {
        if (!M.IsDoingSpecialMove(SM_Stunned)) { Install(M); continue; }
        if (!IsHoldFlags(M.SpecialMoveFlags) || M.SpecialMoves.Length <= SM_Stunned) continue;
        Stun = KFSM_Stunned(M.SpecialMoves[SM_Stunned]);
        if (Stun != None && VRSM_StandingHold(Stun) == None && Stun.DazedPSC != None && Stun.DazedPSC.bIsActive)
            Stun.DazedPSC.DeactivateSystem();
    }
}

static function bool IsHoldFlags(int Flags)
{
    return (Flags & HOLD_FLAG) != 0 && Flags != 1;
}

// Which of the Zed's arms a held bone pins: 1 left, 2 right, 0 neither.
static function byte ArmSide(name Bone)
{
    local string S;
    S = Locs(string(Bone));
    if (InStr(S, "arm") < 0 && InStr(S, "hand") < 0 && InStr(S, "wrist") < 0 && InStr(S, "shoulder") < 0) return 0;
    if (InStr(S, "left") >= 0 || Left(S, 2) == "l_" || Left(S, 2) == "lf") return 1;
    if (InStr(S, "right") >= 0 || Left(S, 2) == "r_" || Left(S, 2) == "rt") return 2;
    return 0;
}

// Which arm an attack animation swings, from its name: 1 left, 2 right, 0 unknown.
static function byte AnimSide(name Anim)
{
    local string S;
    S = Locs(string(Anim));
    if (InStr(S, "left") >= 0 || InStr(S, "_l_") >= 0 || Right(S, 2) == "_l") return 1;
    if (InStr(S, "right") >= 0 || InStr(S, "_r_") >= 0 || Right(S, 2) == "_r") return 2;
    return 0;
}

// The arms the grabber's hands pin (bit 1 left, bit 2 right).
function byte PinnedArms()
{
    local byte Mask;
    local int H;
    for (H = 0; H < 2; ++H)
        if (bHeld[H] != 0) Mask = Mask | ArmSide(HandBone[H]);
    return Mask;
}

// Upper-body attack animations, in PawnAnimInfo order.
function name AttackAnim(int Index)
{
    local KFPawnAnimInfo Info;
    local int I, Seen;
    Info = KFPOwner.PawnAnimInfo;
    if (Info == None || Index < 0) return '';
    for (I = 0; I < Info.Attacks.Length; ++I)
    {
        if (!Info.Attacks[I].bPlayUpperBodyOnly || Info.Attacks[I].Anims.Length == 0) continue;
        if (Seen++ == Index) return Info.Attacks[I].Anims[0];
    }
    return '';
}

// B&S frees the NPC's unheld hand: with one arm pinned, prefer an attack
// tagged to the free arm, else any attack not tagged to the pinned one. Both
// arms pinned: no swing.
function int ChooseSwipe()
{
    local byte Pinned, Side;
    local int I, Count, Pick, Fallback;
    local name Anim;
    Pinned = PinnedArms();
    if (Pinned == 3) return -1;
    Pick = -1; Fallback = -1;
    for (I = 0; I < 31; ++I)
    {
        Anim = AttackAnim(I);
        if (Anim == '') break;
        Side = AnimSide(Anim);
        if (Side != 0 && (Pinned & Side) != 0) continue;
        if (Pinned != 0 && Side == 0)
        {
            if (Fallback < 0 || (SwipeCount & 1) != 0) Fallback = I;
            continue;
        }
        if (Count++ == SwipeCount % 8 || Pick < 0) Pick = I;
    }
    return Pick >= 0 ? Pick : Fallback;
}

function float PlaySwipe(int Index)
{
    local name Anim;
    Anim = AttackAnim(Index);
    if (Anim == '') return 0;
    return KFPOwner.PlayBodyAnim(Anim, EAS_UpperBody, 1.f, 0.1f, 0.25f, false);
}

function StartSwipe(float Now)
{
    local int Flags, Index;
    local float Duration;
    Index = ChooseSwipe();
    if (Index < 0) { NextSwipe = Now + SwipeInterval; return; }
    ++SwipeCount;
    // Bits 2-6 carry the animation index; bit 7 toggles so a repeat replicates.
    Flags = HOLD_FLAG | ((Index & 31) << 2) | ((SwipeCount & 1) << 7);
    KFPOwner.SpecialMoveFlags = Flags;
    KFPOwner.ReplicatedSpecialMove.Flags = Flags;
    KFPOwner.bForceNetUpdate = true;
    Duration = PlaySwipe(Index);
    if (Duration <= 0) { NextSwipe = Now + 1000; return; }
    SwipeHitTime = Now + Duration * SwipeHitFraction;
    NextSwipe = Now + FMax(Duration, SwipeInterval);
}

function StrikeGrabber()
{
    local KFPawn_Monster M;
    M = KFPawn_Monster(KFPOwner);
    if (M == None || M.MeleeAttackHelper == None || Grabber == None || Grabber.bDeleteMe || Grabber.Health <= 0
        || VSize(Grabber.Location - M.Location) > SwipeReach) return;
    Grabber.TakeDamage(int(M.MeleeAttackHelper.BaseDamage), M.Controller, Grabber.Location,
        Normal(Grabber.Location - M.Location) * M.MeleeAttackHelper.MomentumTransfer * 0.5,
        M.MeleeAttackHelper.MyDamageType,, M);
}

function SpecialMoveFlagsUpdated()
{
    if (!bHoldMode)
    {
        Super.SpecialMoveFlagsUpdated();
        return;
    }
    if (KFPOwner.Role < ROLE_Authority && KFPOwner.SpecialMoveFlags != HOLD_FLAG)
        PlaySwipe((KFPOwner.SpecialMoveFlags >> 2) & 31);
}

function SpecialMoveStarted(bool bForced, Name PrevMove)
{
    if (!IsHoldFlags(KFPOwner.SpecialMoveFlags))
    {
        bHoldMode = false;
        Super.SpecialMoveStarted(bForced, PrevMove);
        return;
    }
    // Base special move setup only: the AI is locked by the stun's AI
    // command, but no stun timer, wake-up or dazed effect.
    Super(KFSpecialMove).SpecialMoveStarted(bForced, PrevMove);
    // The hold turns the Zed toward the grabber; the stun locks rotation.
    SetLockPawnRotation(false);
    bHoldMode = true;
    bHeld[0] = 0; bHeld[1] = 0;
    KFPOwner.Velocity.X = 0;
    KFPOwner.Velocity.Y = 0;
    KFPOwner.Acceleration = vect(0,0,0);
    PlaySpecialMoveAnim(StunnedAnim, EAS_FullBody, 0.2f, 0.3f, 1.f, true);
    if (KFPOwner.Role == ROLE_Authority)
    {
        Grabber = StagedGrabber;
        HeldBone = StagedBone;
        Region = StagedRegion;
        HoldStarted = KFPOwner.WorldInfo.TimeSeconds;
        SwipeCount = 0; SwipeHitTime = 0;
        NextSwipe = HoldStarted + class'VRSM_HeldKnockdown'.default.EscapeOneHand
            * class'VRSM_HeldKnockdown'.static.EscapeScale(KFPawn_Monster(KFPOwner));
        if (Grabber != None) AddHold(StagedHand, StagedPalm, StagedBone);
    }
}

function AddHold(byte Hand, vector Palm, optional name Bone)
{
    if (Hand > 1) return;
    bHeld[Hand] = 1;
    HandBone[Hand] = Bone != '' ? Bone : HeldBone;
    HandRegion[Hand] = RegionFor(HandBone[Hand]);
    Target[Hand] = Palm;
    StartZ[Hand] = Palm.Z;
}

function SetTarget(byte Hand, vector Palm)
{
    if (Hand <= 1 && bHeld[Hand] != 0) Target[Hand] = Palm;
}

function ReleaseHold(byte Hand)
{
    if (Hand > 1 || bHeld[Hand] == 0) return;
    bHeld[Hand] = 0;
    if (bHeld[1 - Hand] == 0) EndHold();
}

function EndHold()
{
    if (!bHoldMode || KFPOwner == None || KFPOwner.Role != ROLE_Authority) return;
    bHoldMode = false;
    if (KFPOwner.IsDoingSpecialMove(SM_Stunned)) KFPOwner.EndSpecialMove();
}

// The held Zed drops into the stock knockdown, with the hold gate installed so
// the hands that held it standing keep it down (VRZedGrab and the server
// controller convert their standing grabs when they see the knockdown).
function Fall()
{
    local KFPawn_Monster M;
    M = KFPawn_Monster(KFPOwner);
    if (M == None || M.Role != ROLE_Authority) return;
    bFell = true;
    EndHold();
    if (class'VRSM_HeldKnockdown'.static.Install(M) && class'VRSM_HeldKnockdown'.static.CanStart(M))
        M.Knockdown(vect(0,0,-1) * class'VRZedGrab'.default.KnockdownNudge, vect(0,0,0));
}

function Tick(float DeltaTime)
{
    local vector Palm, Delta;
    local rotator Facing;
    local float Distance, Speed, StepScale;
    local int Count, H, Parts;
    local bool bAnchored, bFace;
    Super.Tick(DeltaTime);
    if (!class'VRExperimentalPolicy'.static.StandingHoldsEnabled()) { EndHold(); return; }
    if (!bHoldMode || KFPOwner == None || KFPOwner.Role != ROLE_Authority || DeltaTime <= 0) return;
    if (Grabber == None || Grabber.bDeleteMe || Grabber.Health <= 0 || KFPOwner.Health <= 0
        || KFPOwner.Physics == PHYS_RigidBody) { EndHold(); return; }
    if (class'VRSM_HeldKnockdown'.static.EscapeEnabled()
        && KFPOwner.WorldInfo.TimeSeconds - HoldStarted >= class'VRSM_HeldKnockdown'.default.EscapeFull
            * class'VRSM_HeldKnockdown'.static.EscapeScale(KFPawn_Monster(KFPOwner)))
    { EndHold(); return; }
    if (bFreeHandAttacks && KFPOwner.WorldInfo.TimeSeconds >= NextSwipe) StartSwipe(KFPOwner.WorldInfo.TimeSeconds);
    if (SwipeHitTime > 0 && KFPOwner.WorldInfo.TimeSeconds >= SwipeHitTime) { SwipeHitTime = 0; StrikeGrabber(); }
    if (bHeld[0] != 0) { Palm += Target[0]; ++Count; }
    if (bHeld[1] != 0) { Palm += Target[1]; ++Count; }
    if (Count == 0) { EndHold(); return; }
    Palm /= Count;
    for (H = 0; H < 2; ++H)
    {
        if (bHeld[H] == 0) continue;
        if ((HandRegion[H] == REGION_NECK || HandRegion[H] == REGION_LEGS) && Target[H].Z - StartZ[H] > LiftHeight)
        {
            Fall();
            return;
        }
        if (HandRegion[H] == REGION_LEGS) bAnchored = true;
        if (HandRegion[H] == REGION_NECK || HandRegion[H] == REGION_SHOULDER) { bFace = true; StepScale = 3.0; }
        else if (StepScale < 1.0) StepScale = 1.0;
        if (HandBone[H] != '') { Delta += Target[H] - KFPOwner.Mesh.GetBoneLocation(HandBone[H]); ++Parts; }
    }
    // Step the body so the held parts follow the hands on the ground plane.
    if (!bAnchored && Parts > 0)
    {
        Delta /= Parts;
        Delta.Z = 0;
        Distance = VSize(Delta) - FollowSlack;
        if (Distance > 0)
        {
            Speed = StepSpeed * StepScale;
            KFPOwner.Move(Normal(Delta) * FMin(Distance, FMin(Speed * DeltaTime, MaxStepPerTick)));
        }
    }
    // Neck and torso holds turn the Zed to face the grabber.
    if (bFace)
    {
        Facing = KFPOwner.Rotation;
        Facing.Yaw = RInterpTo(KFPOwner.Rotation, rotator(Grabber.Location - KFPOwner.Location), DeltaTime, TurnRate).Yaw;
        KFPOwner.SetRotation(Facing);
    }
}

function SpecialMoveEnded(Name PrevMove, Name NextMove)
{
    bHoldMode = false;
    bHeld[0] = 0; bHeld[1] = 0;
    Grabber = None;
    Super.SpecialMoveEnded(PrevMove, NextMove);
}

defaultproperties
{
    StepSpeed=90
    FollowSlack=6
    TurnRate=6
    MaxStepPerTick=12
    LiftHeight=10
    bFreeHandAttacks=true
    SwipeInterval=1.6
    SwipeHitFraction=0.45
    SwipeReach=170
}
