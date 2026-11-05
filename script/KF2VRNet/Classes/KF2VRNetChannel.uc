// Only this server-created, controller-owned actor accepts pose/held RPCs.
class KF2VRNetChannel extends Actor dependsOn(KF2VRNetTypes, KF2VRNetHeldInventory, KF2VRNetVampireReload, KF2VRNetPairedReload, VRWeaponDropState)
    implements(VRTrackedPawnSource, VRWorldDropRecipient);

var int WorldEpoch;
var int ConnectionEpoch;
var int PawnEpoch;
var int CalibrationEpoch;
struct MechanismPolicy
{
    var class<KFWeapon> WeaponClass;
    var array<name> Bones;
};
var private MechanismPolicy MechanismPolicies[2];
var bool bSyntheticAllowed;
var bool bMotionReplayAllowed, bMotionReplayEnabled;
var bool bMotionResetPassed, bMotionResetFailed;
var int MotionResetId;
var private bool bMotionResetPending;
var private bool bMotionResetPlaced, bMotionResetRotated;
var private KFPawn_Human MotionResetPawn;
var private float MotionResetDeadline;
var private string MotionResetReason;
var private int MotionReplayId, LastMotionEdge;
var private vector MotionSavedRoot, MotionSavedVelocity;
// Recorded-world admission is independent of the session spawn restored at end.
var private vector MotionReplayRoot;
var private bool bHaveMotionReplayRoot;
var private rotator MotionSavedRotation;
var private EPhysics MotionSavedPhysics;
var private bool bMotionSavedCrouch;
var private float MotionSavedEyeHeight;
var bool bDiagnosticAutoReady;
var bool bDiagnosticPerkReady, bDiagnosticClientsReady;
var bool bHandshakeAccepted;
var bool bHandshakeRejected;
var bool bSyntheticEnabled;
var bool bVRTrackingEnabled;
var bool bMultiplayerZedGrabAllowed;
var bool bGrabOptIn;
var int GrabPolicyEpoch;
var private int GrabIntentPawnEpoch;
var private float GrabOptInLease;
var private float NextGrabIntent;
var private bool bLastGrabIntent, bLastZedGrabIntent;
var bool bInteractionOptIn;
var private bool bLastInteractionIntent;
var private int InteractionIntentPawnEpoch;
var private float InteractionOptInLease;
var int AcceptedPoses;
var int RejectedPoses;
var int LastAcceptedSequence;

var private KFPawn_Human BoundPawn;
var private KF2VRNetPose PublicPose;
var private int NextPawnEpoch;
var private bool bHaveSequence;
var private float LastAcceptedRealTime;
var private float LastModeChangeRealTime;
var private float RateWindowStart;
var private int RateWindowCount;
var private float NextAuthorityStatusRealTime;
var private float NextRejectionLogTime;
var private bool bInventoryFocusRequested;
var private float InventoryFocusLeaseUntil;
var private float InventoryFocusRateStart;
var private int InventoryFocusRateCount;
var private bool bLocalInventoryFocusOpen;
var private float NextInventoryFocusRefresh;
var private int LocalFocusWorldEpoch, LocalFocusConnectionEpoch, LocalFocusPawnEpoch;
// One server ledger per VR pawn lifetime. The native adapter isolates stock
// pending fire; clients predict hand selection and keep stock weapon RPCs.
var private KF2VRNetHeldInventory HeldInventory;
var private bool bHeldLedgerChecked;
var int NativeAuthorityReady;
var int NativeCarryVersion, PredictedCarryMask;
var int PredictedShieldHandToken;
var int NativeWorldDropVersion;
var int NativePouchAmmoVersion;
var KF2VRNetWorldDropChannel WorldDrops;
var KF2VRNetMagazineChannel MagazineActions;
var KF2VRNetPouchAmmo PouchAmmo;
var KF2VRNetReloadCase ReloadCase;
var private bool bReplacementPrepared, bReplacementDropped;
var private KFWeapon ReplacementOldWeapon, ReplacementNewWeapon;
var private name ReplacementOldName;
var private int ReplacementHand, ReplacementRole, ReplacementTransaction, ReplacementMarker;
var private KFPawn_Human ReplacementPawn;
var private float ReplacementPreparedAt;
var private VRWeaponDropState.HandlingState ReplacementHandling;
var private float ReplacementFireReadyAt;
var private int LocalReplacementTransaction, LocalReplacementSerial;
var private int LocalReplacementWorld, LocalReplacementConnection, LocalReplacementPawnEpoch;
var private KFWeapon LocalReplacementOld, LocalReplacementNew;
var private name LocalReplacementOldName;
var private VRWeaponDropState.HandlingState LocalReplacementHandling;
var private float LocalReplacementFireReadyAt, LocalReplacementStartedAt, LocalCycleStartedAt;
// Client give-up for an owner request whose authority answer never arrives.
const OwnerReplyDeadline = 8.0;
var private bool bLocalReplacementDropped, bLocalReplacementHandlingCaptured;
var private VRHeldInventory LocalReplacementLedger;
struct CycleEjectReceipt
{
    var KFPawn_Human Human;
    var KFWeapon Weapon;
    var int WorldEpoch, ConnectionEpoch, PawnEpoch, Serial, Ammo, Reserve;
    var byte Status;
    var bool bHaveAmmo;
};
var CycleEjectReceipt CycleReceipt;
var private int LastCycleSerial, LocalCycleSerial, ReconciledCycleSerial;
// The epochs the outstanding local cycle request was sent under.
var private int LocalCycleWorld, LocalCycleConnection, LocalCyclePawnEpoch;
var private KFPawn_Human LocalCyclePawn, PendingPairedPawn;
var private int PendingPairedBegin[2];
var private KFWeapon PendingCycleWeapon;
var private int PendingCycleSerial, PendingCycleHand, PendingCycleRevision, PendingCycleAmmo, PendingCycleCount;
var private int PendingCycleWorld, PendingCycleConnection, PendingCyclePawn;
var private float PendingCycleDeadline;
// Owner-ended physical reloads waiting for their weapon-channel marker.
var private KFWeapon PendingReloadEndWeapon[2];
var private KF2VRNetItemRuntime PendingReloadEndRuntime[2];
var private int PendingReloadEndSerial[2];
var private float PendingReloadEndDeadline[2];


var private bool bPendingFireChecked;
var NetHeldState HeldState;
var private KF2VRNetHeldNetworkProbe HeldProbe;
var private KFPawn_Human PredictedHeldPawn;
var private KFWeapon PredictedLeft, PredictedRight;
var private int LocalHeldRequest;
var private float HeldRateStart;
var private int HeldRateCount;
var private KF2VRNetDiagnosticClot DualTargetLeft, DualTargetRight;
var private array<VRWeaponPair> WeaponPairs;
var private float NextPairAttemptTime;
// A trader menu is populated from the client inventory, while pair restoration
// happens on authority. Hold conversion across that replication hand-off.
var private float TraderPairPreflightUntil;

// Count and release acknowledgement travel together. A client reserves one
// while its reliable request is outstanding, never mutating stock ammunition.
struct GrenadeAuthorityState
{
    var KFPawn_Human Human;
    var int AcknowledgedRequest, Count;
    var bool bAccepted;
};
var GrenadeAuthorityState GrenadeState;
var private KFPawn_Human LocalGrenadePawn;
var private int LocalGrenadeRequest, GrenadeRateCount;
var private int LocalGrenadeWorld, LocalGrenadeConnection, LocalGrenadePawnEpoch;
var private float GrenadeRateStart;

// One authority object survives terminal reloads during this pawn lifetime:
// its native fence also rejects late stock weapon-channel reload requests.
var KF2VRNetPairedReload PairedReloads[2];
// Realistic ammo, server side: rounds this player's removed magazines took,
// per weapon, the most a pickup may return to that weapon's reserve.
var array<KFWeapon> MagazineBudgetWeapons;
var array<int> MagazineBudgetRounds;
var KF2VRNetPairedReload.ReloadState PairedStates[2];
var private int LocalPairedReloadRequest;

var KF2VRNetVampireReload VampireReload;
var KF2VRNetVampireReload.ReloadState VampireState;
var private KFPawn_Human LocalVampirePawn;
var private KFPawn_Human LocalVampireManagedPawn;
var private int LocalVampireManagedWorld, LocalVampireManagedConnection, LocalVampireManagedEpoch;
var private int LocalVampireRequest;

// One release acknowledgment; stock ClientForceAmmoUpdate owns ammunition.
// Drawing/nocking remain local and reuse the ordinary physical reload path.
struct BowReleaseState
{
    var KFPawn_Human Human;
    var KFWeapon Weapon, AcknowledgedWeapon;
    var int WorldEpoch, ConnectionEpoch, PawnEpoch;
    var int NativeVersion, AcknowledgedRequest, PrimaryAmmo;
    var bool bAccepted, bReady;
};
var BowReleaseState BowState;
var VRCompoundBowAuthority BowAuthority;
var private int LocalBowRequest, LocalBowWorld, LocalBowConnection, LocalBowPawn;
var private float NextBowCapabilityCheck;
// The owner's inventory links last sent, so a native mid-chain insert is resent.
var private array<Inventory> LastChainLinks;

function UpdateBowReadiness()
{
    local bool bReady;
    bReady = BowAuthority != None && BowAuthority.Ready();
    if (bReady != BowState.bReady) bForceNetUpdate = true;
    BowState.bReady = bReady;
}

function UpdateBowAuthority()
{
    local KFWeapon W;
    if (BoundPawn == None || HeldInventory == None) return;
    if (BowAuthority != None && !BowAuthority.OwnsWeapon())
    {
        BowAuthority = None;
        BowState.Weapon = None; BowState.NativeVersion = 0;
        bForceNetUpdate = true;
    }
    if (BowAuthority == None)
    {
        W = HeldInventory.Snapshot.LeftWeapon;
        if (!class'VRCompoundBowAuthority'.static.Supports(W)) W = HeldInventory.Snapshot.RightWeapon;
        if (class'VRCompoundBowAuthority'.static.Supports(W) && HeldInventory.IsOwned(W))
        {
            BowAuthority = new(self) class'VRCompoundBowAuthority';
            BowAuthority.Human = BoundPawn;
            BowAuthority.Controller = KFPlayerController(Owner);
            BowAuthority.Gun = KFWeap_Bow_CompoundBow(W);
            NextBowCapabilityCheck = 0;
        }
    }
    if (BowAuthority != None && BowState.NativeVersion != 1
        && WorldInfo.RealTimeSeconds >= NextBowCapabilityCheck)
    {
        NextBowCapabilityCheck = WorldInfo.RealTimeSeconds + 1.0;
        BowAuthority.Available();
        if (BowState.NativeVersion != BowAuthority.NativeVersion || BowState.Weapon != BowAuthority.Gun)
            bForceNetUpdate = true;
        BowState.NativeVersion = BowAuthority.NativeVersion;
        BowState.Weapon = BowAuthority.Gun;
    }
    // Readiness changes with stock reload sync/cooldown even after capability
    // is established. Keep per-request acknowledgment ammo immutable.
    UpdateBowReadiness();
}

simulated function bool BowReleaseAvailable(KFWeapon W)
{
    return class'VRCompoundBowAuthority'.static.Supports(W) && CanRequestHeldWeapons()
        && HeldState.bIndependentWeapons && bVRTrackingEnabled
        && BowState.Human == HeldState.Human && BowState.Weapon == W && BowState.NativeVersion == 1
        && BowState.WorldEpoch == WorldEpoch && BowState.ConnectionEpoch == ConnectionEpoch
        && BowState.PawnEpoch == PawnEpoch;
}

simulated function bool BowCaptureRelease(KFWeapon W, int Hand, int ReferenceEpoch,
    out VRCompoundBowAuthority.VRBowReleaseIdentity Identity)
{
    local VRCompoundBowAuthority.VRBowReleaseIdentity Empty;
    Identity = Empty;
    if (!BowReleaseAvailable(W) || !BowState.bReady || Hand < 0 || Hand > 1 || ReferenceEpoch < 0
        || (Hand == 0 ? HeldState.LeftWeapon : HeldState.RightWeapon) != W
        || (Hand == 0 ? HeldState.RightWeapon : HeldState.LeftWeapon) != None
        || (PredictedHeldPawn != None && LocalHeldRequest > HeldState.AcknowledgedRequest)) return false;
    Identity.Revision = HeldState.Revision;
    Identity.WorldEpoch = WorldEpoch; Identity.ConnectionEpoch = ConnectionEpoch; Identity.PawnEpoch = PawnEpoch;
    Identity.CalibrationEpoch = CalibrationEpoch; Identity.ReferenceEpoch = ReferenceEpoch;
    return true;
}

simulated function int BowRelease(KFWeapon W, int Hand, byte Mode, VRCompoundBowAuthority.VRBowReleaseIdentity Identity,
    vector Origin, rotator Aim, float Tension)
{
    if (!BowReleaseAvailable(W) || Hand < 0 || Hand > 1 || Mode > 1
        || Identity.WorldEpoch != WorldEpoch || Identity.ConnectionEpoch != ConnectionEpoch
        || Identity.PawnEpoch != PawnEpoch || Identity.CalibrationEpoch != CalibrationEpoch
        || Identity.Revision != HeldState.Revision
        || (Hand == 0 ? HeldState.LeftWeapon : HeldState.RightWeapon) != W
        || (Hand == 0 ? HeldState.RightWeapon : HeldState.LeftWeapon) != None) return 0;
    if (LocalBowWorld != WorldEpoch || LocalBowConnection != ConnectionEpoch || LocalBowPawn != PawnEpoch)
    {
        LocalBowWorld = WorldEpoch; LocalBowConnection = ConnectionEpoch; LocalBowPawn = PawnEpoch;
        LocalBowRequest = BowState.AcknowledgedRequest;
    }
    // A held arrow cannot start another request until this one is terminal.
    if (LocalBowRequest > BowState.AcknowledgedRequest || LocalBowRequest >= MaxInt - 1) return 0;
    LocalBowRequest = Max(LocalBowRequest, BowState.AcknowledgedRequest) + 1;
    ServerBowRelease(Identity, LocalBowRequest, W, Hand, Mode,
        Origin - HeldState.Human.Location, Normalize(Aim), Tension);
    return LocalBowRequest;
}

simulated function bool BowReleaseRead(KFWeapon W, int Request, out byte Status, out int Ammo)
{
    Status = 0; Ammo = 0;
    if (Request <= 0 || BowState.Human == None || BowState.Human != HeldState.Human
        || BowState.WorldEpoch != WorldEpoch || BowState.ConnectionEpoch != ConnectionEpoch
        || BowState.PawnEpoch != PawnEpoch || BowState.AcknowledgedRequest != Request
        || BowState.AcknowledgedWeapon != W) return false;
    Status = byte(BowState.bAccepted ? class'VRCompoundBowAuthority'.const.Committed : class'VRCompoundBowAuthority'.const.Rejected);
    Ammo = BowState.PrimaryAmmo;
    return true;
}

reliable server function ServerBowRelease(VRCompoundBowAuthority.VRBowReleaseIdentity Identity, int Request,
    KFWeapon W, int Hand, byte Mode, vector ReleaseOffset, rotator Aim, float Tension)
{
    local vector Origin, Head;
    if (Role != ROLE_Authority || Identity.WorldEpoch != WorldEpoch
        || Identity.ConnectionEpoch != ConnectionEpoch || Identity.PawnEpoch != PawnEpoch
        || BoundPawn == None || Request <= BowState.AcknowledgedRequest || Request <= 0 || Request == MaxInt) return;
    // Retire before gameplay checks, including rejected releases. Reliable
    // owner delivery needs no retries, begin/cancel exchange or shot replay.
    BowState.AcknowledgedRequest = Request;
    BowState.AcknowledgedWeapon = W;
    BowState.bAccepted = false; BowState.PrimaryAmmo = 0;
    bForceNetUpdate = true;
    UpdateBowReadiness();
    if (HeldInventory != None && HeldInventory.IsOwned(W)) BowState.PrimaryAmmo = W.AmmoCount[0];
    if (!HeldCommandsAvailable() || !HeldState.bIndependentWeapons || !IsInventoryFocusEligible()
        || bInventoryFocusRequested || Hand < 0 || Hand > 1 || Mode > 1
        || BowAuthority == None || BowAuthority.Gun != W || BowState.NativeVersion != 1
        || (PublicPose.Snapshot.Sample.TrackingFlags & 7) != 7
        || Identity.CalibrationEpoch != CalibrationEpoch
        || PublicPose.Snapshot.Sample.CalibrationEpoch != Identity.CalibrationEpoch
        || Identity.ReferenceEpoch < 0 || Identity.ReferenceEpoch != PublicPose.Snapshot.Sample.ReferenceEpoch
        || !class'KF2VRNetTypes'.static.IsBoundedVector(ReleaseOffset, 240)
        || !class'KF2VRNetTypes'.static.IsCanonicalRotation(Aim) || !(Tension >= 0 && Tension <= 1)) return;
    HeldInventory.Refresh();
    if (Identity.Revision != HeldInventory.Snapshot.Revision
        || (Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) != W
        || (Hand == 0 ? HeldInventory.Snapshot.RightWeapon : HeldInventory.Snapshot.LeftWeapon) != None
        || !HeldInventory.IsOwned(W)) return;
    Origin = BoundPawn.Location + ReleaseOffset;
    Head = BoundPawn.Location + (PublicPose.Snapshot.Sample.HeadPosition >> PublicPose.Snapshot.RootRotation);
    BowState.bAccepted = BowAuthority.Release(Request, Mode, Origin, Aim, Tension, Head);
    // Rejected releases do not overwrite a still-arriving stock reload sync.
    // Successful stock firing supplies its own authoritative correction.
    if (HeldInventory.IsOwned(W)) BowState.PrimaryAmmo = W.AmmoCount[0];
    UpdateBowReadiness();
}

function KFWeapon ResolveShieldDefender()
{
    local KFWeapon W;
    local int H;
    local vector Rel, Forward;
    if (!HeldCommandsAvailable() || !HeldState.bIndependentWeapons || !IsInventoryFocusEligible()
        || bInventoryFocusRequested || PublicPose==None || !class'VRPhysicalInteraction'.static.Allowed(BoundPawn)
        || WorldInfo.RealTimeSeconds-LastAcceptedRealTime>class'KF2VRNetTypes'.const.PoseLeaseSeconds) return None;
    W=HeldInventory.HeldShield(); H=HeldInventory.Snapshot.ShieldHandToken-1;
    if (W==None || !W.bUsingSights || H<0 || H>1 || (PublicPose.Snapshot.Sample.TrackingFlags & (1 | (2<<H)))!=(1 | (2<<H))) return None;
    Rel=(H==0 ? PublicPose.Snapshot.Sample.LeftPosition : PublicPose.Snapshot.Sample.RightPosition)
        -PublicPose.Snapshot.Sample.HeadPosition;
    Forward=vect(1,0,0);
    if ((Rel dot Forward)<=6 || Rel.Z<=-42) return None;
    return W;
}

function bool PairedReloadContext(int Hand, optional bool bContinuation)
{
    return Hand >= 0 && Hand < 2 && HeldCommandsAvailable() && HeldState.bIndependentWeapons
        && IsInventoryFocusEligible() && !bInventoryFocusRequested
        && (WorldDrops == None || WorldDrops.bDeleteMe || !WorldDrops.Busy()
            || (bContinuation && WorldDrops.PreservesPairedSession(PairedStates[Hand].Weapon, Hand)))
        // A new begin needs this hand's gun free of magazine traffic; a held
        // session needs only its own. The other hand's gun never interferes.
        && (MagazineActions == None || MagazineActions.bDeleteMe || !MagazineActions.Busy()
            || (bContinuation ? MagazineActions.PreservesPairedSession(PairedStates[Hand].Weapon, PairedStates[Hand].SessionId)
                : MagazineActions.PreservesPairedSession(Hand == 0 ? HeldState.LeftWeapon : HeldState.RightWeapon, 0)))
        && class'VRPhysicalInteraction'.static.Allowed(BoundPawn)
        // A new begin needs the hand tracked. Once running, the owner's hands
        // are its own business: a controller lost at the hip mid-slam must
        // not cancel the reload; the owner's motion guard handles tracking.
        && (bContinuation || (PublicPose.Snapshot.Sample.TrackingFlags & (2 << Hand)) != 0);
}

function UpdatePairedReloads()
{
    local int H;
    for (H = 0; H < 2; ++H)
    {
        if (PairedReloads[H] == None)
        {
            PairedReloads[H] = new(self) class'KF2VRNetPairedReload';
            PairedReloads[H].Initialize(self, HeldInventory, H);
        }
        PairedReloads[H].Tick();
        PairedStates[H] = PairedReloads[H].Snapshot;
    }
}

