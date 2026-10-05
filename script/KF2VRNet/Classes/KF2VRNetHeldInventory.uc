// Server ledger for exact inventory actors during one pawn lifetime. Accepted
// hand changes activate the stock actors, which retain their firing/reload RPCs.
class KF2VRNetHeldInventory extends Object;

struct HeldItem
{
    var KFWeapon Weapon;
    var int Id;
    var int Revision;
    var int Hand;
    var KF2VRNetItemRuntime Runtime;
};

struct HeldState
{
    var int Revision;
    var KFWeapon LeftWeapon;
    var KFWeapon RightWeapon;
    var int LeftId;
    var int RightId;
    var int LeftRevision;
    var int RightRevision;
};

var private KFPawn_Human Human;
var private array<HeldItem> Items;
var private int NextId;
var HeldState Snapshot;
var KFPlayerController PC;
var int NativeRoutingEnabled, NativeFault;
var int NativeWeaponCalls, NativeManagerCalls;
var KFWeapon NativeQueryWeapon;
var KF2VRNetItemRuntime NativeQueryRuntime;
var private KFWeapon ActiveLeft, ActiveRight;
// Acting-item perk context for this player (see VRPerkContext). ServerAdapter
// brackets FireAmmunition, Zed TakeDamage and UpdateGroundSpeed with it.
var VRPerkContext PerkContext;

function KFPawn_Human GetHuman()
{
    return Human;
}

function bool Initialize(KFPawn_Human P)
{
    if (Human != None || P == None || P.Role != ROLE_Authority
        || P.Health <= 0 || P.bDeleteMe || P.InvManager == None) return false;
    Human = P;
    PC = KFPlayerController(P.Controller);
    PerkContext = new(self) class'VRPerkContext';
    PerkContext.Bind(P);
    NextId = 1;
    Snapshot.Revision = 1;
    return true;
}

function bool IsOwned(KFWeapon W)
{
    local KFWeapon Candidate;
    if (Human == None || Human.bDeleteMe || Human.Health <= 0
        || Human.Controller == None || Human.Controller.Pawn != Human
        || Human.InvManager == None || W == None || W.bDeleteMe
        || W.Instigator != Human || W.Owner != Human
        || W.InvManager != Human.InvManager) return false;
    foreach Human.InvManager.InventoryActors(class'KFWeapon', Candidate)
        if (Candidate == W) return true;
    return false;
}

function int FindItem(KFWeapon W)
{
    local int I;
    if (W == None) return -1;
    for (I = 0; I < Items.Length; ++I)
        if (Items[I].Weapon == W) return I;
    return -1;
}

function ResolveNativeItem()
{
    local int I;
    NativeQueryRuntime = None;
    if (NativeRoutingEnabled != 1 || !IsOwned(NativeQueryWeapon)) return;
    I = FindItem(NativeQueryWeapon);
    if (I >= 0) NativeQueryRuntime = Items[I].Runtime;
}

// Called at the stock removal ingress, even if the same actor is reacquired
// before the next tick. Polling alone cannot observe that ownership interval.
function NotifyRemoved(KFWeapon W)
{
    local int I;
    I = FindItem(W);
    if (I < 0) return;
    RetireItem(I);
}

private function RetireItem(int I)
{
    if (Snapshot.Revision < MaxInt) ++Snapshot.Revision;
    if (Items[I].Hand >= 0)
    {
        ClearHand(Items[I].Hand);
    }
    if (Items[I].Runtime != None)
    {
        Items[I].Runtime.PendingFireMask = 0;
        Items[I].Runtime.NativeReady = 0;
        Items[I].Runtime.Item = None;
    }
    Items.Remove(I, 1);
}

function bool DescribeItem(KFWeapon W, out int Id, out int Revision)
{
    local int I;
    Id = 0;
    Revision = 0;
    if (!IsOwned(W)) return false;
    I = FindItem(W);
    if (I < 0) return false;
    Id = Items[I].Id;
    Revision = Items[I].Revision;
    return true;
}

