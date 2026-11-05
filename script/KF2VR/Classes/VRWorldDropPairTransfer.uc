// Preallocates stock singles for a cross-owner paired-pistol pickup. The pair
// authority owns the release escrow and the irreversible chain/weight change.
// No reserve policy is inferred here: both allocations arrive explicitly.
class VRWorldDropPairTransfer extends Object;

const Rejected = 0;
const Transferred = 1;
const OwnershipFault = 2;

var VRWeaponPair Pair;
var KFPawn_Human OriginalOwner, Catcher;
var KFWeapon DepartingMember, RetainedMember, CaughtWeapon, KeptWeapon;
var int DepartingIndex, ExpectedPairRevision, ExpectedAvailableReserve;
var int ExpectedDropToken, ExpectedOtherDropToken, ExpectedOtherDropReserve;
var int CaughtReserve, KeptReserve;
var int DepartingAmmo[2], RetainedAmmo[2], ExpectedPairUpgrade;
var int DepartingUpgrade, RetainedUpgrade, CaughtUpgrade, KeptUpgrade;
var bool bMutationStarted;
var VRWorldDropSingleMerge PreparedMerge;
var private Controller OriginalController, CatcherController;
var private KFInventoryManager OriginalInventory, CatcherInventory;
var private bool bPrepared;

// Root binder must revalidate the exact release escrow token and held identities,
// then call the Pair-owned extraction API. That API marks mutation immediately
// before retiring the first wrapper; Rejected must have no inventory effects.
// Pair API contract:
// - First paired release: keep up to the retained stock single's PRE-UPGRADE
//   spare capacity for the original owner's perk (the SDK SetupDroppedPickup
//   order), escrow only the excess, and downgrade the dropped member to upgrade
//   0. Preserve both physical members' loaded counts exactly.
// - Already-separated singles use their full allocated reserve and own upgrade;
//   a second toss must not perform the dual split/downgrade again.
// - Own catch/recall: consume the exact escrow once, reunite Reserve and restore
//   the combined pair upgrade under stock rules without clamping loaded rounds.
// - Cross-owner extraction: validate this snapshot and escrow, then remove both
//   wrappers through stock inventory cleanup while their weight policy is live;
//   install these singles through AddInventory(...,true), clear every pair pool
//   and escrow, set PairState=3, and retire empty wrappers/aggregate receipt.
// The source binder remaps any retained dropped prop and its mechanism state to
// KeptWeapon. Its remaining escrow is included in KeptReserve, never copied twice.
delegate byte CommitExtraction(VRWorldDropPairTransfer Request) { return Rejected; }

function bool PairCurrent()
{
    local int I;
    if (Pair == None || Pair.bDeleteMe || Pair.Role != ROLE_Authority || Pair.PairState != 2
        || !class'VRWorldDropTransfer'.static.ValidBody(OriginalOwner)
        || !class'VRWorldDropTransfer'.static.ValidBody(Catcher) || Catcher == OriginalOwner
        || Pair.Human != OriginalOwner || Pair.Manager != OriginalOwner.InvManager
        || Pair.AmmoDepth != 0 || Pair.AmmoBorrower != None || Pair.PhysicalReloadPermit != None
        || Pair.StockItem == None || Pair.StockItem.bDeleteMe
        || Pair.StockItem.Owner != None || Pair.StockItem.InvManager != None
        || Pair.StockItem.Instigator != None || Pair.StockItem.Inventory != None
        || Pair.StockItem.AmmoCount[0] != 0 || Pair.StockItem.SpareAmmoCount[0] != 0
        || Pair.Reserve < 0 || Pair.Revision <= 0 || DepartingIndex < 0 || DepartingIndex > 1
        || !Pair.bWorldSplit || Pair.WorldDropToken[DepartingIndex] <= 0
        || Pair.Members[DepartingIndex] != DepartingMember
        || Pair.Members[1 - DepartingIndex] != RetainedMember) return false;
    for (I = 0; I < 2; ++I)
        if (!Pair.IsMember(Pair.Members[I])
            || !class'VRWorldDropTransfer'.static.Owns(OriginalOwner, Pair.Members[I])
            || Pair.PhysicalStatuses[I] == 1 || Pair.PhysicalStatuses[I] == 4
            || Pair.Members[I].IsInState('Reloading')
            || Pair.Members[I].AmmoCount[0] < 0
            || Pair.Members[I].SpareAmmoCount[0] != 0 || Pair.Members[I].SpareAmmoCount[1] != 0
            || Pair.Members[I].AmmoCount[1] != 0) return false;
    return true;
}

