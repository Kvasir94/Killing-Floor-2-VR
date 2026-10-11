// One hand's authority-owned paired reload. Stock performs the only ammo write.
class KF2VRNetPairedReload extends Object;

struct ReloadState
{
    var KFPawn_Human Human;
    var KFWeapon Weapon;
    var int WorldEpoch, ConnectionEpoch, PawnEpoch;
    var int BeginRequest, LastBeginRequest, SessionId;
    var KFWeapon LastBeginWeapon;
    var int Hand, ItemId, ItemRevision, PairRevision;
    var int Status, PrimaryAmmo, PrimaryReserve;
    var bool bBeginAccepted;
};

var ReloadState Snapshot;
var private KF2VRNetChannel Channel;
var private KF2VRNetHeldInventory Inventory;
var private VRWeaponPair Pair;


function Initialize(KF2VRNetChannel C, KF2VRNetHeldInventory Ledger, int Hand)
{
    Channel = C; Inventory = Ledger;
    Snapshot.Human = Ledger.GetHuman(); Snapshot.Hand = Hand;
    Snapshot.WorldEpoch = C.WorldEpoch;
    Snapshot.ConnectionEpoch = C.ConnectionEpoch;
    Snapshot.PawnEpoch = C.PawnEpoch;
}

function bool IdentityCurrent()
{
    local int Id, Revision;
    return Inventory != None && Snapshot.Human != None && !Snapshot.Human.bDeleteMe
        && Snapshot.Human.Health > 0 && Snapshot.Human.Controller != None
        && Snapshot.Human.Controller == Channel.Owner
        && Snapshot.Human.Controller.Pawn == Snapshot.Human
        && Inventory.DescribeItem(Snapshot.Weapon, Id, Revision)
        && Id == Snapshot.ItemId && Revision == Snapshot.ItemRevision
        && (Snapshot.Hand == 0 ? Inventory.Snapshot.LeftWeapon : Inventory.Snapshot.RightWeapon) == Snapshot.Weapon
        && Pair != None && !Pair.bDeleteMe && Pair.IsMember(Snapshot.Weapon)
        && Pair == class'VRWeaponPair'.static.ForMember(Snapshot.Weapon)
        // Pair.Revision counts reserve transactions, including the other hand.
        && Pair.Revision >= Snapshot.PairRevision;
}

function Publish()
{
    if (IdentityCurrent())
    {
        Snapshot.PrimaryAmmo = Snapshot.Weapon.AmmoCount[0];
        Snapshot.PrimaryReserve = Pair.SharedReserve();
    }
    if (Channel != None) Channel.bForceNetUpdate = true;
}

function bool Begin(int Request, KFWeapon W, int ExpectedHeldRevision, int ExpectedAmmo, optional bool bStock)
{
    local int Id, Revision;
    local VRWeaponPair Candidate;
    if (Request <= Snapshot.LastBeginRequest || Request <= 0 || Request == MaxInt) return false;
    Snapshot.LastBeginRequest = Request; Snapshot.LastBeginWeapon = W;
    Snapshot.bBeginAccepted = false;
    Inventory.Refresh();
    Candidate = class'VRWeaponPair'.static.ForMember(W);
    if (Snapshot.Status == 1 || Snapshot.Status == 4 || !Channel.PairedReloadContext(Snapshot.Hand)
        || W == None || W.Role != ROLE_Authority || W.bAllowClientAmmoTracking
        || W.AmmoCount[0] != ExpectedAmmo
        || Candidate == None || !Candidate.IsMember(W)
        || ExpectedHeldRevision != Inventory.Snapshot.Revision
        || !Inventory.DescribeItem(W, Id, Revision)
        || (Snapshot.Hand == 0 ? Inventory.Snapshot.LeftWeapon : Inventory.Snapshot.RightWeapon) != W
        || (!W.IsInState('Active') && !W.IsInState('Reloading')) || !W.CanReload(0) || W.MySkelMesh == None)
    { Publish(); return false; }
    Pair = Candidate;
    Snapshot.Weapon = W; Snapshot.ItemId = Id; Snapshot.ItemRevision = Revision;
    Snapshot.PairRevision = Pair.Revision;
    Snapshot.BeginRequest = Request; Snapshot.SessionId = Request;
    Snapshot.bBeginAccepted = Pair.BeginPhysicalReload(W, Request, bStock);
    Snapshot.Status = Pair.PhysicalReloadStatus(W, Request);
    if (!Snapshot.bBeginAccepted) Snapshot.Status = 3;
    Publish();
    return Snapshot.bBeginAccepted;
}

function bool Commit(int Request, KFWeapon W)
{
    Inventory.Refresh();
    if (Request != Snapshot.SessionId || W != Snapshot.Weapon || Snapshot.Status != 1) return false;
    if (!IdentityCurrent() || !Channel.PairedReloadContext(Snapshot.Hand)) { Cancel(Request); return false; }
    Pair.CommitPhysicalReload(W, Request);
    Snapshot.Status = Pair.PhysicalReloadStatus(W, Request);
    Publish();
    return Snapshot.Status == 2;
}

function Cancel(int Request)
{
    if (Request != Snapshot.SessionId || (Snapshot.Status != 1 && Snapshot.Status != 4)) return;
    if (Pair != None && !Pair.bDeleteMe) Pair.CancelPhysicalReload(Snapshot.Weapon, Request);
    Snapshot.Status = 3;
    Publish();
}

function Tick()
{
    local int Previous;
    if (Snapshot.Status != 1 && Snapshot.Status != 4) return;
    Inventory.Refresh();
    if (!IdentityCurrent() || !Channel.PairedReloadContext(Snapshot.Hand)) Cancel(Snapshot.SessionId);
    else
    {
        Previous = Snapshot.Status;
        Pair.TickPhysicalReloads();
        Snapshot.Status = Pair.PhysicalReloadStatus(Snapshot.Weapon, Snapshot.SessionId);
        if (Previous != Snapshot.Status) Publish();
    }
}
