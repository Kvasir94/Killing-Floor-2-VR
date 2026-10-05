// Canonical references for one pawn lifetime. No inventory grants, stock
// selection changes, item cloning, networking or presentation work occurs here.
class VRHeldInventory extends Object;

var KFPlayerController PC;
var KFPawn_Human Human;
var array<VRWeaponRuntime> Items;
var int NextItemId;
var bool bInitialized;
var int NativeRoutingEnabled, NativeFault;
var int NativeWeaponCalls, NativeManagerCalls;
var int NativeAimRoutingEnabled, NativeAimFault, NativeAimCalls, NativeRejectedShots;
var VRWeaponRuntime LeftItem, RightItem;
var VRWeaponRuntime LeftSupport, RightSupport;
var int HandRevision[2], PoseSequence;
// The native integrator accepts exactly this synchronous dispatch. Stock
// controller updates are suppressed only while this scheduler is enabled.
var int NativeRecoilScheduling, RecoilFrame;
var int NativeRuntimeFault, NativeRecoilSuppressions, NativeRecoilIntegrations;
var KFWeapon NativeRecoilItem;
// Synchronous native query ingress; the caller saves/restores these for nesting.
var KFWeapon NativeQueryWeapon;
var VRWeaponRuntime NativeQueryRuntime;

// bAllowNetwork is the caller's assertion that a local VR context already
// exists for this pawn. Only VRHandsBridge.IsLocalVRContext, which the network
// client overrides, may supply it; every other caller stays standalone-only.
function bool Initialize(KFPlayerController Controller, KFPawn_Human PawnOwner, optional bool bAllowNetwork)
{
    if (bInitialized || PC != None || Human != None || Controller == None || PawnOwner == None
        || Controller.Pawn != PawnOwner || !Controller.IsLocalController()
        || (!bAllowNetwork && PawnOwner.WorldInfo.NetMode != NM_Standalone)) return false;
    PC = Controller;
    bInitialized = true;
    Human = PawnOwner;
    NextItemId = 1;
    HandRevision[0] = 1;
    HandRevision[1] = 1;
    return true;
}

function bool IsOwned(KFWeapon W)
{
    local KFWeapon Candidate;
    if (Human == None || Human.bDeleteMe || PC == None || PC.Pawn != Human
        || W == None || W.bDeleteMe || W.Instigator != Human || Human.InvManager == None
        || W.InvManager != Human.InvManager) return false;
    foreach Human.InvManager.InventoryActors(class'KFWeapon', Candidate)
        if (Candidate == W) return true;
    return false;
}

function VRWeaponRuntime FindItem(KFWeapon W)
{
    local int I;
    if (!IsOwned(W)) return None;
    for (I = 0; I < Items.Length; ++I)
        if (Items[I] != None && Items[I].Item == W) return Items[I];
    return None;
}

function VRWeaponRuntime RegisterItem(KFWeapon W)
{
    local VRWeaponRuntime R;
    local int I, Count;
    R = FindItem(W);
    if (R != None) return R;
    if (!IsOwned(W) || NextItemId <= 0 || NextItemId == MaxInt) return None;
    // Read the stock length before publishing this exact item to the router.
    Count = W.GetPendingFireLength();
    if (Count <= 0 || Count > 32) return None;
    R = new(self) class'VRWeaponRuntime';
    R.Inventory = self;
    R.Item = W;
    R.ItemId = NextItemId++;
    R.PendingFireCount = Count;
    // Only the stock selected item can inherit the old shared trigger state.
    if (Human.Weapon == W)
        for (I = 0; I < Count; ++I)
            if (W.PendingFire(I)) R.PendingFireMask = R.PendingFireMask | (1 << I);
    R.NativeReady = 1;
    Items.AddItem(R);
    return R;
}

function ResolveNativeItem()
{
    NativeQueryRuntime = FindItem(NativeQueryWeapon);
}