function bool SourceCanKeep()
{
    local KFWeapon Existing;
    local VRWeaponPair ExistingPair;
    local int RemovedWeight, RemainingWeight, SingleWeight;
    if (KeptWeapon == None || Pair.SourceWeight < 0 || OriginalInventory.CurrentCarryBlocks < Pair.SourceWeight)
        return false;
    RemovedWeight = DepartingMember.GetModifiedWeightValue() + RetainedMember.GetModifiedWeightValue();
    if (RemovedWeight != Pair.SourceWeight) return false;
    RemainingWeight = OriginalInventory.CurrentCarryBlocks - RemovedWeight;
    SingleWeight = KeptWeapon.GetModifiedWeightValue();
    if (SingleWeight < 0 || SingleWeight > MaxInt - RemainingWeight
        || (!OriginalInventory.bInfiniteWeight
            && RemainingWeight + SingleWeight > OriginalInventory.MaxCarryBlocks)) return false;
    foreach OriginalInventory.InventoryActors(class'KFWeapon', Existing)
    {
        if (Existing == DepartingMember || Existing == RetainedMember) continue;
        if (Existing.Class == KeptWeapon.Class || Existing.Class == KeptWeapon.DualClass
            || (class'VRWorldDropTransfer'.static.SecondaryPistol(Existing.Class)
                && class'VRWorldDropTransfer'.static.SecondaryPistol(KeptWeapon.Class))) return false;
        ExistingPair = class'VRWeaponPair'.static.ForMember(Existing);
        if (ExistingPair != None && ExistingPair.StockItem != None
            && ExistingPair.StockItem.SingleClass == KeptWeapon.Class) return false;
    }
    return true;
}

function Cancel()
{
    // A post-boundary fault leaves the prepared actors available to the binder's
    // ownership reconciliation. Never destroy an actor another ledger adopted.
    if (!bMutationStarted)
    {
        if (PreparedMerge != None) PreparedMerge.Cancel();
        PreparedMerge = None;
        if (KeptWeapon != None && KeptWeapon.Owner == None && KeptWeapon.InvManager == None) KeptWeapon.Destroy();
        if (CaughtWeapon != None && CaughtWeapon.Owner == None && CaughtWeapon.InvManager == None) CaughtWeapon.Destroy();
        KeptWeapon = None; CaughtWeapon = None;
    }
    bPrepared = false;
}

function PrepareSingle(KFWeapon W, KFPawn_Human Body, int Loaded, int Reserve, int Upgrade)
{
    W.SetOwner(None); W.Inventory = None; W.InvManager = None;
    W.Instigator = Body;
    W.CacheKFPlayerController();
    W.SetWeaponUpgradeLevel(Upgrade);
    W.bGivenAtStart = Pair.bSourceGivenAtStart;
    W.AmmoCount[0] = Loaded; W.AmmoCount[1] = 0;
    W.SpareAmmoCount[0] = Reserve; W.SpareAmmoCount[1] = 0;
    W.GotoState('Inactive'); W.SetHidden(true);
    // Preparation is not a second owned weapon. Avoid retaining a live pawn
    // context until the Pair authority publishes ownership through GivenTo.
    W.Instigator = None;
    W.CacheKFPlayerController();
}