// Call before command validation as well as every authority tick. Removing an
// actor also retires its identity: reacquiring that same actor gets a new ID.
function Refresh()
{
    local int I, Count;
    local KFWeapon W;
    for (I = Items.Length - 1; I >= 0; --I)
    {
        if (IsOwned(Items[I].Weapon)) continue;
        RetireItem(I);
    }
    if (Human == None || Human.Health <= 0 || Human.bDeleteMe
        || Human.InvManager == None) return;
    foreach Human.InvManager.InventoryActors(class'KFWeapon', W)
    {
        if (!IsOwned(W) || FindItem(W) >= 0 || Items.Length >= 100
            || NextId <= 0 || NextId == MaxInt || Snapshot.Revision == MaxInt) continue;
        Count = W.GetPendingFireLength();
        if (Count <= 0 || Count > 32) continue;
        I = Items.Length;
        Items.Add(1);
        Items[I].Weapon = W;
        Items[I].Id = NextId++;
        Items[I].Revision = 1;
        Items[I].Hand = -1;
        Items[I].Runtime = new(self) class'KF2VRNetItemRuntime';
        Items[I].Runtime.Inventory = self;
        Items[I].Runtime.Item = W;
        Items[I].Runtime.PendingFireCount = Count;
        Items[I].Runtime.NativeReady = 1;
        ++Snapshot.Revision;
    }
}

private function ClearHand(int Hand)
{
    if (Hand == 0)
    {
        Snapshot.LeftWeapon = None;
        Snapshot.LeftId = 0;
        Snapshot.LeftRevision = 0;
    }
    else
    {
        Snapshot.RightWeapon = None;
        Snapshot.RightId = 0;
        Snapshot.RightRevision = 0;
    }
}

// Expected revisions come from the owner request, never freshly reread to
// make a stale command succeed. One revision protects the entire hand pair.
function bool SetPrimary(int Hand, KFWeapon W, int ExpectedState,
    int ExpectedId, int ExpectedItemRevision)
{
    local int I, Old;
    local KFWeapon Previous;
    Refresh();
    if (Hand < 0 || Hand > 1 || Snapshot.Revision != ExpectedState
        || Snapshot.Revision <= 0 || Snapshot.Revision == MaxInt) return false;
    I = -1;
    if (W != None)
    {
        I = FindItem(W);
        if (I < 0 || !IsOwned(W) || Items[I].Id != ExpectedId
            || Items[I].Revision != ExpectedItemRevision
            || Items[I].Revision == MaxInt
            || (Items[I].Hand >= 0 && Items[I].Hand != Hand)) return false;
        if (Items[I].Hand == Hand) return true;
    }
    else if (ExpectedId != 0 || ExpectedItemRevision != 0) return false;
    Previous = Hand == 0 ? Snapshot.LeftWeapon : Snapshot.RightWeapon;
    Old = FindItem(Previous);
    if (Old >= 0 && Items[Old].Revision == MaxInt) return false;
    if (Previous == None && W == None) return true;
    // All checks precede the atomic replacement. No empty intermediate state
    // is published, and the other hand's actor and item revision are retained.
    if (Old >= 0)
    {
        Items[Old].Hand = -1;
        ++Items[Old].Revision;
    }
    ClearHand(Hand);
    if (I >= 0)
    {
        Items[I].Hand = Hand;
        ++Items[I].Revision;
        if (Hand == 0)
        {
            Snapshot.LeftWeapon = W;
            Snapshot.LeftId = Items[I].Id;
            Snapshot.LeftRevision = Items[I].Revision;
        }
        else
        {
            Snapshot.RightWeapon = W;
            Snapshot.RightId = Items[I].Id;
            Snapshot.RightRevision = Items[I].Revision;
        }
    }
    ++Snapshot.Revision;
    return true;
}

// Network commands describe the latest desired pair, not an inventory delta.
// Validate both actors before changing either hand, including a direct swap.
function bool SetHands(KFWeapon Left, KFWeapon Right)
{
    local int I, Hand;
    Refresh();
    if (Snapshot.Revision <= 0 || Snapshot.Revision == MaxInt
        || (Left != None && (FindItem(Left) < 0 || !IsOwned(Left)))
        || (Right != None && (FindItem(Right) < 0 || !IsOwned(Right)))
        || (Left != None && Left == Right)) return false;
    if (Left == Snapshot.LeftWeapon && Right == Snapshot.RightWeapon) return true;
    for (I = 0; I < Items.Length; ++I)
        if (Items[I].Revision == MaxInt) return false;
    ClearHand(0);
    ClearHand(1);
    for (I = 0; I < Items.Length; ++I)
    {
        Hand = Items[I].Weapon == Left ? 0 : (Items[I].Weapon == Right ? 1 : -1);
        if (Items[I].Hand != Hand) ++Items[I].Revision;
        Items[I].Hand = Hand;
        if (Hand == 0)
        {
            Snapshot.LeftWeapon = Left;
            Snapshot.LeftId = Items[I].Id;
            Snapshot.LeftRevision = Items[I].Revision;
        }
        else if (Hand == 1)
        {
            Snapshot.RightWeapon = Right;
            Snapshot.RightId = Items[I].Id;
            Snapshot.RightRevision = Items[I].Revision;
        }
    }
    ++Snapshot.Revision;
    return true;
}