function ShutdownPairedReloads()
{
    local int H;
    for (H = 0; H < 2; ++H)
    {
        if (PairedReloads[H] != None) PairedReloads[H].Cancel(PairedReloads[H].Snapshot.SessionId);
        PairedReloads[H] = None;
        PairedStates[H].Human = None;
        PairedStates[H].Weapon = None;
        PairedStates[H].LastBeginWeapon = None;
        PairedStates[H].BeginRequest = 0;
        PairedStates[H].LastBeginRequest = 0;
        PairedStates[H].Status = 0;
    }
}

simulated function bool PairedReloadAvailable()
{
    return CanRequestHeldWeapons() && HeldState.bIndependentWeapons && bVRTrackingEnabled
        && PairedStates[0].Human == HeldState.Human && HeldState.Human != None
        && PairedStates[0].WorldEpoch == WorldEpoch && PairedStates[0].ConnectionEpoch == ConnectionEpoch
        && PairedStates[0].PawnEpoch == PawnEpoch;
}

simulated function int PairedReloadBegin(KFWeapon W, int Hand, optional bool bStock, optional bool bRealistic,
    optional bool bSwingOut, optional bool bLoseAmmo)
{
    if (!PairedReloadAvailable() || Hand < 0 || Hand > 1 || W == None
        || class'VRWeaponPair'.static.ForMember(W) == None
        || (Hand == 0 ? HeldState.LeftWeapon : HeldState.RightWeapon) != W
        || LocalPairedReloadRequest >= MaxInt - 1) return 0;
    ++LocalPairedReloadRequest;
    if (PendingPairedPawn != HeldState.Human)
    { PendingPairedPawn = HeldState.Human; PendingPairedBegin[0] = 0; PendingPairedBegin[1] = 0; }
    PendingPairedBegin[Hand] = LocalPairedReloadRequest;
    ServerPairedReloadBegin(WorldEpoch, ConnectionEpoch, PawnEpoch, LocalPairedReloadRequest, W, Hand, HeldState.Revision, W.AmmoCount[0], bStock, bRealistic, bSwingOut, bLoseAmmo);
    return LocalPairedReloadRequest;
}

simulated function bool PairedReloadRead(KFWeapon W, int BeginRequest, out int Session,
    out byte Status, out int Ammo, out int Reserve, optional out byte Ejected)
{
    local int H;
    Session = 0; Status = 0; Ammo = 0; Reserve = 0;
    Ejected = 0;
    if (BeginRequest <= 0 || W == None) return false;
    for (H = 0; H < 2; ++H)
    {
        if (PairedStates[H].PawnEpoch != PawnEpoch || PairedStates[H].WorldEpoch != WorldEpoch
            || PairedStates[H].ConnectionEpoch != ConnectionEpoch) continue;
        if (PairedStates[H].LastBeginRequest == BeginRequest && PairedStates[H].LastBeginWeapon == W
            && !PairedStates[H].bBeginAccepted)
        { Session = BeginRequest; Status = 3; return true; }
        if (PairedStates[H].Weapon != W || PairedStates[H].BeginRequest != BeginRequest) continue;
        Session = PairedStates[H].SessionId; Status = byte(PairedStates[H].Status);
        Ammo = PairedStates[H].PrimaryAmmo; Reserve = PairedStates[H].PrimaryReserve;
        Ejected = byte(PairedStates[H].bCylinderEjected);
        return true;
    }
    return false;
}

simulated function bool PairedReloadEject(KFWeapon W, int BeginRequest, int Session)
{
    local int H;
    if (!PairedReloadAvailable() || Session <= 0 || Session != BeginRequest) return false;
    for (H = 0; H < 2; ++H)
        if (PairedStates[H].Weapon == W && PairedStates[H].SessionId == Session && PairedStates[H].Status == 1)
        {
            ServerPairedReloadEject(WorldEpoch, ConnectionEpoch, PawnEpoch, W, H, Session);
            return true;
        }
    return false;
}

simulated function bool PairedReloadCommit(KFWeapon W, int BeginRequest, int Session, optional bool bNoLoad, optional int Maximum)
{
    local int H;
    if (PouchAmmoPending()) return false;
    if (!PairedReloadAvailable() || Session <= 0 || Session != BeginRequest) return false;
    for (H = 0; H < 2; ++H)
        if (PairedStates[H].Weapon == W && PairedStates[H].SessionId == Session && PairedStates[H].Status == 1)
        {
            ServerPairedReloadFinish(WorldEpoch, ConnectionEpoch, PawnEpoch, W, H, Session, true, bNoLoad, Maximum);
            return true;
        }
    return false;
}

simulated function MagazineRemoved(KFWeapon W, int Kept, int Lost)
{
    if (W != None && Lost > 0) ServerMagazineRemoved(WorldEpoch, ConnectionEpoch, PawnEpoch, W, Kept, Lost);
}

function bool MagazineWeaponOwned(int WE, int CE, int PE, KFWeapon W)
{
    local Controller C;
    C = Controller(Owner);
    return WE == WorldEpoch && CE == ConnectionEpoch && PE == PawnEpoch && W != None && !W.bDeleteMe
        && C != None && C.Pawn != None && W.Instigator == C.Pawn && W.InvManager == C.Pawn.InvManager;
}

reliable server function ServerMagazineRemoved(int WE, int CE, int PE, KFWeapon W, int Kept, int Lost)
{
    if (!MagazineWeaponOwned(WE, CE, PE, W)) return;
    class'VRHandsBridge'.static.ApplyMagazineRemoved(W, Kept, Lost, PlayerController(Owner) != None && PlayerController(Owner).IsLocalController(),
        MagazineBudgetWeapons, MagazineBudgetRounds);
}

simulated function PairedReloadCancel(KFWeapon W, int BeginRequest, int Session)
{
    if (W != None && BeginRequest > 0 && (Session == 0 || Session == BeginRequest))
        ServerPairedReloadFinish(WorldEpoch, ConnectionEpoch, PawnEpoch, W, -1, BeginRequest, false);
}

reliable server function ServerPairedReloadBegin(int WE, int CE, int PE, int Request,
    KFWeapon W, int Hand, int ExpectedHeldRevision, int ExpectedAmmo, bool bStock, optional bool bRealistic,
    optional bool bSwingOut, optional bool bLoseAmmo)
{
    if (WE != WorldEpoch || CE != ConnectionEpoch || PE != PawnEpoch || Hand < 0 || Hand > 1
        || PairedReloads[Hand] == None) return;
    PairedReloads[Hand].Tick();
    PairedReloads[Hand].Begin(Request, W, ExpectedHeldRevision, ExpectedAmmo, bStock, bRealistic, bSwingOut, bLoseAmmo);
    PairedStates[Hand] = PairedReloads[Hand].Snapshot;
    bForceNetUpdate = true;
}

reliable server function ServerPairedReloadEject(int WE, int CE, int PE, KFWeapon W, int Hand, int Session)
{
    if (WE != WorldEpoch || CE != ConnectionEpoch || PE != PawnEpoch || Hand < 0 || Hand > 1
        || PairedReloads[Hand] == None) return;
    PairedReloads[Hand].Eject(Session, W);
    PairedStates[Hand] = PairedReloads[Hand].Snapshot;
    bForceNetUpdate = true;
}

reliable server function ServerPairedReloadFinish(int WE, int CE, int PE,
    KFWeapon W, int Hand, int Session, bool bCommit, optional bool bNoLoad, optional int Maximum)
{
    local int H;
    if (WE != WorldEpoch || CE != ConnectionEpoch || PE != PawnEpoch || Session <= 0) return;
    for (H = 0; H < 2; ++H)
        if (PairedReloads[H] != None && PairedReloads[H].Snapshot.Weapon == W
            && PairedReloads[H].Snapshot.SessionId == Session && (!bCommit || Hand == H))
        {
            if (bCommit) PairedReloads[H].Commit(Session, W, bNoLoad, Maximum);
            else PairedReloads[H].Cancel(Session);
            PairedStates[H] = PairedReloads[H].Snapshot;
            bForceNetUpdate = true;
        }
}

function bool VampireContextAllowed()
{
    return HeldCommandsAvailable() && HeldState.bIndependentWeapons
        && bVRTrackingEnabled && !bInventoryFocusRequested && !WorldDropPending();
}

function PublishVampireState()
{
    if (VampireReload == None) return;
    VampireState = VampireReload.Snapshot;
    bForceNetUpdate = true;
}

simulated function bool VampireAvailable()
{
    return CanRequestHeldWeapons() && HeldState.bIndependentWeapons && bVRTrackingEnabled
        && VampireState.Human == HeldState.Human && VampireState.NativeVersion == 1
        && VampireState.WorldEpoch == WorldEpoch && VampireState.ConnectionEpoch == ConnectionEpoch
        && VampireState.PawnEpoch == PawnEpoch;
}

simulated function bool VampireManaged()
{
    local KF2VRNetPlayerController PC;
    PC = KF2VRNetPlayerController(Owner);
    // Remember a capability-gated begin even while its acknowledgement is
    // pending. A request on the weapon actor cannot safely replace it.
    return PC != None && LocalVampireManagedPawn != None
        && LocalVampireManagedPawn == PC.Pawn
        && LocalVampireManagedWorld == WorldEpoch
        && LocalVampireManagedConnection == ConnectionEpoch
        && LocalVampireManagedEpoch == PawnEpoch;
}

simulated function int NextVampireRequest()
{
    if (!VampireAvailable()) return 0;
    if (LocalVampirePawn != HeldState.Human)
    {
        LocalVampirePawn = HeldState.Human;
        LocalVampireRequest = 0;
    }
    if (VampireState.Human == LocalVampirePawn)
        LocalVampireRequest = Max(LocalVampireRequest, VampireState.AcknowledgedRequest);
    if (LocalVampireRequest >= MaxInt - 1) return 0;
    return ++LocalVampireRequest;
}

simulated function int VampireBegin(KFWeapon W, int Hand, bool bStock, optional bool bLoseAmmo)
{
    local int Request;
    if (!VampireAvailable() || !class'VRVampireReloadAuthority'.static.Supports(W)
        || Hand < 0 || Hand > 1
        || (Hand == 0 ? HeldState.LeftWeapon : HeldState.RightWeapon) != W) return 0;
    Request = NextVampireRequest();
    if (Request == 0) return 0;
    LocalVampireManagedPawn = HeldState.Human;
    LocalVampireManagedWorld = WorldEpoch;
    LocalVampireManagedConnection = ConnectionEpoch;
    LocalVampireManagedEpoch = PawnEpoch;
    ServerVampireBegin(WorldEpoch, ConnectionEpoch, PawnEpoch, Request, W, Hand, HeldState.Revision, bStock, bLoseAmmo);
    return Request;
}

simulated function bool VampireRead(KFWeapon W, int BeginRequest, out int Session,
    out byte Status, out int Ammo, out int Reserve)
{
    Session = 0; Status = 0; Ammo = 0; Reserve = 0;
    if (!VampireAvailable() || VampireState.Human != HeldState.Human
        || VampireState.WorldEpoch != WorldEpoch || VampireState.ConnectionEpoch != ConnectionEpoch
        || VampireState.PawnEpoch != PawnEpoch || BeginRequest <= 0) return false;
    if (VampireState.LastBeginRequest == BeginRequest && VampireState.LastBeginWeapon == W
        && !VampireState.bBeginAccepted)
    {
        Session = BeginRequest;
        Status = byte(class'VRVampireReloadAuthority'.const.Cancelled);
        return true;
    }
    if (VampireState.BeginRequest != BeginRequest || VampireState.Weapon != W
        || VampireState.SessionId != BeginRequest) return false;
    Session = VampireState.SessionId;
    Status = byte(VampireState.Status);
    Ammo = VampireState.PrimaryAmmo;
    Reserve = VampireState.PrimaryReserve;
    return true;
}

simulated function bool VampireRemoveMagazine(KFWeapon W, int BeginRequest, int Session)
{
    local int Request;
    if (!VampireAvailable() || Session != BeginRequest || Session <= 0
        || VampireState.Human != HeldState.Human || VampireState.Weapon != W
        || VampireState.BeginRequest != BeginRequest || VampireState.SessionId != Session
        || VampireState.Status != class'VRVampireReloadAuthority'.const.Held) return false;
    Request = NextVampireRequest();
    if (Request == 0) return false;
    ServerVampireRemoveMagazine(WorldEpoch, ConnectionEpoch, PawnEpoch, Request, W,
        VampireState.Hand, VampireState.ItemId, VampireState.ItemRevision, Session);
    return true;
}

simulated function bool VampireCommit(KFWeapon W, int BeginRequest, int Session, optional int Maximum)
{
    local int Request;
    if (PouchAmmoPending()) return false;
    if (!VampireAvailable() || Session != BeginRequest || Session <= 0
        || VampireState.Human != HeldState.Human || VampireState.Weapon != W
        || VampireState.BeginRequest != BeginRequest || VampireState.SessionId != Session
        || VampireState.Status != class'VRVampireReloadAuthority'.const.Held) return false;
    Request = NextVampireRequest();
    if (Request == 0) return false;
    ServerVampireCommit(WorldEpoch, ConnectionEpoch, PawnEpoch, Request, W,
        VampireState.Hand, VampireState.ItemId, VampireState.ItemRevision, Session, Maximum);
    return true;
}

simulated function VampireCancel(KFWeapon W, int BeginRequest, int Session)
{
    local int Request;
    // Cancel can follow a still-pending begin on this same reliable actor.
    // The authority resolves that begin's tuple; no client item ID is needed.
    if (W == None || BeginRequest <= 0 || (Session != 0 && Session != BeginRequest)) return;
    Request = NextVampireRequest();
    if (Request == 0) return;
    ServerVampireCancel(WorldEpoch, ConnectionEpoch, PawnEpoch, Request, W, BeginRequest);
}

reliable server function ServerVampireBegin(int W, int C, int P, int Request,
    KFWeapon Weapon, int Hand, int ExpectedHeldRevision, bool bStock, optional bool bLoseAmmo)
{
    if (W != WorldEpoch || C != ConnectionEpoch || P != PawnEpoch || VampireReload == None) return;
    VampireReload.Tick(VampireContextAllowed());
    VampireReload.Begin(Request, Weapon, Hand, ExpectedHeldRevision, W, C, P, bStock, bLoseAmmo);
    PublishVampireState();
}

reliable server function ServerVampireRemoveMagazine(int W, int C, int P, int Request,
    KFWeapon Weapon, int Hand, int Id, int Revision, int Session)
{
    if (W != WorldEpoch || C != ConnectionEpoch || P != PawnEpoch || VampireReload == None) return;
    VampireReload.Tick(VampireContextAllowed());
    VampireReload.RemoveMagazine(Request, Weapon, Hand, Id, Revision, Session, W, C, P);
    PublishVampireState();
}

reliable server function ServerVampireCommit(int W, int C, int P, int Request,
    KFWeapon Weapon, int Hand, int Id, int Revision, int Session, optional int Maximum)
{
    if (W != WorldEpoch || C != ConnectionEpoch || P != PawnEpoch || VampireReload == None) return;
    VampireReload.Tick(VampireContextAllowed());
    VampireReload.Commit(Request, Weapon, Hand, Id, Revision, Session, W, C, P, Maximum);
    PublishVampireState();
}

reliable server function ServerVampireCancel(int W, int C, int P, int Request,
    KFWeapon Weapon, int BeginRequest)
{
    // Always record the cancel: a refused begin never set Snapshot.Weapon, and
    // dropping its cancel left the client one request ahead for the whole life
    // (OwnerActionsSettled false for every gun). Cancel acts only on a match.
    if (W != WorldEpoch || C != ConnectionEpoch || P != PawnEpoch || VampireReload == None) return;
    VampireReload.Cancel(Request, Weapon, VampireReload.Snapshot.Hand,
        VampireReload.Snapshot.ItemId, VampireReload.Snapshot.ItemRevision, BeginRequest, W, C, P);
    PublishVampireState();
}

function PublishGrenadeState()
{
    local KFInventoryManager Manager;
    local int Count;
    if (BoundPawn != None) Manager = KFInventoryManager(BoundPawn.InvManager);
    if (Manager != None) Count = Manager.GrenadeCount;
    if (GrenadeState.Human != BoundPawn || GrenadeState.Count != Count) bForceNetUpdate = true;
    GrenadeState.Human = BoundPawn;
    GrenadeState.Count = Count;
}

simulated function bool GrenadePending()
{
    return LocalGrenadePawn != None && LocalGrenadePawn == HeldState.Human
        && LocalGrenadePawn == GrenadeState.Human
        && LocalGrenadeRequest > GrenadeState.AcknowledgedRequest;
}

simulated function int AvailableGrenades()
{
    if (!CanRequestHeldWeapons() || GrenadeState.Human != HeldState.Human) return 0;
    return Max(0, GrenadeState.Count - (GrenadePending() ? 1 : 0));
}

simulated function int RequestGrenade(KFWeapon WeaponOwner, class<KFProj_Grenade> GrenadeClass,
    int Hand, vector Position, vector ReleaseVelocity, int ReferenceEpoch)
{
    if (!CanRequestHeldWeapons() || !HeldState.bIndependentWeapons || !bVRTrackingEnabled
        || Hand < 0 || Hand > 1 || AvailableGrenades() <= 0 || GrenadePending()) return 0;
    if (LocalGrenadePawn != HeldState.Human)
    {
        LocalGrenadePawn = HeldState.Human;
        LocalGrenadeRequest = GrenadeState.AcknowledgedRequest;
    }
    LocalGrenadeRequest = Max(LocalGrenadeRequest, GrenadeState.AcknowledgedRequest);
    if (LocalGrenadeRequest >= MaxInt - 1) return 0;
    ++LocalGrenadeRequest;
    LocalGrenadeWorld = WorldEpoch; LocalGrenadeConnection = ConnectionEpoch; LocalGrenadePawnEpoch = PawnEpoch;
    // World-oriented pawn offsets survive prediction corrections without a
    // server camera/yaw change rotating the measured gesture.
    ServerThrowGrenade(PawnEpoch, LocalGrenadeRequest, ReferenceEpoch, Hand, WeaponOwner,
        GrenadeClass, Position - LocalGrenadePawn.Location, ReleaseVelocity);
    return LocalGrenadeRequest;
}

simulated function byte ReadGrenadeResult(int Request, KFPawn_Human Pawn)
{
    if (!CanRequestHeldWeapons() || !bVRTrackingEnabled || Request <= 0 || Request != LocalGrenadeRequest
        || Pawn == None || Pawn != LocalGrenadePawn || Pawn != HeldState.Human || Pawn != GrenadeState.Human
        || LocalGrenadeWorld != WorldEpoch || LocalGrenadeConnection != ConnectionEpoch
        || LocalGrenadePawnEpoch != PawnEpoch || GrenadeState.AcknowledgedRequest > Request) return 3;
    if (GrenadeState.AcknowledgedRequest != Request) return 0;
    return GrenadeState.bAccepted ? 1 : 2;
}