function VRWeaponRuntime GetPrimary(int Hand)
{
    if (Hand == 0) return LeftItem;
    if (Hand == 1) return RightItem;
    return None;
}

function VRWeaponRuntime GetSupport(int Hand)
{
    if (Hand == 0) return LeftSupport;
    if (Hand == 1) return RightSupport;
    return None;
}

function bool IsDefensiveItem(VRWeaponRuntime R)
{
    return R != None && R.Inventory == self && R.IsCurrent()
        && R.PrimaryHand >= 0 && R.PrimaryHand < 2 && GetPrimary(R.PrimaryHand) == R
        && R.Item.IsA('KFWeap_MeleeBase') && R.Item.IsInState('MeleeBlocking')
        && (R.Presenter == None || R.Presenter.PhysicalMelee == None
            || R.Presenter.PhysicalMelee.bButtonGuard || R.Presenter.PhysicalMelee.CanDefend())
        && R.NativePoseReady == 1 && PoseSequence > 0 && R.PoseSequence == PoseSequence
        && R.OwnershipRevision > 0 && R.PoseOwnershipRevision == R.OwnershipRevision;
}

// Defensive stock callbacks have no weapon argument. Resolve one actual
// blocking primary, preferring the compatibility selection without stacking
// two weapons' damage reductions. Native callers use this result only inside
// their synchronous pawn-state scope; input intent is not proof of blocking.
function KFWeapon ResolveDefensiveItem()
{
    local VRWeaponRuntime R;
    if (Human == None || Human.bDeleteMe || Human.Health <= 0 || PC == None || PC.Pawn != Human) return None;
    R = FindItem(Human.MyKFWeapon);
    if (IsDefensiveItem(R)) return R.Item;
    R = GetPrimary(0);
    if (IsDefensiveItem(R)) return R.Item;
    R = GetPrimary(1);
    if (IsDefensiveItem(R)) return R.Item;
    return None;
}

// Stock grabs ask Victim.MyKFWeapon.IsGrappleBlocked directly. Native routes
// that question here: -1 lets the asked item answer itself, otherwise 0/1 is
// the answer of the one actual blocker, which may be the other hand's item.
function int ResolveGrappleBlock(Pawn InstigatedBy, KFWeapon Asked)
{
    local KFWeapon Defender;
    if (Asked == None || InstigatedBy == None || Human == None || Asked.Instigator != Human) return -1;
    Defender = ResolveDefensiveItem();
    if (Defender == Asked) return -1;
    if (Defender == None)
        // A stale managed block state cannot defend; stock items keep theirs.
        return (FindItem(Asked) != None && Asked.IsA('KFWeap_MeleeBase')) ? 0 : -1;
    return Defender.IsGrappleBlocked(InstigatedBy) ? 1 : 0;
}

function bool BindSupport(VRWeaponRuntime R, int Hand, int ExpectedItemRevision, int ExpectedHandRevision)
{
    if (R == None || R.Inventory != self || !R.IsCurrent() || Hand < 0 || Hand > 1
        || R.PrimaryHand != 1 - Hand || GetPrimary(R.PrimaryHand) != R || R.SupportHand != -1
        || GetPrimary(Hand) != None || GetSupport(Hand) != None
        || R.OwnershipRevision != ExpectedItemRevision || HandRevision[Hand] != ExpectedHandRevision
        || R.OwnershipRevision == MaxInt || HandRevision[Hand] == MaxInt) return false;
    R.InvalidatePose();
    R.SupportHand = Hand;
    ++R.OwnershipRevision;
    ++HandRevision[Hand];
    if (Hand == 0) LeftSupport = R;
    else RightSupport = R;
    return true;
}