// ReservedRounds is the departing pistol's already-segregated release escrow.
// RemainingRounds includes every pool still owned by the retained pistol; the
// authority, not this helper, reconciles a second dropped member's escrow.
function bool Prepare(VRWeaponPair SourcePair, KFWeapon Departing, KFPawn_Human Recipient,
    int ReservedRounds, int RemainingRounds, int ReservedUpgrade, int RemainingUpgrade,
    optional bool bPairRecipient=true)
{
    local class<KFWeapon> SingleClass;
    local int I;
    if (bMutationStarted) return false;
    Cancel();
    Pair = SourcePair; DepartingMember = Departing; Catcher = Recipient;
    if (Pair == None || Departing == None || ReservedRounds < 0 || RemainingRounds < 0
        || ReservedUpgrade < 0 || RemainingUpgrade < 0
        || ReservedRounds > MaxInt - RemainingRounds) return false;
    OriginalOwner = Pair.Human;
    DepartingIndex = Pair.Members[0] == Departing ? 0 : 1;
    RetainedMember = Pair.Members[1 - DepartingIndex];
    if (!PairCurrent()) return false;
    CommitExtraction = Pair.CommitWorldExtraction;
    if (ReservedRounds != Pair.WorldDropReserve[DepartingIndex]
        || RemainingRounds != Pair.Reserve + Pair.WorldDropReserve[1 - DepartingIndex]
        || ReservedUpgrade != Pair.WorldDropUpgrade[DepartingIndex]
        || RemainingUpgrade != Pair.WorldDropUpgrade[1 - DepartingIndex]) return false;
    // Only the catalog's audited stock single may replace its private wrapper.
    SingleClass = Pair.StockItem.SingleClass;
    if (SingleClass == None || class'VRWeaponPair'.static.MemberClassFor(Pair.StockItem) != Departing.Class)
        return false;
    OriginalController = OriginalOwner.Controller; CatcherController = Catcher.Controller;
    OriginalInventory = KFInventoryManager(OriginalOwner.InvManager);
    CatcherInventory = KFInventoryManager(Catcher.InvManager);
    ExpectedPairRevision = Pair.Revision; ExpectedAvailableReserve = Pair.Reserve;
    ExpectedPairUpgrade = Pair.SourceUpgrade;
    ExpectedDropToken = Pair.WorldDropToken[DepartingIndex];
    ExpectedOtherDropToken = Pair.WorldDropToken[1 - DepartingIndex];
    ExpectedOtherDropReserve = Pair.WorldDropReserve[1 - DepartingIndex];
    DepartingUpgrade = Departing.CurrentWeaponUpgradeIndex;
    RetainedUpgrade = RetainedMember.CurrentWeaponUpgradeIndex;
    CaughtUpgrade = ReservedUpgrade; KeptUpgrade = RemainingUpgrade;
    CaughtReserve = ReservedRounds; KeptReserve = RemainingRounds;
    for (I = 0; I < 2; ++I)
    { DepartingAmmo[I] = Departing.AmmoCount[I]; RetainedAmmo[I] = RetainedMember.AmmoCount[I]; }
    KeptWeapon = OriginalOwner.Spawn(SingleClass);
    if (KeptWeapon == None) { Cancel(); return false; }
    PrepareSingle(KeptWeapon, OriginalOwner, RetainedAmmo[0], KeptReserve, KeptUpgrade);
    CaughtWeapon = Catcher.Spawn(SingleClass);
    if (CaughtWeapon == None) { Cancel(); return false; }
    PrepareSingle(CaughtWeapon, Catcher, DepartingAmmo[0], CaughtReserve, CaughtUpgrade);
    // Current audited pair families have no auxiliary actor components. A new
    // family must acquire an explicit preparation path before being admitted.
    if (KeptWeapon.MedicCompClass != None || KeptWeapon.TargetingCompClass != None
        || CaughtWeapon.MedicCompClass != None || CaughtWeapon.TargetingCompClass != None
        || !SourceCanKeep())
    { Cancel(); return false; }
    if (!class'VRWorldDropTransfer'.static.CanReceive(Catcher, CaughtWeapon))
    {
        PreparedMerge = new(self) class'VRWorldDropSingleMerge';
        if (!PreparedMerge.Prepare(Catcher, CaughtWeapon, None, bPairRecipient))
        { Cancel(); return false; }
    }
    bPrepared = true;
    return true;
}