reliable server function ServerThrowGrenade(int InPawnEpoch, int RequestId, int ReferenceEpoch,
    int Hand, KFWeapon WeaponOwner, class<KFProj_Grenade> GrenadeClass,
    vector ReleaseOffset, vector ReleaseVelocity)
{
    local vector Position, Head;
    local int TrackingBit;
    if (Role != ROLE_Authority || InPawnEpoch != PawnEpoch || BoundPawn == None
        || RequestId <= GrenadeState.AcknowledgedRequest || RequestId <= 0 || RequestId == MaxInt) return;
    // Mark before validation/spawn: each request can enter the transaction once,
    // including refused releases. Reliable owner RPCs need no retry transport.
    GrenadeState.AcknowledgedRequest = RequestId;
    GrenadeState.bAccepted = false;
    bForceNetUpdate = true;
    if (WorldInfo.RealTimeSeconds - GrenadeRateStart >= 1.0)
    {
        GrenadeRateStart = WorldInfo.RealTimeSeconds;
        GrenadeRateCount = 0;
    }
    GrenadeRateCount = Min(GrenadeRateCount + 1, 5);
    if (HeldCommandsAvailable() && HeldState.bIndependentWeapons && bVRTrackingEnabled
        && Hand >= 0 && Hand <= 1 && PublicPose != None && GrenadeRateCount <= 4
        && WorldInfo.RealTimeSeconds - LastAcceptedRealTime <= class'KF2VRNetTypes'.const.PoseLeaseSeconds
        && ReferenceEpoch >= 0 && ReferenceEpoch == PublicPose.Snapshot.Sample.ReferenceEpoch
        && class'VRGrenadeThrow'.static.Bounded(ReleaseOffset, 240)
        && class'VRGrenadeThrow'.static.Bounded(ReleaseVelocity, 1800))
    {
        HeldInventory.Refresh();
        TrackingBit = 2 << Hand;
        if ((PublicPose.Snapshot.Sample.TrackingFlags & (1 | TrackingBit)) == (1 | TrackingBit)
            && (Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) == None
            && HeldInventory.IsOwned(WeaponOwner))
        {
            Position = BoundPawn.Location + ReleaseOffset;
            Head = BoundPawn.Location + (PublicPose.Snapshot.Sample.HeadPosition >> PublicPose.Snapshot.RootRotation);
            GrenadeState.bAccepted = class'VRGrenadeThrow'.static.Launch(self, BoundPawn,
                WeaponOwner, GrenadeClass, Hand, Position, ReleaseVelocity, Head);
        }
    }
    PublishGrenadeState();
    `log("KF2VRNet grenade_release pawn=" $ PawnEpoch $ " request=" $ RequestId
        $ " hand=" $ Hand $ " accepted=" $ GrenadeState.bAccepted
        $ " count=" $ GrenadeState.Count $ " velocity=" $ ReleaseVelocity
        $ " netmode=" $ WorldInfo.NetMode);
}

function RestoreWeaponPairs()
{
    local int I;
    if (Role != ROLE_Authority) return;
    for (I = WeaponPairs.Length - 1; I >= 0; --I)
    {
        if (WeaponPairs[I] == None || WeaponPairs[I].bDeleteMe)
        {
            WeaponPairs.Remove(I, 1);
            continue;
        }
        // A failed restoration must retain its only ammunition/stock receipt.
        if (WeaponPairs[I].Restore())
        {
            WeaponPairs[I].Destroy();
            WeaponPairs.Remove(I, 1);
        }
    }
    if (HeldInventory != None) { HeldInventory.Refresh(); PublishHeldState(); }
}

function int StockWeaponCount()
{
    local KFWeapon Weapon;
    local int Count;
    if (BoundPawn == None || BoundPawn.InvManager == None) return 0;
    // Keep the braces: a brace-less foreach body here compiled to bytecode the
    // VM rejects ("Unknown code token 04"), killing the server on trader open.
    foreach BoundPawn.InvManager.InventoryActors(class'KFWeapon', Weapon)
    {
        ++Count;
    }
    return Count;
}

// Returns the complete post-restore weapon count. Waiting for every weapon, not
// only restored pairs, keeps a just-purchased ordinary weapon in the client's
// cached sell list as well as in the hand selector.
function int BeginTraderPairPreflight()
{
    if (Role != ROLE_Authority) return -1;
    TraderPairPreflightUntil = WorldInfo.RealTimeSeconds + 10.0;
    RestoreWeaponPairs();
    if (BoundPawn != None) BoundPawn.bForceNetUpdate = true;
    if (BoundPawn != None && BoundPawn.InvManager != None) BoundPawn.InvManager.bForceNetUpdate = true;
    return StockWeaponCount();
}

function EndTraderPairPreflight()
{
    TraderPairPreflightUntil = 0;
}

function bool TraderPairPreflightActive()
{
    if (TraderPairPreflightUntil <= 0) return false;
    if (WorldInfo.RealTimeSeconds < TraderPairPreflightUntil) return true;
    TraderPairPreflightUntil = 0;
    return false;
}

// Native AddWeaponToGroup links a bought or picked-up weapon into the middle
// of the chain with a C++ write, which never marks the previous item dirty.
// Stock clients relink it themselves in ClientWeaponSet, but independent hands
// keep one server-owned chain (WeaponRuntimeDispatch event 6), so the client
// would never see the new link (a single Deagle bought online). Resend every
// link whenever the chain changes.
function ResendChainLinks()
{
    local Inventory Item;
    local int I, Count;
    local bool bChanged;
    if (Role != ROLE_Authority || BoundPawn == None || BoundPawn.InvManager == None) return;
    for (Item = BoundPawn.InvManager.InventoryChain; Item != None && Count < 64; Item = Item.Inventory)
    {
        if (Count >= LastChainLinks.Length || LastChainLinks[Count] != Item) bChanged = true;
        ++Count;
    }
    if (!bChanged && Count == LastChainLinks.Length) return;
    LastChainLinks.Length = 0;
    for (Item = BoundPawn.InvManager.InventoryChain; Item != None && I < 64; Item = Item.Inventory)
    {
        LastChainLinks.AddItem(Item);
        Item.bNetDirty = true; Item.bForceNetUpdate = true;
        ++I;
    }
    BoundPawn.InvManager.bNetDirty = true; BoundPawn.InvManager.bForceNetUpdate = true;
}

function UpdateWeaponPairs()
{
    local KFWeap_DualBase Source;
    local VRWeaponPair Pair;
    local bool bWasCurrent;
    local KFInventoryManager Manager;
    local int I;
    for (I = WeaponPairs.Length - 1; I >= 0; --I)
        if (WeaponPairs[I] == None || WeaponPairs[I].bDeleteMe || WeaponPairs[I].PairState == 3)
            WeaponPairs.Remove(I, 1);
    if (!HeldCommandsAvailable() || !HeldState.bIndependentWeapons || BoundPawn == None
        || WorldInfo.RealTimeSeconds < NextPairAttemptTime) return;
    Manager = KFInventoryManager(BoundPawn.InvManager);
    if (Manager == None || Manager.bServerTraderMenuOpen || TraderPairPreflightActive()) return;
    foreach Manager.InventoryActors(class'KFWeap_DualBase', Source)
    {
        if (class'VRWeaponPair'.static.MemberClassFor(Source) == None) continue;
        NextPairAttemptTime = WorldInfo.RealTimeSeconds + 1;
        bWasCurrent = BoundPawn.Weapon == Source;
        Pair = Spawn(class'VRWeaponPair', Owner);
        if (Pair != None && Pair.BeginForPawn(BoundPawn, Source) && Pair.Commit())
        {
            WeaponPairs.AddItem(Pair);
            KF2VRNetPlayerController(Owner).PairedCaseConverted(Pair);
            HeldInventory.Refresh();
            // Only a pair that was already in hand goes back to the hands; a
            // bought or picked-up pair stays in inventory, even with empty hands
            // (Kvasir94, #31: "it should go to inventory").
            if (bWasCurrent)
            {
                HeldInventory.SetHands(Pair.Members[1], Pair.Members[0]);
                HeldInventory.ApplyHands();
            }
            PublishHeldState();
            bForceNetUpdate = true;
            `log("KF2VRNet paired phase=converted family=" $ Source.Class.Name
                $ " rounds=" $ Pair.TotalRounds() $ " weight=" $ Manager.CurrentCarryBlocks
                $ " left=" $ Pair.Members[1] $ " right=" $ Pair.Members[0]);
        }
        else if (Pair != None) { Pair.AbortPreparation(); Pair.Destroy(); }
        return;
    }
}

// The server adapter supplies per-item stock pending fire. Diagnostic probes
// are evidence, not a prerequisite or an extra round trip for normal play.
function bool HeldCommandsAvailable()
{
    local KF2VRNetGame Game;
    Game = KF2VRNetGame(WorldInfo.Game);
    return Role == ROLE_Authority && WorldInfo.NetMode == NM_DedicatedServer
        && bHandshakeAccepted && Game != None && Game.bServerAdapter && NativeAuthorityReady == 1
        && HeldInventory != None
        && BoundPawn != None && BoundPawn.Health > 0 && !BoundPawn.bDeleteMe
        && KF2VRNetPlayerController(Owner) != None && KF2VRNetPlayerController(Owner).Pawn == BoundPawn;
}

// Grip of one held item (1 braced/sighted, 0 hip, -1 unmanaged), for perks.
function SetItemGrip(KFWeapon W, int Policy)
{
    if (Role == ROLE_Authority && HeldInventory != None) HeldInventory.SetGrip(W, Policy);
}

reliable server function ServerSetHeldWeapons(KFPawn_Human RequestedPawn, int RequestId,
    KFWeapon Left, KFWeapon Right, optional int CarryMask, optional int ShieldHandToken)
{
    // Reliable calls on this owner actor already arrive in order. The request
    // number only correlates prediction with authority; it is not a transport.
    if (!HeldCommandsAvailable() || RequestedPawn != BoundPawn
        || RequestId <= HeldState.AcknowledgedRequest || RequestId == MaxInt) return;
    if (WorldInfo.RealTimeSeconds - HeldRateStart >= 1.0)
    {
        HeldRateStart = WorldInfo.RealTimeSeconds;
        HeldRateCount = 0;
    }
    HeldRateCount = Min(HeldRateCount + 1, 33);
    HeldState.AcknowledgedRequest = RequestId;
    HeldState.bAccepted = PendingCycleWeapon == None && !WorldDropPending() && HeldRateCount <= 32 && (CarryMask == 0 || NativeCarryVersion == 1)
        && (WorldDrops == None || WorldDrops.PreservesTrickHands(Left, Right, CarryMask))
        && HeldInventory.SetHands(Left, Right, CarryMask, ShieldHandToken);
    if (HeldState.bAccepted && HeldState.bIndependentWeapons) HeldInventory.ApplyHands();
    PublishHeldState();
    bForceNetUpdate = true;
    if (HeldRateCount <= 32)
        `log("KF2VRNet held_command world=" $ WorldEpoch $ " connection=" $ ConnectionEpoch
            $ " pawn=" $ PawnEpoch $ " request=" $ RequestId
            $ " accepted=" $ HeldState.bAccepted $ " revision=" $ HeldState.Revision
            $ " left=" $ HeldState.LeftWeapon $ " right=" $ HeldState.RightWeapon
            $ " netmode=" $ WorldInfo.NetMode);
}

simulated function bool CanRequestHeldWeapons()
{
    local KF2VRNetPlayerController PC;
    PC = KF2VRNetPlayerController(Owner);
    return WorldInfo.NetMode == NM_Client && PC != None && PC.IsLocalPlayerController()
        && bHandshakeAccepted && HeldState.bAvailable && HeldState.Human != None
        && HeldState.Human == PC.Pawn && HeldState.Human.Health > 0 && !HeldState.Human.bDeleteMe;
}

simulated function bool RequestHeldWeapons(KFWeapon Left, KFWeapon Right, optional int CarryMask, optional int ShieldHandToken)
{
    if (!CanRequestHeldWeapons() || WorldReplacementPending() || PhysicalCyclePending() || WorldDropPending() || (Left != None && Left == Right) || CarryMask < 0 || CarryMask > 3
        || (CarryMask != 0 && HeldState.NativeCarryVersion != 1)) return false;
    if (PredictedHeldPawn != HeldState.Human)
    {
        PredictedHeldPawn = HeldState.Human;
        LocalHeldRequest = HeldState.AcknowledgedRequest;
    }
    LocalHeldRequest = Max(LocalHeldRequest, HeldState.AcknowledgedRequest);
    if (LocalHeldRequest >= MaxInt - 1) return false;
    ++LocalHeldRequest;
    PredictedLeft = Left;
    PredictedRight = Right;
    PredictedCarryMask = CarryMask;
    PredictedShieldHandToken = ShieldHandToken;
    ServerSetHeldWeapons(PredictedHeldPawn, LocalHeldRequest, Left, Right, CarryMask, ShieldHandToken);
    return true;
}

// Presentation reads this immediately after input. An older server update
// cannot undo a newer grip; the processed request confirms or corrects it.
simulated function bool HeldRequestPending()
{
    return CanRequestHeldWeapons() && PredictedHeldPawn == HeldState.Human
        && LocalHeldRequest > HeldState.AcknowledgedRequest;
}

simulated function bool GetDesiredHeldWeapons(out KFWeapon Left, out KFWeapon Right, optional out int CarryMask, optional out int ShieldHandToken)
{
    Left = None;
    Right = None;
    CarryMask = 0;
    ShieldHandToken=0;
    if (!CanRequestHeldWeapons() || WorldReplacementPending()) return false;
    if (PredictedHeldPawn == HeldState.Human && LocalHeldRequest > HeldState.AcknowledgedRequest)
    {
        Left = PredictedLeft;
        Right = PredictedRight;
        CarryMask = PredictedCarryMask;
        ShieldHandToken = PredictedShieldHandToken;
    }
    else
    {
        Left = HeldState.LeftWeapon;
        Right = HeldState.RightWeapon;
        CarryMask = HeldState.CarryMask;
        ShieldHandToken = HeldState.ShieldHandToken;
    }
    return true;
}

function PublishHeldState()
{
    local KF2VRNetGame Game;
    Game = KF2VRNetGame(WorldInfo.Game);
    HeldState.Human = BoundPawn;
    HeldState.bAvailable = HeldCommandsAvailable();
    HeldState.bIndependentWeapons = HeldState.bAvailable && bVRTrackingEnabled
        && Game != None && Game.bIndependentWeapons;
    if (HeldInventory == None) return;
    HeldState.Revision = HeldInventory.Snapshot.Revision;
    HeldState.LeftGeneration = HeldInventory.Snapshot.LeftGeneration;
    HeldState.RightGeneration = HeldInventory.Snapshot.RightGeneration;
    HeldState.LeftWeapon = HeldInventory.Snapshot.LeftWeapon;
    HeldState.RightWeapon = HeldInventory.Snapshot.RightWeapon;
    HeldState.CarryMask = HeldInventory.Snapshot.CarryMask;
    HeldState.ShieldHandToken = HeldInventory.Snapshot.ShieldHandToken;
    HeldState.NativeCarryVersion = NativeCarryVersion;
    HeldState.NativeWeaponActionVersion = NativeWorldDropVersion;
    HeldState.NativePouchAmmoVersion = NativePouchAmmoVersion;
    if (PublicPose != None && !bMotionReplayEnabled)
        PublicPose.PublishWeapons(HeldState.bIndependentWeapons,
            HeldState.LeftWeapon, HeldInventory.Snapshot.LeftId,
            HeldState.RightWeapon, HeldInventory.Snapshot.RightId, HeldInventory);
}

reliable server function ServerObserveDualWeapons(string Phase, int ClientLeftAmmo, int ClientRightAmmo)
{
    local KFWeapon Left, Right;
    if (!bSyntheticAllowed || !HeldCommandsAvailable() || !HeldState.bIndependentWeapons || Len(Phase) > 24) return;
    Left = HeldInventory.Snapshot.LeftWeapon;
    Right = HeldInventory.Snapshot.RightWeapon;
    if (Left == None || Right == None) return;
    `log("KF2VRNet dual_weapon_server phase=" $ Phase $ " world=" $ WorldEpoch
        $ " connection=" $ ConnectionEpoch $ " pawn=" $ PawnEpoch
        $ " left_ammo=" $ Left.AmmoCount[0] $ " right_ammo=" $ Right.AmmoCount[0]
        $ " client_left=" $ ClientLeftAmmo $ " client_right=" $ ClientRightAmmo
        $ " left_state=" $ Left.GetStateName() $ " right_state=" $ Right.GetStateName()
        $ " native_fault=" $ HeldInventory.NativeFault $ " netmode=" $ WorldInfo.NetMode);
}

reliable server function ServerObserveDualDrop(int ClientLeftAmmo)
{
    local KFWeapon Left;
    if (!bSyntheticAllowed || !HeldCommandsAvailable() || !HeldState.bIndependentWeapons) return;
    Left = HeldInventory.Snapshot.LeftWeapon;
    `log("KF2VRNet dual_drop_server passed=" $ (Left != None
        && HeldInventory.Snapshot.RightWeapon == None && BoundPawn.Weapon == Left
        && Left.AmmoCount[0] == ClientLeftAmmo && HeldInventory.NativeFault == 0)
        $ " world=" $ WorldEpoch $ " connection=" $ ConnectionEpoch $ " pawn=" $ PawnEpoch
        $ " left_ammo=" $ ClientLeftAmmo $ " netmode=" $ WorldInfo.NetMode);
}

function KF2VRNetDiagnosticClot SpawnDualTarget(KFWeapon W, vector Origin, rotator Aim, string Suffix)
{
    local KF2VRNetDiagnosticClot Target;
    local vector Position, HitLocation, HitNormal;
    local TraceHitInfo HitInfo;
    local Actor Hit;
    local int Attempt;
    local float Distance;
    if (W == None || BoundPawn == None) return None;
    // Keep each recorded ray fixed. Try nearer points on that same ray when
    // map geometry or another actor prevents the stock pawn from fitting.
    for (Attempt = 0; Attempt < 3; ++Attempt)
    {
        Distance = 100.0 - 25.0 * Attempt;
        Position = Origin + vector(Aim) * Distance;
        Position.Z = BoundPawn.Location.Z;
        Target = Spawn(class'KF2VRNetDiagnosticClot',,, Position);
        if (Target == None)
        {
            `log("KF2VRNet dual_target_setup hand=" $ Suffix $ " distance=" $ Distance
                $ " target=None origin=" $ Origin $ " aim=" $ Aim $ " location=" $ Position
                $ " netmode=" $ WorldInfo.NetMode);
            continue;
        }
        Target.ForceUpdateComponents(true, false);
        Hit = W.GetTraceOwner().Trace(HitLocation, HitNormal, Origin + vector(Aim) * W.GetTraceRange(),
            Origin, true, vect(0,0,0), HitInfo, W.TRACEFLAG_Bullet);
        `log("KF2VRNet dual_target_setup hand=" $ Suffix $ " distance=" $ Distance
            $ " target=" $ Target $ " hit=" $ Hit $ " origin=" $ Origin $ " aim=" $ Aim
            $ " location=" $ Target.Location $ " netmode=" $ WorldInfo.NetMode);
        if (Hit == Target)
        {
            Target.InitializeDiagnostic(WorldEpoch, ConnectionEpoch, PawnEpoch, Suffix);
            return Target;
        }
        Target.Destroy();
    }
    return None;
}

function int ReloadCaseItemId()
{
    return HeldInventory != None ? HeldInventory.Snapshot.RightId : 0;
}

reliable server function ServerBegin9mmReloadCase(vector Origin, rotator Aim)
{
    local KF2VRNetGame G;
    local KF2VRNetDiagnosticClot T;
    G = KF2VRNetGame(WorldInfo.Game);
    if (G == None || !G.bDiagnostic9mmReload || !G.DiagnosticClientsReady()
        || !bSyntheticAllowed || !HeldCommandsAvailable() || !HeldState.bIndependentWeapons
        || ReloadCase != None || HeldState.RightWeapon == None || HeldState.LeftWeapon != None
        || HeldState.RightWeapon.Class != class'KFWeap_Pistol_9mm'
        || VSize(Origin - BoundPawn.Location) > 250) return;
    T = SpawnDualTarget(HeldState.RightWeapon, Origin, Aim, "reload9mm");
    if (T == None) return;
    // Two body hits must use the real stock damage path on the same target.
    T.Health = 1000; T.HealthMax = 1000; T.ObservedHealth = 1000; T.LifeSpan = 120;
    T.bForceNetUpdate = true;
    ReloadCase = Spawn(class'KF2VRNetReloadCase', Owner);
    if (ReloadCase != None) ReloadCase.Initialize(self, HeldState.RightWeapon, T);
    else T.Destroy();
}

reliable server function ServerSpawnDualTargets(vector LeftOrigin, rotator LeftAim, vector RightOrigin, rotator RightAim)
{
    if (!bSyntheticAllowed || !HeldCommandsAvailable() || !HeldState.bIndependentWeapons || DualTargetLeft != None
        || DualTargetRight != None || VSize(LeftOrigin - BoundPawn.Location) > 500
        || VSize(RightOrigin - BoundPawn.Location) > 500) return;
    DualTargetLeft = SpawnDualTarget(HeldInventory.Snapshot.LeftWeapon, LeftOrigin, LeftAim, "left");
    DualTargetRight = SpawnDualTarget(HeldInventory.Snapshot.RightWeapon, RightOrigin, RightAim, "right");
}

// Shipping VM skips empty functions. Reset on every call so only the native
// hook completing this exact callback can establish current readiness.
function NativeAuthorityUpdate()
{
    NativeAuthorityReady = 0;
}

// All physical actions share the native process-lifetime serial source.
simulated function int NextWeaponActionSerial()
{
    local KF2VRNetPlayerController C;
    local VRHandsBridge Bridge;
    C = KF2VRNetPlayerController(Owner);
    if (C != None) Bridge = VRHandsBridge(C.LocalVRBridge);
    return Bridge != None ? Bridge.AllocateWeaponActionSerial() : 0;
}

// The owner's physical session ended its stock reload (completion or
// abort) on its own timing; the authority's copy otherwise stays in
// Reloading for the full stock clip and withholds shots taken meanwhile.
// The marker rides the weapon channel behind that reload's ServerSyncReload.
simulated function NotifyPhysicalReloadEnded(KFWeapon W)
{
    local int Serial;
    if (Role == ROLE_Authority || W == None || W.bDeleteMe || !bVRTrackingEnabled
        || !HeldState.bIndependentWeapons) return;
    Serial = NextWeaponActionSerial();
    if (Serial <= 0) return;
    W.SyncCurrentAmmoCount(255, Serial);
    ServerPhysicalReloadEnded(WorldEpoch, ConnectionEpoch, PawnEpoch, W, Serial);
}

reliable server function ServerPhysicalReloadEnded(int WE, int CE, int PE, KFWeapon W, int Serial)
{
    local int I;
    local KF2VRNetItemRuntime R;
    if (!MagazineWeaponOwned(WE, CE, PE, W) || !bVRTrackingEnabled || Serial <= 0 || Serial == MaxInt) return;
    if (HeldInventory == None) return;
    R = HeldInventory.RuntimeFor(W);
    if (R == None || R.NativeReady != 1 || Serial <= R.LastPhysicalReloadEndSerial) return;
    I = PendingReloadEndWeapon[0] == W ? 0 : (PendingReloadEndWeapon[1] == W ? 1
        : (PendingReloadEndWeapon[0] == None ? 0 : 1));
    if (PendingReloadEndWeapon[I] == W && Serial <= PendingReloadEndSerial[I]) return;
    // Rapid switching can leave an older gun waiting for its weapon marker.
    // Retire that request without touching its stock timeline.
    ClearPhysicalReloadEnd(I);
    PendingReloadEndWeapon[I] = W; PendingReloadEndSerial[I] = Serial;
    PendingReloadEndRuntime[I] = R;
    PendingReloadEndDeadline[I] = WorldInfo.RealTimeSeconds + 3.0;
    UpdatePhysicalReloadEnds();
}

function UpdatePhysicalReloadEnds()
{
    local KF2VRNetItemRuntime R;
    local int I;
    local byte Disposition;
    for (I = 0; I < 2; ++I)
    {
        if (PendingReloadEndWeapon[I] == None) continue;
        R = PendingReloadEndRuntime[I];
        if (!PhysicalReloadEndIdentity(I)) { ClearPhysicalReloadEnd(I); continue; }
        // The exact marker follows ServerSyncReload on the weapon channel.
        // A deadline only expires this optimization; it never grants permission
        // to complete before sync, after a replacement, or in a newer reload.
        Disposition = class'VRReloadEndGuard'.static.Disposition(PendingReloadEndSerial[I],
            R.WeaponBarrierSerial, R.WeaponBarrierReloadGeneration, R.ReloadGeneration,
            R.LastPhysicalReloadEndSerial, WorldInfo.RealTimeSeconds >= PendingReloadEndDeadline[I]);
        if (Disposition == class'VRReloadEndGuard'.const.WaitForMarker) continue;
        if (Disposition != class'VRReloadEndGuard'.const.Complete) { ClearPhysicalReloadEnd(I); continue; }
        EndPhysicalReload(I);
    }
}

function bool PhysicalReloadEndIdentity(int I)
{
    local KF2VRNetItemRuntime R;
    local KFWeapon W;
    if (I < 0 || I > 1 || !bVRTrackingEnabled || HeldInventory == None
        || HeldInventory.GetHuman() != BoundPawn) return false;
    W = PendingReloadEndWeapon[I]; R = PendingReloadEndRuntime[I];
    return W != None && !W.bDeleteMe && R != None && R.NativeReady == 1
        && R.Inventory == HeldInventory && R.Item == W && HeldInventory.IsOwned(W)
        && HeldInventory.RuntimeFor(W) == R && R.WorldDropped == 0 && R.MechanismPending == 0;
}

function ClearPhysicalReloadEnd(int I)
{
    local KF2VRNetItemRuntime R;
    if (I < 0 || I > 1) return;
    R = PendingReloadEndRuntime[I];
    if (R != None) R.LastPhysicalReloadEndSerial = Max(R.LastPhysicalReloadEndSerial, PendingReloadEndSerial[I]);
    PendingReloadEndWeapon[I] = None; PendingReloadEndRuntime[I] = None;
    PendingReloadEndSerial[I] = 0; PendingReloadEndDeadline[I] = 0;
}

function EndPhysicalReload(int I)
{
    local KFWeapon W;
    local KF2VRNetItemRuntime R;
    if (!PhysicalReloadEndIdentity(I)) { ClearPhysicalReloadEnd(I); return; }
    R = PendingReloadEndRuntime[I];
    if (class'VRReloadEndGuard'.static.Disposition(PendingReloadEndSerial[I], R.WeaponBarrierSerial,
        R.WeaponBarrierReloadGeneration, R.ReloadGeneration, R.LastPhysicalReloadEndSerial)
        != class'VRReloadEndGuard'.const.Complete) { ClearPhysicalReloadEnd(I); return; }
    W = PendingReloadEndWeapon[I];
    // Consume before stock callbacks can reenter. Dedicated server-ammo,
    // paired members and underbarrels retain their own authority transactions.
    ClearPhysicalReloadEnd(I);
    if (W == None || W.bDeleteMe || !W.IsInState('Reloading') || W.IsInState('AltReloading')
        || !W.bAllowClientAmmoTracking || class'VRWeaponPair'.static.ForMember(W) != None) return;
    W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
    W.ReloadComplete();
}

simulated function bool PhysicalCyclePending()
{
    // Past the deadline release only this owner-wide fence: the gun keeps
    // its own MechanismPending, so a retry cannot cost a second round, and a
    // late receipt still reconciles it.
    if (LocalCyclePawn == HeldState.Human && LocalCycleSerial > ReconciledCycleSerial
        && WorldInfo.RealTimeSeconds - LocalCycleStartedAt > OwnerReplyDeadline)
    {
        `log("KF2VRNet owner_wait phase=expired kind=cycle_eject serial=" $ LocalCycleSerial);
        AbandonCycleEject(LocalCycleSerial);
    }
    return LocalCyclePawn == HeldState.Human && LocalCycleSerial > ReconciledCycleSerial;
}