function bool ReleaseSupport(VRWeaponRuntime R, int Hand, int ExpectedItemRevision, int ExpectedHandRevision)
{
    if (R == None || R.Inventory != self || Hand < 0 || Hand > 1
        || R.SupportHand != Hand || GetSupport(Hand) != R
        || R.OwnershipRevision != ExpectedItemRevision || HandRevision[Hand] != ExpectedHandRevision
        || R.OwnershipRevision == MaxInt || HandRevision[Hand] == MaxInt) return false;
    R.InvalidatePose();
    R.SupportHand = -1;
    ++R.OwnershipRevision;
    ++HandRevision[Hand];
    if (Hand == 0) LeftSupport = None;
    else RightSupport = None;
    return true;
}

// Commit-only ledger operations: callers must finish stock readiness/action
// work first. These do not equip, animate or swap Pawn.Weapon. Stale item/hand
// revisions reject delayed commands without disturbing either independent hand.
function bool BindPrimary(VRWeaponRuntime R, int Hand, int ExpectedItemRevision, int ExpectedHandRevision)
{
    if (R == None || R.Inventory != self || !R.IsCurrent() || Hand < 0 || Hand > 1
        || GetPrimary(Hand) != None || GetSupport(Hand) != None || R.PrimaryHand != -1 || R.PendingFireMask != 0
        || R.OwnershipRevision != ExpectedItemRevision || HandRevision[Hand] != ExpectedHandRevision
        || R.OwnershipRevision == MaxInt || HandRevision[Hand] == MaxInt) return false;
    R.InvalidatePose();
    R.PrimaryHand = Hand;
    ++R.OwnershipRevision;
    ++HandRevision[Hand];
    if (Hand == 0) LeftItem = R;
    else RightItem = R;
    return true;
}

function bool ReleasePrimary(VRWeaponRuntime R, int Hand, int ExpectedItemRevision, int ExpectedHandRevision)
{
    if (R == None || R.Inventory != self || Hand < 0 || Hand > 1
        || GetPrimary(Hand) != R || R.PrimaryHand != Hand || R.PendingFireMask != 0
        || R.OwnershipRevision != ExpectedItemRevision || HandRevision[Hand] != ExpectedHandRevision
        || R.OwnershipRevision == MaxInt || HandRevision[Hand] == MaxInt) return false;
    R.InvalidatePose();
    R.PrimaryHand = -1;
    ++R.OwnershipRevision;
    ++HandRevision[Hand];
    if (Hand == 0) LeftItem = None;
    else RightItem = None;
    return true;
}

function bool ReplacePrimary(VRWeaponRuntime Old, VRWeaponRuntime R, int Hand,
    int OldRevision, int NewRevision, int ExpectedHandRevision)
{
    if (Hand < 0 || Hand > 1 || Old == None || R == None || Old == R
        || !Old.IsCurrent() || !R.IsCurrent() || Old.Inventory != self || R.Inventory != self
        || GetPrimary(Hand) != Old || Old.PrimaryHand != Hand || GetSupport(Hand) != None
        || R.PrimaryHand != -1 || R.SupportHand != -1 || Old.PendingFireMask != 0 || R.PendingFireMask != 0
        || Old.OwnershipRevision != OldRevision || R.OwnershipRevision != NewRevision
        || HandRevision[Hand] != ExpectedHandRevision || OldRevision == MaxInt
        || NewRevision == MaxInt || ExpectedHandRevision == MaxInt) return false;
    Old.InvalidatePose(); R.InvalidatePose();
    Old.PrimaryHand = -1;
    R.PrimaryHand = Hand;
    ++Old.OwnershipRevision; ++R.OwnershipRevision; ++HandRevision[Hand];
    if (Hand == 0) LeftItem = R; else RightItem = R;
    return true;
}

