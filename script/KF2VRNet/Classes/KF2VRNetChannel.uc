// Only this server-created, controller-owned actor accepts pose/held RPCs.
class KF2VRNetChannel extends Actor dependsOn(KF2VRNetTypes, KF2VRNetHeldInventory, KF2VRNetVampireReload, KF2VRNetPairedReload)
    implements(VRTrackedPawnSource);

var int WorldEpoch;
var int ConnectionEpoch;
var int PawnEpoch;
var int CalibrationEpoch;
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
var private bool bLastGrabIntent;
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
var private float GrenadeRateStart;

// One authority object survives terminal reloads during this pawn lifetime:
// its native fence also rejects late stock weapon-channel reload requests.
var KF2VRNetPairedReload PairedReloads[2];
var KF2VRNetPairedReload.ReloadState PairedStates[2];
var private int LocalPairedReloadRequest;

var KF2VRNetVampireReload VampireReload;
var KF2VRNetVampireReload.ReloadState VampireState;
var private KFPawn_Human LocalVampirePawn;
var private KFPawn_Human LocalVampireManagedPawn;
var private int LocalVampireManagedWorld, LocalVampireManagedConnection, LocalVampireManagedEpoch;
var private int LocalVampireRequest;

function bool PairedReloadContext(int Hand)
{
    return Hand >= 0 && Hand < 2 && HeldCommandsAvailable() && HeldState.bIndependentWeapons
        && IsInventoryFocusEligible() && !bInventoryFocusRequested
        && class'VRPhysicalInteraction'.static.Allowed(BoundPawn)
        && (PublicPose.Snapshot.Sample.TrackingFlags & (2 << Hand)) != 0;
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

simulated function int PairedReloadBegin(KFWeapon W, int Hand, optional bool bStock)
{
    if (!PairedReloadAvailable() || Hand < 0 || Hand > 1 || W == None
        || class'VRWeaponPair'.static.ForMember(W) == None
        || (Hand == 0 ? HeldState.LeftWeapon : HeldState.RightWeapon) != W
        || LocalPairedReloadRequest >= MaxInt - 1) return 0;
    ++LocalPairedReloadRequest;
    ServerPairedReloadBegin(WorldEpoch, ConnectionEpoch, PawnEpoch, LocalPairedReloadRequest, W, Hand, HeldState.Revision, W.AmmoCount[0], bStock);
    return LocalPairedReloadRequest;
}

simulated function bool PairedReloadRead(KFWeapon W, int BeginRequest, out int Session,
    out byte Status, out int Ammo, out int Reserve)
{
    local int H;
    Session = 0; Status = 0; Ammo = 0; Reserve = 0;
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
        return true;
    }
    return false;
}

simulated function bool PairedReloadCommit(KFWeapon W, int BeginRequest, int Session)
{
    local int H;
    if (!PairedReloadAvailable() || Session <= 0 || Session != BeginRequest) return false;
    for (H = 0; H < 2; ++H)
        if (PairedStates[H].Weapon == W && PairedStates[H].SessionId == Session && PairedStates[H].Status == 1)
        {
            ServerPairedReloadFinish(WorldEpoch, ConnectionEpoch, PawnEpoch, W, H, Session, true);
            return true;
        }
    return false;
}

simulated function PairedReloadCancel(KFWeapon W, int BeginRequest, int Session)
{
    if (W != None && BeginRequest > 0 && (Session == 0 || Session == BeginRequest))
        ServerPairedReloadFinish(WorldEpoch, ConnectionEpoch, PawnEpoch, W, -1, BeginRequest, false);
}

reliable server function ServerPairedReloadBegin(int WE, int CE, int PE, int Request,
    KFWeapon W, int Hand, int ExpectedHeldRevision, int ExpectedAmmo, bool bStock)
{
    if (WE != WorldEpoch || CE != ConnectionEpoch || PE != PawnEpoch || Hand < 0 || Hand > 1
        || PairedReloads[Hand] == None) return;
    PairedReloads[Hand].Tick();
    PairedReloads[Hand].Begin(Request, W, ExpectedHeldRevision, ExpectedAmmo, bStock);
    PairedStates[Hand] = PairedReloads[Hand].Snapshot;
    bForceNetUpdate = true;
}