// The local held runtime calls this only after both return-channel marker and
// receipt are reconciled (or the exact ownership/connection is abandoned).
simulated function AcknowledgeCycleEject(int Serial)
{
    if (Serial == LocalCycleSerial) ReconciledCycleSerial = Serial;
}

simulated function AbandonCycleEject(int Serial)
{
    if (Serial != LocalCycleSerial || Serial <= ReconciledCycleSerial) return;
    // Same owner channel as Begin: cancel reaches authority before any next
    // action. Never refund an already accepted irreversible live-round eject.
    ServerCancelCycleEject(WorldEpoch, ConnectionEpoch, PawnEpoch, Serial);
    ReconciledCycleSerial = Serial;
}

reliable server function ServerCancelCycleEject(int WE, int CE, int PE, int Serial)
{
    if (WE == WorldEpoch && CE == ConnectionEpoch && PE == PawnEpoch
        && Serial > 0 && Serial == PendingCycleSerial) FinishCycleEject(2);
}

// Other owner-channel transactions must settle before sending the weapon marker.
// bMagazineLanes: the magazine channel asks for its own Start, which fences
// each weapon across its lanes itself; its other lane must not refuse it.
simulated function bool OwnerActionsSettled(optional KFWeapon MagazineTarget, optional int MagazineSession,
    optional bool bMagazineLedgerOnly, optional bool bPouchDiscard, optional bool bMagazineLanes)
{
    local int H;
    if (!bPouchDiscard && PouchAmmo != None && PouchAmmo.LocalWeapon != None) return false;
    if (WorldReplacementPending() || PhysicalCyclePending()
        || (bMagazineLanes ? (WorldDrops != None && !WorldDrops.bDeleteMe && WorldDrops.Busy()) : WorldDropPending())
        || (PredictedHeldPawn == HeldState.Human && LocalHeldRequest > HeldState.AcknowledgedRequest)) return false;
    if (LocalBowWorld == WorldEpoch && LocalBowConnection == ConnectionEpoch && LocalBowPawn == PawnEpoch
        && LocalBowRequest > BowState.AcknowledgedRequest) return false;
    if (LocalVampirePawn == HeldState.Human && (LocalVampireRequest > VampireState.AcknowledgedRequest
        || (VampireState.Status == 1 && !(bPouchDiscard && VampireState.Weapon == MagazineTarget))
        || VampireState.Status == 4)) return false;
    for (H = 0; H < 2; ++H)
    {
        // Each hand's paired gun has its own magazine lane. A removal or seat
        // on one gun waits only for that gun, so both hands reload at once.
        if (MagazineTarget != None && PairedStates[H].Weapon != MagazineTarget
            && (H == 0 ? HeldState.LeftWeapon : HeldState.RightWeapon) != MagazineTarget) continue;
        if ((PendingPairedPawn == HeldState.Human && PendingPairedBegin[H] > PairedStates[H].LastBeginRequest)
            || (PairedStates[H].Human == HeldState.Human && (PairedStates[H].Status == 4
                || (PairedStates[H].Status == 1 && !bMagazineLedgerOnly
                    && (MagazineTarget == None || PairedStates[H].Weapon != MagazineTarget
                    || (MagazineSession > 0 && PairedStates[H].SessionId != MagazineSession)))))) return false;
    }
    return true;
}

// Only an ordinary owned gun in the other hand has no paired reserve or
// replacement footprint. Missing local pair replication must fail closed.
simulated function bool WorldActionWeaponOwned(KFWeapon W)
{
    local KFWeapon Candidate;
    local KFPawn_Human P;
    if (Role == ROLE_Authority) return class'VRWorldDropTransfer'.static.Owns(HeldState.Human, W);
    P = HeldState.Human;
    if (P == None || P.bDeleteMe || P.Health <= 0 || P.InvManager == None
        || PlayerController(Owner) == None || PlayerController(Owner).Pawn != P
        || W == None || W.bDeleteMe || W.Owner != P || W.Instigator != P || W.InvManager != P.InvManager) return false;
    foreach P.InvManager.InventoryActors(class'KFWeapon', Candidate)
        if (Candidate == W) return true;
    return false;
}

simulated function bool WorldActionDisjointFromPaired(KFWeapon W, int Hand, KFWeapon ReloadWeapon, int ReloadHand)
{
    return Hand >= 0 && Hand < 2 && ReloadHand >= 0 && ReloadHand < 2 && Hand != ReloadHand
        && W != None && !W.bDeleteMe && ReloadWeapon != None && !ReloadWeapon.bDeleteMe && W != ReloadWeapon
        && WorldActionWeaponOwned(W)
        && (ReloadHand == 0 ? HeldState.LeftWeapon : HeldState.RightWeapon) == ReloadWeapon
        && class'VRWeaponPair'.static.ForMember(W) == None
        && !class'VRWeaponPair'.static.IsMemberClass(W.Class)
        && KFWeap_DualBase(W) == None;
}

simulated function bool WorldPairedSessionsAllow(KFWeapon W, int Hand)
{
    local int H;
    for (H = 0; H < 2; ++H)
        if ((PairedStates[H].Status == 1 || PairedStates[H].Status == 4)
            && (PairedStates[H].Human != HeldState.Human
                || !WorldActionDisjointFromPaired(W, Hand, PairedStates[H].Weapon, H))) return false;
    return true;
}

simulated function bool IncomingWorldDisjoint(Actor Target, int Hand, KFWeapon ReloadWeapon, int ReloadHand)
{
    return Hand >= 0 && Hand < 2 && ReloadHand >= 0 && ReloadHand < 2 && Hand != ReloadHand
        && HeldState.Human != None && ReloadWeapon != None && !ReloadWeapon.bDeleteMe
        && (Hand == 0 ? HeldState.LeftWeapon : HeldState.RightWeapon) == None
        && (ReloadHand == 0 ? HeldState.LeftWeapon : HeldState.RightWeapon) == ReloadWeapon
        && !class'VRWorldPickupFootprint'.static.TouchesWeapon(Target, ReloadWeapon);
}

simulated function bool IncomingWorldSessionsAllow(Actor Target, int Hand)
{
    local int H;
    if (class'VRWorldPickupFootprint'.static.IncomingClass(Target) == None) return false;
    for (H = 0; H < 2; ++H)
        if ((PairedStates[H].Status == 1 || PairedStates[H].Status == 4)
            && (PairedStates[H].Human != HeldState.Human
                || !IncomingWorldDisjoint(Target, Hand, PairedStates[H].Weapon, H))) return false;
    // Stock Vampire owns only its gun; its physical reload also owns the free hand.
    if (VampireState.Status == class'VRVampireReloadAuthority'.const.Held) return false;
    if (VampireState.Status == class'VRVampireReloadAuthority'.const.Stock
        && (VampireState.Human != HeldState.Human
            || !IncomingWorldDisjoint(Target, Hand, VampireState.Weapon, VampireState.Hand))) return false;
    return true;
}

// Inventory removal/addition changes the global held revision. Keep pending
// cycle and replacement receipts fenced on both sides of a tracked transfer.
function bool WorldTransferRevisionReady()
{
    return PendingCycleWeapon == None && !bReplacementPrepared
        && (MagazineActions == None || MagazineActions.bDeleteMe || !MagazineActions.Busy());
}

function bool IncomingWorldActionsReady(Actor Target, int Hand)
{
    return class'VRWorldWeaponPolicy'.static.Enabled()
        && WorldTransferRevisionReady() && IncomingWorldSessionsAllow(Target, Hand);
}

simulated function bool WorldActionsSettled(KFWeapon W, int Hand, optional Actor IncomingTarget)
{
    local int H;
    if (!class'VRWorldWeaponPolicy'.static.Enabled()) return false;
    // Keep global cycle/held-request fences: their receipts use the global held revision.
    if (WorldReplacementPending() || PhysicalCyclePending()
        || (MagazineActions != None && !MagazineActions.bDeleteMe && MagazineActions.Busy())
        || (PredictedHeldPawn == HeldState.Human && LocalHeldRequest > HeldState.AcknowledgedRequest)) return false;
    if (LocalBowWorld == WorldEpoch && LocalBowConnection == ConnectionEpoch && LocalBowPawn == PawnEpoch
        && LocalBowRequest > BowState.AcknowledgedRequest) return false;
    if (LocalVampirePawn == HeldState.Human && (LocalVampireRequest > VampireState.AcknowledgedRequest
        || (IncomingTarget == None && (VampireState.Status == 1 || VampireState.Status == 4)))) return false;
    for (H = 0; H < 2; ++H)
        if (PendingPairedPawn == HeldState.Human && PendingPairedBegin[H] > PairedStates[H].LastBeginRequest) return false;
    if (IncomingTarget != None) return IncomingWorldSessionsAllow(IncomingTarget, Hand);
    return WorldPairedSessionsAllow(W, Hand);
}

simulated function int BeginCycleEject(KFWeapon W, int Hand, int Count)
{
    local int Serial;
    if (!CanRequestHeldWeapons() || !HeldState.bIndependentWeapons || !bVRTrackingEnabled
        || HeldState.NativeWeaponActionVersion != 9 || !OwnerActionsSettled() || Hand < 0 || Hand > 1
        || W == None || (Hand == 0 ? HeldState.LeftWeapon : HeldState.RightWeapon) != W
        || Count != Min(W.AmmoCount[0], class'VRWeaponActionBarrier'.static.LiveRoundCount(W)) || Count <= 0
        || W.AmmoCount[0] < Count || !class'VRWeaponRuntime'.static.StockIdle(W)) return 0;
    Serial = NextWeaponActionSerial();
    if (Serial <= 0) return 0;
    W.StopFire(0); W.StopFire(1);
    LocalCyclePawn = HeldState.Human; LocalCycleSerial = Serial; LocalCycleStartedAt = WorldInfo.RealTimeSeconds;
    LocalCycleWorld = WorldEpoch; LocalCycleConnection = ConnectionEpoch; LocalCyclePawnEpoch = PawnEpoch;
    // Reliable on the exact stock weapon, after its ordinary cleanup/sync.
    W.SyncCurrentAmmoCount(255, Serial);
    ServerCycleEject(WorldEpoch, ConnectionEpoch, PawnEpoch, W, Hand, Serial, HeldState.Revision, W.AmmoCount[0], Count);
    return Serial;
}

// 3 (lost) only when this request can no longer be settled: another pawn or
// epoch owns the channel now, or the authority answered without an owned
// weapon (that receipt is never an accepted debit). A request that is merely
// waiting while held requests are briefly unavailable stays pending (0): the
// authority may already have taken the round, and its receipt carries the
// authoritative count. Reading that as lost would un-open the stroke and let
// a retry cost a second round.
simulated function byte ReadCycleEject(KFWeapon W, int Serial, out int Ammo, out int Reserve)
{
    Ammo = -1; Reserve = 0;
    if (LocalCyclePawn != HeldState.Human || HeldState.Human == None || Serial != LocalCycleSerial
        || LocalCycleWorld != WorldEpoch || LocalCycleConnection != ConnectionEpoch
        || LocalCyclePawnEpoch != PawnEpoch) return 3;
    if (CycleReceipt.Human != HeldState.Human || CycleReceipt.WorldEpoch != WorldEpoch
        || CycleReceipt.ConnectionEpoch != ConnectionEpoch || CycleReceipt.PawnEpoch != PawnEpoch
        || CycleReceipt.Weapon != W || CycleReceipt.Serial != Serial) return 0;
    if (CycleReceipt.bHaveAmmo) { Ammo = CycleReceipt.Ammo; Reserve = CycleReceipt.Reserve; }
    return CycleReceipt.bHaveAmmo ? CycleReceipt.Status : 3;
}

function FinishCycleEject(byte Status)
{
    CycleReceipt.Human = BoundPawn; CycleReceipt.Weapon = PendingCycleWeapon;
    CycleReceipt.WorldEpoch = PendingCycleWorld; CycleReceipt.ConnectionEpoch = PendingCycleConnection;
    CycleReceipt.PawnEpoch = PendingCyclePawn; CycleReceipt.Serial = PendingCycleSerial;
    CycleReceipt.Status = Status; CycleReceipt.bHaveAmmo = false;
    if (HeldInventory != None && HeldInventory.IsOwned(PendingCycleWeapon))
    {
        CycleReceipt.bHaveAmmo = true;
        CycleReceipt.Ammo = PendingCycleWeapon.AmmoCount[0];
        CycleReceipt.Reserve = PendingCycleWeapon.SpareAmmoCount[0];
        // This carries ordering only; matching native peers swallow its body.
        PendingCycleWeapon.ClientForceAmmoUpdate(-255, PendingCycleSerial);
    }
    PendingCycleWeapon = None; PendingCycleSerial = 0;
    bForceNetUpdate = true;
}

function UpdateCycleEject()
{
    local KF2VRNetItemRuntime R;
    local KFPawn_Human Body;
    local vector Position;
    local byte Pose;
    local int Revision, H;
    if (PendingCycleSerial <= 0) return;
    if (PendingCycleWeapon == None || PendingCycleWeapon.bDeleteMe) { FinishCycleEject(2); return; }
    if (!HeldCommandsAvailable() || !bVRTrackingEnabled || NativeWorldDropVersion != 9
        || PendingCycleWorld != WorldEpoch || PendingCycleConnection != ConnectionEpoch || PendingCyclePawn != PawnEpoch
        || HeldInventory.Snapshot.Revision != PendingCycleRevision || bInventoryFocusRequested
        || !class'VRPhysicalInteraction'.static.Allowed(BoundPawn)
        || (PendingCycleHand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) != PendingCycleWeapon
        || !ContactHand(PendingCycleHand, Body, Position, Pose, Revision) || Body != BoundPawn)
    { FinishCycleEject(2); return; }
    for (H = 0; H < 2; ++H)
        if (PairedStates[H].Weapon == PendingCycleWeapon
            && (PairedStates[H].Status == 1 || PairedStates[H].Status == 4)) { FinishCycleEject(2); return; }
    if (VampireState.Status == 1 || VampireState.Status == 4) { FinishCycleEject(2); return; }
    R = HeldInventory.RuntimeFor(PendingCycleWeapon);
    if (R == None || R.WorldDropped != 0 || R.WeaponBarrierSerial > PendingCycleSerial
        || WorldInfo.RealTimeSeconds >= PendingCycleDeadline) { FinishCycleEject(2); return; }
    // Waiting never suppresses earlier weapon handlers; they must reach the marker.
    if (R.WeaponBarrierSerial != PendingCycleSerial || !class'VRWeaponRuntime'.static.StockIdle(PendingCycleWeapon)) return;
    FinishCycleEject(class'VRWeaponActionBarrier'.static.Eject(PendingCycleWeapon, PendingCycleAmmo, PendingCycleCount) ? 1 : 2);
}

reliable server function ServerCycleEject(int WE, int CE, int PE, KFWeapon W, int Hand,
    int Serial, int ExpectedRevision, int ExpectedAmmo, int Count)
{
    if (WE != WorldEpoch || CE != ConnectionEpoch || PE != PawnEpoch || Serial <= LastCycleSerial
        || Serial <= 0 || Serial == MaxInt || PendingCycleWeapon != None) return;
    LastCycleSerial = Serial;
    PendingCycleWeapon = W; PendingCycleSerial = Serial; PendingCycleHand = Hand;
    PendingCycleWorld = WE; PendingCycleConnection = CE; PendingCyclePawn = PE;
    PendingCycleRevision = ExpectedRevision; PendingCycleAmmo = ExpectedAmmo; PendingCycleCount = Count;
    PendingCycleDeadline = WorldInfo.RealTimeSeconds + 1.0;
    if (W == None || Hand < 0 || Hand > 1 || Count <= 0
        || Count != Min(ExpectedAmmo, class'VRWeaponActionBarrier'.static.LiveRoundCount(W))) { FinishCycleEject(2); return; }
    UpdateCycleEject();
}