// A validated held support can follow a primary replacement to a new authored
// support grip. Both hand revisions and both item revisions commit together.
function bool ReplacePrimaryWithSupport(VRWeaponRuntime Old, VRWeaponRuntime R, int Hand,
    int OldRevision, int NewRevision, int ExpectedHandRevision, int ExpectedSupportRevision)
{
    local int SupportHand;
    if (Hand < 0 || Hand > 1) return false;
    SupportHand = 1 - Hand;
    if (Old == None || R == None || Old == R || !Old.IsCurrent() || !R.IsCurrent()
        || Old.Inventory != self || R.Inventory != self || GetPrimary(Hand) != Old
        || Old.PrimaryHand != Hand || Old.SupportHand != SupportHand
        || GetSupport(SupportHand) != Old || GetPrimary(SupportHand) != None || GetSupport(Hand) != None
        || R.PrimaryHand != -1 || R.SupportHand != -1 || Old.PendingFireMask != 0 || R.PendingFireMask != 0
        || Old.OwnershipRevision != OldRevision || R.OwnershipRevision != NewRevision
        || HandRevision[Hand] != ExpectedHandRevision || HandRevision[SupportHand] != ExpectedSupportRevision
        || OldRevision == MaxInt || NewRevision == MaxInt || ExpectedHandRevision == MaxInt
        || ExpectedSupportRevision == MaxInt) return false;
    Old.InvalidatePose(); R.InvalidatePose();
    Old.PrimaryHand = -1;
    Old.SupportHand = -1;
    R.PrimaryHand = Hand;
    R.SupportHand = SupportHand;
    ++Old.OwnershipRevision; ++R.OwnershipRevision;
    ++HandRevision[Hand]; ++HandRevision[SupportHand];
    if (Hand == 0) { LeftItem = R; RightSupport = R; }
    else { RightItem = R; LeftSupport = R; }
    return true;
}

// Replace this hand's support contact with a different prepared item in one
// commit. The other primary's pending fire/reload belongs to that item and is
// not cancelled merely because its supporting hand draws another weapon.
function bool ReplaceSupport(VRWeaponRuntime Old, VRWeaponRuntime R, int Hand,
    int OldRevision, int NewRevision, int ExpectedHandRevision)
{
    if (Hand < 0 || Hand > 1 || Old == None || R == None || Old == R
        || !Old.IsCurrent() || !R.IsCurrent() || Old.Inventory != self || R.Inventory != self
        || GetSupport(Hand) != Old || Old.SupportHand != Hand || GetPrimary(Hand) != None
        || (Old.PrimaryHand != -1 && (Old.PrimaryHand != 1 - Hand || GetPrimary(1 - Hand) != Old))
        || R.PrimaryHand != -1 || R.SupportHand != -1 || R.PendingFireMask != 0
        || Old.OwnershipRevision != OldRevision || R.OwnershipRevision != NewRevision
        || HandRevision[Hand] != ExpectedHandRevision || OldRevision == MaxInt
        || NewRevision == MaxInt || ExpectedHandRevision == MaxInt) return false;
    Old.InvalidatePose(); R.InvalidatePose();
    Old.SupportHand = -1;
    R.PrimaryHand = Hand;
    ++Old.OwnershipRevision; ++R.OwnershipRevision; ++HandRevision[Hand];
    if (Hand == 0) { LeftSupport = None; LeftItem = R; }
    else { RightSupport = None; RightItem = R; }
    return true;
}

// Ownership invalidation is not a normal revisioned user command. It must
// revoke stale references even after the item has been sold or destroyed.
function Revoke(VRWeaponRuntime R)
{
    if (R == None || R.Inventory != self) return;
    if (LeftItem == R || LeftSupport == R)
    {
        if (LeftItem == R) LeftItem = None;
        if (LeftSupport == R) LeftSupport = None;
        if (HandRevision[0] < MaxInt) ++HandRevision[0];
    }
    if (RightItem == R || RightSupport == R)
    {
        if (RightItem == R) RightItem = None;
        if (RightSupport == R) RightSupport = None;
        if (HandRevision[1] < MaxInt) ++HandRevision[1];
    }
    R.NativeReady = 0;
    R.InvalidatePose(); R.PendingFireMask = 0;
    R.PrimaryHand = -1; R.SupportHand = -1;
}

