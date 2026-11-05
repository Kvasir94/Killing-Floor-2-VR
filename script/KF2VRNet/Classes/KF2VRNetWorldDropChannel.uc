// Optional controller-owned transport, separate from pose/reload wire fields.
// Spawn/bind on authority after the existing channel establishes its pawn.
class KF2VRNetWorldDropChannel extends Actor
    dependsOn(KF2VRNetTypes, VRWeaponDropState);

var repnotify KF2VRNetChannel Source;
var repnotify KFPawn_Human Human;
var int BoundWorld, BoundConnection, BoundPawn;
var VRWorldDropRegistry Registry;
var private int LastRequest, LocalRequest, RateCount, LastResolved;
var private float RateStart;
var private array<KFWeapon> DroppedWeapons;

struct DropResult
{
    var int Request;
    var int MarkerSerial;
    var float FireDelay;
    var byte Action;
    var byte Hand;
    var KFWeapon Weapon;
    var bool bAccepted;
    var bool bTransfer;
    var VRWeaponDropState.HandlingState Handling;
    var byte GripRole;
    var vector RootPosition;
    var quat RootRotation;
    var KF2VRNetTypes.NetHeldState HeldState;
};
var repnotify DropResult Result;
struct ActionLane
{
    var int ReleaseSerial;
    var int ReleaseRequest, ReleaseHand, ReleaseRevision, ReleaseCalibration;
    var KFWeapon ReleaseWeapon;
    var vector ReleaseAt, ReleaseLinear, ReleaseAngular, ReleasePalm;
    var rotator ReleaseFacing;
    var bool bReleaseRoot;
    var float ReleaseDeadline;
    var VRWeaponDropState.HandlingState ReleaseHandling;
    var int PendingRequest, PendingSerial;
    var KFWeapon PendingWeapon;
    var Actor PendingTarget;
    var float PendingDeadline;
    var VRHeldInventory PendingTransferLedger;
    var DropResult PendingResult;
    var int CatchRequest, CatchSerial, CatchRevision, CatchHand;
    var VRWorldDropGun CatchProp;
    var KFWeapon CatchWeapon;
    var byte CatchRole;
    var vector CatchRoot;
    var quat CatchRootQ;
    var float CatchDeadline;
};
var private ActionLane Lanes[2];
var array<KF2VRNetWorldTrick> Tricks;
var KF2VRNetWorldTrick TrickDispatch;
var int TrickDispatchRequest;
var KF2VRNetWorldTrickClient LocalTricks;
var int TrickObservedGeneration[2], TrickExternalEpoch[2];

function int TrickHandEpoch(int Hand)
{
    local int Generation;
    Generation=HandGeneration(Hand);
    if (TrickObservedGeneration[Hand]!=0 && TrickObservedGeneration[Hand]!=Generation)
        ++TrickExternalEpoch[Hand];
    TrickObservedGeneration[Hand]=Generation;
    return TrickExternalEpoch[Hand];
}

function RecordTrickHandCommit(int Hand)
{
    TrickObservedGeneration[Hand]=HandGeneration(Hand);
}

function KF2VRNetWorldTrick FindTrick(int Token,KFWeapon W)
{
    local int I;
    for (I=0; I<Tricks.Length; ++I)
        if (Tricks[I]!=None && Tricks[I].Token==Token && Tricks[I].Weapon==W) return Tricks[I];
    return None;
}

function KF2VRNetWorldTrick BeginTrick(KFWeapon W,int Token,int Hand,byte Action,int Serial)
{
    local int I;
    local KF2VRNetWorldTrick T;
    if (!class'VRWorldWeaponPolicy'.static.Enabled()) return None;
    for (I=Tricks.Length-1; I>=0; --I)
        if (Tricks[I].Weapon==W)
        {
            if (!Tricks[I].bSettled && !Tricks[I].bAborted && Tricks[I].CurrentAction==1) return None;
            Tricks[I].Shutdown(); Tricks.Remove(I,1);
        }
    if (Tricks.Length>=16) return None;
    T=new(self) class'KF2VRNetWorldTrick';
    if (!T.Initialize(self,W,Token,Hand,Action,Serial)) return None;
    Tricks.AddItem(T);
    return T;
}

function ForgetTrick(int Token,KFWeapon W)
{
    local int I;
    for (I=Tricks.Length-1; I>=0; --I)
        if (Tricks[I].Token==Token && Tricks[I].Weapon==W)
        {
            // Keep only this already-admitted entry identity available for a
            // late exact recovery receipt. Unknown tokens never create leases.
            Tricks[I].bEntryPending=false;
            Tricks[I].Abort(); Tricks[I].Gate(false); Tricks[I].bSettled=true;
        }
}

function bool PreservesTrickHands(KFWeapon Left,KFWeapon Right,int CarryMask)
{
    local int I;
    local KF2VRNetWorldTrick T;
    local KF2VRNetItemRuntime R;
    if (!class'VRWorldWeaponPolicy'.static.Enabled()) return true;
    for (I=0; I<Tricks.Length; ++I)
    {
        T=Tricks[I]; R=Source.WorldDropRuntime(T.Weapon);
        if (R==None || R.WorldTrickPending!=T.Token || T.CurrentAction!=1) continue;
        if ((T.CurrentHand==0 ? Left : Right)!=T.Weapon
            || int((CarryMask & (1<<T.CurrentHand))!=0)!=T.CurrentGripRole) return false;
    }
    return true;
}

function bool TrickMayAdvance(KF2VRNetWorldTrick Candidate,int Hand,int Request)
{
    local int I,J;
    local KF2VRNetWorldTrick T;
    for (I=0; I<Tricks.Length; ++I)
    {
        T=Tricks[I];
        if (T==Candidate || T.bAborted) continue;
        for (J=0; J<T.Events.Length; ++J)
            if (T.Events[J].Hand==Hand && T.Events[J].Request<Request) return false;
    }
    return true;
}

function int TrickEventCount()
{
    local int I,Count;
    for (I=0; I<Tricks.Length; ++I) Count+=Tricks[I].Events.Length;
    return Count;
}

simulated function int NextWorldRequest()
{
    if (!WeaponsReady() || LocalRequest==MaxInt) return 0;
    return ++LocalRequest;
}

simulated function KF2VRNetWorldTrickClient TrickClient()
{
    if (LocalTricks==None)
    {
        LocalTricks=new(self) class'KF2VRNetWorldTrickClient';
        LocalTricks.Host=self;
    }
    return LocalTricks;
}