function NativeWorldDropUpdate() { NativeWorldDropVersion = 0; NativePouchAmmoVersion = 0; }

simulated function KF2VRNetPouchAmmo GetPouchAmmo()
{
    if (PouchAmmo == None) { PouchAmmo = new(self) class'KF2VRNetPouchAmmo'; PouchAmmo.Source = self; }
    return PouchAmmo;
}

simulated function bool DiscardPouchAmmo(KFWeapon W, int Count, byte Slot, vector At, rotator Facing, vector Velocity, float Scale)
{
    return GetPouchAmmo().Queue(W, Count, Slot, At, Facing, Velocity, Scale);
}

simulated function bool PouchAmmoPending()
{
    return PouchAmmo != None && PouchAmmo.Pending();
}

reliable server function ServerPouchDiscard(int WE, int CE, int PE, int Serial, KFWeapon W, int Count, byte Slot, vector At, rotator Facing, vector Velocity, float Scale)
{
    GetPouchAmmo().Begin(WE, CE, PE, Serial, W, Count, Slot, At, Facing, Velocity, Scale);
}

reliable client function ClientPouchCurrency(int WE, int CE, int PE, int Revision, float Score)
{
    GetPouchAmmo().ReceiveCurrency(WE, CE, PE, Revision, Score);
}

reliable client function ClientPouchDiscard(int WE, int CE, int PE, int Serial, KFWeapon W, int Actual,
    VRWeaponPair Pair, int Revision, int Reserve)
{
    GetPouchAmmo().Receive(WE, CE, PE, Serial, W, Actual, Pair, Revision, Reserve);
}

simulated function bool WorldDropPending()
{
    return (WorldDrops != None && !WorldDrops.bDeleteMe && WorldDrops.Busy())
        || (MagazineActions != None && !MagazineActions.bDeleteMe && MagazineActions.Busy());
}

function KF2VRNetItemRuntime WorldDropRuntime(KFWeapon W)
{
    return HeldInventory != None ? HeldInventory.RuntimeFor(W) : None;
}

function bool WorldDropIdentity(KFWeapon W, out int ItemId, out int ItemRevision)
{
    return HeldInventory != None && HeldInventory.DescribeItem(W, ItemId, ItemRevision);
}

function KF2VRNetTypes.NetWorldTransition CaptureWorldTransition(int Hand, int Generation,
    byte Action, int Request, int ItemId, VRWorldDropGun Prop, optional int ContactRequest)
{
    local KF2VRNetTypes.NetWorldTransition Empty;
    if (PublicPose == None) return Empty;
    return PublicPose.MakeWorldTransition(Hand, Generation, Action, Request, ItemId, Prop, ContactRequest);
}

function PublishWorldTransition(KF2VRNetTypes.NetWorldTransition Transition)
{
    if (PublicPose != None) PublicPose.PublishWorldTransition(Transition);
}

// 0 waits for earlier stock actions, 1 may commit, 2 rejects this lifetime.
function byte WorldReleaseReadiness(KFWeapon W, int Hand, int Revision, int Serial)
{
    local int Mode;
    local KF2VRNetItemRuntime R;
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || !HeldCommandsAvailable() || !bVRTrackingEnabled || NativeWorldDropVersion != 9
        || bInventoryFocusRequested || !class'VRPhysicalInteraction'.static.Allowed(BoundPawn)
        || Hand < 0 || Hand > 1 || W == None || W.bDeleteMe
        || (Hand == 0 ? HeldInventory.Snapshot.LeftGeneration : HeldInventory.Snapshot.RightGeneration) != Revision
        || (Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) != W)
        return 2;
    R = HeldInventory.RuntimeFor(W);
    if (R == None || R.NativeReady != 1 || R.WorldDropped != 0 || R.WeaponBarrierSerial > Serial) return 2;
    if (R.WeaponBarrierSerial != Serial || PendingCycleWeapon != None || R.MechanismPending != 0) return 0;
    if (!WorldPairedSessionsAllow(W, Hand)) return 0;
    if (VampireState.Status == 1 || VampireState.Status == 4) return 0;
    if (!class'VRWorldDropGun'.static.ReleaseActionReady(W)) return 0;
    for (Mode = 0; Mode < W.GetPendingFireLength(); ++Mode)
        if (W.PendingFire(byte(Mode))) return 0;
    return 1;
}

function bool ReleaseWorldWeapon(KFWeapon W, int Hand)
{
    local VRWeaponPair Pair;
    local int Serial;
    if (!class'VRWorldWeaponPolicy'.static.Enabled()
        || WorldDrops == None || WorldDrops.ReleaseToken(Hand) <= 0 || HeldInventory == None) return false;
    Serial = WorldDrops.ReleaseToken(Hand);
    WorldDropRuntime(W).WorldDropFireReadyAt = FMax(WorldDropRuntime(W).WorldDropFireReadyAt,
        WorldInfo.TimeSeconds + class'VRWorldDropGun'.static.RemainingFireDelay(W));
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None && !Pair.BeginWorldRelease(W, Serial)) return false;
    if (!HeldInventory.ReleaseForWorld(W, Hand))
    {
        if (Pair != None) Pair.ReturnWorldRelease(W, Serial);
        return false;
    }
    PublishHeldState();
    return true;
}

function bool ReceivesWorldDropPawn(KFPawn_Human P)
{
    return class'VRWorldWeaponPolicy'.static.Enabled()
        && P != None && P == BoundPawn && HeldCommandsAvailable() && bVRTrackingEnabled && !bSyntheticEnabled;
}

function RegisterWorldDropPair(VRWeaponPair Pair)
{
    if (!ReceivesWorldDropPawn(BoundPawn) || Pair == None || Pair.bDeleteMe
        || Pair.Role != ROLE_Authority || Pair.Human != BoundPawn || Pair.PairState != 2) return;
    if (WeaponPairs.Find(Pair) == INDEX_NONE) WeaponPairs.AddItem(Pair);
    Pair.RetireWorldDrops = RetirePairWorldDrops;
    KF2VRNetPlayerController(Owner).PairedCaseConverted(Pair);
}

function bool CanReceiveWorldContact(int Hand)
{
    local vector At;
    local KFPawn_Human Body;
    local byte Pose;
    local int Revision;
    if (!ReceivesWorldDropPawn(BoundPawn) || bInventoryFocusRequested || bReplacementPrepared
        || !class'VRPhysicalInteraction'.static.Allowed(BoundPawn) || Hand < 0 || Hand > 1
        || !ContactHand(Hand, Body, At, Pose, Revision) || Body != BoundPawn) return false;
    HeldInventory.Refresh();
    return HeldInventory.Snapshot.Revision > 0 && HeldInventory.Snapshot.Revision < MaxInt
        && (Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) == None;
}

function bool AdoptTransferredWorldWeapon(KFWeapon W, int Hand, byte GripRole)
{
    local KF2VRNetItemRuntime R;
    if (!ReceivesWorldDropPawn(BoundPawn) || bInventoryFocusRequested || Hand < 0 || Hand > 1
        || !class'VRPhysicalInteraction'.static.Allowed(BoundPawn) || GripRole > 1
        || (GripRole == 1 && (NativeCarryVersion != 1 || !class'VRHandsBridge'.static.SupportsCarryWeapon(W)))) return false;
    HeldInventory.Refresh();
    if ((Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) != None) return false;
    R = HeldInventory.RuntimeFor(W);
    if (R == None || R.NativeReady != 1 || R.MechanismPending != 0) return false;
    R.WorldDropped = 1;
    if (!HeldInventory.CatchFromWorld(W, Hand, GripRole)) { R.WorldDropped = 0; return false; }
    PublishHeldState();
    return true;
}

function bool PrepareWorldReplacement(KFWeapon W)
{
    local VRWorldDropGun Prop;
    local VRWeaponPair Pair;
    local KF2VRNetItemRuntime R;
    local VRWeaponDropState.HandlingState Empty;
    if (ReplacementPawn != BoundPawn) { bReplacementPrepared = false; ReplacementNewWeapon = None; }
    if (!ReceivesWorldDropPawn(BoundPawn) || bInventoryFocusRequested || bReplacementPrepared
        || ReplacementTransaction == MaxInt || WorldDrops == None || WorldDrops.Busy()
        || !class'VRPhysicalInteraction'.static.Allowed(BoundPawn)) return false;
    HeldInventory.Refresh();
    R = HeldInventory.RuntimeFor(W);
    if (R == None || R.NativeReady != 1 || R.MechanismPending != 0
        || HeldInventory.Snapshot.Revision >= MaxInt - 2) return false;
    ReplacementOldWeapon = W; ReplacementOldName = W.Name;
    ReplacementHand = HeldInventory.Snapshot.LeftWeapon == W ? 0 : (HeldInventory.Snapshot.RightWeapon == W ? 1 : -1);
    ReplacementRole = ReplacementHand >= 0 ? int((HeldInventory.Snapshot.CarryMask & (1 << ReplacementHand)) != 0) : 0;
    bReplacementDropped = R.WorldDropped != 0;
    ReplacementHandling = Empty;
    ReplacementHandling.Family = class'VRWeaponDropState'.static.FamilyFor(W.Class);
    if (WorldDrops.Registry != None) Prop = WorldDrops.Registry.Find(W);
    if (Prop != None) ReplacementHandling = Prop.Handling;
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if ((MagazineActions != None && MagazineActions.WellFor(W) >= 0)
        || (Pair != None && Pair.MagazineWellOpen(W)))
    {
        if (class'VRWeaponRuntime'.static.TracksMagazineFeedClass(ReplacementHandling.Family))
        { ReplacementHandling.FeedFlags = ReplacementHandling.FeedFlags | 3; ReplacementHandling.EmptyMagazineFlags = 0; }
        else ReplacementHandling.EmptyMagazineFlags = ReplacementHandling.EmptyMagazineFlags | 1;
    }
    if (!class'VRWeaponDropState'.static.Canonicalize(W, ReplacementHandling)) return false;
    ReplacementFireReadyAt = FMax(R.WorldDropFireReadyAt,
        WorldInfo.TimeSeconds + class'VRWorldDropGun'.static.RemainingFireDelay(W));
    ReplacementPawn = BoundPawn; ReplacementNewWeapon = None; ReplacementMarker = 0;
    ++ReplacementTransaction;
    bReplacementPrepared = true;
    ReplacementPreparedAt = WorldInfo.RealTimeSeconds;
    return true;
}

function FinishWorldReplacement(KFWeapon OldWeapon, KFWeapon NewWeapon)
{
    local KF2VRNetItemRuntime R;
    if (!bReplacementPrepared || ReplacementPawn != BoundPawn
        || (OldWeapon != ReplacementOldWeapon && (OldWeapon == None || OldWeapon.Name != ReplacementOldName))) return;
    if (NewWeapon == None || !class'VRWorldDropTransfer'.static.Owns(BoundPawn, NewWeapon))
    { bReplacementPrepared = false; ReplacementNewWeapon = None; return; }
    HeldInventory.Refresh();
    R = HeldInventory.RuntimeFor(NewWeapon);
    if (R == None) { bReplacementPrepared = false; return; }
    ReplacementNewWeapon = NewWeapon;
    AdoptWorldDropHandling(NewWeapon, ReplacementHandling);
    // Until the owner arms the exact new actor's receipt, it has no held role
    // and stock offensive/reload RPCs remain fenced on authority.
    R.WorldDropped = 1; R.CarryOnly = 1;
    R.WorldDropFireReadyAt = ReplacementFireReadyAt;
    ClientBeginWorldReplacement(WorldEpoch, ConnectionEpoch, PawnEpoch, ReplacementTransaction,
        OldWeapon, ReplacementOldName, NewWeapon, ReplacementHandling,
        FMax(0.0, ReplacementFireReadyAt - WorldInfo.TimeSeconds), bReplacementDropped);
}

reliable client function ClientBeginWorldReplacement(int WE, int CE, int PE, int Transaction,
    KFWeapon OldWeapon, name ExactOldName, KFWeapon NewWeapon, VRWeaponDropState.HandlingState Handling,
    float FireDelay, bool bDropped)
{
    if (WE != WorldEpoch || CE != ConnectionEpoch || PE != PawnEpoch || Transaction <= 0
        || (LocalReplacementTransaction > 0 && LocalReplacementTransaction != Transaction)) return;
    if (LocalReplacementTransaction == Transaction) return;
    LocalReplacementTransaction = Transaction;
    bLocalReplacementHandlingCaptured = false;
    LocalReplacementWorld = WE; LocalReplacementConnection = CE; LocalReplacementPawnEpoch = PE;
    LocalReplacementOld = OldWeapon; LocalReplacementOldName = ExactOldName; LocalReplacementNew = NewWeapon;
    LocalReplacementHandling = Handling; bLocalReplacementDropped = bDropped;
    LocalReplacementFireReadyAt = WorldInfo.TimeSeconds + FMax(FireDelay, 0.0);
    LocalReplacementStartedAt = WorldInfo.RealTimeSeconds;
}

reliable server function ServerReadyWorldReplacement(int WE, int CE, int PE, int Transaction, int Serial)
{
    local KF2VRNetItemRuntime R;
    if (WE != WorldEpoch || CE != ConnectionEpoch || PE != PawnEpoch || !bReplacementPrepared
        || ReplacementPawn != BoundPawn || Transaction != ReplacementTransaction
        || Serial <= 0 || Serial == MaxInt || (ReplacementMarker != 0 && Serial < ReplacementMarker)) return;
    if (!class'VRWorldDropTransfer'.static.Owns(BoundPawn, ReplacementNewWeapon))
    { CancelWorldReplacement(); return; }
    HeldInventory.Refresh();
    R = HeldInventory.RuntimeFor(ReplacementNewWeapon);
    if (R == None) return;
    ReplacementMarker = Serial;
    if (ReplacementHand >= 0 && HeldCommandsAvailable() && !bInventoryFocusRequested
        && class'VRPhysicalInteraction'.static.Allowed(BoundPawn)
        && (ReplacementHand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) == None
        && (ReplacementRole == 0 || NativeCarryVersion == 1))
    {
        R.WorldDropped = 1;
        if (!HeldInventory.CatchFromWorld(ReplacementNewWeapon, ReplacementHand, byte(ReplacementRole)))
            R.WorldDropped = int(bReplacementDropped);
    }
    else R.WorldDropped = int(bReplacementDropped);
    PublishHeldState();
    ReplacementNewWeapon.ClientForceAmmoUpdate(-255, Serial);
}

reliable server function ServerFinishWorldReplacement(int WE, int CE, int PE, int Transaction, int Serial)
{
    if (WE != WorldEpoch || CE != ConnectionEpoch || PE != PawnEpoch || !bReplacementPrepared
        || Transaction != ReplacementTransaction || Serial != ReplacementMarker) return;
    bReplacementPrepared = false; ReplacementOldWeapon = None; ReplacementNewWeapon = None;
}

simulated function ClearLocalWorldReplacement()
{
    if (LocalReplacementLedger != None) LocalReplacementLedger.ForgetTransferReceipt(LocalReplacementSerial);
    LocalReplacementLedger = None; LocalReplacementTransaction = 0; LocalReplacementSerial = 0;
    LocalReplacementOld = None; LocalReplacementNew = None;
    bLocalReplacementHandlingCaptured = false;
}