function bool TransferPrimary(VRWeaponRuntime R, int FromHand, int ExpectedItemRevision,
    int ExpectedFromRevision, int ExpectedToRevision)
{
    local int ToHand;
    if (FromHand < 0 || FromHand > 1) return false;
    ToHand = 1 - FromHand;
    if (R == None || R.Inventory != self || !R.IsCurrent() || GetPrimary(FromHand) != R
        || R.PrimaryHand != FromHand || GetPrimary(ToHand) != None || R.PendingFireMask != 0
        || (GetSupport(ToHand) != None && GetSupport(ToHand) != R)
        || (R.SupportHand != -1 && (R.SupportHand != ToHand || GetSupport(ToHand) != R))
        || R.OwnershipRevision != ExpectedItemRevision || HandRevision[FromHand] != ExpectedFromRevision
        || HandRevision[ToHand] != ExpectedToRevision || R.OwnershipRevision == MaxInt
        || HandRevision[FromHand] == MaxInt || HandRevision[ToHand] == MaxInt) return false;
    R.InvalidatePose();
    R.PrimaryHand = ToHand;
    // A deliberate handoff may promote this same item's support hand. Merely
    // releasing the primary above leaves support-only carry, with no firing.
    R.SupportHand = -1;
    if (ToHand == 0) LeftSupport = None;
    else RightSupport = None;
    ++R.OwnershipRevision;
    ++HandRevision[FromHand];
    ++HandRevision[ToHand];
    if (ToHand == 0) { LeftItem = R; RightItem = None; }
    else { RightItem = R; LeftItem = None; }
    return true;
}

function int BeginPoseFrame()
{
    local int I;
    for (I = 0; I < Items.Length; ++I)
        if (Items[I] != None) Items[I].InvalidatePose();
    if (PoseSequence == MaxInt) { NativeAimRoutingEnabled = 0; return 0; }
    return ++PoseSequence;
}

// Explicit support-only promotion is a command, never a release side effect.
function bool PromoteSupport(VRWeaponRuntime R, int Hand, int ItemRevision, int ExpectedHandRevision)
{
    if (Hand < 0 || Hand > 1 || R == None || !R.IsCurrent() || R.Inventory != self
        || R.PrimaryHand != -1 || R.SupportHand != Hand || GetSupport(Hand) != R
        || GetPrimary(Hand) != None || R.PendingFireMask != 0
        || R.OwnershipRevision != ItemRevision || HandRevision[Hand] != ExpectedHandRevision
        || ItemRevision == MaxInt || ExpectedHandRevision == MaxInt) return false;
    R.InvalidatePose();
    R.PrimaryHand = Hand;
    R.SupportHand = -1;
    ++R.OwnershipRevision;
    ++HandRevision[Hand];
    if (Hand == 0) { LeftSupport = None; LeftItem = R; }
    else { RightSupport = None; RightItem = R; }
    return true;
}

function Shutdown()
{
    local int I;
    // Ownership/actions must be released before production teardown. The
    // feasibility probe changes pending bits synchronously and restores them.
    NativeRoutingEnabled = 0;
    NativeAimRoutingEnabled = 0;
    NativeRecoilScheduling = 0;
    NativeRecoilItem = None;
    LeftItem = None;
    RightItem = None;
    LeftSupport = None;
    RightSupport = None;
    for (I = 0; I < Items.Length; ++I)
    {
        if (Items[I] == None) continue;
        Items[I].NativeReady = 0;
        Items[I].InvalidatePose();
        Items[I].PrimaryHand = -1;
        Items[I].SupportHand = -1;
        Items[I].PendingFireMask = 0;
        Items[I].Item = None;
        Items[I].Inventory = None;
    }
    Items.Length = 0;
    NativeQueryWeapon = None;
    NativeQueryRuntime = None;
    Human = None;
    PC = None;
}