reliable server function ServerPairedReloadFinish(int WE, int CE, int PE,
    KFWeapon W, int Hand, int Session, bool bCommit)
{
    local int H;
    if (WE != WorldEpoch || CE != ConnectionEpoch || PE != PawnEpoch || Session <= 0) return;
    for (H = 0; H < 2; ++H)
        if (PairedReloads[H] != None && PairedReloads[H].Snapshot.Weapon == W
            && PairedReloads[H].Snapshot.SessionId == Session && (!bCommit || Hand == H))
        {
            if (bCommit) PairedReloads[H].Commit(Session, W);
            else PairedReloads[H].Cancel(Session);
            PairedStates[H] = PairedReloads[H].Snapshot;
            bForceNetUpdate = true;
        }
}

function bool VampireContextAllowed()
{
    return HeldCommandsAvailable() && HeldState.bIndependentWeapons
        && bVRTrackingEnabled && !bInventoryFocusRequested;
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

simulated function int VampireBegin(KFWeapon W, int Hand, bool bStock)
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
    ServerVampireBegin(WorldEpoch, ConnectionEpoch, PawnEpoch, Request, W, Hand, HeldState.Revision, bStock);
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

simulated function bool VampireCommit(KFWeapon W, int BeginRequest, int Session)
{
    local int Request;
    if (!VampireAvailable() || Session != BeginRequest || Session <= 0
        || VampireState.Human != HeldState.Human || VampireState.Weapon != W
        || VampireState.BeginRequest != BeginRequest || VampireState.SessionId != Session
        || VampireState.Status != class'VRVampireReloadAuthority'.const.Held) return false;
    Request = NextVampireRequest();
    if (Request == 0) return false;
    ServerVampireCommit(WorldEpoch, ConnectionEpoch, PawnEpoch, Request, W,
        VampireState.Hand, VampireState.ItemId, VampireState.ItemRevision, Session);
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
    KFWeapon Weapon, int Hand, int ExpectedHeldRevision, bool bStock)
{
    if (W != WorldEpoch || C != ConnectionEpoch || P != PawnEpoch || VampireReload == None) return;
    VampireReload.Tick(VampireContextAllowed());
    VampireReload.Begin(Request, Weapon, Hand, ExpectedHeldRevision, W, C, P, bStock);
    PublishVampireState();
}

reliable server function ServerVampireCommit(int W, int C, int P, int Request,
    KFWeapon Weapon, int Hand, int Id, int Revision, int Session)
{
    if (W != WorldEpoch || C != ConnectionEpoch || P != PawnEpoch || VampireReload == None) return;
    VampireReload.Tick(VampireContextAllowed());
    VampireReload.Commit(Request, Weapon, Hand, Id, Revision, Session, W, C, P);
    PublishVampireState();
}

reliable server function ServerVampireCancel(int W, int C, int P, int Request,
    KFWeapon Weapon, int BeginRequest)
{
    if (W != WorldEpoch || C != ConnectionEpoch || P != PawnEpoch || VampireReload == None
        || VampireReload.Snapshot.Weapon != Weapon
        || VampireReload.Snapshot.BeginRequest != BeginRequest) return;
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

simulated function bool RequestGrenade(KFWeapon WeaponOwner, class<KFProj_Grenade> GrenadeClass,
    int Hand, vector Position, vector ReleaseVelocity, int ReferenceEpoch)
{
    if (!CanRequestHeldWeapons() || !HeldState.bIndependentWeapons || !bVRTrackingEnabled
        || Hand < 0 || Hand > 1 || AvailableGrenades() <= 0 || GrenadePending()) return false;
    if (LocalGrenadePawn != HeldState.Human)
    {
        LocalGrenadePawn = HeldState.Human;
        LocalGrenadeRequest = GrenadeState.AcknowledgedRequest;
    }
    LocalGrenadeRequest = Max(LocalGrenadeRequest, GrenadeState.AcknowledgedRequest);
    if (LocalGrenadeRequest >= MaxInt - 1) return false;
    ++LocalGrenadeRequest;
    // World-oriented pawn offsets survive prediction corrections without a
    // server camera/yaw change rotating the measured gesture.
    ServerThrowGrenade(PawnEpoch, LocalGrenadeRequest, ReferenceEpoch, Hand, WeaponOwner,
        GrenadeClass, Position - LocalGrenadePawn.Location, ReleaseVelocity);
    return true;
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
            if (bWasCurrent || (HeldInventory.Snapshot.LeftWeapon == None && HeldInventory.Snapshot.RightWeapon == None))
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
    KFWeapon Left, KFWeapon Right)
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
    HeldState.bAccepted = HeldRateCount <= 32 && HeldInventory.SetHands(Left, Right);
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

simulated function bool RequestHeldWeapons(KFWeapon Left, KFWeapon Right)
{
    if (!CanRequestHeldWeapons() || (Left != None && Left == Right)) return false;
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
    ServerSetHeldWeapons(PredictedHeldPawn, LocalHeldRequest, Left, Right);
    return true;
}

// Presentation reads this immediately after input. An older server update
// cannot undo a newer grip; the processed request confirms or corrects it.
simulated function bool GetDesiredHeldWeapons(out KFWeapon Left, out KFWeapon Right)
{
    Left = None;
    Right = None;
    if (!CanRequestHeldWeapons()) return false;
    if (PredictedHeldPawn == HeldState.Human && LocalHeldRequest > HeldState.AcknowledgedRequest)
    {
        Left = PredictedLeft;
        Right = PredictedRight;
    }
    else
    {
        Left = HeldState.LeftWeapon;
        Right = HeldState.RightWeapon;
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
    HeldState.LeftWeapon = HeldInventory.Snapshot.LeftWeapon;
    HeldState.RightWeapon = HeldInventory.Snapshot.RightWeapon;
    if (PublicPose != None && !bMotionReplayEnabled)
        PublicPose.PublishWeapons(HeldState.bIndependentWeapons,
            HeldState.LeftWeapon, HeldInventory.Snapshot.LeftId,
            HeldState.RightWeapon, HeldInventory.Snapshot.RightId);
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

replication
{
    if (Role == ROLE_Authority && bNetOwner)
        WorldEpoch, ConnectionEpoch, PawnEpoch, CalibrationEpoch,
        bSyntheticAllowed, bMotionReplayAllowed, bMotionReplayEnabled, bMotionResetPassed, bMotionResetFailed, MotionResetId, bDiagnosticAutoReady, bDiagnosticPerkReady, bDiagnosticClientsReady,
        bHandshakeAccepted, bHandshakeRejected, bSyntheticEnabled, bVRTrackingEnabled,
        AcceptedPoses, RejectedPoses, LastAcceptedSequence, HeldState, GrenadeState, VampireState, PairedStates,
        bMultiplayerZedGrabAllowed, bGrabOptIn, GrabPolicyEpoch;
}

simulated function UpdateGrabIntent(bool bOptIn)
{
    if (bLastGrabIntent != bOptIn || WorldInfo.RealTimeSeconds >= NextGrabIntent)
    {
        ServerGrabIntent(WorldEpoch, ConnectionEpoch, PawnEpoch, bOptIn);
        bLastGrabIntent = bOptIn;
        NextGrabIntent = WorldInfo.RealTimeSeconds + 0.5;
    }
}

reliable server function ServerGrabIntent(int W, int C, int P, bool bOptIn)
{
    if (!bOptIn) { RevokeGrabIntent(); return; }
    if (W != WorldEpoch || C != ConnectionEpoch || P != PawnEpoch || !IsInventoryFocusEligible()) return;
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
    return Role == ROLE_Authority && Game != None && Game.bMultiplayerZedGrabAllowed
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

unreliable server function ServerSubmitPose(NetPoseSample Sample, optional NetMotionFrame Motion)
{
    local float Now;
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
    bHaveSequence = true;
    LastAcceptedSequence = Sample.Sequence;
    LastAcceptedRealTime = Now;
    AcceptedPoses = Min(AcceptedPoses + 1, 2147483646);
    PublicPose.PublishPose(Sample, BoundPawn, bSyntheticEnabled, Motion);
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
        VerifyMotionReset();
        if (bMotionReplayEnabled && WorldInfo.RealTimeSeconds - LastAcceptedRealTime > 1.0)
            EndMotionReplay("lease_expired");
        // A bought or picked-up RAVEN-7 validates throws/recalls through the
        // channel of the tracked player now holding it.
        if (bVRTrackingEnabled && BoundPawn != None && BoundPawn.InvManager != None)
            foreach BoundPawn.InvManager.InventoryActors(class'VRWeap_Tomahawk', Hawk)
                if (Hawk.ThrowAuthority != self) { Hawk.CanThrowHand = TomahawkHandAllowed; Hawk.ThrowAuthority = self; }
        PublishGrenadeState();
        NativeAuthorityUpdate();
        if (BoundPawn != None && HeldInventory == None && BoundPawn.InvManager != None
            && (bVRTrackingEnabled || bSyntheticAllowed && bDiagnosticAutoReady))
        {
            HeldInventory = new(self) class'KF2VRNetHeldInventory';
            if (!HeldInventory.Initialize(BoundPawn)) HeldInventory = None;
        }
        if (HeldInventory != None)
        {
            HeldInventory.Refresh();
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