simulated function bool WorldReplacementPending()
{
    if (LocalReplacementTransaction > 0 && (LocalReplacementWorld != WorldEpoch
        || LocalReplacementConnection != ConnectionEpoch || LocalReplacementPawnEpoch != PawnEpoch)) ClearLocalWorldReplacement();
    // A new weapon that never replicates (or was removed) must not fence
    // every owner action; the authority cancels its side on its own deadline.
    if (LocalReplacementTransaction > 0 && WorldInfo.RealTimeSeconds - LocalReplacementStartedAt > 10.0)
    {
        `log("KF2VRNet owner_wait phase=expired kind=replacement transaction=" $ LocalReplacementTransaction
            @ "new=" $ LocalReplacementNew);
        ClearLocalWorldReplacement();
    }
    return LocalReplacementTransaction > 0;
}

// While prepared, this player can catch no world gun or stock pickup and no one
// can catch theirs. A new pawn or a missing owner answer (the client gives up
// at 10 s) must not hold that refusal for the rest of the match.
function UpdateWorldReplacementLease()
{
    if (!bReplacementPrepared
        || (ReplacementPawn == BoundPawn && WorldInfo.RealTimeSeconds - ReplacementPreparedAt <= 15.0)) return;
    `log("KF2VRNet owner_wait phase=expired kind=replacement_authority transaction=" $ ReplacementTransaction
        @ "pawn_changed=" $ (ReplacementPawn != BoundPawn));
    CancelWorldReplacement();
}

function CancelWorldReplacement()
{
    local KF2VRNetItemRuntime R;
    if (!bReplacementPrepared) return;
    if (HeldInventory != None) R = HeldInventory.RuntimeFor(ReplacementNewWeapon);
    if (R != None) R.WorldDropped = int(bReplacementDropped);
    ClientCancelWorldReplacement(WorldEpoch, ConnectionEpoch, PawnEpoch, ReplacementTransaction);
    bReplacementPrepared = false; ReplacementOldWeapon = None; ReplacementNewWeapon = None;
}

reliable client function ClientCancelWorldReplacement(int WE, int CE, int PE, int Transaction)
{
    if (WE == LocalReplacementWorld && CE == LocalReplacementConnection && PE == LocalReplacementPawnEpoch
        && Transaction == LocalReplacementTransaction) ClearLocalWorldReplacement();
}

simulated function bool ReadWorldReplacement(VRHeldInventory Ledger, out KFWeapon W,
    out VRWeaponDropState.HandlingState Handling, out float FireDelay)
{
    local VRWeaponRuntime R;
    local VRWeaponDropState.HandlingState Cached;
    local int I;
    W = None;
    if (!WorldReplacementPending()) return false;
    if (LocalReplacementWorld != WorldEpoch || LocalReplacementConnection != ConnectionEpoch
        || LocalReplacementPawnEpoch != PawnEpoch || HeldState.Human == None
        || HeldState.Human.Health <= 0 || Ledger == None || Ledger.Human != HeldState.Human)
    { ClearLocalWorldReplacement(); return false; }
    if (LocalReplacementNew == None || LocalReplacementNew.bDeleteMe) return false;
    if (!bLocalReplacementHandlingCaptured)
    {
        // Move an exact cached old snapshot into this transaction promptly;
        // marker/streaming delays must not outlive the bounded removal cache.
        if (Ledger.TakeRemovedHandling(LocalReplacementOld, Cached, LocalReplacementOldName)
            && Cached.Family == class'VRWeaponDropState'.static.FamilyFor(LocalReplacementNew.Class))
        {
            LocalReplacementHandling = Cached;
            bLocalReplacementHandlingCaptured = true;
        }
        else
        {
            // The owner-channel notice may precede stock removal on the old
            // weapon channel. Capture that exact still-live runtime now, or
            // keep waiting for its retirement cache on subsequent polls.
            for (I = 0; I < Ledger.Items.Length; ++I)
            {
                R = Ledger.Items[I];
                if (R == None || R.Item == None || (R.Item != LocalReplacementOld
                    && R.Item.Name != LocalReplacementOldName)) continue;
                if (class'VRWeaponDropState'.static.CaptureForReplacement(R, Cached)
                    && Cached.Family == class'VRWeaponDropState'.static.FamilyFor(LocalReplacementNew.Class))
                {
                    LocalReplacementHandling = Cached;
                    bLocalReplacementHandlingCaptured = true;
                }
                break;
            }
        }
    }
    if (LocalReplacementLedger != None && LocalReplacementLedger != Ledger)
    {
        LocalReplacementLedger.ForgetTransferReceipt(LocalReplacementSerial);
        LocalReplacementLedger = None; LocalReplacementSerial = 0;
    }
    if (LocalReplacementSerial == 0)
    {
        LocalReplacementSerial = NextWeaponActionSerial();
        if (LocalReplacementSerial <= 0) return false;
        if (!Ledger.ExpectTransferReceipt(LocalReplacementSerial, LocalReplacementNew))
        { LocalReplacementSerial = 0; return false; }
        LocalReplacementLedger = Ledger;
        ServerReadyWorldReplacement(WorldEpoch, ConnectionEpoch, PawnEpoch, LocalReplacementTransaction, LocalReplacementSerial);
    }
    if (!Ledger.TransferReceiptReady(LocalReplacementNew, LocalReplacementSerial)) return false;
    R = Ledger.RegisterItem(LocalReplacementNew);
    if (R == None) return false;
    Handling = LocalReplacementHandling;
    if (!class'VRWeaponDropState'.static.Canonicalize(LocalReplacementNew, Handling)) return false;
    R.WorldDropped = int(bLocalReplacementDropped);
    if (bLocalReplacementDropped) R.WorldDropLifetime = WorldDrops;
    if (WorldDrops != None) WorldDrops.RemapDroppedIdentity(LocalReplacementOld, LocalReplacementNew, bLocalReplacementDropped);
    W = LocalReplacementNew;
    FireDelay = FMax(0.0, LocalReplacementFireReadyAt - WorldInfo.TimeSeconds);
    ServerFinishWorldReplacement(WorldEpoch, ConnectionEpoch, PawnEpoch, LocalReplacementTransaction, LocalReplacementSerial);
    ClearLocalWorldReplacement();
    return true;
}

function PublishWorldDeathLoot()
{
    if (Role == ROLE_Authority && BoundPawn != None && BoundPawn.Health <= 0
        && WorldDrops != None && WorldDrops.Registry != None) WorldDrops.Registry.PublishDeathLoot();
}

function AdoptWorldDropHandling(KFWeapon W, VRWeaponDropState.HandlingState Handling)
{
    if (MagazineActions != None) MagazineActions.AdoptTransferredWell(W, Handling);
}

function bool CatchWorldWeapon(KFPawn_Human Catcher, KFWeapon W, int Hand, byte GripRole,
    vector RootPosition, quat RootRotation)
{
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || Catcher != BoundPawn || !HeldCommandsAvailable() || bInventoryFocusRequested
        || !class'VRPhysicalInteraction'.static.Allowed(BoundPawn) || HeldInventory == None || GripRole > 1
        || (GripRole == 1 && NativeCarryVersion != 1))
    {
        `log("KF2VR_WORLD_DROP phase=channel-catch-refused hand=" $ Hand @ "catcher_bound=" $ (Catcher == BoundPawn)
            @ "held_commands=" $ HeldCommandsAvailable() @ "focus=" $ bInventoryFocusRequested
            @ "physical=" $ class'VRPhysicalInteraction'.static.Allowed(BoundPawn) @ "held=" $ (HeldInventory != None)
            @ "role=" $ GripRole @ "carry_version=" $ NativeCarryVersion);
        return false;
    }
    if (!HeldInventory.CatchFromWorld(W, Hand, GripRole)) return false;
    PublishHeldState();
    return true;
}

function RetireWorldWeapon(KFWeapon W, byte Reason)
{
    local VRWeaponPair Pair;
    local KF2VRNetItemRuntime R;
    local VRWorldDropGun Prop;
    local int I;
    // Registry removes its slot before this callback, but the exact body is
    // still alive. Close remote presentation before recall or retirement.
    if (Reason != 1 && WorldDrops != None && WorldDrops.Registry != None)
        foreach WorldInfo.AllActors(class'VRWorldDropGun', Prop)
            if (Prop.OwnedWeapon == W && Prop.SourceRegistry == WorldDrops.Registry && !Prop.bDeleteMe)
            {
                PublishWorldTransition(CaptureWorldTransition(-1, 0, 2, Prop.ReleaseRequestId,
                    Prop.ReleasedItemId, Prop));
                break;
            }
    R = WorldDropRuntime(W);
    if (R != None) R.WorldDropped = 0;
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None)
    {
        I = Pair.PhysicalMemberIndex(W);
        if (I >= 0 && Pair.WorldDropToken[I] > 0) Pair.ReturnWorldRelease(W, Pair.WorldDropToken[I]);
    }
}

function bool RetirePairWorldDrops(VRWeaponPair Pair)
{
    local int I;
    if (Pair == None || Pair.Human != BoundPawn || WorldDrops == None || WorldDrops.Registry == None) return false;
    for (I = 0; I < 2; ++I) WorldDrops.Registry.InvalidateWeapon(Pair.Members[I]);
    return Pair.WorldDropToken[0] == 0 && Pair.WorldDropToken[1] == 0;
}

function UpdateWorldDropAuthority()
{
    local int I;
    if (HeldInventory == None || BoundPawn == None || NativeWorldDropVersion != 9
        || !bVRTrackingEnabled || bSyntheticEnabled) return;
    // Paid magazines use the native weapon-action capability even while the
    // optional world-weapon interactions are disabled or fail to initialize.
    if (MagazineActions == None || MagazineActions.bDeleteMe)
    {
        MagazineActions = Spawn(class'KF2VRNetMagazineChannel', Owner);
        if (MagazineActions != None && !MagazineActions.Initialize(self, BoundPawn))
        { MagazineActions.Destroy(); MagazineActions = None; }
        bForceNetUpdate = true;
    }
    // This channel also carries magazine recovery; its weapon admission is
    // gated separately from that shared transport and registry lifetime.
    if (WorldDrops == None || WorldDrops.bDeleteMe)
    {
        WorldDrops = Spawn(class'KF2VRNetWorldDropChannel', Owner);
        if (WorldDrops == None) return;
        if (!WorldDrops.Initialize(self, BoundPawn)) { WorldDrops.Destroy(); WorldDrops = None; return; }
        WorldDrops.Registry.ReleaseHeldWeapon = ReleaseWorldWeapon;
        WorldDrops.Registry.CatchHeldWeapon = CatchWorldWeapon;
        WorldDrops.Registry.OnRetired = RetireWorldWeapon;
        WorldDrops.Registry.Handoff.PrepareReplacement = PrepareWorldReplacement;
        WorldDrops.Registry.Handoff.FinishReplacement = FinishWorldReplacement;
        HeldInventory.OnWorldItemRemoved = InvalidateWorldItem;
        bForceNetUpdate = true;
    }
    if (MagazineActions != None && MagazineActions.Registry != None)
        MagazineActions.Registry.SetSharingSource(WorldDrops.Registry);
    for (I = 0; I < WeaponPairs.Length; ++I)
        if (WeaponPairs[I] != None && !WeaponPairs[I].bDeleteMe)
            WeaponPairs[I].RetireWorldDrops = RetirePairWorldDrops;
}

function InvalidateWorldItem(KFWeapon W)
{
    if (bReplacementPrepared && W == ReplacementNewWeapon) CancelWorldReplacement();
    if (WorldDrops != None && WorldDrops.Registry != None) WorldDrops.Registry.InvalidateWeapon(W);
    if (MagazineActions != None) MagazineActions.InvalidateWeapon(W);
}

// Called only after the world-action result AND its weapon return marker.
// Reconcile both hands atomically; a newer authority revision wins.
simulated function bool AdoptWorldDropHeldState(KF2VRNetTypes.NetHeldState Snapshot)
{
    if (Snapshot.Human == None || Snapshot.Human != HeldState.Human || Snapshot.Revision <= 0
        || Snapshot.Revision < HeldState.Revision) return false;
    HeldState = Snapshot;
    PredictedHeldPawn = Snapshot.Human;
    LocalHeldRequest = Max(LocalHeldRequest, Snapshot.AcknowledgedRequest);
    PredictedLeft = Snapshot.LeftWeapon; PredictedRight = Snapshot.RightWeapon;
    PredictedCarryMask = Snapshot.CarryMask;
    PredictedShieldHandToken = Snapshot.ShieldHandToken;
    return true;
}

function NativeSupportCarryUpdate()
{
    NativeCarryVersion = 0;
}

replication
{
    if (Role == ROLE_Authority && bNetOwner)
        WorldEpoch, ConnectionEpoch, PawnEpoch, CalibrationEpoch,
        ReloadCase, bSyntheticAllowed, bMotionReplayAllowed, bMotionReplayEnabled, bMotionResetPassed, bMotionResetFailed, MotionResetId, bDiagnosticAutoReady, bDiagnosticPerkReady, bDiagnosticClientsReady,
        bHandshakeAccepted, bHandshakeRejected, bSyntheticEnabled, bVRTrackingEnabled,
        AcceptedPoses, RejectedPoses, LastAcceptedSequence, HeldState, GrenadeState, VampireState, PairedStates, BowState, CycleReceipt, WorldDrops, MagazineActions,
        bMultiplayerZedGrabAllowed, bGrabOptIn, GrabPolicyEpoch, bInteractionOptIn;
}

simulated function UpdateGrabIntent(bool bOptIn, optional bool bInteractions, optional bool bZedGrabs)
{
    if (bLastGrabIntent != bOptIn || bLastInteractionIntent != bInteractions || bLastZedGrabIntent != bZedGrabs || WorldInfo.RealTimeSeconds >= NextGrabIntent)
    {
        ServerGrabIntent(WorldEpoch, ConnectionEpoch, PawnEpoch, bOptIn, bInteractions, bZedGrabs);
        bLastGrabIntent = bOptIn;
        bLastInteractionIntent = bInteractions;
        bLastZedGrabIntent = bZedGrabs;
        NextGrabIntent = WorldInfo.RealTimeSeconds + 0.5;
    }
}

reliable server function ServerGrabIntent(int W, int C, int P, bool bOptIn, optional bool bInteractions, optional bool bZedGrabs)
{
    if (W != WorldEpoch || C != ConnectionEpoch || P != PawnEpoch) return;
    bInteractionOptIn = class'VRExperimentalPolicy'.static.InteractionsEnabled()
        && bOptIn && bInteractions && IsInventoryFocusEligible();
    InteractionIntentPawnEpoch = PawnEpoch;
    InteractionOptInLease = bInteractionOptIn ? WorldInfo.RealTimeSeconds + 1.0 : 0.0;
    bForceNetUpdate = true;
    if (!class'VRExperimentalPolicy'.static.ZedGrabbingEnabled() || !bZedGrabs || !bOptIn
        || KF2VRNetGame(WorldInfo.Game) == None || !KF2VRNetGame(WorldInfo.Game).bMultiplayerZedGrabAllowed
        || !IsInventoryFocusEligible()) { RevokeGrabIntent(); return; }
    if (!bGrabOptIn) { ++GrabPolicyEpoch; bForceNetUpdate = true; }
    bGrabOptIn = true;
    GrabIntentPawnEpoch = PawnEpoch;
    GrabOptInLease = WorldInfo.RealTimeSeconds + 1.0;
}

function RevokeGrabIntent()
{
    if (bGrabOptIn) { ++GrabPolicyEpoch; bForceNetUpdate = true; }
    bGrabOptIn = false;
    GrabOptInLease = 0;
    if (KF2VRNetPlayerController(Owner) != None)
        KF2VRNetPlayerController(Owner).ReleaseAllServerGrabs();
}

function bool ExperimentalInteractionsAllowed()
{
    return class'VRExperimentalPolicy'.static.InteractionsEnabled()
        && Role == ROLE_Authority && bInteractionOptIn && InteractionIntentPawnEpoch == PawnEpoch
        && WorldInfo.RealTimeSeconds < InteractionOptInLease && IsInventoryFocusEligible();
}

function bool PhysicalHandEligible(byte Hand, vector HitLocation)
{
    local vector HandLocation;
    if (Role != ROLE_Authority || Hand > 1 || !IsInventoryFocusEligible() || HeldInventory == None
        || !class'VRPhysicalInteraction'.static.Allowed(BoundPawn)
        || (PublicPose.Snapshot.Sample.TrackingFlags & (2 << Hand)) == 0) return false;
    HeldInventory.Refresh();
    if ((Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) != None) return false;
    HandLocation = BoundPawn.Location + ((Hand == 0 ? PublicPose.Snapshot.Sample.LeftPosition
        : PublicPose.Snapshot.Sample.RightPosition) >> PublicPose.Snapshot.RootRotation);
    return class'VRGrenadeThrow'.static.Bounded(HitLocation - HandLocation, 200);
}

function bool GrabCommandsAllowed()
{
    local KF2VRNetGame Game;
    Game = KF2VRNetGame(WorldInfo.Game);
    return class'VRExperimentalPolicy'.static.ZedGrabbingEnabled() && Role == ROLE_Authority
        && Game != None && Game.bMultiplayerZedGrabAllowed
        && bGrabOptIn && GrabIntentPawnEpoch == PawnEpoch && WorldInfo.RealTimeSeconds < GrabOptInLease && IsInventoryFocusEligible()
        && class'VRPhysicalInteraction'.static.Allowed(BoundPawn)
        && (PublicPose.Snapshot.Sample.TrackingFlags & 7) == 7;
}

function Initialize(int NewWorldEpoch, int NewConnectionEpoch,
    bool bAllowSynthetic, bool bAutoReady)
{
    if (Role != ROLE_Authority || KF2VRNetPlayerController(Owner) == None)
    {
        return;
    }
    WorldEpoch = NewWorldEpoch;
    ConnectionEpoch = NewConnectionEpoch;
    bSyntheticAllowed = bAllowSynthetic;
    bMotionReplayAllowed = bAllowSynthetic && KF2VRNetGame(WorldInfo.Game) != None
        && KF2VRNetGame(WorldInfo.Game).bAllowMotionReplay;
    bDiagnosticAutoReady = bAutoReady;
    NextPawnEpoch = 1;
    LastModeChangeRealTime = -1.0;
    bForceNetUpdate = true;
    `log("KF2VRNet channel world=" $ WorldEpoch $ " connection="
        $ ConnectionEpoch $ " owner=" $ Owner $ " role=" $ Role);
}

reliable server function ServerHello(int ClientProtocol, int ClientRevision)
{
    if (Role != ROLE_Authority || Owner == None || WorldEpoch == 0
        || bHandshakeAccepted || bHandshakeRejected)
    {
        return;
    }
    bHandshakeAccepted = ClientProtocol == class'KF2VRNetTypes'.const.ProtocolVersion
        && ClientRevision == class'KF2VRNetTypes'.const.PackageRevision;
    bHandshakeRejected = !bHandshakeAccepted;
    bForceNetUpdate = true;
    `log("KF2VRNet hello world=" $ WorldEpoch $ " connection=" $ ConnectionEpoch
        $ " accepted=" $ bHandshakeAccepted $ " protocol=" $ ClientProtocol
        $ " revision=" $ ClientRevision $ " netmode=" $ WorldInfo.NetMode);
}

reliable server function ServerSetSyntheticEnabled(int InWorldEpoch,
    int InConnectionEpoch, bool bEnabled)
{
    if (!bHandshakeAccepted || InWorldEpoch != WorldEpoch
        || InConnectionEpoch != ConnectionEpoch || !bSyntheticAllowed)
    {
        return;
    }
    // Disable is always accepted; repeated enable cannot reset packet budgets.
    if (bEnabled && WorldInfo.RealTimeSeconds - LastModeChangeRealTime < 0.25)
    {
        return;
    }
    LastModeChangeRealTime = WorldInfo.RealTimeSeconds;
    bSyntheticEnabled = bEnabled;
    if (bEnabled) bVRTrackingEnabled = false;
    if (!bEnabled && PublicPose != None)
    {
        PublicPose.ExpirePose();
    }
    bForceNetUpdate = true;
    `log("KF2VRNet synthetic world=" $ WorldEpoch $ " connection="
        $ ConnectionEpoch $ " enabled=" $ bSyntheticEnabled);
}

simulated function UpdateInventoryFocusIntent(bool bOpen)
{
    local KF2VRNetPlayerController PC;
    local KFPawn_Human LocalPawn;
    local float Now;
    PC = KF2VRNetPlayerController(Owner);
    if (PC != None)
        LocalPawn = KFPawn_Human(PC.Pawn);
    bOpen = bOpen && WorldInfo.NetMode == NM_Client && PC != None
        && PC.IsLocalPlayerController() && !PC.bDeleteMe && bHandshakeAccepted
        && bVRTrackingEnabled && WorldEpoch != 0 && ConnectionEpoch != 0 && PawnEpoch != 0
        && LocalPawn != None && LocalPawn.Health > 0 && !LocalPawn.bDeleteMe;
    Now = WorldInfo.RealTimeSeconds;
    if (bOpen != bLocalInventoryFocusOpen || (bOpen
        && (Now >= NextInventoryFocusRefresh || WorldEpoch != LocalFocusWorldEpoch
            || ConnectionEpoch != LocalFocusConnectionEpoch || PawnEpoch != LocalFocusPawnEpoch)))
    {
        ServerSetInventoryFocus(WorldEpoch, ConnectionEpoch, PawnEpoch, bOpen);
        NextInventoryFocusRefresh = Now + 0.5;
        LocalFocusWorldEpoch = WorldEpoch;
        LocalFocusConnectionEpoch = ConnectionEpoch;
        LocalFocusPawnEpoch = PawnEpoch;
    }
    bLocalInventoryFocusOpen = bOpen;
}

function bool HasValidInventoryFocusRequest()
{
    return Role == ROLE_Authority && bInventoryFocusRequested
        && WorldInfo.RealTimeSeconds < InventoryFocusLeaseUntil
        && IsInventoryFocusEligible();
}

function bool IsInventoryFocusEligible()
{
    local KF2VRNetPlayerController PC;
    PC = KF2VRNetPlayerController(Owner);
    return PC != None && !PC.bDeleteMe && BoundPawn != None && PC.Pawn == BoundPawn
        && BoundPawn.Controller == PC && BoundPawn.Health > 0 && !BoundPawn.bDeleteMe
        && bHandshakeAccepted && bVRTrackingEnabled && !bSyntheticEnabled
        && PublicPose != None && (PublicPose.Snapshot.Sample.TrackingFlags & 1) != 0
        && WorldInfo.RealTimeSeconds - LastAcceptedRealTime <= class'KF2VRNetTypes'.const.PoseLeaseSeconds;
}

reliable server function ServerSetInventoryFocus(int RequestWorldEpoch, int RequestConnectionEpoch,
    int RequestPawnEpoch, bool bOpen)
{
    local float Now;
    if (!bOpen)
    {
        bInventoryFocusRequested = false;
        InventoryFocusLeaseUntil = 0.0;
    }
    Now = WorldInfo.RealTimeSeconds;
    if (Now - InventoryFocusRateStart >= 1.0)
    {
        InventoryFocusRateStart = Now;
        InventoryFocusRateCount = 0;
    }
    ++InventoryFocusRateCount;
    if (!bOpen || InventoryFocusRateCount > 8) return;
    if (RequestWorldEpoch != WorldEpoch || RequestConnectionEpoch != ConnectionEpoch
        || RequestPawnEpoch != PawnEpoch || WorldEpoch == 0 || ConnectionEpoch == 0 || PawnEpoch == 0
        || !IsInventoryFocusEligible()) return;
    bInventoryFocusRequested = true;
    InventoryFocusLeaseUntil = Now + 1.0;
}

reliable server function ServerSetVRTrackingEnabled(bool bEnabled)
{
    if (!bEnabled)
    {
        bInventoryFocusRequested = false;
        InventoryFocusLeaseUntil = 0.0;
    }
    if (!bHandshakeAccepted) return;
    bVRTrackingEnabled = bEnabled;
    if (bEnabled) bSyntheticEnabled = false;
    else if (PublicPose != None) PublicPose.ExpirePose();
    bForceNetUpdate = true;
}

// Two bounded snapshots per failed reset: restoration and final failure only.
function LogMotionResetState(string Phase)
{
    local bool bPawnValid, bPawnDeleted, bRootPassed, bRotationPassed, bPhysicsPassed, bVelocityPassed;
    local bool bCrouchPassed, bWantsCrouchPassed, bEyePassed;
    if (MotionResetPawn != None) bPawnDeleted = MotionResetPawn.bDeleteMe;
    bPawnValid = MotionResetPawn != None && !bPawnDeleted;
    if (bPawnValid)
    {
        bRootPassed = VSize(MotionResetPawn.Location - MotionSavedRoot) < 0.1;
        bRotationPassed = Normalize(MotionResetPawn.Rotation - MotionSavedRotation) == rot(0,0,0);
        bPhysicsPassed = MotionResetPawn.Physics == MotionSavedPhysics;
        bVelocityPassed = VSize(MotionResetPawn.Velocity - MotionSavedVelocity) < 0.1;
        bCrouchPassed = MotionResetPawn.bIsCrouched == bMotionSavedCrouch;
        bWantsCrouchPassed = MotionResetPawn.bWantsToCrouch == bMotionSavedCrouch;
        bEyePassed = Abs(MotionResetPawn.BaseEyeHeight - MotionSavedEyeHeight) < 0.01;
    }
    `log("KF2VRNet motion_reset_state replay=" $ MotionReplayId $ " stage=" $ Phase
        $ " time=" $ WorldInfo.RealTimeSeconds $ " deadline=" $ MotionResetDeadline
        $ " placed=" $ bMotionResetPlaced $ " rotated=" $ bMotionResetRotated
        $ " pawn=" $ MotionResetPawn $ " pawn_exists=" $ (MotionResetPawn != None)
        $ " pawn_deleted=" $ bPawnDeleted $ " pawn_valid=" $ bPawnValid
        $ " root_passed=" $ bRootPassed $ " rotation_passed=" $ bRotationPassed
        $ " physics_passed=" $ bPhysicsPassed $ " velocity_passed=" $ bVelocityPassed
        $ " crouch_passed=" $ bCrouchPassed $ " wants_crouch_passed=" $ bWantsCrouchPassed $ " eye_passed=" $ bEyePassed);
    `log("KF2VRNet motion_reset_expected replay=" $ MotionReplayId $ " stage=" $ Phase
        $ " root=" $ MotionSavedRoot $ " rotation=" $ MotionSavedRotation
        $ " physics=" $ MotionSavedPhysics $ " velocity=" $ MotionSavedVelocity
        $ " crouch=" $ bMotionSavedCrouch $ " wants_crouch=" $ bMotionSavedCrouch $ " eye=" $ MotionSavedEyeHeight);
    if (bPawnValid)
        `log("KF2VRNet motion_reset_actual replay=" $ MotionReplayId $ " stage=" $ Phase
            $ " root=" $ MotionResetPawn.Location $ " root_error=" $ VSize(MotionResetPawn.Location - MotionSavedRoot)
            $ " rotation=" $ MotionResetPawn.Rotation $ " rotation_delta=" $ Normalize(MotionResetPawn.Rotation - MotionSavedRotation)
            $ " physics=" $ MotionResetPawn.Physics $ " velocity=" $ MotionResetPawn.Velocity
            $ " velocity_error=" $ VSize(MotionResetPawn.Velocity - MotionSavedVelocity)
            $ " crouch=" $ MotionResetPawn.bIsCrouched $ " wants_crouch=" $ MotionResetPawn.bWantsToCrouch
            $ " eye=" $ MotionResetPawn.BaseEyeHeight $ " eye_error=" $ Abs(MotionResetPawn.BaseEyeHeight - MotionSavedEyeHeight));
}

function CompleteMotionReset(bool bPassed)
{
    if (!bPassed) LogMotionResetState("failure");
    bMotionResetPending = false;
    MotionResetId = MotionReplayId;
    bMotionResetPassed = bPassed;
    bMotionResetFailed = bMotionResetFailed || !bPassed;
    bForceNetUpdate = true;
    `log("KF2VRNet motion_reset replay=" $ MotionResetId $ " passed=" $ bPassed
        $ " reason=" $ MotionResetReason $ " time=" $ WorldInfo.RealTimeSeconds);
}

function VerifyMotionReset()
{
    local bool bPassed;
    if (!bMotionResetPending) return;
    bPassed = MotionResetPawn != None && !MotionResetPawn.bDeleteMe
        && VSize(MotionResetPawn.Location - MotionSavedRoot) < 0.1
        && Normalize(MotionResetPawn.Rotation - MotionSavedRotation) == rot(0,0,0)
        && MotionResetPawn.Physics == MotionSavedPhysics
        && VSize(MotionResetPawn.Velocity - MotionSavedVelocity) < 0.1
        && MotionResetPawn.bIsCrouched == bMotionSavedCrouch
        && MotionResetPawn.bWantsToCrouch == bMotionSavedCrouch
        && Abs(MotionResetPawn.BaseEyeHeight - MotionSavedEyeHeight) < 0.01;
    if (bPassed || WorldInfo.RealTimeSeconds >= MotionResetDeadline)
        CompleteMotionReset(bPassed);
}

function EndMotionReplay(string Reason)
{
    local bool bPlaced, bRotated;
    if (!bMotionReplayEnabled) return;
    bMotionReplayEnabled = false;
    bMotionResetPassed = false;
    MotionResetPawn = BoundPawn;
    MotionResetReason = Reason;
    MotionResetDeadline = WorldInfo.RealTimeSeconds + 1;
    bMotionResetPending = true;
    if (BoundPawn != None && !BoundPawn.bDeleteMe)
    {
        bPlaced = BoundPawn.SetLocation(MotionSavedRoot);
        bRotated = BoundPawn.SetRotation(MotionSavedRotation);
        BoundPawn.SetPhysics(MotionSavedPhysics); BoundPawn.Velocity = MotionSavedVelocity;
        BoundPawn.ShouldCrouch(bMotionSavedCrouch); BoundPawn.BaseEyeHeight = MotionSavedEyeHeight;
    }
    bMotionResetPlaced = bPlaced; bMotionResetRotated = bRotated;
    LogMotionResetState("restored");
    if (PublicPose != None) PublicPose.ExpirePose();
    bForceNetUpdate = true;
    `log("KF2VRNet motion_end replay=" $ MotionReplayId $ " reason=" $ Reason $ " time=" $ WorldInfo.RealTimeSeconds);
    if (!bPlaced || !bRotated) CompleteMotionReset(false);
    else VerifyMotionReset();
}

reliable server function ServerSetMotionReplay(int W, int C, int P, int ReplayId, bool bEnabled)
{
    if (!bHandshakeAccepted || W != WorldEpoch || C != ConnectionEpoch || P != PawnEpoch) return;
    if (!bEnabled) { if (ReplayId == MotionReplayId) EndMotionReplay("stop"); return; }
    if (!bMotionReplayAllowed || !bVRTrackingEnabled || BoundPawn == None || BoundPawn.Health <= 0
        || BoundPawn.bDeleteMe || (!bMotionReplayEnabled && BoundPawn.Physics != PHYS_Walking)
        || BoundPawn.bIsCrouched != BoundPawn.bWantsToCrouch || ReplayId <= MotionReplayId) return;
    if (bMotionResetFailed || bMotionResetPending || (MotionReplayId > 0 && !bMotionResetPassed && !bMotionReplayEnabled)) return;
    EndMotionReplay("replace");
    // Replacement must not bypass a failed or still-pending reset.
    if (bMotionResetFailed || bMotionResetPending || (MotionReplayId > 0 && (!bMotionResetPassed || MotionResetId != MotionReplayId))
        || !bMotionReplayAllowed || !bVRTrackingEnabled
        || BoundPawn == None || BoundPawn.bDeleteMe || BoundPawn.Health <= 0
        || BoundPawn.Physics != PHYS_Walking || BoundPawn.bIsCrouched != BoundPawn.bWantsToCrouch
        || !bHandshakeAccepted || W != WorldEpoch || C != ConnectionEpoch || P != PawnEpoch) return;
    bMotionResetPassed = false;
    MotionReplayId = ReplayId; LastMotionEdge = -1; bHaveMotionReplayRoot = false;
    MotionSavedRoot = BoundPawn.Location; MotionSavedRotation = BoundPawn.Rotation;
    MotionSavedVelocity = BoundPawn.Velocity; MotionSavedPhysics = BoundPawn.Physics;
    bMotionSavedCrouch = BoundPawn.bIsCrouched; MotionSavedEyeHeight = BoundPawn.BaseEyeHeight;
    BoundPawn.SetPhysics(PHYS_None); BoundPawn.Velocity = vect(0,0,0);
    bMotionReplayEnabled = true; LastAcceptedRealTime = WorldInfo.RealTimeSeconds;
    bForceNetUpdate = true;
    `log("KF2VRNet motion_begin replay=" $ ReplayId $ " time=" $ WorldInfo.RealTimeSeconds);
}

// Reliable, ordered input transitions are review telemetry only. Never execute fire/reload/movement.
reliable server function ServerMotionEdge(int ReplayId, int Index, float Seconds, int Pressed, int Released, int Boundary)
{
    if (!bMotionReplayEnabled || !bMotionReplayAllowed || ReplayId != MotionReplayId
        || Index <= LastMotionEdge || Index > 32767 || Seconds < 0 || Seconds > 36000
        || Pressed < 0 || Pressed > 4095 || Released < 0 || Released > 4095 || Boundary < 0 || Boundary > 31) return;
    LastMotionEdge = Index;
    `log("KF2VRNet motion_edge replay=" $ ReplayId $ " sample=" $ Index $ " clip_time=" $ Seconds
        $ " pressed=" $ Pressed $ " released=" $ Released $ " boundary=" $ Boundary);
}

function SanitizeMechanisms(out NetPoseSample Sample)
{
    local int I, J, Hand, Generation;
    local KFWeapon W;
    if (HeldInventory == None || !HeldState.bAvailable || !HeldState.bIndependentWeapons)
    { Sample.Mechanisms.Length = 0; return; }
    for (I = Sample.Mechanisms.Length - 1; I >= 0; --I)
    {
        Hand = Sample.Mechanisms[I].Hand;
        W = Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon;
        Generation = Hand == 0 ? HeldInventory.Snapshot.LeftGeneration : HeldInventory.Snapshot.RightGeneration;
        if (W == None || W.bDeleteMe || W.Instigator != BoundPawn || Sample.Mechanisms[I].Generation != Generation
            || (Sample.TrackingFlags & (1 | (2 << Hand))) != (1 | (2 << Hand)))
        { Sample.Mechanisms.Remove(I, 1); continue; }
        if (MechanismPolicies[Hand].WeaponClass != W.Class)
        {
            MechanismPolicies[Hand].WeaponClass = W.Class;
            class'KF2VRNetMechanismCatalog'.static.Collect(W.Class, MechanismPolicies[Hand].Bones);
        }
        if (MechanismPolicies[Hand].Bones.Find(Sample.Mechanisms[I].Bone) == INDEX_NONE)
        { Sample.Mechanisms.Remove(I, 1); continue; }
        for (J = 0; J < I; ++J)
            if (Sample.Mechanisms[J].Hand == Hand && Sample.Mechanisms[J].Bone == Sample.Mechanisms[I].Bone) break;
        if (J < I) { Sample.Mechanisms.Remove(I, 1); continue; }
        Sample.Mechanisms[I].ItemId = Hand == 0 ? HeldInventory.Snapshot.LeftId : HeldInventory.Snapshot.RightId;
    }
}

function SanitizeReloadProps(out NetPoseSample Sample)
{
    local int I, J, Generation;
    local KFWeapon W;
    local NetReloadProp Prop;
    if (HeldInventory == None || !HeldState.bAvailable || !HeldState.bIndependentWeapons)
    { Sample.ReloadProps.Length = 0; return; }
    for (I = Sample.ReloadProps.Length - 1; I >= 0; --I)
    {
        Prop = Sample.ReloadProps[I];
        W = Prop.SourceHand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon;
        Generation = Prop.SourceHand == 0 ? HeldInventory.Snapshot.LeftGeneration : HeldInventory.Snapshot.RightGeneration;
        if (W == None || W.bDeleteMe || W.Instigator != BoundPawn || Prop.Generation != Generation
            || (Sample.TrackingFlags & 7) != 7
            || (!Prop.bSeated && (Prop.Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) != None)
            || VSizeSq(Prop.Position - (Prop.Hand == 0 ? Sample.LeftPosition : Sample.RightPosition)) > Square(100)
            || (Prop.AmmoSlot == 1 && !class'VRSecondaryReload'.static.Supported(W)))
        { Sample.ReloadProps.Remove(I, 1); continue; }
        // A sender has one component per fixed presentation slot. Never relay
        // duplicate slots that could alias two transforms onto one component.
        for (J = 0; J < I; ++J)
            if (Sample.ReloadProps[J].PropSlot == Prop.PropSlot) break;
        if (J < I) { Sample.ReloadProps.Remove(I, 1); continue; }
        // No client-provided asset path/material is loaded or relayed. The
        // held actor supplies the visual family and cosmetic skin identity.
        Sample.ReloadProps[I].Family = class'VRReloadCatalog'.static.ProfileClass(W.Class);
        Sample.ReloadProps[I].SkinId = class'VRWeaponPair'.static.VisibleSkin(W);
    }
}

unreliable server function ServerSubmitPose(NetPoseSample Sample, optional NetMotionFrame Motion)
{
    local float Now;
    local KFWeapon PumpWeapon;
    local int Hand;
    Now = WorldInfo.RealTimeSeconds;
    // Fixed work and storage per owner, at most 150 samples in one real
    // second (senders run at 120 Hz).
    if (Now - RateWindowStart >= 1.0)
    {
        RateWindowStart = Now;
        RateWindowCount = 0;
    }
    RateWindowCount = Min(RateWindowCount + 1, 151);
    if (RateWindowCount > 150 || !bHandshakeAccepted || (!bSyntheticEnabled && !bVRTrackingEnabled)
        || (bSyntheticEnabled && !bSyntheticAllowed) || BoundPawn == None || PublicPose == None
        || BoundPawn.bDeleteMe || BoundPawn.Health <= 0
        || KF2VRNetPlayerController(Owner) == None
        || KF2VRNetPlayerController(Owner).Pawn != BoundPawn
        || Sample.WorldEpoch != WorldEpoch
        || Sample.ConnectionEpoch != ConnectionEpoch
        || Sample.PawnEpoch != PawnEpoch
        || Sample.CalibrationEpoch != CalibrationEpoch
        || !class'KF2VRNetTypes'.static.IsValidSample(Sample)
        || (bHaveSequence && !class'KF2VRNetTypes'.static.IsNewerSequence(
            Sample.Sequence, LastAcceptedSequence)))
    {
        RejectedPoses = Min(RejectedPoses + 1, 2147483646);
        if (RejectedPoses <= 3 || Now >= NextRejectionLogTime)
        {
            NextRejectionLogTime = Now + 5.0;
            `log("KF2VRNet pose_rejected sequence=" $ Sample.Sequence
                $ " last=" $ LastAcceptedSequence $ " valid=" $ class'KF2VRNetTypes'.static.IsValidSample(Sample)
                $ " pawn=" $ Sample.PawnEpoch $ " expected_pawn=" $ PawnEpoch
                $ " budget=" $ RateWindowCount $ " head_rotation=" $ Sample.HeadRotation);
        }
        return;
    }
    if (Motion.bEnabled)
    {
        if (!bMotionReplayAllowed || !bMotionReplayEnabled || Motion.ReplayId != MotionReplayId
            || Motion.SampleIndex < 0 || Motion.SampleIndex > 32767
            || !(Motion.ClipSeconds >= 0 && Motion.ClipSeconds <= 36000)
            || !class'KF2VRNetTypes'.static.IsBoundedVector(Motion.RootPosition, 10000000)
            || (bHaveMotionReplayRoot && !class'KF2VRNetTypes'.static.IsBoundedVector(Motion.RootPosition - MotionReplayRoot, 10000))
            || !class'KF2VRNetTypes'.static.IsCanonicalRotation(Motion.RootRotation)
            || !class'KF2VRNetTypes'.static.IsBoundedVector(Motion.LeftAxes, 1)
            || !class'KF2VRNetTypes'.static.IsBoundedVector(Motion.RightAxes, 1)) return;
        if (!BoundPawn.SetLocation(Motion.RootPosition)) { EndMotionReplay("root_blocked"); return; }
        if (!bHaveMotionReplayRoot) { MotionReplayRoot = Motion.RootPosition; bHaveMotionReplayRoot = true; }
        BoundPawn.SetRotation(Motion.RootRotation); BoundPawn.ShouldCrouch(Motion.bCrouched);
        if (Motion.bCrouched) BoundPawn.ForceCrouch();
        BoundPawn.BaseEyeHeight = FClamp(Motion.EyeHeight, 0, 160);
        BoundPawn.bForceNetUpdate = true;
    }
    else if (bMotionReplayEnabled) return;
    // Held grenades are cosmetic intent only. Never trust a client-supplied
    // asset, consume ammo, or enter the gameplay release transaction here.
    Sample.GrenadeClass = None;
    Hand = int(Sample.GrenadeHand) - 1;
    if (Hand >= 0 && Hand <= 1 && bVRTrackingEnabled && !Motion.bEnabled
        && HeldState.bIndependentWeapons && HeldInventory != None
        && GrenadeState.Human == BoundPawn && GrenadeState.Count > 0
        && BoundPawn.GetPerk() != None
        && (Sample.TrackingFlags & (1 | (2 << Hand))) == (1 | (2 << Hand))
        && (Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) == None
        && class'VRGrenadeThrow'.static.Bounded(Sample.GrenadePosition
            - (Hand == 0 ? Sample.LeftPosition : Sample.RightPosition), 60))
        Sample.GrenadeClass = BoundPawn.GetPerk().GetGrenadeClass();
    if (Sample.GrenadeClass == None)
    {
        Sample.GrenadeHand = 0;
        Sample.GrenadePosition = vect(0,0,0);
        Sample.GrenadeRotation = rot(0,0,0);
    }
    // Pure presentation: only an accepted carried pump weapon may animate
    // these parts. It grants no chamber credit, action or firing permission.
    for (Hand = 0; Hand < 2; ++Hand)
    {
        PumpWeapon = HeldInventory != None ? (Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) : None;
        if (HeldInventory == None || (HeldInventory.Snapshot.CarryMask & (1 << Hand)) == 0
            || (Sample.TrackingFlags & (2 << Hand)) == 0 || PumpWeapon == None
            || (PumpWeapon.Class != class'KFWeap_Shotgun_MB500' && PumpWeapon.Class != class'KFWeap_Shotgun_DragonsBreath'))
        {
            if (Hand == 0) { Sample.LeftPumpLo = 0; Sample.LeftPumpHi = 0; }
            else { Sample.RightPumpLo = 0; Sample.RightPumpHi = 0; }
        }
    }
    SanitizeReloadProps(Sample);
    SanitizeMechanisms(Sample);
    bHaveSequence = true;
    LastAcceptedSequence = Sample.Sequence;
    LastAcceptedRealTime = Now;
    AcceptedPoses = Min(AcceptedPoses + 1, 2147483646);
    PublicPose.PublishPose(Sample, BoundPawn, bSyntheticEnabled, Motion);
    AimHeldSprays();
    // The accepted 120 Hz hand pair also drives held Zeds. No second stream.
    KF2VRNetPlayerController(Owner).UpdateTrackedGrabs();
    if (Motion.bEnabled)
        `log("KF2VRNet motion_server replay=" $ Motion.ReplayId $ " sample=" $ Motion.SampleIndex
            $ " clip_time=" $ Motion.ClipSeconds $ " sequence=" $ Sample.Sequence $ " paused=" $ Motion.bPaused
            $ " root=" $ BoundPawn.Location $ " left=" $ Sample.LeftPosition $ " right=" $ Sample.RightPosition
            $ " right_class=" $ PathName(Motion.RightWeapon.WeaponClass) $ " shot=" $ Motion.RightWeapon.ShotSequence
            $ " time=" $ Now);
}

function UpdatePawnBinding()
{
    local KF2VRNetPlayerController NetPC;
    local KFPawn_Human NewPawn;
    NetPC = KF2VRNetPlayerController(Owner);
    if (NetPC == None || NetPC.bDeleteMe)
    {
        Destroy();
        return;
    }
    NewPawn = KFPawn_Human(NetPC.Pawn);
    if (NewPawn != None && (NewPawn.Health <= 0 || NewPawn.bDeleteMe
        || KFPawn_Customization(NewPawn) != None))
    {
        NewPawn = None;
    }
    if (NewPawn == BoundPawn)
    {
        return;
    }
    EndMotionReplay("pawn_changed");
    ClearPhysicalReloadEnd(0); ClearPhysicalReloadEnd(1);
    bInventoryFocusRequested = false;
    InventoryFocusLeaseUntil = 0.0;
    ShutdownPairedReloads();
    if (VampireReload != None) VampireReload.Shutdown();
    VampireReload = None;
    VampireState.Human = None;
    VampireState.Weapon = None;
    VampireState.LastBeginWeapon = None;
    VampireState.BeginRequest = 0;
    VampireState.LastBeginRequest = 0;
    VampireState.AcknowledgedRequest = 0;
    VampireState.SessionId = 0;
    VampireState.Status = 0;
    VampireState.NativeVersion = 0;
    BowAuthority = None;
    BowState.Human = None; BowState.Weapon = None; BowState.AcknowledgedWeapon = None;
    BowState.NativeVersion = 0; BowState.AcknowledgedRequest = 0; BowState.bAccepted = false; BowState.bReady = false;
    BowState.PrimaryAmmo = 0; NextBowCapabilityCheck = 0;
    if (WorldDrops != None) WorldDrops.Destroy();
    WorldDrops = None;
    if (MagazineActions != None) MagazineActions.Destroy();
    MagazineActions = None;
    RestoreWeaponPairs();
    if (PublicPose != None)
    {
        PublicPose.Destroy();
        PublicPose = None;
    }
    if (DualTargetLeft != None) DualTargetLeft.Destroy();
    if (DualTargetRight != None) DualTargetRight.Destroy();
    DualTargetLeft = None;
    DualTargetRight = None;
    HeldState.AcknowledgedRequest = 0;
    HeldState.bAccepted = false;
    HeldState.Revision = 0;
    HeldState.LeftWeapon = None;
    HeldState.RightWeapon = None;
    HeldState.ShieldHandToken = 0; PredictedShieldHandToken = 0;
    HeldState.CarryMask = 0; HeldState.NativeCarryVersion = 0;
    NativeCarryVersion = 0; PredictedCarryMask = 0;
    HeldRateStart = 0;
    HeldRateCount = 0;
    GrenadeState.AcknowledgedRequest = 0;
    GrenadeState.bAccepted = false;
    GrenadeRateStart = 0;
    GrenadeRateCount = 0;
    if (HeldInventory != None) HeldInventory.Shutdown();
    HeldInventory = None;
    bHeldLedgerChecked = false;
    bPendingFireChecked = false;
    BoundPawn = NewPawn;
    PublishGrenadeState();
    HeldState.Human = BoundPawn;
    HeldState.bAvailable = false;
    PawnEpoch = 0;
    CalibrationEpoch = 0;
    bHaveSequence = false;
    bForceNetUpdate = true;
    if (BoundPawn == None || NextPawnEpoch <= 0)
    {
        return;
    }
    PawnEpoch = NextPawnEpoch;
    CalibrationEpoch = 1;
    BowState.Human = BoundPawn;
    BowState.WorldEpoch = WorldEpoch; BowState.ConnectionEpoch = ConnectionEpoch; BowState.PawnEpoch = PawnEpoch;
    if (NextPawnEpoch == 2147483647)
    {
        NextPawnEpoch = 0;
    }
    else
    {
        ++NextPawnEpoch;
    }
    // No Owner: the public state never becomes exclusive to the sending PC.
    PublicPose = Spawn(class'KF2VRNetPose',,, BoundPawn.Location);
    if (PublicPose != None)
    {
        PublicPose.Initialize(BoundPawn, WorldEpoch, ConnectionEpoch,
            PawnEpoch, CalibrationEpoch);
    }
    `log("KF2VRNet pawn world=" $ WorldEpoch $ " connection=" $ ConnectionEpoch
        $ " pawn=" $ PawnEpoch $ " actor=" $ BoundPawn $ " public=" $ PublicPose);
}

