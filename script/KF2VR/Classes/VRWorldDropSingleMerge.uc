// Preallocated stock-legal single-to-dual sharing. Allocation and capacity
// checks precede either removal; every paid round survives the transaction.
class VRWorldDropSingleMerge extends Object;

const Rejected = 0;
const Transferred = 1;
const OwnershipFault = 2;

var KFPawn_Human Recipient, OriginalOwner;
var KFWeapon Incoming, RecipientSingle, ResultWeapon, RetainedWeapon;
var KFWeap_DualBase PreparedDual;
var VRWeaponPair ResultPair;
var private VRWorldDropGun PublicProp;
var private Actor StockPickupActor;
var private bool bPreparingStock;
var private KFWeapon StockOriginal;
var private int StockOriginalAmmo[2], StockOriginalReserve[2], StockOriginalUpgrade;
var bool bMutationStarted, bAsPair;
var private bool bPrepared, bIncomingOwned;
var private Controller RecipientController, OriginalController;
var private KFInventoryManager RecipientInventory, OriginalInventory;
var private int IncomingAmmo, ExistingAmmo, IncomingReserve, ExistingReserve;
var private int IncomingUpgrade, ExistingUpgrade, CombinedUpgrade, CombinedReserve, CombinedLoaded;
var private int ExpectedRecipientCarry, ExpectedSourceCarry, ExistingWeight, IncomingWeight, DualWeight;
var private bool bIncomingGivenAtStart;

function Cancel()
{
    if (!bMutationStarted)
    {
        if (ResultPair != None) { ResultPair.AbortPreparation(); ResultPair.Destroy(); }
        if (PreparedDual != None && PreparedDual.Owner == None && PreparedDual.InvManager == None)
            PreparedDual.Destroy();
        ResultPair = None; PreparedDual = None;
    }
    bPrepared = false;
}

private function bool ExactFamily(KFWeapon W)
{
    local int I;
    if (W == None || W.bDeleteMe || W.DualClass == None) return false;
    for (I = 0; I < class'VRWeaponPair'.default.Families.Length; ++I)
        if (W.Class == class'VRWeaponPair'.default.Families[I].SingleClass
            && W.DualClass == class'VRWeaponPair'.default.Families[I].DualClass) return true;
    return false;
}