reliable server function ServerTrickEvent(int WE,int CE,int PE,int Token,KFWeapon W,
    KF2VRNetTypes.NetWorldTrickEvent E)
{
    local KF2VRNetWorldTrick T;
    if (!Admit(WE,CE,PE,E.Request,5,E.Hand,W)) return;
    T=FindTrick(Token,W);
    if (T==None) return;
    if (TrickEventCount()>=64) { T.Abort(); return; }
    T.Enqueue(E);
}

reliable server function ServerSettleTrick(int WE,int CE,int PE,int Request,int Token,KFWeapon W,
    int Serial,int EventId,int Hand,int Generation,bool bRecovery)
{
    local KF2VRNetWorldTrick T;
    if (!Admit(WE,CE,PE,Request,7,Hand,W)) return;
    T=FindTrick(Token,W);
    if (T!=None) T.RequestSettlement(Request,Serial,EventId,Hand,Generation,bRecovery);
}

reliable server function ServerAbortTrick(int WE,int CE,int PE,int Request,int Token,KFWeapon W)
{
    local KF2VRNetWorldTrick T;
    if (!Admit(WE,CE,PE,Request,8,-1,W)) return;
    T=FindTrick(Token,W);
    if (T!=None)
    {
        if (!T.bAborted) T.Abort();
        else ClientTrickAborted(Token,W,Registry.IsDropped(W),T.LastCommitted,Source.HeldState);
    }
    else if (Registry.Owns(W) && Registry.Find(W)!=None)
        ClientTrickAborted(Token,W,true,Registry.Find(W).ReleaseRequestId,Source.HeldState);

}

reliable client function ClientTrickProgress(int Token,int EventId,byte Action,int Hand,KFWeapon W,
    int ItemId,int Predecessor,byte GripRole,vector Root,quat RootQ,KF2VRNetTypes.NetHeldState Held)
{
    if (!WeaponsReady() || Held.Human!=Human || LocalTricks==None || !LocalTricks.Tracks(Token,W)) return;
    if (Action==0) { if (DroppedWeapons.Find(W)<0) DroppedWeapons.AddItem(W); }
    else DroppedWeapons.RemoveItem(W);
    Source.AdoptWorldDropHeldState(Held);
    TrickClient().Progress(Token,EventId,Action,Hand,W,ItemId,Predecessor,GripRole,Root,RootQ);
}

reliable client function ClientTrickSettled(int Token,int Request,int Serial,int EventId,KFWeapon W,
    int ItemId,int Hand,bool bAccepted,byte GripRole,vector Root,quat RootQ,KF2VRNetTypes.NetHeldState Held)
{
    if (!WeaponsReady() || Held.Human!=Human || LocalTricks==None || !LocalTricks.Tracks(Token,W)) return;
    TrickClient().Settled(Token,Request,Serial,EventId,W,ItemId,Hand,bAccepted,GripRole,Root,RootQ,Held);
}

reliable client function ClientTrickAborted(int Token,KFWeapon W,bool bWorld,int Committed,
    KF2VRNetTypes.NetHeldState Held)
{
    if (!WeaponsReady() || Held.Human!=Human || LocalTricks==None || !LocalTricks.Tracks(Token,W)) return;
    if (bWorld) { if (DroppedWeapons.Find(W)<0) DroppedWeapons.AddItem(W); }
    else DroppedWeapons.RemoveItem(W);
    Source.AdoptWorldDropHeldState(Held);
    TrickClient().Aborted(Token,W,bWorld,Committed);
}


delegate Resolved(DropResult Reply) {}
delegate Returned(KFWeapon W, Object Lifetime) {}

replication
{
    if (Role == ROLE_Authority)
        Source, Human, BoundWorld, BoundConnection, BoundPawn, Result;
}

function bool Initialize(KF2VRNetChannel InSource, KFPawn_Human InHuman)
{
    if (Role != ROLE_Authority || InSource == None || InHuman == None
        || Owner != InSource.Owner || InHuman.Controller != Owner) return false;
    Source = InSource;
    Human = InHuman;
    BoundWorld = Source.WorldEpoch;
    BoundConnection = Source.ConnectionEpoch;
    BoundPawn = Source.PawnEpoch;
    Registry = new(self) class'VRWorldDropRegistry';
    Registry.Initialize(self, Human);
    Registry.OnReturned = NotifyReturned;
    bForceNetUpdate = true;
    return true;
}

function bool ContextValid()
{
    return Registry != None && Source != None && !Source.bDeleteMe
        && Source.bHandshakeAccepted && Source.bVRTrackingEnabled
        && Source.NativeWorldDropVersion == 9 && Source.HeldState.bAvailable
        && !Source.bSyntheticEnabled && Source.Owner == Owner && Human != None
        && !Human.bDeleteMe && Human.Health > 0 && Human.Controller == Owner
        && Controller(Owner) != None && Controller(Owner).Pawn == Human
        && Source.WorldEpoch == BoundWorld && Source.ConnectionEpoch == BoundConnection
        && Source.PawnEpoch == BoundPawn;
}