// Server-only presentation/projectile-origin source. Local player aiming must
// call the controller's current local input source, never this delayed state.
function bool GetAcceptedWeaponPose(out vector Position, out rotator Aim)
{
    if (Role != ROLE_Authority || (!bSyntheticEnabled && !bVRTrackingEnabled) || PublicPose == None
        || BoundPawn == None || BoundPawn.Health <= 0
        || (PublicPose.Snapshot.Sample.TrackingFlags & 4) == 0
        || WorldInfo.RealTimeSeconds - LastAcceptedRealTime
            > class'KF2VRNetTypes'.const.PoseLeaseSeconds)
    {
        return false;
    }
    Aim = Normalize(PublicPose.Snapshot.RootRotation
        + PublicPose.Snapshot.Sample.RightRotation);
    Position = PublicPose.Snapshot.RootPosition
        + (PublicPose.Snapshot.Sample.RightPosition >> PublicPose.Snapshot.RootRotation)
        + vector(Aim) * 12.0;
    return true;
}

// Server view of whether this player's pawn has tracked VR hands.
function bool TracksPawn(Pawn P)
{
    return P != None && bVRTrackingEnabled && BoundPawn == P;
}

// Server view of one fresh tracked hand for teammate fist bumps and high
// fives (KF2VRNetHandContact): world position, finger pose and pose revision.
// Share the held-snapshot actor channel: a successful toss must be admitted
// before the subsequent snapshot clears its releasing hand.
reliable server function ServerThrownWeaponContact(KFWeapon W, byte Hand, int Token,
    vector Position, vector ReleaseVelocity, optional bool bStop)
{
    local KF2VRNetPlayerController Player;
    Player = KF2VRNetPlayerController(Owner);
    if (Role == ROLE_Authority && Player != None && Player.NetChannel == self)
        Player.ThrownWeaponContact(W, Hand, Token, Position, ReleaseVelocity, bStop);
}

