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
    var int CarryMask;
    var int ShieldHandToken;
    var KFWeapon LeftWeapon;
    var KFWeapon RightWeapon;
    var int LeftId;
    var int RightId;
    var int LeftRevision;
    var int RightRevision;
    var int LeftGeneration, RightGeneration;
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

// Optional transaction cleanup runs at native stock-removal ingress, before
// Owner changes, so polling cannot miss a drop and immediate reacquisition.
delegate OnItemRemoved(KFWeapon W) {}
// Separate owner cleanup slot: Vampire's session delegate retains its lifetime.
delegate OnWorldItemRemoved(KFWeapon W) {}

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
    Snapshot.LeftGeneration = 1;
    Snapshot.RightGeneration = 1;
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

function KF2VRNetItemRuntime RuntimeFor(KFWeapon W)
{
    local int I;
    if (!IsOwned(W)) return None;
    I = FindItem(W);
    return I >= 0 ? Items[I].Runtime : None;
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
    OnItemRemoved(W);
    OnWorldItemRemoved(W);
    RetireItem(I);
}

private function RetireItem(int I)
{
    if (Snapshot.Revision < MaxInt) ++Snapshot.Revision;
    if (Items[I].Hand >= 0)
    {
        AdvanceHandGeneration(Items[I].Hand);
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
        // Match the owning VR inventory's initial MANUAL mode, once per actor.
        if (W.Class == class'KFWeap_Rifle_RailGun') W.bUseAltFireMode = true;
        ++Snapshot.Revision;
    }
}

private function bool CanAdvanceHand(int Hand)
{
    local int Generation;
    if (Hand < 0 || Hand > 1) return false;
    Generation = Hand == 0 ? Snapshot.LeftGeneration : Snapshot.RightGeneration;
    return Generation > 0 && Generation < MaxInt;
}

// Never wrap a hand's empty/occupied lifetime back onto an old request token.
// Forced stock removal may still clear an exhausted hand, but no later command
// can bind it again until the owning pawn/connection epochs are replaced.
private function AdvanceHandGeneration(int Hand)
{
    if (Hand == 0 && Snapshot.LeftGeneration < MaxInt) ++Snapshot.LeftGeneration;
    else if (Hand == 1 && Snapshot.RightGeneration < MaxInt) ++Snapshot.RightGeneration;
}