function bool Admit(int WE, int CE, int PE, int Request, byte Action, int Hand, KFWeapon W)
{
    // Configure and pocket still service magazine escrow while gun actions are gated.
    if ((!class'VRWorldWeaponPolicy'.static.Enabled() && Action != 3 && Action != 4)
        || !ContextValid() || WE != BoundWorld || CE != BoundConnection || PE != BoundPawn
        || Request <= LastRequest || Request <= 0)
    {
        `log("KF2VR_WORLD_DROP phase=server-admit-refused action=" $ Action @ "request=" $ Request
            @ "last=" $ LastRequest @ "policy=" $ class'VRWorldWeaponPolicy'.static.Enabled()
            @ "context=" $ ContextValid() @ "epochs=" $ (WE == BoundWorld && CE == BoundConnection && PE == BoundPawn)
            @ "handshake=" $ (Source != None && Source.bHandshakeAccepted)
            @ "tracking=" $ (Source != None && Source.bVRTrackingEnabled)
            @ "drop_version=" $ (Source != None ? Source.NativeWorldDropVersion : -1)
            @ "held_available=" $ (Source != None && Source.HeldState.bAvailable)
            @ "synthetic=" $ (Source != None && Source.bSyntheticEnabled));
        if (Request > 0 && WE == BoundWorld && CE == BoundConnection && PE == BoundPawn)
            Reply(Request, Action, Hand, W, false);
        return false;
    }
    LastRequest = Request;
    if (WorldInfo.RealTimeSeconds - RateStart >= 1.0)
    {
        RateStart = WorldInfo.RealTimeSeconds;
        RateCount = 0;
    }
    if (++RateCount > 64)
    {
        Reply(Request, Action, Hand, W, false);
        return false;
    }
    return true;
}

function bool HandPosition(int Hand, out vector Position)
{
    local KFPawn_Human Body;
    local byte Pose;
    local int Revision;
    return Hand >= 0 && Hand <= 1 && Source.ContactHand(Hand, Body, Position, Pose, Revision)
        && Body == Human;
}

function Reply(int Request, byte Action, int Hand, KFWeapon W, bool bAccepted,
    optional byte GripRole, optional vector RootPosition, optional quat RootRotation, optional int MarkerSerial,
    optional bool bTransfer, optional VRWeaponDropState.HandlingState Handling, optional float TransferFireDelay)
{
    local KF2VRNetTypes.NetHeldState EmptyHeldState;
    local KF2VRNetItemRuntime R;
    Result.Request = Request;
    Result.MarkerSerial = MarkerSerial;
    R = Source != None ? Source.WorldDropRuntime(W) : None;
    Result.FireDelay = R != None ? FMax(0.0, R.WorldDropFireReadyAt - WorldInfo.TimeSeconds) : 0.0;
    if (bTransfer) Result.FireDelay = FMax(Result.FireDelay, TransferFireDelay);
    Result.Action = Action;
    Result.Hand = byte(Hand);
    Result.Weapon = W;
    Result.bAccepted = bAccepted;
    Result.bTransfer = bTransfer;
    Result.Handling = Handling;
    Result.GripRole = GripRole;
    Result.RootPosition = RootPosition;
    Result.RootRotation = RootRotation;
    Result.HeldState = EmptyHeldState;
    if (Source != None && !Source.bDeleteMe)
    {
        Source.PublishHeldState();
        Result.HeldState = Source.HeldState;
    }
    bForceNetUpdate = true;
    ClientResolved(Result);
}

reliable client function ClientResolved(DropResult ReplyResult)
{
    local int H;
    if (!class'VRWorldWeaponPolicy'.static.Enabled() && ReplyResult.Action != 3 && ReplyResult.Action != 4) return;
    H = PendingHand(ReplyResult.Request);
    if (H >= 0 && ReplyResult.Request == Lanes[H].PendingRequest) Lanes[H].PendingResult = ReplyResult;
    // Replies for independent hands may finish out of request order.
    LastResolved = Max(LastResolved, ReplyResult.Request);
    Result = ReplyResult;
    if (ReplyResult.bAccepted && ReplyResult.Action == 0)
    {
        if (DroppedWeapons.Find(ReplyResult.Weapon) == INDEX_NONE) DroppedWeapons.AddItem(ReplyResult.Weapon);
    }
    else if (ReplyResult.bAccepted && ReplyResult.Action == 1) DroppedWeapons.RemoveItem(ReplyResult.Weapon);
    // ReadResult waits for the same-weapon return marker, then adopts the
    // complete held snapshot before notifying the local input owner.
}

function NotifyReturned(KFWeapon W)
{
    if (Source != None && !Source.bDeleteMe) Source.PublishHeldState();
    ClientReturned(W);
}

reliable client function ClientReturned(KFWeapon W)
{
    DroppedWeapons.RemoveItem(W);
    Returned(W, self);
}

simulated function bool IsDropped(KFWeapon W)
{
    return class'VRWorldWeaponPolicy'.static.Enabled() && W != None && DroppedWeapons.Find(W) != INDEX_NONE;
}

simulated function RemapDroppedIdentity(KFWeapon OldWeapon, KFWeapon NewWeapon, bool bDropped)
{
    DroppedWeapons.RemoveItem(OldWeapon);
    if (class'VRWorldWeaponPolicy'.static.Enabled() && bDropped && NewWeapon != None && DroppedWeapons.Find(NewWeapon) == INDEX_NONE)
        DroppedWeapons.AddItem(NewWeapon);
}

simulated function bool LaneBusy(int H)
{
    if (H < 0 || H > 1) return true;
    if (!class'VRWorldWeaponPolicy'.static.Enabled()) return false;
    return Role == ROLE_Authority ? (Lanes[H].ReleaseRequest > 0 || Lanes[H].CatchRequest > 0) : Lanes[H].PendingRequest > 0;
}

simulated function bool Busy() { return LaneBusy(0) || LaneBusy(1); }

simulated function bool OtherWeaponPending(KFWeapon W, int Hand)
{
    if (W == None || Hand < 0 || Hand > 1) return false;
    return Lanes[1 - Hand].PendingRequest > 0 && Lanes[1 - Hand].PendingWeapon == W;
}

simulated function int PendingHand(int Request)
{
    local int H;
    for (H = 0; H < 2; ++H) if (Request > 0 && Lanes[H].PendingRequest == Request) return H;
    return -1;
}

function int ReleaseToken(int Hand)
{
    if (Hand < 0 || Hand > 1) return 0;
    if (TrickDispatch!=None && TrickDispatch.CurrentHand==Hand) return TrickDispatchRequest;
    return Lanes[Hand].ReleaseSerial;
}

simulated function int HandGeneration(int Hand)
{
    return Hand == 0 ? Source.HeldState.LeftGeneration : Source.HeldState.RightGeneration;
}

function FinishRelease(int H, bool bAccepted)
{
    local int Request, Hand, Serial;
    local KFWeapon W;
    local KF2VRNetItemRuntime R;
    Request = Lanes[H].ReleaseRequest; Hand = Lanes[H].ReleaseHand; Serial = Lanes[H].ReleaseSerial; W = Lanes[H].ReleaseWeapon;
    Lanes[H].ReleaseRequest = 0; Lanes[H].ReleaseSerial = 0; Lanes[H].ReleaseWeapon = None;
    if (!bAccepted) ForgetTrick(Request,W);
    R = Source != None ? Source.WorldDropRuntime(W) : None;
    if (R != None && R.NativeReady == 1) W.ClientForceAmmoUpdate(-255, Serial);
    else Serial = 0;
    Reply(Request, 0, Hand, W, bAccepted,,,, Serial);
}

function bool PreservesPairedSession(KFWeapon W, int Hand)
{
    local int H;
    if (!class'VRWorldWeaponPolicy'.static.Enabled()) return true;
    if (Source == None) return false;
    for (H = 0; H < 2; ++H)
    {
        if (Lanes[H].ReleaseRequest > 0 && !Source.WorldActionDisjointFromPaired(Lanes[H].ReleaseWeapon, H, W, Hand)) return false;
        if (Lanes[H].CatchRequest > 0 && (Lanes[H].CatchProp == None || Lanes[H].CatchProp.DropOwner != Human
            || !Source.WorldActionDisjointFromPaired(Lanes[H].CatchWeapon, H, W, Hand))) return false;
    }
    return true;
}

function UpdateRelease(int H)
{
    local byte Readiness;
    local VRWorldDropGun Prop;
    local int ItemId, ItemRevision;
    local KF2VRNetWorldTrick Trick;
    if (Lanes[H].ReleaseRequest <= 0) return;
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || !ContextValid() || Source.CalibrationEpoch != Lanes[H].ReleaseCalibration
        || WorldInfo.RealTimeSeconds >= Lanes[H].ReleaseDeadline)
    { FinishRelease(H, false); return; }
    Readiness = Source.WorldReleaseReadiness(Lanes[H].ReleaseWeapon, Lanes[H].ReleaseHand, Lanes[H].ReleaseRevision, Lanes[H].ReleaseSerial);
    if (Readiness == 2) { FinishRelease(H, false); return; }
    if (Readiness == 0) return;
    Trick=FindTrick(Lanes[H].ReleaseRequest,Lanes[H].ReleaseWeapon);
    if (Trick==None || !Trick.Gate(true)) { FinishRelease(H,false); return; }
    Source.WorldDropIdentity(Lanes[H].ReleaseWeapon, ItemId, ItemRevision);
    TrickHandEpoch(H);
    Prop = Registry.Release(Lanes[H].ReleaseWeapon, Lanes[H].ReleaseHand, Lanes[H].ReleaseAt, Lanes[H].ReleaseFacing,
        Lanes[H].ReleaseLinear, Lanes[H].ReleaseAngular, Lanes[H].bReleaseRoot, Lanes[H].ReleasePalm, Lanes[H].ReleaseHandling);
    if (Prop != None)
    {
        RecordTrickHandCommit(H);
        Prop.WorldTrickLeaseToken = Trick.Token;
        Prop.RememberRelease(Lanes[H].ReleaseRequest, ItemId, HandGeneration(H), Lanes[H].ReleaseAngular);
        Trick.Activate(Prop,Lanes[H].ReleaseHandling);
        Source.PublishWorldTransition(Source.CaptureWorldTransition(H, HandGeneration(H), 0,
            Lanes[H].ReleaseRequest, ItemId, Prop));
    }
    FinishRelease(H, Prop != None);
}

function FinishCatch(int H, bool bAccepted)
{
    local int Request, Serial, Hand;
    local KFWeapon W;
    local KF2VRNetItemRuntime R;
    Request = Lanes[H].CatchRequest; Serial = Lanes[H].CatchSerial; Hand = Lanes[H].CatchHand;
    W = Lanes[H].CatchWeapon;
    if (!bAccepted) ForgetTrick(Request,W);
    if (Lanes[H].CatchProp != None) Lanes[H].CatchProp.bCatchPending = false;
    Lanes[H].CatchRequest = 0; Lanes[H].CatchSerial = 0; Lanes[H].CatchProp = None; Lanes[H].CatchWeapon = None;
    R = Source != None ? Source.WorldDropRuntime(W) : None;
    if (R != None && R.NativeReady == 1) W.ClientForceAmmoUpdate(-255, Serial);
    else Serial = 0;
    Reply(Request, 1, Hand, W, bAccepted, Lanes[H].CatchRole, Lanes[H].CatchRoot, Lanes[H].CatchRootQ, Serial);
}

function UpdateCatch(int H)
{
    local KF2VRNetItemRuntime R;
    local vector FreshHand;
    local KF2VRNetTypes.NetWorldTransition Transition;
    local bool bAccepted;
    local KF2VRNetWorldTrick Trick;
    local VRWeaponDropState.HandlingState Handling;
    local string Why;
    if (Lanes[H].CatchRequest <= 0) return;
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || !ContextValid() || Lanes[H].CatchProp == None || Lanes[H].CatchProp.bDeleteMe || Lanes[H].CatchProp.bReturning
        || !Source.WorldPairedSessionsAllow(Lanes[H].CatchWeapon, Lanes[H].CatchHand)
        || HandGeneration(H) != Lanes[H].CatchRevision || !HandPosition(Lanes[H].CatchHand, FreshHand)
        || WorldInfo.RealTimeSeconds >= Lanes[H].CatchDeadline)
    {
        if (!ContextValid()) Why = "context";
        else if (Lanes[H].CatchProp == None || Lanes[H].CatchProp.bDeleteMe) Why = "prop-gone";
        else if (Lanes[H].CatchProp.bReturning) Why = "returning";
        else if (!Source.WorldPairedSessionsAllow(Lanes[H].CatchWeapon, Lanes[H].CatchHand)) Why = "paired-session";
        else if (HandGeneration(H) != Lanes[H].CatchRevision) Why = "hand-revision";
        else if (!HandPosition(Lanes[H].CatchHand, FreshHand)) Why = "hand-pose";
        else Why = "deadline";
        LogCatchFail(H, Why);
        FinishCatch(H, false); return;
    }
    R = Source.WorldDropRuntime(Lanes[H].CatchProp.OwnedWeapon);
    if (R == None || R.WorldDropped != 1 || R.WeaponBarrierSerial > Lanes[H].CatchSerial)
    {
        LogCatchFail(H, R == None ? "no-runtime" : ("runtime dropped=" $ R.WorldDropped
            @ "barrier=" $ R.WeaponBarrierSerial @ "serial=" $ Lanes[H].CatchSerial));
        FinishCatch(H, false); return;
    }
    if (R.WeaponBarrierSerial != Lanes[H].CatchSerial) return;
    Trick=FindTrick(Lanes[H].CatchRequest,Lanes[H].CatchWeapon);
    if (Trick==None || !Trick.Gate(true)) { LogCatchFail(H, Trick==None ? "no-trick" : "trick-gate"); FinishCatch(H,false); return; }
    Handling=Lanes[H].CatchProp.Handling;
    TrickHandEpoch(H);
    Transition = Source.CaptureWorldTransition(H, 0, 1, Lanes[H].CatchRequest,
        Lanes[H].CatchProp.ReleasedItemId, Lanes[H].CatchProp, Lanes[H].CatchRequest);
    bAccepted = Registry.CompleteOwnedCatch(Lanes[H].CatchProp, Lanes[H].CatchHand,
        Lanes[H].CatchRole, Lanes[H].CatchRoot, Lanes[H].CatchRootQ);
    if (bAccepted)
    {
        RecordTrickHandCommit(H);
        Trick.Activate(None,Handling,Lanes[H].CatchRole,Lanes[H].CatchRoot,Lanes[H].CatchRootQ);
        Transition.Generation = HandGeneration(H);
        Source.PublishWorldTransition(Transition);
    }
    else LogCatchFail(H, "complete-owned-catch");
    FinishCatch(H, bAccepted);
}

function LogCatchFail(int H, string Why)
{
    `log("KF2VR_WORLD_DROP phase=server-catch-failed request=" $ Lanes[H].CatchRequest @ "hand=" $ H
        @ "weapon=" $ (Lanes[H].CatchWeapon != None ? string(Lanes[H].CatchWeapon.Class) : "None") @ "why=" $ Why);
}

// Action 0 release; 1 catch; 2 radial recall; 3 setting update.
reliable server function ServerRelease(int WE, int CE, int PE, int Request,
    int ExpectedHeldRevision, int Serial, KFWeapon W, byte Hand, vector At, rotator Facing, vector Linear, vector Angular,
    optional bool bWeaponRootPose, optional VRWeaponDropState.HandlingState Snapshot)
{
    local vector AcceptedHand;
    if (!Admit(WE, CE, PE, Request, 0, Hand, W)) return;
    // This actor has its own reliable stream. A newer regrip on Source must
    // retire a queued release even when it happens to hold the same actor.
    if (Hand >= 0 && Hand < 2 && !LaneBusy(Hand) && Serial > 0 && Serial < MaxInt && ExpectedHeldRevision > 0
        && HandGeneration(Hand) == ExpectedHeldRevision
        && Source.WorldPairedSessionsAllow(W, Hand)
        && HandPosition(Hand, AcceptedHand)
        && VSizeSq(At - AcceptedHand) <= Square(bWeaponRootPose ? 110.0 : 35.0)
        && Registry.Owns(W))
    {
        if (BeginTrick(W,Request,Hand,0,Serial)==None) { Reply(Request,0,Hand,W,false); return; }
        Lanes[Hand].ReleaseRequest = Request; Lanes[Hand].ReleaseSerial = Serial; Lanes[Hand].ReleaseWeapon = W; Lanes[Hand].ReleaseHand = Hand;
        Lanes[Hand].ReleaseRevision = ExpectedHeldRevision; Lanes[Hand].ReleaseCalibration = Source.CalibrationEpoch;
        Lanes[Hand].ReleaseAt = At; Lanes[Hand].ReleaseFacing = Facing; Lanes[Hand].ReleaseLinear = Linear; Lanes[Hand].ReleaseAngular = Angular;
        Lanes[Hand].ReleasePalm = AcceptedHand; Lanes[Hand].bReleaseRoot = bWeaponRootPose;
        Lanes[Hand].ReleaseHandling = Snapshot;
        Lanes[Hand].ReleaseDeadline = WorldInfo.RealTimeSeconds + 1.0;
        UpdateRelease(Hand);
    }
    else
    {
        `log("KF2VR_WORLD_DROP phase=server-release-refused request=" $ Request @ "hand=" $ Hand
            @ "weapon=" $ (W != None ? string(W.Class) : "None") @ "lane_busy=" $ (Hand < 2 && LaneBusy(Hand))
            @ "serial=" $ Serial @ "revision=" $ ExpectedHeldRevision);
        Reply(Request, 0, Hand, W, false);
    }
}

reliable server function ServerCancelRelease(int WE, int CE, int PE, int Request)
{
    local int H;
    if (WE != BoundWorld || CE != BoundConnection || PE != BoundPawn) return;
    for (H = 0; H < 2; ++H)
    {
        if (Request == Lanes[H].ReleaseRequest) FinishRelease(H, false);
        if (Request == Lanes[H].CatchRequest) FinishCatch(H, false);
    }
}

reliable server function ServerCatch(int WE, int CE, int PE, int Request,
    int ExpectedHeldRevision, int Serial, Actor Target, byte Hand)
{
    local vector AcceptedHand, RootPosition;
    local quat RootRotation;
    local byte GripRole;
    local KFWeapon W, CaughtWeapon;
    local bool bAccepted;
    local VRWeaponDropState.HandlingState Handling;
    local KF2VRNetWorldDropChannel DonorChannel;
    local KF2VRNetItemRuntime DonorRuntime, RecipientRuntime;
    local float FireDelay;
    local VRWorldDropGun Prop;
    local VRStockWorldPickup StockPickup;
    local KF2VRNetTypes.NetWorldTransition Transition;
    local int ItemId, ItemRevision;
    Prop = VRWorldDropGun(Target);
    if (Prop != None) W = Prop.OwnedWeapon;
    if (!Admit(WE, CE, PE, Request, 1, Hand, W)) return;
    if (Hand >= 0 && Hand < 2 && Registry.bEnabled && !LaneBusy(Hand) && ExpectedHeldRevision > 0 && HandGeneration(Hand) == ExpectedHeldRevision
        && HandPosition(Hand, AcceptedHand))
    {
        if (Prop != None && Prop.DropOwner == Human && Serial > 0 && Serial < MaxInt
            && Source.WorldPairedSessionsAllow(W, Hand)
            && Registry.ReserveOwnedCatch(Prop, Hand, AcceptedHand, Lanes[Hand].CatchRole, Lanes[Hand].CatchRoot, Lanes[Hand].CatchRootQ))
        {
            if (BeginTrick(W,Request,Hand,1,Serial)==None)
            {
                `log("KF2VR_WORLD_DROP phase=server-catch-refused request=" $ Request @ "hand=" $ Hand @ "why=no-trick-slot");
                Prop.bCatchPending=false; Reply(Request,1,Hand,W,false); return;
            }
            Lanes[Hand].CatchRequest = Request; Lanes[Hand].CatchSerial = Serial; Lanes[Hand].CatchRevision = ExpectedHeldRevision;
            Lanes[Hand].CatchHand = Hand; Lanes[Hand].CatchProp = Prop; Lanes[Hand].CatchWeapon = W; Lanes[Hand].CatchDeadline = WorldInfo.RealTimeSeconds + 1.0;
            UpdateCatch(Hand);
            return;
        }
        if (Prop != None && Prop.DropOwner != Human && Serial > 0 && Serial < MaxInt
            && Source.IncomingWorldActionsReady(Target, Hand)
            && Source.CanReceiveWorldContact(Hand))
        {
            // Capture before the donor's commit retires the prop and may
            // replace a paired wrapper with a genuinely owned stock single.
            Handling = Prop.Handling;
            FireDelay = class'VRWorldDropGun'.static.RemainingFireDelay(W);
            if (Prop.SourceRegistry != None) DonorChannel = KF2VRNetWorldDropChannel(Prop.SourceRegistry.Host);
            if (DonorChannel != None && DonorChannel.Source != None
                && !DonorChannel.Source.WorldTransferRevisionReady())
            { Reply(Request, 1, Hand, W, false); return; }
            if (DonorChannel != None && DonorChannel.Source != None)
                DonorRuntime = DonorChannel.Source.WorldDropRuntime(W);
            if (DonorRuntime != None)
                FireDelay = FMax(FireDelay, DonorRuntime.WorldDropFireReadyAt - WorldInfo.TimeSeconds);
            Transition = Source.CaptureWorldTransition(Hand, 0, 1, Request, 0, Prop);
            bAccepted = Registry.Catch(Prop, Human, Hand, AcceptedHand, GripRole, RootPosition, RootRotation, CaughtWeapon);
            if (bAccepted)
            {
                W = CaughtWeapon;
                class'VRWeaponDropState'.static.MatchTransferredFamily(W, Handling);
                Source.AdoptWorldDropHandling(W, Handling);
                if (Source.AdoptTransferredWorldWeapon(W, Hand, GripRole))
                {
                    RecipientRuntime = Source.WorldDropRuntime(W);
                    if (RecipientRuntime != None)
                        RecipientRuntime.WorldDropFireReadyAt = FMax(RecipientRuntime.WorldDropFireReadyAt,
                            WorldInfo.TimeSeconds + FMax(FireDelay, 0.0));
                }
                // ClientGivenTo and actual ammo corrections precede this on
                // the newly owned weapon's reliable stream. Never marker the
                // donor actor before ownership moves to this connection.
                W.ClientForceAmmoUpdate(-255, Serial);
                Source.WorldDropIdentity(W, ItemId, ItemRevision);
                Transition.ItemId = ItemId; Transition.Generation = HandGeneration(Hand);
                Source.PublishWorldTransition(Transition);
                Reply(Request, 1, Hand, W, true, GripRole, RootPosition, RootRotation,
                    Serial, true, Handling, FMax(FireDelay, 0.0));
                return;
            }
        }
        if (Prop == None && Target != None && !Target.bDeleteMe && Target.WorldInfo == WorldInfo
            && Source.IncomingWorldActionsReady(Target, Hand)
            && Serial > 0 && Serial < MaxInt && Source.CanReceiveWorldContact(Hand)
            && class'VRStockWorldPickup'.static.IsPickup(Target))
        {
            // The server resolves stock pickup contents. Client inventory
            // references are never authority or an RPC target for this path.
            StockPickup = new(self) class'VRStockWorldPickup';
            CaughtWeapon = StockPickup.Catch(Target, Human, AcceptedHand, Hand);
            if (class'VRWorldDropTransfer'.static.Owns(Human, CaughtWeapon))
            {
                W = CaughtWeapon;
                Handling.Family = class'VRWeaponDropState'.static.FamilyFor(W.Class);
                Source.AdoptTransferredWorldWeapon(W, Hand, 0);
                W.ClientForceAmmoUpdate(-255, Serial);
                Reply(Request, 1, Hand, W, true, 0, RootPosition, RootRotation, Serial, true, Handling);
                return;
            }
        }
    }
    if (bAccepted) W = CaughtWeapon;
    if (!bAccepted) LogCatchRefusal(Request, ExpectedHeldRevision, Serial, Prop, Target, Hand);
    Reply(Request, 1, Hand, W, bAccepted, GripRole, RootPosition, RootRotation);
}

