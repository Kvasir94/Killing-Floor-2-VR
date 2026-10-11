// Owner-channel facade. The channel validates its current admission/context
// and carries every Vampire reload intent; stock weapon reload RPCs are fenced
// while that capability is armed, including after this session is terminal.
class KF2VRNetVampireReload extends Object;

struct ReloadState
{
    var KFPawn_Human Human;
    var KFWeapon Weapon;
    var int WorldEpoch, ConnectionEpoch, PawnEpoch;
    var int BeginRequest, AcknowledgedRequest, SessionId;
    var int LastBeginRequest;
    var KFWeapon LastBeginWeapon;
    var int Hand, ItemId, ItemRevision;
    var int PrimaryAmmo, PrimaryReserve;
    var int Status;
    var int NativeVersion;
    var bool bAccepted, bBeginAccepted;
};

var ReloadState Snapshot;
var VRVampireReloadAuthority Authority;
var private Actor Transport;
var private KF2VRNetHeldInventory Inventory;
var private bool bAdmission;
var private bool bCommitRequested;

function bool Initialize(Actor OwnerChannel, KF2VRNetHeldInventory Ledger,
    int WorldEpoch, int ConnectionEpoch, int PawnEpoch)
{
    if (Transport != None || OwnerChannel == None || OwnerChannel.Role != ROLE_Authority
        || Ledger == None || Ledger.GetHuman() == None
        || WorldEpoch <= 0 || ConnectionEpoch <= 0 || PawnEpoch <= 0) return false;
    Transport = OwnerChannel;
    Inventory = Ledger;
    Snapshot.Human = Ledger.GetHuman();
    Snapshot.WorldEpoch = WorldEpoch;
    Snapshot.ConnectionEpoch = ConnectionEpoch;
    Snapshot.PawnEpoch = PawnEpoch;
    Snapshot.Hand = -1;
    Authority = new(self) class'VRVampireReloadAuthority';
    Authority.Human = Snapshot.Human;
    Authority.Controller = KFPlayerController(Snapshot.Human.Controller);
    Authority.NativeVampireReloadGate();
    Snapshot.NativeVersion = Authority.NativeVersion;
    Inventory.OnItemRemoved = NotifyRemoved;
    return true;
}

function bool EpochsMatch(int W, int C, int P)
{
    return Transport != None && !Transport.bDeleteMe && Transport.Role == ROLE_Authority
        && Inventory != None && Authority != None && Snapshot.Human != None
        && W == Snapshot.WorldEpoch && C == Snapshot.ConnectionEpoch && P == Snapshot.PawnEpoch
        && Transport.Owner == Snapshot.Human.Controller
        && Snapshot.Human.Controller != None
        && Snapshot.Human.Controller.Pawn == Snapshot.Human;
}

function bool RecordRequest(int Request, int W, int C, int P)
{
    if (!EpochsMatch(W, C, P) || Request <= Snapshot.AcknowledgedRequest
        || Request <= 0 || Request == MaxInt) return false;
    Snapshot.AcknowledgedRequest = Request;
    Snapshot.bAccepted = false;
    return true;
}

function bool IdentityCurrent()
{
    local int Id, Revision;
    return Inventory != None && Inventory.GetHuman() == Snapshot.Human
        && Snapshot.Hand >= 0 && Snapshot.Hand <= 1
        && Inventory.DescribeItem(Snapshot.Weapon, Id, Revision)
        && Id == Snapshot.ItemId && Revision == Snapshot.ItemRevision
        && (Snapshot.Hand == 0 ? Inventory.Snapshot.LeftWeapon : Inventory.Snapshot.RightWeapon) == Snapshot.Weapon;
}

function bool SameIncarnation()
{
    local int Id, Revision;
    return Inventory != None && Inventory.GetHuman() == Snapshot.Human
        && Inventory.DescribeItem(Snapshot.Weapon, Id, Revision)
        && Id == Snapshot.ItemId;
}

function bool ActionAllowed(optional bool bStock)
{
    return bAdmission && EpochsMatch(Snapshot.WorldEpoch, Snapshot.ConnectionEpoch, Snapshot.PawnEpoch)
        && IdentityCurrent()
        && (bStock || (Snapshot.Hand == 0 ? Inventory.Snapshot.RightWeapon : Inventory.Snapshot.LeftWeapon) == None);
}

function Publish()
{
    Snapshot.Status = Authority.Status;
    // These are acknowledgement/display observations, never an ammo ledger.
    if (IdentityCurrent() && Authority.OwnsWeapon())
    {
        Snapshot.PrimaryAmmo = Snapshot.Weapon.AmmoCount[0];
        Snapshot.PrimaryReserve = Snapshot.Weapon.SpareAmmoCount[0];
    }
    if (Transport != None) Transport.bForceNetUpdate = true;
}

function NotifyRemoved(KFWeapon W)
{
    if (Authority == None || W == None || W != Snapshot.Weapon) return;
    // Called synchronously before the stock inventory removal mutates Owner.
    // This also revokes an explicitly authorized stock-timer fallback.
    if (Authority.Cancel(Authority.SessionId))
    {
        bCommitRequested = false;
        Publish();
    }
}