private function bool SourceCurrent()
{
    local KFDroppedPickup Drop;
    local KFPickupFactory_Item Factory;
    if (Incoming == None || Incoming.bDeleteMe) return false;
    if (StockPickupActor != None)
    {
        if (StockPickupActor.bDeleteMe || StockPickupActor.Role != ROLE_Authority
            || Incoming.Role != ROLE_Authority || StockPickupActor.WorldInfo != Incoming.WorldInfo
            || VRWorldDropGun(StockPickupActor) != None) return false;
        Drop = KFDroppedPickup(StockPickupActor);
        if (Drop != None)
        {
            // Stock DropFrom leaves Owner=None and may retain its old
            // InvManager pointer. The exact pickup owns the paid actor;
            // membership in that old inventory must already be gone.
            if (StockOriginal == None || StockOriginal.bDeleteMe || StockOriginal.Role != ROLE_Authority
                || StockOriginal.WorldInfo != Drop.WorldInfo || Drop.Inventory != StockOriginal
                || Drop.InventoryClass != Incoming.Class
                || (StockOriginal.Owner != None && StockOriginal.Owner != Drop)
                || StockOriginal.Instigator != None || StockOriginal.Inventory != None
                || (StockOriginal.InvManager != None && (KFInventoryManager(StockOriginal.InvManager) == None
                    || KFInventoryManager(StockOriginal.InvManager).ItemIsInInventory(StockOriginal)))) return false;
            if (StockOriginal == Incoming) return true;
            // Stock drops half a dual under InventoryClass=SingleClass while
            // retaining its original dual actor as the pickup's paid receipt.
            return KFWeap_DualBase(StockOriginal) != None && StockOriginal.Class == Incoming.DualClass
                && KFWeap_DualBase(StockOriginal).SingleClass == Incoming.Class
                && StockOriginal.AmmoCount[0] == StockOriginalAmmo[0]
                && StockOriginal.AmmoCount[1] == StockOriginalAmmo[1]
                && StockOriginal.SpareAmmoCount[0] == StockOriginalReserve[0]
                && StockOriginal.SpareAmmoCount[1] == StockOriginalReserve[1]
                && StockOriginal.CurrentWeaponUpgradeIndex == StockOriginalUpgrade
                && Incoming.AmmoCount[0] == StockOriginalAmmo[0] && Incoming.AmmoCount[1] == StockOriginalAmmo[1]
                && Incoming.SpareAmmoCount[0] == StockOriginalReserve[0] && Incoming.SpareAmmoCount[1] == StockOriginalReserve[1]
                && Incoming.CurrentWeaponUpgradeIndex == StockOriginalUpgrade
                && Incoming.Owner == None && Incoming.InvManager == None
                && Incoming.Instigator == None && Incoming.Inventory == None;
        }
        Factory = KFPickupFactory_Item(StockPickupActor);
        return Factory != None && Factory.ReadyToPickup(0) && Factory.CanUsePickup()
            && Factory.PickupIndex < Factory.ItemPickups.Length
            && Factory.ItemPickups[Factory.PickupIndex].ItemClass == Incoming.Class
            && Incoming.Owner == None && Incoming.InvManager == None
            && Incoming.Instigator == None && Incoming.Inventory == None;
    }
    if (PublicProp != None)
        return PublicProp.SourceRegistry != None
            && PublicProp.SourceRegistry.HasPublicWeapon(PublicProp, Incoming);
    if (bIncomingOwned)
        return class'VRWorldDropTransfer'.static.Owns(OriginalOwner, Incoming)
            && OriginalOwner.Controller == OriginalController && OriginalOwner.InvManager == OriginalInventory;
    return Incoming.Owner == None && Incoming.InvManager == None
        && Incoming.Instigator == None && Incoming.Inventory == None;
}

private function bool SingleActionReady(KFWeapon W)
{
    local int Mode;
    if (W == None || W.bDeleteMe || (!W.IsInState('Active') && !W.IsInState('Inactive')
            && !(W == Incoming && (PublicProp != None || StockPickupActor != None) && W.GetStateName() == ''))
        || W.IsTimerActive('ForceReload') || W.IsTimerActive('Timer_StartFireAfterReload')
        || W.IsTimerActive('RefireCheckTimer') || W.IsTimerActive('ReloadAmmoTimer')
        || W.IsTimerActive('ReloadStatusTimer')) return false;
    for (Mode = 0; Mode < W.GetPendingFireLength(); ++Mode)
        if (W.PendingFire(byte(Mode))) return false;
    return true;
}