private function ClearHand(int Hand)
{
    if (KFWeap_SMG_G18(Hand==0 ? Snapshot.LeftWeapon : Snapshot.RightWeapon)!=None) Snapshot.ShieldHandToken=0;
    Snapshot.CarryMask = Snapshot.CarryMask & ~(1 << Hand);
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
        if (I < 0 || !IsOwned(W) || Items[I].Runtime.WorldDropped != 0 || Items[I].Id != ExpectedId
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
    if (!CanAdvanceHand(Hand)) return false;
    // All checks precede the atomic replacement. No empty intermediate state
    // is published, and the other hand's actor and item revision are retained.
    if (Old >= 0)
    {
        Items[Old].Hand = -1;
        ++Items[Old].Revision;
    }
    AdvanceHandGeneration(Hand);
    ClearHand(Hand);
    if (I >= 0)
    {
        Items[I].Hand = Hand;
        Items[I].Runtime.CarryOnly = 0;
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
function bool ValidCarryRoles(KFWeapon Left, KFWeapon Right, int CarryMask)
{
    local KFWeapon W;
    local int H, OldHand;
    for (H = 0; H < 2; ++H)
    {
        W = H == 0 ? Left : Right;
        if (KFWeap_SMG_G18(W)!=None) continue;
        if (W == None) continue;
        OldHand = Snapshot.LeftWeapon == W ? 0 : (Snapshot.RightWeapon == W ? 1 : -1);
        if ((CarryMask & (1 << H)) != 0)
        {
            if (!class'VRHandsBridge'.static.SupportsCarryWeapon(W)) return false;
            // Enter from the other firing hand, or retain this existing carry.
            if (OldHand < 0 || (OldHand == H && (Snapshot.CarryMask & (1 << H)) == 0)
                || (OldHand != H && (Snapshot.CarryMask & (1 << OldHand)) != 0)) return false;
        }
        else if (OldHand == H && (Snapshot.CarryMask & (1 << H)) != 0) return false;
    }
    return true;
}

function bool ValidShieldRole(KFWeapon Left, KFWeapon Right, int CarryMask, int Token)
{
    local KFWeapon W, AtHand;
    if (Token==0) return !((KFWeap_SMG_G18(Left)!=None && (CarryMask & 1)!=0)
        || (KFWeap_SMG_G18(Right)!=None && (CarryMask & 2)!=0));
    if (Token<1 || Token>2) return false;
    W=KFWeap_SMG_G18(Left)!=None ? Left : Right;
    if (KFWeap_SMG_G18(W)==None || !IsOwned(W)) return false;
    AtHand=Token==1 ? Left : Right;
    return AtHand==None || (AtHand==W && (CarryMask & (1<<(Token-1)))!=0);
}

function KFWeapon HeldShield()
{
    if (!ValidShieldRole(Snapshot.LeftWeapon,Snapshot.RightWeapon,Snapshot.CarryMask,Snapshot.ShieldHandToken)
        || Snapshot.ShieldHandToken==0) return None;
    return KFWeap_SMG_G18(Snapshot.LeftWeapon)!=None ? Snapshot.LeftWeapon : Snapshot.RightWeapon;
}

function KFWeapon ResolveShieldDefender()
{
    if (KF2VRNetPlayerController(PC)==None || KF2VRNetPlayerController(PC).NetChannel==None) return None;
    return KF2VRNetPlayerController(PC).NetChannel.ResolveShieldDefender();
}

function bool SetHands(KFWeapon Left, KFWeapon Right, optional int CarryMask, optional int ShieldHandToken)
{
    return CommitHands(Left, Right, CarryMask, ShieldHandToken);
}

// This sole exception admits a verified airborne/ground contact into a free
// hand. Ordinary owner commands cannot manufacture a fore-end-only catch.
function bool CatchFromWorld(KFWeapon W, int Hand, byte GripRole)
{
    local int I, CarryMask;
    local KF2VRNetItemRuntime R;
    Refresh();
    I = FindItem(W);
    R = RuntimeFor(W);
    if (I < 0 || R == None || R.Inventory != self || R.Item != W || R.NativeReady != 1
        || R.WorldDropped != 1 || R.MechanismPending != 0 || Items[I].Hand >= 0
        || Snapshot.Revision <= 0 || Snapshot.Revision == MaxInt || Items[I].Revision == MaxInt
        || Hand < 0 || Hand > 1 || GripRole > 1 || !CanAdvanceHand(Hand)
        || (Hand == 0 ? Snapshot.LeftWeapon : Snapshot.RightWeapon) != None
        || W == Snapshot.LeftWeapon || W == Snapshot.RightWeapon)
    {
        // A refused world catch names every gate it checked (online re-grab).
        `log("KF2VR_WORLD_DROP phase=held-catch-refused weapon=" $ (W != None ? string(W.Class) : "None") @ "hand=" $ Hand
            @ "item=" $ I @ "runtime=" $ (R != None) @ "own=" $ (R != None && R.Inventory == self && R.Item == W)
            @ "native_ready=" $ (R != None ? R.NativeReady : -1) @ "dropped=" $ (R != None ? R.WorldDropped : -1)
            @ "mechanism=" $ (R != None ? R.MechanismPending : -1) @ "item_hand=" $ (I >= 0 ? Items[I].Hand : -9)
            @ "revision=" $ Snapshot.Revision @ "advance=" $ CanAdvanceHand(Hand)
            @ "left=" $ Snapshot.LeftWeapon @ "right=" $ Snapshot.RightWeapon @ "role=" $ GripRole);
        return false;
    }
    CarryMask = Snapshot.CarryMask;
    if (GripRole == 1)
    {
        if (!class'VRHandsBridge'.static.SupportsCarryWeapon(W) || (CarryMask | (1 << Hand)) > 3)
        {
            `log("KF2VR_WORLD_DROP phase=held-catch-refused weapon=" $ W.Class @ "hand=" $ Hand @ "role=1 carry_supported="
                $ class'VRHandsBridge'.static.SupportsCarryWeapon(W) @ "carry_mask=" $ CarryMask);
            return false;
        }
        CarryMask = CarryMask | (1 << Hand);
    }
    Items[I].Hand = Hand;
    ++Items[I].Revision;
    R.CarryOnly = int(GripRole == 1);
    R.PendingFireMask = 0;
    R.WorldDropped = 0;
    AdvanceHandGeneration(Hand);
    Snapshot.CarryMask = CarryMask;
    if (Hand == 0)
    { Snapshot.LeftWeapon = W; Snapshot.LeftId = Items[I].Id; Snapshot.LeftRevision = Items[I].Revision; }
    else
    { Snapshot.RightWeapon = W; Snapshot.RightId = Items[I].Id; Snapshot.RightRevision = Items[I].Revision; }
    ++Snapshot.Revision;
    class'VRWorldDropGun'.static.ActivateCaught(W);
    ApplyHands();
    return true;
}

function bool ReleaseForWorld(KFWeapon W, int Hand)
{
    local KF2VRNetItemRuntime R;
    local int I;
    I = FindItem(W);
    R = RuntimeFor(W);
    if (I < 0 || R == None || R.Inventory != self || R.Item != W || R.NativeReady != 1
        || R.WorldDropped != 0 || R.MechanismPending != 0 || Hand < 0 || Hand > 1
        || Items[I].Hand != Hand || Snapshot.Revision <= 0 || Snapshot.Revision == MaxInt
        || Items[I].Revision == MaxInt || !CanAdvanceHand(Hand)
        || (Hand == 0 ? Snapshot.LeftWeapon : Snapshot.RightWeapon) != W) return false;
    R.WorldDropped = 1;
    R.CarryOnly = 1;
    R.PendingFireMask = 0;
    Items[I].Hand = -1;
    ++Items[I].Revision;
    AdvanceHandGeneration(Hand);
    ClearHand(Hand);
    ++Snapshot.Revision;
    ApplyHands();
    return true;
}

private function bool CommitHands(KFWeapon Left, KFWeapon Right, int CarryMask, optional int ShieldHandToken)
{
    local int I, Hand, Carry;
    local bool LeftChanged, RightChanged;
    Refresh();
    if (Snapshot.Revision <= 0 || Snapshot.Revision == MaxInt
        || (Left != None && (FindItem(Left) < 0 || !IsOwned(Left)))
        || (Right != None && (FindItem(Right) < 0 || !IsOwned(Right)))
        || (Left != None && Left == Right) || CarryMask < 0 || CarryMask > 3
        || ((CarryMask & 1) != 0 && Left == None) || ((CarryMask & 2) != 0 && Right == None)) return false;
    if ((Left != None && RuntimeFor(Left).WorldDropped != 0)
        || (Right != None && RuntimeFor(Right).WorldDropped != 0)) return false;
    if (!ValidCarryRoles(Left, Right, CarryMask) || !ValidShieldRole(Left,Right,CarryMask,ShieldHandToken)) return false;
    if (Left == Snapshot.LeftWeapon && Right == Snapshot.RightWeapon && CarryMask == Snapshot.CarryMask
        && ShieldHandToken==Snapshot.ShieldHandToken) return true;
    LeftChanged = Left != Snapshot.LeftWeapon || ((CarryMask ^ Snapshot.CarryMask) & 1) != 0;
    RightChanged = Right != Snapshot.RightWeapon || ((CarryMask ^ Snapshot.CarryMask) & 2) != 0;
    if (ShieldHandToken!=Snapshot.ShieldHandToken)
    {
        LeftChanged=LeftChanged || ShieldHandToken==1 || Snapshot.ShieldHandToken==1;
        RightChanged=RightChanged || ShieldHandToken==2 || Snapshot.ShieldHandToken==2;
    }
    if ((LeftChanged && !CanAdvanceHand(0)) || (RightChanged && !CanAdvanceHand(1))) return false;
    for (I = 0; I < Items.Length; ++I)
        if (Items[I].Revision == MaxInt) return false;
    if (LeftChanged) AdvanceHandGeneration(0);
    if (RightChanged) AdvanceHandGeneration(1);
    ClearHand(0);
    ClearHand(1);
    for (I = 0; I < Items.Length; ++I)
    {
        Hand = Items[I].Weapon == Left ? 0 : (Items[I].Weapon == Right ? 1 : -1);
        Carry = (Hand >= 0 && (CarryMask & (1 << Hand)) != 0) ? 1 : 0;
        // A stowed former carry remains fire-fenced until an explicit primary
        // draw. Late weapon RPCs must not turn final release into a shot.
        if (Hand < 0) Carry = Items[I].Runtime.CarryOnly;
        if (Items[I].Hand != Hand || Items[I].Runtime.CarryOnly != Carry) ++Items[I].Revision;
        Items[I].Hand = Hand;
        Items[I].Runtime.CarryOnly = Carry;
        if (Carry != 0)
        {
            Items[I].Weapon.StopFire(0); Items[I].Weapon.StopFire(1);
            Items[I].Runtime.PendingFireMask = Items[I].Runtime.PendingFireMask & (1 << class'KFWeapon'.const.RELOAD_FIREMODE);
        }
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
    Snapshot.CarryMask = CarryMask;
    Snapshot.ShieldHandToken = ShieldHandToken;
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
function NativeWeaponFired(KFWeapon W, byte Mode)
{
    local KF2VRNetItemRuntime R;
    if (NativeRoutingEnabled != 1 || Mode > 1
        || (W != Snapshot.LeftWeapon && W != Snapshot.RightWeapon)) return;
    R = RuntimeFor(W);
    if (R == None || R.NativeReady != 1 || R.CarryOnly != 0) return;
    R.ShotSequence = (R.ShotSequence + 1) & 65535;
    R.LastShotFireMode = Mode;
    if (Mode == 1 && (R.SecondaryMagazineFlags & 1) != 0) R.SecondaryMagazineFlags = 3;
}

// Native (ServerAdapter), on the dedicated server's game thread.
function NativePerkFire(KFWeapon W)
{
    if (PerkContext == None) return;
    if (FindItem(W) < 0) W = None;
    else PerkContext.RecordShot(W);
    PerkContext.Begin(W, PerkContext.ShotGrip(W), true);
}

function NativePerkProjectile(Projectile P)
{
    if (PerkContext != None && P != None && FindItem(KFWeapon(P.Owner)) >= 0)
        PerkContext.RecordProjectile(P);
    AimFromHeldMuzzle(KFProjectile(P));
}

// Stock launchers, crossbows and darts spawn only on the authority, from the
// head view. Re-seat such a shot on the tracked muzzle of the gun that fired it
// and turn its flight by the same head-to-bore rotation, so stock spread and
// fans survive. Called after Init too (the pre-Init call has no velocity yet).
// Client-spawned bullets, the compound bow's own release authority and
// throw/custom modes keep their existing paths.
function AimFromHeldMuzzle(KFProjectile P)
{
    local KFWeapon W;
    local KF2VRNetPlayerController Player;
    local vector Muzzle;
    local rotator Aim;
    local quat Turn;
    local int Hand;
    if (P == None || P.bDeleteMe || P.Role != ROLE_Authority || VSizeSq(P.Velocity) <= 0
        || (P.bUseClientSideHitDetection && P.bNoReplicationToInstigator)) return;
    W = KFWeapon(P.Owner);
    if (W == None || FindItem(W) < 0 || W.CurrentFireMode > 1 || Human == None
        || class'VRCompoundBowAuthority'.static.Supports(W)) return;
    Hand = Snapshot.LeftWeapon == W ? 0 : (Snapshot.RightWeapon == W ? 1 : -1);
    Player = KF2VRNetPlayerController(PC);
    if (Hand < 0 || Player == None || Player.NetChannel == None
        || !Player.NetChannel.HeldMuzzleFrame(Hand, W, Muzzle, Aim)) return;
    Turn = QuatProduct(QuatFromRotator(Aim), QuatInvert(QuatFromRotator(Human.GetBaseAimRotation())));
    P.SetLocation(Muzzle);
    P.Velocity = QuatRotateVector(Turn, P.Velocity);
    P.Acceleration = QuatRotateVector(Turn, P.Acceleration);
    P.SetRotation(QuatToRotator(QuatProduct(Turn, QuatFromRotator(P.Rotation))));
    if (P.bSyncToOriginalLocation) P.OriginalLocation = P.Location;
}

function NativePerkDamage(Actor Causer)
{
    local KFWeapon W;
    if (PerkContext == None) return;
    W = class'VRPerkContext'.static.ItemFromCauser(Causer);
    if (W != None && FindItem(W) < 0) W = None;
    PerkContext.Begin(W, PerkContext.DamageGrip(Causer));
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
    Snapshot.LeftGeneration = 0;
    Snapshot.RightGeneration = 0;
    Human = None;
    PC = None;
    NativeQueryWeapon = None;
    NativeQueryRuntime = None;
    NextId = 0;
}