// Keep stock per-weapon firing/reload state and RPCs. Only the stock shared
// pending-fire array needs native isolation; there is no custom shot transport.
function ApplyHands()
{
    local KFWeapon W;
    if (Human == None || Human.Health <= 0) return;
    NativeRoutingEnabled = 1;
    if (ActiveLeft != None && ActiveLeft != Snapshot.LeftWeapon && ActiveLeft != Snapshot.RightWeapon)
        Stow(ActiveLeft);
    if (ActiveRight != None && ActiveRight != Snapshot.LeftWeapon && ActiveRight != Snapshot.RightWeapon)
        Stow(ActiveRight);
    W = KFWeapon(Human.Weapon);
    if (W != None && W != Snapshot.LeftWeapon && W != Snapshot.RightWeapon) Stow(W);
    Human.Weapon = Snapshot.RightWeapon != None ? Snapshot.RightWeapon : Snapshot.LeftWeapon;
    Human.MyKFWeapon = KFWeapon(Human.Weapon);
    if (Snapshot.LeftWeapon != None && Snapshot.LeftWeapon != ActiveLeft && Snapshot.LeftWeapon != ActiveRight)
        Snapshot.LeftWeapon.Activate();
    if (Snapshot.RightWeapon != None && Snapshot.RightWeapon != ActiveLeft && Snapshot.RightWeapon != ActiveRight)
        Snapshot.RightWeapon.Activate();
    // Movement skills follow the held items, not one stock selection.
    if (ActiveLeft != Snapshot.LeftWeapon || ActiveRight != Snapshot.RightWeapon) Human.UpdateGroundSpeed();
    ActiveLeft = Snapshot.LeftWeapon;
    ActiveRight = Snapshot.RightWeapon;
}

// The owning client reports each held item's grip when it changes.
function SetGrip(KFWeapon W, int Policy)
{
    if (PerkContext != None && IsOwned(W)) PerkContext.SetGrip(W, Policy);
}

// Native (ServerAdapter), on the dedicated server's game thread.
function NativePerkFire(KFWeapon W)
{
    if (PerkContext == None) return;
    if (FindItem(W) < 0) W = None;
    else PerkContext.RecordShot(W);
    PerkContext.Begin(W, PerkContext.ShotGrip(W));
}

function NativePerkDamage(Actor Causer)
{
    local KFWeapon W;
    if (PerkContext == None) return;
    W = class'VRPerkContext'.static.ItemFromCauser(Causer);
    if (W != None && FindItem(W) < 0) W = None;
    PerkContext.Begin(W, PerkContext.ShotGrip(W));
}

function NativePerkMovement()
{
    if (PerkContext == None) return;
    PerkContext.Begin(PerkContext.ChooseMovementItem(Snapshot.LeftWeapon, Snapshot.RightWeapon), -1);
}

function NativePerkEnd()
{
    if (PerkContext != None) PerkContext.End();
}

private function Stow(KFWeapon W)
{
    if (!IsOwned(W)) return;
    W.ForceEndFire();
    W.GotoState('Inactive');
}

function Shutdown()
{
    Stow(ActiveLeft);
    Stow(ActiveRight);
    ActiveLeft = None;
    ActiveRight = None;
    NativeRoutingEnabled = 0;
    while (Items.Length > 0) RetireItem(Items.Length - 1);
    ClearHand(0);
    ClearHand(1);
    Snapshot.Revision = 0;
    Human = None;
    PC = None;
    NativeQueryWeapon = None;
    NativeQueryRuntime = None;
    NextId = 0;
}
