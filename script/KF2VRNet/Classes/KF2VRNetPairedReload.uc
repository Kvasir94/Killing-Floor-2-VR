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
    var bool bBeginAccepted, bCylinderEjected;
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

function string ContinuationFault()
{
    if (!IdentityCurrent()) return "identity";
    if (!Channel.PairedReloadContext(Snapshot.Hand, true)) return "context";
    return "";
}

// The owner settles this receipt only when its own member shows PrimaryAmmo.
// That member's replicated AmmoCount never reached a dedicated client after
// the commit (10 s timeout, then every Begin refused on the stale count), so
// restate the exact count on the weapon's reliable channel, as removal does.
function CorrectOwnerAmmo(KFWeapon W)
{
    if (W != None && !W.bDeleteMe && W.Role == ROLE_Authority && Snapshot.Human != None
        && W.Instigator == Snapshot.Human && !Snapshot.Human.IsLocallyControlled()
        && class'VRWeaponPair'.static.ForMember(W) != None)
        W.ClientForceAmmoUpdate(W.AmmoCount[0], W.SpareAmmoCount[0]);
}

function Refused(string Reason, KFWeapon W, int Request)
{
    `log("KF2VRNet paired_reload phase=refused reason=" $ Reason @ "hand=" $ Snapshot.Hand
        @ "weapon=" $ W @ "request=" $ Request @ "status=" $ Snapshot.Status
        @ "ammo=" $ (W != None ? W.AmmoCount[0] : -1) @ "state=" $ (W != None ? W.GetStateName() : ''));
}

function Publish()
{
    if (IdentityCurrent())
    {
        Snapshot.PrimaryAmmo = Snapshot.Weapon.AmmoCount[0];
        Snapshot.PrimaryReserve = Pair.SharedReserve(Snapshot.Weapon);
        Snapshot.bCylinderEjected = Pair.CylinderWasEjected(Snapshot.Weapon, Snapshot.SessionId);
        CorrectOwnerAmmo(Snapshot.Weapon);
    }
    if (Channel != None) Channel.bForceNetUpdate = true;
}

function bool Begin(int Request, KFWeapon W, int ExpectedHeldRevision, int ExpectedAmmo, optional bool bStock,
    optional bool bRealistic, optional bool bSwingOut, optional bool bLoseAmmo)
{
    local int Id, Revision;
    local VRWeaponPair Candidate;
    if (Request <= Snapshot.LastBeginRequest || Request <= 0 || Request == MaxInt) return false;
    Snapshot.LastBeginRequest = Request; Snapshot.LastBeginWeapon = W;
    Snapshot.bBeginAccepted = false;
    Inventory.Refresh();
    Candidate = class'VRWeaponPair'.static.ForMember(W);
    bSwingOut = bSwingOut && !bStock && class'VRBreakCatalog'.static.SwingOutCylinder(W);
    if (Snapshot.Status == 1 || Snapshot.Status == 4 || !Channel.PairedReloadContext(Snapshot.Hand)
        || W == None || W.Role != ROLE_Authority || W.bAllowClientAmmoTracking
        || W.AmmoCount[0] != ExpectedAmmo
        || Candidate == None || !Candidate.IsMember(W)
        || ExpectedHeldRevision != Inventory.Snapshot.Revision
        || !Inventory.DescribeItem(W, Id, Revision)
        || (Snapshot.Hand == 0 ? Inventory.Snapshot.LeftWeapon : Inventory.Snapshot.RightWeapon) != W
        || (!class'VRWeaponRuntime'.static.StockIdle(W) && !W.IsInState('Reloading'))
        || (!bSwingOut && !W.CanReload(0) && !Candidate.PhysicalTopUp(W, bRealistic)) || W.MySkelMesh == None)
    {
        Refused("begin expected_ammo=" $ ExpectedAmmo @ "held=" $ ExpectedHeldRevision $ "/" $ Inventory.Snapshot.Revision, W, Request);
        // A stale owner count refuses every later Begin; repair it here too.
        if (W != None && W.AmmoCount[0] != ExpectedAmmo) CorrectOwnerAmmo(W);
        Publish(); return false;
    }
    Pair = Candidate;
    Snapshot.Weapon = W; Snapshot.ItemId = Id; Snapshot.ItemRevision = Revision;
    Snapshot.PairRevision = Pair.Revision;
    Snapshot.BeginRequest = Request; Snapshot.SessionId = Request;
    Snapshot.bBeginAccepted = Pair.BeginPhysicalReload(W, Request, bStock, bRealistic, bSwingOut, bLoseAmmo);
    Snapshot.Status = Pair.PhysicalReloadStatus(W, Request);
    if (!Snapshot.bBeginAccepted) { Snapshot.Status = 3; Refused("pair-begin", W, Request); }
    Publish();
    return Snapshot.bBeginAccepted;
}

function bool Eject(int Request, KFWeapon W)
{
    local string Fault;
    Inventory.Refresh();
    if (Request != Snapshot.SessionId || W != Snapshot.Weapon || Snapshot.Status != 1) return false;
    Fault = ContinuationFault();
    if (Fault != "") { Cancel(Request, Fault); return false; }
    if (!Pair.EjectPhysicalCylinder(W, Request))
    {
        Snapshot.Status = Pair.PhysicalReloadStatus(W, Request);
        if (Snapshot.Status == 3) Refused("eject", W, Request);
        Publish(); return false;
    }
    Publish();
    return true;
}

function bool Commit(int Request, KFWeapon W, optional bool bNoLoad, optional int Maximum)
{
    local string Fault;
    Inventory.Refresh();
    if (Request != Snapshot.SessionId || W != Snapshot.Weapon || Snapshot.Status != 1) return false;
    Fault = ContinuationFault();
    if (Fault != "") { Cancel(Request, Fault); return false; }
    Pair.CommitPhysicalReload(W, Request, bNoLoad, Maximum);
    Snapshot.Status = Pair.PhysicalReloadStatus(W, Request);
    if (Snapshot.Status == 3) Refused("commit", W, Request);
    Publish();
    return Snapshot.Status == 2;
}

function Cancel(int Request, optional string Reason = "owner")
{
    if (Request != Snapshot.SessionId || (Snapshot.Status != 1 && Snapshot.Status != 4)) return;
    if (Pair != None && !Pair.bDeleteMe) Pair.CancelPhysicalReload(Snapshot.Weapon, Request);
    Snapshot.Status = 3;
    Refused(Reason, Snapshot.Weapon, Request);
    Publish();
}

function Tick()
{
    local int Previous;
    local string Fault;
    if (Snapshot.Status != 1 && Snapshot.Status != 4) return;
    // An external paid magazine may complete the exact pair session while
    // its owner-channel receipt remains busy. Publish terminal authority
    // first; context cancellation cannot rewrite accepted completion.
    if (Pair != None && !Pair.bDeleteMe)
    {
        Previous = Pair.PhysicalReloadStatus(Snapshot.Weapon, Snapshot.SessionId);
        if (Previous == 2 || Previous == 3)
        {
            Snapshot.Status = Previous;
            if (Previous == 3) Refused("pair", Snapshot.Weapon, Snapshot.SessionId);
            Publish(); return;
        }
    }
    Inventory.Refresh();
    Fault = ContinuationFault();
    if (Fault != "") Cancel(Snapshot.SessionId, Fault);
    else
    {
        Previous = Snapshot.Status;
        Pair.TickPhysicalReloads();
        Snapshot.Status = Pair.PhysicalReloadStatus(Snapshot.Weapon, Snapshot.SessionId);
        if (Snapshot.Status == 3) Refused("pair-tick", Snapshot.Weapon, Snapshot.SessionId);
        if (Previous != Snapshot.Status) Publish();
    }
}