function bool Begin(int Request, KFWeapon W, int Hand, int ExpectedHeldRevision,
    int WorldEpoch, int ConnectionEpoch, int PawnEpoch, optional bool bStock)
{
    local int Id, Revision;
    if (!RecordRequest(Request, WorldEpoch, ConnectionEpoch, PawnEpoch)) return false;
    Snapshot.LastBeginRequest = Request;
    Snapshot.LastBeginWeapon = W;
    Snapshot.bBeginAccepted = false;
    Inventory.Refresh();
    if (!bAdmission || Authority.Status == class'VRVampireReloadAuthority'.const.Held
        || Authority.Status == class'VRVampireReloadAuthority'.const.Stock
        || Hand < 0 || Hand > 1 || !class'VRVampireReloadAuthority'.static.Supports(W)
        || ExpectedHeldRevision != Inventory.Snapshot.Revision
        || !Inventory.DescribeItem(W, Id, Revision)
        || (Hand == 0 ? Inventory.Snapshot.LeftWeapon : Inventory.Snapshot.RightWeapon) != W
        || (!bStock && (Hand == 0 ? Inventory.Snapshot.RightWeapon : Inventory.Snapshot.LeftWeapon) != None))
    { Publish(); return false; }
    Snapshot.Weapon = W;
    Snapshot.Hand = Hand;
    Snapshot.ItemId = Id;
    Snapshot.ItemRevision = Revision;
    Snapshot.BeginRequest = Request;
    Snapshot.SessionId = Request;
    Snapshot.PrimaryAmmo = W.AmmoCount[0];
    Snapshot.PrimaryReserve = W.SpareAmmoCount[0];
    Snapshot.bAccepted = Authority.Begin(Snapshot.Human, W, Request, bStock);
    Snapshot.bBeginAccepted = Snapshot.bAccepted;
    bCommitRequested = false;
    Publish();
    return Snapshot.bAccepted;
}

function bool BeginStock(int Request, KFWeapon W, int Hand, int ExpectedHeldRevision,
    int WorldEpoch, int ConnectionEpoch, int PawnEpoch)
{
    return Begin(Request, W, Hand, ExpectedHeldRevision, WorldEpoch, ConnectionEpoch, PawnEpoch, true);
}

function bool TupleMatches(KFWeapon W, int Hand, int Id, int Revision, int Session)
{
    return W != None && W == Snapshot.Weapon && Hand == Snapshot.Hand
        && Id == Snapshot.ItemId && Revision == Snapshot.ItemRevision
        && Session > 0 && Session == Snapshot.SessionId && Session == Authority.SessionId;
}

function bool Commit(int Request, KFWeapon W, int Hand, int Id, int Revision, int Session,
    int WorldEpoch, int ConnectionEpoch, int PawnEpoch)
{
    if (!RecordRequest(Request, WorldEpoch, ConnectionEpoch, PawnEpoch)) return false;
    Inventory.Refresh();
    if (TupleMatches(W, Hand, Id, Revision, Session) && ActionAllowed()
        && Authority.Status == class'VRVampireReloadAuthority'.const.Held)
    {
        // A physical completion can beat the stock minimum time. Accept the
        // intent once, then pay on authority when that minimum has elapsed.
        bCommitRequested = true;
        Snapshot.bAccepted = true;
        Authority.Commit(Session);
    }
    Publish();
    return Snapshot.bAccepted;
}

function bool Cancel(int Request, KFWeapon W, int Hand, int Id, int Revision, int Session,
    int WorldEpoch, int ConnectionEpoch, int PawnEpoch)
{
    if (!RecordRequest(Request, WorldEpoch, ConnectionEpoch, PawnEpoch)) return false;
    Inventory.Refresh();
    // Context/admission loss must still be allowed to retire the held reload.
    if (TupleMatches(W, Hand, Id, Revision, Session))
        Snapshot.bAccepted = Authority.Cancel(Session, !SameIncarnation());
    if (Authority.Status != class'VRVampireReloadAuthority'.const.Held) bCommitRequested = false;
    Publish();
    return Snapshot.bAccepted;
}

function Tick(bool ContextAllowed)
{
    local int Previous;
    bAdmission = ContextAllowed;
    if (Inventory == None || Authority == None) return;
    Inventory.Refresh();
    Previous = Authority.Status;
    if (Authority.Status == class'VRVampireReloadAuthority'.const.Held
        || Authority.Status == class'VRVampireReloadAuthority'.const.Stock)
    {
        if (!IdentityCurrent()) Authority.Cancel(Authority.SessionId, !SameIncarnation());
        else if (!ActionAllowed(Authority.Status == class'VRVampireReloadAuthority'.const.Stock)) Authority.Cancel(Authority.SessionId);
        else Authority.Tick();
        if (Authority.Status == class'VRVampireReloadAuthority'.const.Held && bCommitRequested)
            Authority.Commit(Authority.SessionId);
    }
    if (Authority.Status != class'VRVampireReloadAuthority'.const.Held) bCommitRequested = false;
    if (Previous != Authority.Status) Publish();
}

function Shutdown()
{
    bAdmission = false;
    if (Authority != None)
    {
        if (Inventory != None) Inventory.Refresh();
        Authority.Cancel(Authority.SessionId, !SameIncarnation());
        Publish();
    }
    if (Inventory != None) Inventory.OnItemRemoved = None;
    Inventory = None;
    Transport = None;
}