// Names every server catch gate, so a refused grab in a log says which one held.
function LogCatchRefusal(int Request, int ExpectedHeldRevision, int Serial, VRWorldDropGun Prop, Actor Target,
    byte Hand)
{
    local vector Palm;
    local bool bHand;
    bHand = Hand < 2 && HandPosition(Hand, Palm);
    `log("KF2VR_WORLD_DROP phase=server-catch-refused request=" $ Request @ "hand=" $ Hand
        @ "target=" $ (Target != None ? string(Target.Class) : "None")
        @ "own=" $ (Prop != None && Prop.DropOwner == Human)
        @ "enabled=" $ Registry.bEnabled @ "lane_busy=" $ LaneBusy(Hand)
        @ "revision=" $ ExpectedHeldRevision $ "/" $ (Hand < 2 ? HandGeneration(Hand) : -1)
        @ "hand_pose=" $ bHand @ "serial=" $ Serial
        @ "paired_ok=" $ (Prop != None && Prop.OwnedWeapon != None && Source.WorldPairedSessionsAllow(Prop.OwnedWeapon, Hand))
        @ "pickup_ok=" $ (Prop != None && Prop.CanPickupBy(Human))
        @ "catch_pending=" $ (Prop != None && Prop.bCatchPending)
        @ "registry_match=" $ (Prop != None && Prop.SourceRegistry == Registry && Registry.Find(Prop.OwnedWeapon) == Prop)
        @ "grip_role=" $ ((Prop != None && bHand) ? Prop.GripRoleAt(Palm, Hand, Registry.bSupportCatch) : -9)
        @ "palm_distance=" $ ((Prop != None && bHand) ? VSize(Palm - Prop.GrabPosition()) : -1.0));
}

reliable server function ServerRecall(int WE, int CE, int PE, int Request, KFWeapon W)
{
    if (!Admit(WE, CE, PE, Request, 2, 0, W)) return;
    Reply(Request, 2, 0, W, Registry.TryRecall(W));
}

reliable server function ServerConfigure(int WE, int CE, int PE, int Request, bool bEnabled, float Delay,
    optional bool bAllowSupportCatch, optional bool bOtherPlayers, optional bool bAllowRecall=true)
{
    if (!Admit(WE, CE, PE, Request, 3, 0, None)) return;
    Registry.Configure(bEnabled, Delay, bAllowSupportCatch, bOtherPlayers, bAllowRecall);
    Reply(Request, 3, 0, None, true);
}

reliable server function ServerPocketMagazine(int WE, int CE, int PE, int Request,
    VRWorldDropMagazine Prop, byte Hand)
{
    local vector AcceptedHand;
    local KFWeapon W;
    local bool bAccepted;
    local int ActualCredited;
    if (Prop != None) W = Prop.SourceWeapon;
    if (!Admit(WE, CE, PE, Request, 4, Hand, W)) return;
    if (HandPosition(Hand, AcceptedHand)) bAccepted = Registry.TryPocketMagazine(Prop, AcceptedHand, ActualCredited);
    Reply(Request, 4, Hand, W, bAccepted);
}

simulated function bool Ready()
{
    return Source != None && Human != None && Human.Health > 0
        && Source.CanRequestHeldWeapons() && Source.HeldState.NativeWeaponActionVersion == 9 && Source.WorldEpoch == BoundWorld
        && Source.ConnectionEpoch == BoundConnection && Source.PawnEpoch == BoundPawn;
}

simulated function bool WeaponsReady()
{
    return class'VRWorldWeaponPolicy'.static.Enabled() && Ready();
}

simulated function int RequestRelease(KFWeapon W, int Hand, vector At, rotator Facing,
    vector Linear, vector Angular, optional bool bWeaponRootPose, optional VRWeaponDropState.HandlingState Snapshot)
{
    local int Serial;
    if (!WeaponsReady() || LaneBusy(Hand) || !Source.WorldActionsSettled(W, Hand) || !class'VRWorldDropGun'.static.ReleaseActionReady(W)
        || Hand < 0 || Hand > 1 || LocalRequest == MaxInt) return 0;
    Serial = Source.NextWeaponActionSerial();
    if (Serial <= 0) return 0;
    W.StopFire(0); W.StopFire(1);
    W.SyncCurrentAmmoCount(255, Serial);
    ++LocalRequest;
    Lanes[Hand].PendingRequest = LocalRequest; Lanes[Hand].PendingSerial = Serial; Lanes[Hand].PendingWeapon = W;
    Lanes[Hand].PendingDeadline = WorldInfo.RealTimeSeconds + 3.0;
    ServerRelease(BoundWorld, BoundConnection, BoundPawn, LocalRequest,
        HandGeneration(Hand), Serial, W, byte(Hand), At, Facing, Linear, Angular, bWeaponRootPose, Snapshot);
    return LocalRequest;
}

simulated function int RequestCatch(Actor Target, int Hand, optional VRHeldInventory TransferLedger)
{
    local int Serial;
    local VRWorldDropGun Prop;
    if (!WeaponsReady() || LaneBusy(Hand) || Target == None || Target.bDeleteMe
        || Hand < 0 || Hand > 1 || LocalRequest == MaxInt) return 0;
    if (Lanes[1 - Hand].PendingRequest > 0 && Lanes[1 - Hand].PendingTarget == Target) return 0;
    Prop = VRWorldDropGun(Target);
    if (Prop != None && OtherWeaponPending(Prop.OwnedWeapon, Hand)) return 0;
    if (Prop != None && Prop.DropOwner == Human)
    {
        if (!Source.WorldActionsSettled(Prop.OwnedWeapon, Hand)) return 0;
    }
    else if (!Source.WorldActionsSettled(None, Hand, Target)) return 0;
    if (Prop == None && !class'VRStockWorldPickup'.static.IsPickup(Target)) return 0;
    Serial = Source.NextWeaponActionSerial();
    if (Serial <= 0) return 0;
    if (Prop != None && Prop.DropOwner == Human)
    {
        if (Prop.OwnedWeapon == None) return 0;
        Prop.OwnedWeapon.SyncCurrentAmmoCount(255, Serial);
    }
    else
    {
        // The resulting actor can differ from Prop.OwnedWeapon. Arm the
        // first-candidate mailbox before any recipient-side weapon RPC arrives.
        if (TransferLedger == None || TransferLedger.Human != Human
            || !TransferLedger.ExpectTransferReceipt(Serial)) return 0;
        Lanes[Hand].PendingTransferLedger = TransferLedger;
    }
    ++LocalRequest;
    Lanes[Hand].PendingRequest = LocalRequest; Lanes[Hand].PendingSerial = Serial; Lanes[Hand].PendingWeapon = Prop != None ? Prop.OwnedWeapon : None;
    Lanes[Hand].PendingTarget = Target;
    Lanes[Hand].PendingDeadline = WorldInfo.RealTimeSeconds + 3.0;
    ServerCatch(BoundWorld, BoundConnection, BoundPawn, LocalRequest, HandGeneration(Hand), Serial, Target, byte(Hand));
    return LocalRequest;
}

simulated function int RequestRecall(KFWeapon W)
{
    if (!WeaponsReady() || Busy() || W == None || LocalRequest == MaxInt) return 0;
    ++LocalRequest;
    ServerRecall(BoundWorld, BoundConnection, BoundPawn, LocalRequest, W);
    return LocalRequest;
}

simulated function int RequestConfigure(bool bEnabled, float Delay, optional bool bAllowSupportCatch,
    optional bool bOtherPlayers, optional bool bAllowRecall=true)
{
    if (!Ready() || Busy() || LocalRequest == MaxInt) return 0;
    ++LocalRequest;
    ServerConfigure(BoundWorld, BoundConnection, BoundPawn, LocalRequest,
        bEnabled, Delay, bAllowSupportCatch, bOtherPlayers, bAllowRecall);
    return LocalRequest;
}

simulated function int RequestPocketMagazine(VRWorldDropMagazine Prop, int Hand)
{
    if (!Ready() || Prop == None || Hand < 0 || Hand > 1 || LocalRequest == MaxInt) return 0;
    ++LocalRequest;
    ServerPocketMagazine(BoundWorld, BoundConnection, BoundPawn, LocalRequest, Prop, byte(Hand));
    return LocalRequest;
}

simulated function byte ReadResult(int Request, VRWeaponRuntime Runtime, out byte Action,
    out byte Accepted, out KFWeapon W, out byte GripRole, out vector RootPosition, out quat RootRotation,
    optional bool bManualCycles, optional bool bPhysicalHandling)
{
    local int H;
    local bool bLate, bAnswered;
    H = PendingHand(Request);
    if (H < 0) return 2;
    // An answered non-transfer result is the authority's verdict; a late or
    // overtaken marker only orders stock count corrections. Settle it rather
    // than cancelling an action the authority already accepted.
    bLate = WorldInfo.RealTimeSeconds >= Lanes[H].PendingDeadline;
    bAnswered = Lanes[H].PendingResult.Request == Request
        && !(Lanes[H].PendingResult.bAccepted && Lanes[H].PendingResult.bTransfer);
    if (!WeaponsReady() || (bLate && !bAnswered))
    {
        ServerCancelRelease(BoundWorld, BoundConnection, BoundPawn, Request);
        ClearPending(H);
        return 2;
    }
    if (Lanes[H].PendingResult.Request != Request) return 0;
    if (Lanes[H].PendingResult.bAccepted && Lanes[H].PendingResult.bTransfer)
    {
        if (Lanes[H].PendingTransferLedger == None || Lanes[H].PendingTransferLedger.Human != Human || Lanes[H].PendingResult.MarkerSerial != Lanes[H].PendingSerial
            || Lanes[H].PendingResult.MarkerSerial <= 0) { ClearPending(H); return 2; }
        if (!Lanes[H].PendingTransferLedger.TransferReceiptReady(Lanes[H].PendingResult.Weapon, Lanes[H].PendingSerial)) return 0;
        Runtime = Lanes[H].PendingTransferLedger.RegisterItem(Lanes[H].PendingResult.Weapon);
        if (Runtime == None) return 0;
        // Install paid mechanism obligations before held-state reconciliation
        // can bind, activate or allow input on this freshly owned runtime.
        if (!class'VRWeaponDropState'.static.ApplyToRuntime(Runtime, Lanes[H].PendingResult.Handling,
            bManualCycles, bPhysicalHandling)) return 0;
    }
    else if (Lanes[H].PendingResult.MarkerSerial > 0 && !bLate)
    {
        if (Runtime == None || Runtime.Item != Lanes[H].PendingWeapon) return 0;
        if (Runtime.WeaponReceiptSerial < Lanes[H].PendingResult.MarkerSerial) return 0;
    }
    // An owned actor already retains its original local deadline. Reapplying
    // server remaining time on every catch would add RTT to each stunt loop.
    if (Runtime != None && Runtime.WorldDropFireReadyAt <= 0 && Lanes[H].PendingResult.FireDelay > 0)
        Runtime.WorldDropFireReadyAt = FMax(Runtime.WorldDropFireReadyAt, WorldInfo.TimeSeconds + Lanes[H].PendingResult.FireDelay);
    Source.AdoptWorldDropHeldState(Lanes[H].PendingResult.HeldState);
    Action = Lanes[H].PendingResult.Action; Accepted = byte(Lanes[H].PendingResult.bAccepted); W = Lanes[H].PendingResult.Weapon;
    GripRole = Lanes[H].PendingResult.GripRole; RootPosition = Lanes[H].PendingResult.RootPosition; RootRotation = Lanes[H].PendingResult.RootRotation;
    Resolved(Lanes[H].PendingResult);
    ClearPending(H);
    return 1;
}

simulated function ClearPending(int H)
{
    if (Lanes[H].PendingTransferLedger != None) Lanes[H].PendingTransferLedger.ForgetTransferReceipt(Lanes[H].PendingSerial);
    Lanes[H].PendingTransferLedger = None;
    Lanes[H].PendingRequest = 0; Lanes[H].PendingSerial = 0; Lanes[H].PendingWeapon = None;
    Lanes[H].PendingTarget = None;
}

simulated function KFWeapon PendingItem(int Request)
{
    local int H;
    H = PendingHand(Request);
    return H >= 0 ? Lanes[H].PendingWeapon : None;
}

simulated function Abandon()
{
    local int H;
    for (H = 0; H < 2; ++H)
    {
        if (Lanes[H].PendingRequest > 0) ServerCancelRelease(BoundWorld, BoundConnection, BoundPawn, Lanes[H].PendingRequest);
        ClearPending(H);
    }
}

simulated event ReplicatedEvent(name VarName)
{
    // Reliable ClientResolved delivers every reply even if several requests
    // complete between actor replication frames.
    if (VarName != 'Result') Super.ReplicatedEvent(VarName);
}

event Tick(float DeltaTime)
{
    local int H,I,Pass;
    local bool Progress;
    if (Role == ROLE_Authority)
    {
        if (!ContextValid()) Destroy();
        else
        {
            if (!class'VRWorldWeaponPolicy'.static.Enabled())
            {
                for (H = 0; H < 2; ++H)
                {
                    if (Lanes[H].ReleaseRequest > 0) FinishRelease(H, false);
                    if (Lanes[H].CatchRequest > 0) FinishCatch(H, false);
                }
                for (I = Tricks.Length - 1; I >= 0; --I) Tricks[I].Shutdown();
                Tricks.Length = 0;
                Registry.Compact();
                return;
            }
            for (H = 0; H < 2; ++H) { UpdateRelease(H); UpdateCatch(H); }
            for (Pass=0; Pass<8; ++Pass)
            {
                Progress=false;
                for (I=0; I<Tricks.Length; ++I) Progress=Tricks[I].AdvanceOne() || Progress;
                if (!Progress) break;
            }
            for (I=Tricks.Length-1; I>=0; --I)
            {
                Tricks[I].UpdateSettlement();
                if (!Tricks[I].IdentityValid())
                { Tricks[I].Abort(); Tricks[I].Shutdown(); Tricks.Remove(I,1); continue; }
                if (!Tricks[I].bEntryPending && WorldInfo.RealTimeSeconds-Tricks[I].LastProgressAt>3.0)
                {
                    if (Tricks[I].CurrentAction==0)
                    { Tricks[I].Abort(); Tricks[I].Shutdown(); Tricks.Remove(I,1); }
                    else if (!Tricks[I].bSettled) Tricks[I].Abort();
                }
            }
            Registry.Compact();
        }
    }
}

event Destroyed()
{
    local int H;
    for (H = Tricks.Length - 1; H >= 0; --H) Tricks[H].Shutdown();
    Tricks.Length = 0;
    if (LocalTricks != None) LocalTricks.Shutdown();
    for (H = 0; H < 2; ++H)
    {
        ClearPending(H);
        if (Lanes[H].CatchProp != None) Lanes[H].CatchProp.bCatchPending = false;
    }
    if (Registry != None) Registry.Shutdown();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bOnlyRelevantToOwner=true
    bAlwaysRelevant=false
    bReplicateMovement=false
    NetUpdateFrequency=30
    bHidden=true
    bKillDuringLevelTransition=true
}