function bool Prepare(KFPawn_Human Catcher, KFWeapon AddedSingle,
    optional KFPawn_Human SourceOwner, optional bool bPairRecipient, optional VRWorldDropGun DetachedPublic)
{
    local KFWeapon Existing;
    local VRWeaponPair Pair;
    if (bMutationStarted) return false;
    Cancel();
    if (!bPreparingStock) { StockPickupActor = None; StockOriginal = None; }
    Recipient = Catcher; OriginalOwner = SourceOwner; Incoming = AddedSingle;
    PublicProp = DetachedPublic;
    RecipientSingle = None; ResultWeapon = None; RetainedWeapon = None;
    bAsPair = bPairRecipient;
    if (!class'VRWorldDropTransfer'.static.ValidBody(Recipient) || !Recipient.bCanPickupInventory
        || !class'VRPhysicalInteraction'.static.Allowed(Recipient)
        || !ExactFamily(Incoming) || Incoming.WorldInfo != Recipient.WorldInfo
        || OriginalOwner == Recipient) return false;
    RecipientInventory = KFInventoryManager(Recipient.InvManager);
    RecipientController = Recipient.Controller;
    bIncomingOwned = PublicProp == None && StockPickupActor == None
        && (Incoming.Owner != None || Incoming.InvManager != None);
    if (bIncomingOwned)
    {
        if (!class'VRWorldDropTransfer'.static.Owns(OriginalOwner, Incoming)) return false;
        OriginalInventory = KFInventoryManager(OriginalOwner.InvManager);
        OriginalController = OriginalOwner.Controller;
    }
    if (!SourceCurrent() || !SingleActionReady(Incoming) || RecipientInventory.bServerTraderMenuOpen
        || Incoming.MedicCompClass != None || Incoming.TargetingCompClass != None
        || Incoming.AmmoCount[0] < 0 || Incoming.SpareAmmoCount[0] < 0
        || Incoming.AmmoCount[1] != 0 || Incoming.SpareAmmoCount[1] != 0) return false;
    foreach RecipientInventory.InventoryActors(class'KFWeapon', Existing)
    {
        Pair = class'VRWeaponPair'.static.ForMember(Existing);
        if (Existing.Class == Incoming.DualClass || (Pair != None && Pair.StockItem != None
            && (Pair.StockItem.SingleClass == Incoming.Class
                || (class'VRWorldDropTransfer'.static.SecondaryPistol(Pair.StockItem.SingleClass)
                    && class'VRWorldDropTransfer'.static.SecondaryPistol(Incoming.Class))))) return false;
        // Stock 9mm/93R pickups follow the recipient's current secondary
        // family. Preserve the incoming paid actor until commit, but build
        // the result from the exact existing single's audited dual class.
        if (Existing.Class == Incoming.Class
            || (ExactFamily(Existing) && class'VRWorldDropTransfer'.static.SecondaryPistol(Existing.Class)
                && class'VRWorldDropTransfer'.static.SecondaryPistol(Incoming.Class)))
        {
            if (RecipientSingle != None) return false;
            RecipientSingle = Existing;
        }
        else if (class'VRWorldDropTransfer'.static.SecondaryPistol(Existing.Class)
            && class'VRWorldDropTransfer'.static.SecondaryPistol(Incoming.Class)) return false;
    }
    if (!class'VRWorldDropTransfer'.static.Owns(Recipient, RecipientSingle)
        || !SingleActionReady(RecipientSingle)
        || RecipientSingle.MedicCompClass != None || RecipientSingle.TargetingCompClass != None
        || RecipientSingle.AmmoCount[0] < 0 || RecipientSingle.SpareAmmoCount[0] < 0
        || RecipientSingle.AmmoCount[1] != 0 || RecipientSingle.SpareAmmoCount[1] != 0
        || Incoming.AmmoCount[0] > MaxInt - RecipientSingle.AmmoCount[0]
        || Incoming.SpareAmmoCount[0] > MaxInt - RecipientSingle.SpareAmmoCount[0]) return false;
    IncomingAmmo = Incoming.AmmoCount[0]; ExistingAmmo = RecipientSingle.AmmoCount[0];
    IncomingReserve = Incoming.SpareAmmoCount[0]; ExistingReserve = RecipientSingle.SpareAmmoCount[0];
    IncomingUpgrade = Incoming.CurrentWeaponUpgradeIndex; ExistingUpgrade = RecipientSingle.CurrentWeaponUpgradeIndex;
    CombinedUpgrade = Max(IncomingUpgrade, ExistingUpgrade);
    CombinedLoaded = IncomingAmmo + ExistingAmmo; CombinedReserve = IncomingReserve + ExistingReserve;
    bIncomingGivenAtStart = Incoming.bGivenAtStart;
    if (!RecipientInventory.CanCarryWeapon(RecipientSingle.Class, CombinedUpgrade)) return false;
    PreparedDual = Recipient.Spawn(RecipientSingle.DualClass);
    if (PreparedDual == None || PreparedDual.SingleClass != RecipientSingle.Class)
    { Cancel(); return false; }
    PreparedDual.SetOwner(None); PreparedDual.InvManager = None; PreparedDual.Inventory = None;
    PreparedDual.Instigator = Recipient; PreparedDual.CacheKFPlayerController();
    PreparedDual.SetWeaponUpgradeLevel(CombinedUpgrade);
    PreparedDual.bGivenAtStart = bIncomingGivenAtStart;
    PreparedDual.AmmoCount[0] = bAsPair ? Min(CombinedLoaded, PreparedDual.MagazineCapacity[0]) : CombinedLoaded;
    PreparedDual.AmmoCount[1] = 0;
    PreparedDual.SpareAmmoCount[0] = CombinedReserve; PreparedDual.SpareAmmoCount[1] = 0;
    PreparedDual.GotoState('Inactive'); PreparedDual.SetHidden(true);
    PreparedDual.Instigator = None; PreparedDual.CacheKFPlayerController();
    ExistingWeight = RecipientSingle.GetModifiedWeightValue();
    IncomingWeight = Incoming.GetModifiedWeightValue(); DualWeight = PreparedDual.GetModifiedWeightValue();
    ExpectedRecipientCarry = RecipientInventory.CurrentCarryBlocks;
    if (ExistingWeight < 0 || IncomingWeight < 0 || DualWeight < 0 || ExpectedRecipientCarry < ExistingWeight
        || DualWeight > MaxInt - (ExpectedRecipientCarry - ExistingWeight)
        || (!RecipientInventory.bInfiniteWeight
            && ExpectedRecipientCarry - ExistingWeight + DualWeight > RecipientInventory.MaxCarryBlocks))
    { Cancel(); return false; }
    if (bIncomingOwned) ExpectedSourceCarry = OriginalInventory.CurrentCarryBlocks;
    if (bAsPair)
    {
        ResultPair = Recipient.Spawn(class'VRWeaponPair', Recipient);
        if (ResultPair == None || !ResultPair.BeginPreparedWorldMerge(Recipient, PreparedDual))
        { Cancel(); return false; }
    }
    bPrepared = true;
    return true;
}