reliable server function ServerThrownItemFlinch(vector Position, vector ReleaseVelocity)
{
    local KF2VRNetPlayerController Player;
    Player = KF2VRNetPlayerController(Owner);
    if (Role == ROLE_Authority && Player != None && Player.NetChannel == self)
        Player.ThrownItemFlinch(Position, ReleaseVelocity);
}

function bool ContactHand(int Hand, out KFPawn_Human Body, out vector Position, out byte Pose, out int Revision)
{
    if (Role != ROLE_Authority || (!bSyntheticEnabled && !bVRTrackingEnabled) || PublicPose == None
        || BoundPawn == None || BoundPawn.Health <= 0 || Hand < 0 || Hand > 1
        || (PublicPose.Snapshot.Sample.TrackingFlags & (2 << Hand)) == 0
        || WorldInfo.RealTimeSeconds - LastAcceptedRealTime > class'KF2VRNetTypes'.const.PoseLeaseSeconds)
        return false;
    Body = BoundPawn;
    Pose = Hand == 0 ? PublicPose.Snapshot.Sample.LeftHandPose : PublicPose.Snapshot.Sample.RightHandPose;
    Position = PublicPose.Snapshot.RootPosition + ((Hand == 0 ? PublicPose.Snapshot.Sample.LeftPosition
        : PublicPose.Snapshot.Sample.RightPosition) >> PublicPose.Snapshot.RootRotation);
    Revision = PublicPose.Snapshot.Revision;
    return true;
}

// Body grabs use the aim frame used by PalmPosition, not the weapon grip frame.
function bool GrabHandFrame(int Hand, out vector Position, out rotator Facing, out int Reference)
{
    local KFPawn_Human Body;
    local byte Pose;
    local int Revision;
    if (!ContactHand(Hand, Body, Position, Pose, Revision)) return false;
    Facing = Normalize(PublicPose.Snapshot.RootRotation + (Hand == 0
        ? PublicPose.Snapshot.Sample.LeftRotation : PublicPose.Snapshot.Sample.RightRotation));
    Reference = PublicPose.Snapshot.Sample.ReferenceEpoch;
    return true;
}

// Carried presentation shares the accepted third-person grip frame. ContactHand
// retains the same ownership, tracking freshness and pawn-lifetime admission.
function bool ContactHandFrame(int Hand, out KFPawn_Human Body, out vector Position, out rotator Facing)
{
    local byte Pose;
    local int Revision;
    if (!ContactHand(Hand, Body, Position, Pose, Revision)) return false;
    Facing = Normalize(PublicPose.Snapshot.RootRotation + (Hand == 0
        ? PublicPose.Snapshot.Sample.LeftGripRotation : PublicPose.Snapshot.Sample.RightGripRotation));
    return true;
}

// The authority has no posed first-person mesh for a remote VR owner, so
// stock flame sprays ride the weapon actor at the pawn and burn wherever the
// head looks. Seat them on the tracked muzzle of each accepted 120 Hz frame,
// as authority-spawned projectiles are. Stock spray simulation, damage and
// fuel are unchanged; the owner's own client keeps its presented socket.
function AimHeldSprays()
{
    local int Hand;
    local KFWeapon W;
    local KFSprayActor Spray;
    local vector Muzzle;
    local rotator Aim;
    if (HeldInventory == None || BoundPawn == None || BoundPawn.IsLocallyControlled()) return;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        W = Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon;
        if (W == None || !W.IsA('KFWeap_FlameBase') || !HeldMuzzleFrame(Hand, W, Muzzle, Aim)) continue;
        if (class'VRFlamePresentation'.static.BindSprays(W) == 0) continue;
        foreach W.BasedActors(class'KFSprayActor', Spray)
        {
            Spray.SetLocation(Muzzle);
            Spray.SetRotation(Aim);
        }
    }
}

// Exact held identity in a fresh accepted 120 Hz frame: W is owned, held in
// Hand, and the frame's published root belongs to that same held generation.
function bool HeldRootFrame(int Hand, KFWeapon W, out vector Palm, out int Revision)
{
    local KFPawn_Human Body;
    local byte Pose;
    return bHandshakeAccepted && bVRTrackingEnabled && !bSyntheticEnabled && HeldInventory!=None
        && W!=None && HeldInventory.IsOwned(W)
        && (Hand==0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon)==W
        && ContactHand(Hand,Body,Palm,Pose,Revision) && Body==BoundPawn
        && (PublicPose.Snapshot.Sample.WeaponRootFlags & (Hand==0 ? 2 : 1))!=0
        && (Hand==0 ? PublicPose.Snapshot.Sample.LeftWeaponRootGeneration : PublicPose.Snapshot.Sample.RightWeaponRootGeneration)
            == (Hand==0 ? HeldInventory.Snapshot.LeftGeneration : HeldInventory.Snapshot.RightGeneration);
}

// The held firearm's tracked muzzle and its client fire bore (root x the
// profile's BoreRotation), as the shooter's own shot uses. Authority-spawned
// projectiles otherwise start from the head view: the dedicated server has no
// first-person mesh. Pure melee reuses the muzzle slot for its root.
function bool HeldMuzzleFrame(int Hand, KFWeapon W, out vector Position, out rotator Aim)
{
    local vector Palm;
    local int Revision, P;
    local rotator Root;
    P=class'VRWeaponBlockShapes'.static.Profile(W);
    if(!HeldRootFrame(Hand,W,Palm,Revision) || P<0 || class'VRWeaponBlockShapes'.static.PublishesRoot(P)
        || (PublicPose.Snapshot.Sample.PresentationFlags & (Hand==0 ? 2 : 1))==0)
        return false;
    Position=PublicPose.Snapshot.RootPosition+((Hand==0 ? PublicPose.Snapshot.Sample.LeftMuzzlePosition
        : PublicPose.Snapshot.Sample.MuzzlePosition)>>PublicPose.Snapshot.RootRotation);
    Root=Normalize(PublicPose.Snapshot.RootRotation+(Hand==0 ? PublicPose.Snapshot.Sample.LeftWeaponRootRotation
        : PublicPose.Snapshot.Sample.RightWeaponRootRotation));
    Aim=QuatToRotator(QuatProduct(QuatFromRotator(Root),
        QuatFromRotator(class'VRHandsBridge'.default.WeaponProfiles[P].BoreRotation)));
    return true;
}

// Exact held identity and the existing accepted 120 Hz presentation frame.
// The block rig additionally checks its authored grip against this tracked palm.
function bool WeaponBlockFrame(int Hand, KFWeapon W, out vector Palm, out vector Position,
    out rotator Facing, out int Revision, out int HeldGeneration)
{
    local bool bMeleeRoot;
    if(!HeldRootFrame(Hand,W,Palm,Revision)) return false;
    bMeleeRoot=class'VRWeaponBlockShapes'.static.PublishesRoot(class'VRWeaponBlockShapes'.static.Profile(W));
    if(bMeleeRoot)
    {
        if((PublicPose.Snapshot.Sample.PresentationFlags & (Hand==0 ? 2 : 1))==0) return false;
        Position=Hand==0 ? PublicPose.Snapshot.Sample.LeftMuzzlePosition : PublicPose.Snapshot.Sample.MuzzlePosition;
        Facing=Hand==0 ? PublicPose.Snapshot.Sample.LeftMuzzleRotation : PublicPose.Snapshot.Sample.MuzzleRotation;
    }
    else
    {
        Position=Hand==0 ? PublicPose.Snapshot.Sample.LeftWeaponRootPosition : PublicPose.Snapshot.Sample.RightWeaponRootPosition;
        Facing=Hand==0 ? PublicPose.Snapshot.Sample.LeftWeaponRootRotation : PublicPose.Snapshot.Sample.RightWeaponRootRotation;
    }
    Position=PublicPose.Snapshot.RootPosition+(Position>>PublicPose.Snapshot.RootRotation);
    Facing=Normalize(PublicPose.Snapshot.RootRotation+Facing);
    HeldGeneration=Hand==0 ? HeldInventory.Snapshot.LeftGeneration : HeldInventory.Snapshot.RightGeneration;
    return true;
}

// Cosmetic delivery for actual authority-scored damage. Synthetic channels
// do not generate numbers; this event never accepts a client damage request.
function NotifyDamagePopup(int Amount, vector At, class<KFDamageType> Kind, bool bHeadshot)
{
    local KF2VRNetPlayerController PC;
    PC = KF2VRNetPlayerController(Owner);
    if (Role != ROLE_Authority || PC == None || !bHandshakeAccepted
        || !bVRTrackingEnabled || bSyntheticEnabled || BoundPawn == None
        || BoundPawn != PC.Pawn || BoundPawn.Health <= 0 || Amount <= 0) return;
    ClientDamagePopup(PawnEpoch, Amount, At, Kind, bHeadshot);
}

// Unreliable: a missed cosmetic number is preferable to replaying stale hits.
unreliable client function ClientDamagePopup(int InPawnEpoch, int Amount, vector At,
    class<KFDamageType> Kind, bool bHeadshot)
{
    local KF2VRNetPlayerController PC;
    local VRSpatialHUD HUD;
    PC = KF2VRNetPlayerController(Owner);
    if (PC == None || !PC.IsLocalPlayerController() || !bHandshakeAccepted
        || InPawnEpoch != PawnEpoch || PC.Pawn == None || PC.Pawn.Health <= 0
        || Amount <= 0 || !class'VRGrenadeThrow'.static.Bounded(At, 100000000)) return;
    foreach DynamicActors(class'VRSpatialHUD', HUD)
        if (HUD.PC == PC && HUD.Bridge != None && HUD.Bridge.bDamagePopups)
        {
            HUD.ReceiveDamagePopup(Amount, At, Kind, bHeadshot);
            return;
        }
}

function bool TomahawkHandAllowed(VRWeap_Tomahawk W, int Hand)
{
    return HeldCommandsAvailable() && bVRTrackingEnabled && !bInventoryFocusRequested
        && HeldInventory != None && W != None && Hand >= 0 && Hand < 2
        && PublicPose != None
        && (PublicPose.Snapshot.Sample.TrackingFlags & (Hand == 0 ? 2 : 4)) != 0
        && WorldInfo.RealTimeSeconds - LastAcceptedRealTime <= class'KF2VRNetTypes'.const.PoseLeaseSeconds
        && (Hand == 0 ? HeldInventory.Snapshot.LeftWeapon : HeldInventory.Snapshot.RightWeapon) == W;
}

simulated event Tick(float DeltaTime)
{
    local KF2VRNetPlayerController PC;
    local KFPerk Perk;
    local KF2VRNetGame Game;
    local VRWeap_Tomahawk Hawk;
    Super.Tick(DeltaTime);
    if (Role == ROLE_Authority)
    {
        Game = KF2VRNetGame(WorldInfo.Game);
        if (bMultiplayerZedGrabAllowed != (Game != None && Game.bMultiplayerZedGrabAllowed))
        {
            bMultiplayerZedGrabAllowed = Game != None && Game.bMultiplayerZedGrabAllowed;
            bForceNetUpdate = true;
        }
        if (!GrabCommandsAllowed()) RevokeGrabIntent();
        if (bInventoryFocusRequested && (WorldInfo.RealTimeSeconds >= InventoryFocusLeaseUntil
            || !IsInventoryFocusEligible()))
        {
            bInventoryFocusRequested = false;
            InventoryFocusLeaseUntil = 0.0;
        }
        if (bDiagnosticAutoReady)
        {
            PC = KF2VRNetPlayerController(Owner);
            Game = KF2VRNetGame(WorldInfo.Game);
            if (PC != None) Perk = PC.GetPerk();
            bDiagnosticPerkReady = Perk != None && Perk.bInitialized;
            bDiagnosticClientsReady = Game != None && Game.DiagnosticClientsReady();
        }
        UpdatePawnBinding();
        UpdateWorldReplacementLease();
        VerifyMotionReset();
        if (bMotionReplayEnabled && WorldInfo.RealTimeSeconds - LastAcceptedRealTime > 1.0)
            EndMotionReplay("lease_expired");
        // A bought or picked-up RAVEN-7 validates throws/recalls through the
        // channel of the tracked player now holding it.
        if (bVRTrackingEnabled && BoundPawn != None && BoundPawn.InvManager != None)
            foreach BoundPawn.InvManager.InventoryActors(class'VRWeap_Tomahawk', Hawk)
                if (Hawk.ThrowAuthority != self) { Hawk.CanThrowHand = TomahawkHandAllowed; Hawk.ThrowAuthority = self; }
        ResendChainLinks();
        PublishGrenadeState();
        NativeAuthorityUpdate();
        NativeSupportCarryUpdate();
        NativeWorldDropUpdate();
        if (BoundPawn != None && HeldInventory == None && BoundPawn.InvManager != None
            && (bVRTrackingEnabled || bSyntheticAllowed && bDiagnosticAutoReady))
        {
            HeldInventory = new(self) class'KF2VRNetHeldInventory';
            if (!HeldInventory.Initialize(BoundPawn)) HeldInventory = None;
        }
        if (HeldInventory != None)
        {
            HeldInventory.Refresh();
            UpdateCycleEject();
            UpdatePhysicalReloadEnds();
            GetPouchAmmo().UpdateCurrency();
            PouchAmmo.UpdateServer();
            // Sale/drop/removal can retire a hand without a new owner command.
            // Update the stock compatibility weapon once for that transition.
            if (HeldState.bIndependentWeapons && HeldState.Revision != HeldInventory.Snapshot.Revision)
                HeldInventory.ApplyHands();
            if (bSyntheticAllowed && bDiagnosticAutoReady && !bHeldLedgerChecked)
                bHeldLedgerChecked = class'KF2VRNetHeldInventoryProbe'.static.Run(BoundPawn);
            Game = KF2VRNetGame(WorldInfo.Game);
            if (NativeAuthorityReady == 1 && bSyntheticAllowed && bDiagnosticAutoReady
                && Game != None && Game.bServerAdapter && !bPendingFireChecked)
                bPendingFireChecked = class'KF2VRNetHeldInventoryProbe'.static.RunPending(BoundPawn, HeldInventory);
            PublishHeldState();
            UpdateBowAuthority();
            if (VampireReload == None)
            {
                VampireReload = new(self) class'KF2VRNetVampireReload';
                if (!VampireReload.Initialize(self, HeldInventory, WorldEpoch, ConnectionEpoch, PawnEpoch))
                    VampireReload = None;
                else PublishVampireState();
            }
            if (VampireReload != None)
            {
                VampireReload.Tick(VampireContextAllowed());
                if (VampireState.Status != VampireReload.Snapshot.Status) PublishVampireState();
            }
            UpdateWeaponPairs();
            UpdatePairedReloads();
            UpdateWorldDropAuthority();
        }
        if (PublicPose != None && PublicPose.Snapshot.Sample.TrackingFlags != 0
            && WorldInfo.RealTimeSeconds - LastAcceptedRealTime
                > class'KF2VRNetTypes'.const.PoseLeaseSeconds)
        {
            PublicPose.ExpirePose();
            `log("KF2VRNet expiry world=" $ WorldEpoch $ " connection="
                $ ConnectionEpoch $ " pawn=" $ PawnEpoch);
        }
        if ((bSyntheticEnabled || bVRTrackingEnabled) && WorldInfo.RealTimeSeconds >= NextAuthorityStatusRealTime)
        {
            NextAuthorityStatusRealTime = WorldInfo.RealTimeSeconds + 5.0;
            `log("KF2VRNet authority world=" $ WorldEpoch $ " connection="
                $ ConnectionEpoch $ " pawn=" $ PawnEpoch
                $ " accepted=" $ AcceptedPoses $ " rejected=" $ RejectedPoses
                $ " native_authority=" $ NativeAuthorityReady
                $ " perk_ready=" $ bDiagnosticPerkReady $ " clients_ready=" $ bDiagnosticClientsReady
                $ " grab_permission=" $ bMultiplayerZedGrabAllowed
                $ " lastseq=" $ LastAcceptedSequence $ " netmode=" $ WorldInfo.NetMode);
        }
    }
    else if (WorldInfo.NetMode == NM_Client)
    {
        PC = KF2VRNetPlayerController(Owner);
        if (HeldProbe == None && bSyntheticAllowed && bDiagnosticAutoReady
            && CanRequestHeldWeapons() && !HeldState.bIndependentWeapons && PC != None
            && PC.bEnableVRClient && !PC.bDiagnosticObserverOnly)
        {
            HeldProbe = new(self) class'KF2VRNetHeldNetworkProbe';
            HeldProbe.Channel = self;
        }
        if (HeldProbe != None) HeldProbe.Tick();
    }
}

event Destroyed()
{
    ClearPhysicalReloadEnd(0); ClearPhysicalReloadEnd(1);
    if (WorldDrops != None) WorldDrops.Destroy();
    WorldDrops = None;
    if (MagazineActions != None) MagazineActions.Destroy();
    MagazineActions = None;
    BowAuthority = None;
    ShutdownPairedReloads();
    if (VampireReload != None) VampireReload.Shutdown();
    VampireReload = None;
    EndMotionReplay("pawn_changed");
    bInventoryFocusRequested = false;
    InventoryFocusLeaseUntil = 0.0;
    RestoreWeaponPairs();
    if (DualTargetLeft != None) DualTargetLeft.Destroy();
    if (DualTargetRight != None) DualTargetRight.Destroy();
    HeldProbe = None;
    if (HeldInventory != None) HeldInventory.Shutdown();
    HeldInventory = None;
    if (Role == ROLE_Authority && bSyntheticAllowed)
        `log("KF2VRNet channel_destroyed world=" $ WorldEpoch $ " connection=" $ ConnectionEpoch
            $ " pawn=" $ PawnEpoch $ " netmode=" $ WorldInfo.NetMode);
    if (Role == ROLE_Authority && PublicPose != None)
    {
        PublicPose.Destroy();
        PublicPose = None;
    }
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bOnlyRelevantToOwner=true
    bAlwaysRelevant=false
    bReplicateMovement=false
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    NetUpdateFrequency=5.0
}