function bool StillPrepared()
{
    local int I;
    if (!bPrepared || bMutationStarted || !PairCurrent()
        || OriginalOwner.Controller != OriginalController || Catcher.Controller != CatcherController
        || OriginalOwner.InvManager != OriginalInventory || Catcher.InvManager != CatcherInventory
        || Pair.Revision != ExpectedPairRevision || Pair.Reserve != ExpectedAvailableReserve
        || Pair.SourceUpgrade != ExpectedPairUpgrade
        || Pair.WorldDropToken[DepartingIndex] != ExpectedDropToken
        || Pair.WorldDropReserve[DepartingIndex] != CaughtReserve
        || Pair.WorldDropUpgrade[DepartingIndex] != CaughtUpgrade
        || Pair.WorldDropToken[1 - DepartingIndex] != ExpectedOtherDropToken
        || Pair.WorldDropReserve[1 - DepartingIndex] != ExpectedOtherDropReserve
        || Pair.WorldDropUpgrade[1 - DepartingIndex] != KeptUpgrade
        || DepartingMember.CurrentWeaponUpgradeIndex != DepartingUpgrade
        || RetainedMember.CurrentWeaponUpgradeIndex != RetainedUpgrade
        || KeptWeapon == None || KeptWeapon.bDeleteMe
        || CaughtWeapon == None || CaughtWeapon.bDeleteMe
        || KeptWeapon.Owner != None || KeptWeapon.InvManager != None
        || CaughtWeapon.Owner != None || CaughtWeapon.InvManager != None
        || KeptWeapon.AmmoCount[0] != RetainedAmmo[0] || CaughtWeapon.AmmoCount[0] != DepartingAmmo[0]
        || KeptWeapon.SpareAmmoCount[0] != KeptReserve || CaughtWeapon.SpareAmmoCount[0] != CaughtReserve
        || KeptWeapon.CurrentWeaponUpgradeIndex != KeptUpgrade
        || CaughtWeapon.CurrentWeaponUpgradeIndex != CaughtUpgrade
        || !SourceCanKeep()
        || (PreparedMerge == None && !class'VRWorldDropTransfer'.static.CanReceive(Catcher, CaughtWeapon))
        || (PreparedMerge != None && !PreparedMerge.StillPrepared())) return false;
    for (I = 0; I < 2; ++I)
        if (DepartingMember.AmmoCount[I] != DepartingAmmo[I] || RetainedMember.AmmoCount[I] != RetainedAmmo[I]) return false;
    return true;
}

function byte Commit()
{
    local byte Outcome;
    if (!StillPrepared()) { Cancel(); return Rejected; }
    Outcome = CommitExtraction(self);
    if (Outcome == Rejected && !bMutationStarted) { Cancel(); return Rejected; }
    bMutationStarted = true;
    bPrepared = false;
    if (Outcome != Transferred || Pair == None || Pair.bDeleteMe || Pair.PairState != 3 || Pair.Reserve != 0
        || !class'VRWorldDropTransfer'.static.Owns(OriginalOwner, KeptWeapon)
        || !class'VRWorldDropTransfer'.static.Owns(Catcher, CaughtWeapon)
        || !RetiredMember(DepartingMember) || !RetiredMember(RetainedMember)
        || KeptWeapon.AmmoCount[0] != RetainedAmmo[0]
        || (PreparedMerge == None && (CaughtWeapon.AmmoCount[0] != DepartingAmmo[0]
            || CaughtWeapon.SpareAmmoCount[0] != CaughtReserve))
        || KeptWeapon.SpareAmmoCount[0] != KeptReserve
        || KeptWeapon.CurrentWeaponUpgradeIndex != KeptUpgrade
        || (PreparedMerge == None && CaughtWeapon.CurrentWeaponUpgradeIndex != CaughtUpgrade))
        return OwnershipFault;
    KeptWeapon.ClientForceAmmoUpdate(KeptWeapon.AmmoCount[0], KeptWeapon.SpareAmmoCount[0]);
    KeptWeapon.ClientForceSecondaryAmmoUpdate(KeptWeapon.AmmoCount[1]);
    CaughtWeapon.ClientForceAmmoUpdate(CaughtWeapon.AmmoCount[0], CaughtWeapon.SpareAmmoCount[0]);
    CaughtWeapon.ClientForceSecondaryAmmoUpdate(CaughtWeapon.AmmoCount[1]);
    KeptWeapon.bForceNetUpdate = true; CaughtWeapon.bForceNetUpdate = true;
    if (PreparedMerge == None) CaughtWeapon.NotifyPickedUp();
    OriginalInventory.UpdateHUD(); CatcherInventory.UpdateHUD();
    return Transferred;
}

function bool RetiredMember(KFWeapon W)
{
    return W == None || W.bDeleteMe || (W.Owner == None && W.Instigator == None
        && W.InvManager == None && W.Inventory == None && W.AmmoCount[0] == 0
        && W.AmmoCount[1] == 0 && W.SpareAmmoCount[0] == 0 && W.SpareAmmoCount[1] == 0
        && !OriginalInventory.ItemIsInInventory(W));
}