// Called only by the authoritative stock-pickup binder after its reach/hand
// checks. Factory weapons are preallocated before either paid single moves.
function bool PrepareStock(Actor Pickup, KFPawn_Human Catcher, KFWeapon PreparedIncoming, bool bPairRecipient)
{
    local bool Accepted;
    local KFDroppedPickup Drop;
    local int I;
    if (bMutationStarted || Pickup == None || Pickup.bDeleteMe || Pickup.Role != ROLE_Authority
        || VRWorldDropGun(Pickup) != None
        || (KFDroppedPickup(Pickup) == None && KFPickupFactory_Item(Pickup) == None)) return false;
    StockOriginal = None;
    Drop = KFDroppedPickup(Pickup);
    if (Drop != None)
    {
        StockOriginal = KFWeapon(Drop.Inventory);
        if (StockOriginal == None) return false;
        for (I = 0; I < 2; ++I)
        { StockOriginalAmmo[I] = StockOriginal.AmmoCount[I]; StockOriginalReserve[I] = StockOriginal.SpareAmmoCount[I]; }
        StockOriginalUpgrade = StockOriginal.CurrentWeaponUpgradeIndex;
    }
    StockPickupActor = Pickup; bPreparingStock = true;
    Accepted = Prepare(Catcher, PreparedIncoming, None, bPairRecipient);
    bPreparingStock = false;
    if (!Accepted) { StockPickupActor = None; StockOriginal = None; }
    return Accepted;
}

function bool StillPrepared()
{
    return bPrepared && !bMutationStarted && SourceCurrent()
        && SingleActionReady(Incoming)
        && class'VRWorldDropTransfer'.static.ValidBody(Recipient)
        && class'VRPhysicalInteraction'.static.Allowed(Recipient)
        && Recipient.Controller == RecipientController && Recipient.InvManager == RecipientInventory
        && !RecipientInventory.bServerTraderMenuOpen
        && class'VRWorldDropTransfer'.static.Owns(Recipient, RecipientSingle)
        && SingleActionReady(RecipientSingle)
        && Incoming.AmmoCount[0] == IncomingAmmo && Incoming.SpareAmmoCount[0] == IncomingReserve
        && Incoming.AmmoCount[1] == 0 && Incoming.SpareAmmoCount[1] == 0
        && Incoming.CurrentWeaponUpgradeIndex == IncomingUpgrade
        && RecipientSingle.AmmoCount[0] == ExistingAmmo && RecipientSingle.SpareAmmoCount[0] == ExistingReserve
        && RecipientSingle.AmmoCount[1] == 0 && RecipientSingle.SpareAmmoCount[1] == 0
        && RecipientSingle.CurrentWeaponUpgradeIndex == ExistingUpgrade
        && RecipientInventory.CurrentCarryBlocks == ExpectedRecipientCarry
        && RecipientInventory.CanCarryWeapon(RecipientSingle.Class, CombinedUpgrade)
        && PreparedDual != None && !PreparedDual.bDeleteMe && PreparedDual.Owner == None
        && PreparedDual.Class == RecipientSingle.DualClass && PreparedDual.SingleClass == RecipientSingle.Class
        && PreparedDual.InvManager == None && PreparedDual.CurrentWeaponUpgradeIndex == CombinedUpgrade
        && PreparedDual.SpareAmmoCount[0] == CombinedReserve
        && (!bAsPair || (ResultPair != None && !ResultPair.bDeleteMe && ResultPair.PreparedWorldMergeCompatible()));
}

function int CarryDelta() { return DualWeight - ExistingWeight; }

function byte Commit()
{
    if (!StillPrepared()) { Cancel(); return Rejected; }
    bMutationStarted = true;
    if (bIncomingOwned)
    {
        Incoming.ForceEndFire(); Incoming.GotoState('Inactive');
        OriginalInventory.RemoveFromInventory(Incoming);
        if (OriginalInventory.ItemIsInInventory(Incoming)) return OwnershipFault;
        if (OriginalOwner.MyKFWeapon == Incoming) OriginalOwner.MyKFWeapon = None;
    }
    RecipientSingle.ForceEndFire(); RecipientSingle.GotoState('Inactive');
    RecipientInventory.RemoveFromInventory(RecipientSingle);
    if (RecipientInventory.ItemIsInInventory(RecipientSingle)) return OwnershipFault;
    if (Recipient.MyKFWeapon == RecipientSingle) Recipient.MyKFWeapon = None;
    if (!RecipientInventory.AddInventory(PreparedDual, true)
        || !class'VRWorldDropTransfer'.static.Owns(Recipient, PreparedDual)) return OwnershipFault;
    PreparedDual.AmmoCount[0] = bAsPair ? Min(CombinedLoaded, PreparedDual.MagazineCapacity[0]) : CombinedLoaded;
    PreparedDual.SpareAmmoCount[0] = CombinedReserve;
    if (bAsPair)
    {
        if (!ResultPair.CommitPreparedWorldMerge(ExistingAmmo, IncomingAmmo, CombinedReserve)) return OwnershipFault;
        RetainedWeapon = ResultPair.Members[0]; ResultWeapon = ResultPair.Members[1];
    }
    else ResultWeapon = PreparedDual;
    if (RecipientInventory.CurrentCarryBlocks != ExpectedRecipientCarry - ExistingWeight + DualWeight
        || (bIncomingOwned && OriginalInventory.CurrentCarryBlocks != ExpectedSourceCarry - IncomingWeight)) return OwnershipFault;
    RetireSingle(Incoming); RetireSingle(RecipientSingle);
    ResultWeapon.bForceNetUpdate = true;
    ResultWeapon.ClientForceAmmoUpdate(ResultWeapon.AmmoCount[0], ResultWeapon.SpareAmmoCount[0]);
    if (RetainedWeapon != None) RetainedWeapon.bForceNetUpdate = true;
    ResultWeapon.NotifyPickedUp(); RecipientInventory.UpdateHUD();
    bPrepared = false;
    return Transferred;
}

private function RetireSingle(KFWeapon W)
{
    W.Inventory = None; W.InvManager = None; W.Instigator = None; W.SetOwner(None);
    W.AmmoCount[0] = 0; W.AmmoCount[1] = 0;
    W.SpareAmmoCount[0] = 0; W.SpareAmmoCount[1] = 0;
    W.Destroy();
}
