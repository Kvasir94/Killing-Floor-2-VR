// Authority inventory handoff shared by desktop Use and VR catches. The caller
// owns reach, hand/held revisions, stock-tail readiness and mechanism debt.
// Enter the caller's transfer guard before Commit: stock removal deliberately
// retires the old held identity and must not recall the claimed world prop.
class VRWorldDropTransfer extends Object;

const Rejected = 0;
const Transferred = 1;
const OwnershipFault = 2;

var private KFPawn_Human Original, Recipient;
var private Controller OriginalController, RecipientController;
var private KFInventoryManager OriginalInventory, RecipientInventory;
var private KFWeapon Weapon;
var private KFMedicWeaponComponent PreparedMedic;
var private KFTargetingWeaponComponent PreparedTargeting;
var private class<KFMedicWeaponComponent> MedicClass;
var private class<KFTargetingWeaponComponent> TargetingClass;
var private bool bMedicTickDisabled, bTargetingTickDisabled;
var private int PreparedAmmo[2], PreparedReserve[2], PreparedUpgrade;
var private byte PreparedMedicAmmoCost;
var private bool bPrepared, bComponentsInstalled;
// Once this is true, a failed Commit is terminal, never a safe retry. A native
// inventory callback unexpectedly changing/destroying W needs owner recovery.
var bool bMutationStarted;
var private VRWorldDropGun PublicProp;
var private Actor StockPickup;
var private KFWeapon StockOriginal;
var private byte StockIndex;
var private bool bReuseMedic, bReuseTargeting;
var private bool bRemoteStockSecondary;

function bool PrepareStock(Actor Pickup, KFPawn_Human Catcher, optional KFWeapon PreparedIncoming)
{
    local KFDroppedPickup Dropped;
    local KFPickupFactory_Item Factory;
    if (Pickup == None || Pickup.Role != ROLE_Authority || Pickup.bDeleteMe) return false;
    StockPickup = Pickup;
    Dropped = KFDroppedPickup(Pickup);
    Factory = KFPickupFactory_Item(Pickup);
    if (Dropped != None)
    {
        StockOriginal = KFWeapon(Dropped.Inventory);
        bRemoteStockSecondary = Catcher != None && !Catcher.IsLocallyControlled();
        if (PreparedIncoming == None) PreparedIncoming = StockOriginal;
    }
    else if (Factory != None) StockIndex = Factory.PickupIndex;
    return Prepare(None, Catcher, PreparedIncoming);
}

private function bool StockCurrent(KFWeapon W)
{
    local KFDroppedPickup Dropped;
    local KFPickupFactory_Item Factory;
    local KFWeapon Candidate;
    if (StockPickup == None || StockPickup.bDeleteMe || StockPickup.Role != ROLE_Authority
        || W == None || W.bDeleteMe || W.WorldInfo != StockPickup.WorldInfo
        || W.Inventory != None || W.Instigator != None) return false;
    Dropped = KFDroppedPickup(StockPickup);
    if (Dropped != None)
    {
        if (VRWorldDropGun(Dropped) != None || StockOriginal == None || StockOriginal.bDeleteMe
            || StockOriginal.WorldInfo != StockPickup.WorldInfo
            || Dropped.Inventory != StockOriginal || Dropped.InventoryClass != W.Class) return false;
        if (W != StockOriginal)
        {
            if (KFWeap_DualBase(StockOriginal) == None || KFWeap_DualBase(StockOriginal).SingleClass != W.Class
                || W.Owner != None || W.InvManager != None
                || StockOriginal.AmmoCount[0] != W.AmmoCount[0] || StockOriginal.AmmoCount[1] != W.AmmoCount[1]
                || StockOriginal.SpareAmmoCount[0] != W.SpareAmmoCount[0]
                || StockOriginal.SpareAmmoCount[1] != W.SpareAmmoCount[1]
                || StockOriginal.CurrentWeaponUpgradeIndex != W.CurrentWeaponUpgradeIndex) return false;
        }
        else if (W.Owner != None && W.Owner != Dropped) return false;
        if (StockOriginal.Instigator != None || StockOriginal.Inventory != None
            || (StockOriginal.Owner != None && StockOriginal.Owner != Dropped)) return false;
        if (StockOriginal.InvManager != None && !StockOriginal.InvManager.bPendingDelete)
            foreach StockOriginal.InvManager.InventoryActors(class'KFWeapon', Candidate)
                if (Candidate == StockOriginal) return false;
        return true;
    }
    Factory = KFPickupFactory_Item(StockPickup);
    return Factory != None && !Factory.bPickupHidden && Factory.ReadyToPickup(0)
        && Factory.CanUsePickup() && Factory.PickupIndex == StockIndex
        && StockIndex < Factory.ItemPickups.Length && Factory.ItemPickups[StockIndex].ItemClass == W.Class
        && W.Owner == None && W.InvManager == None;
}

// Death extraction deliberately runs with Health=0 before stock discard.
// Liveness belongs to recipient validation, not this exact chain membership.
static function bool InventoryContains(KFPawn_Human P, KFWeapon W)
{
    local KFWeapon Candidate;
    if (P == None || P.InvManager == None || W == None || W.bDeleteMe
        || W.Role != ROLE_Authority || W.Owner != P || W.InvManager != P.InvManager) return false;
    foreach P.InvManager.InventoryActors(class'KFWeapon', Candidate)
        if (Candidate == W) return true;
    return false;
}

static function bool AdoptOwned(KFPawn_Human P, KFWeapon W)
{
    if (!Owns(P, W)) return false;
    if (VRWeap_Tomahawk(W) != None && !class'VRWeap_Tomahawk'.static.CanWield(W, P)) return false;
    KFInventoryManager(P.InvManager).SetCurrentWeapon(W);
    return Owns(P, W);
}

function bool PreparePublic(VRWorldDropGun Prop, KFPawn_Human Catcher)
{
    if (Prop == None || Prop.SourceRegistry == None
        || !Prop.SourceRegistry.HasPublicWeapon(Prop, Prop.OwnedWeapon)) return false;
    PublicProp = Prop;
    return Prepare(None, Catcher, Prop.OwnedWeapon);
}

static function bool ValidBody(KFPawn_Human P)
{
    return P != None && !P.bDeleteMe && P.Role == ROLE_Authority
        && P.IsAliveAndWell() && P.Controller != None && !P.Controller.bDeleteMe
        && P.Controller.Pawn == P && KFInventoryManager(P.InvManager) != None
        && !P.InvManager.bPendingDelete;
}

static function bool Owns(KFPawn_Human P, KFWeapon W)
{
    local KFWeapon Candidate;
    if (!ValidBody(P) || W == None || W.bDeleteMe || W.Role != ROLE_Authority
        || W.Owner != P || W.Instigator != P || W.InvManager != P.InvManager) return false;
    foreach P.InvManager.InventoryActors(class'KFWeapon', Candidate)
        if (Candidate == W) return true;
    return false;
}

static function bool SecondaryPistol(class<KFWeapon> WeaponClass)
{
    return WeaponClass != None && (WeaponClass.Name == 'KFWeap_Pistol_9mm'
        || WeaponClass.Name == 'KFWeap_Pistol_Dual9mm'
        || WeaponClass.Name == 'KFWeap_HRG_93R'
        || WeaponClass.Name == 'KFWeap_HRG_93R_Dual');
}

static function bool CanReceive(KFPawn_Human P, KFWeapon W)
{
    local KFInventoryManager Manager;
    local KFWeapon Existing;
    local KFWeap_DualBase Dual;
    local VRWeaponPair ExistingPair;
    local KFGameReplicationInfo GRI;
    if (!ValidBody(P) || !P.bCanPickupInventory || W == None || W.bDeleteMe
        || W.WorldInfo != P.WorldInfo) return false;
    // World props bypass VRTomahawkPickup.ValidTouch. Keep its tracked-hand
    // requirement at the authority transaction before ownership can change.
    if (VRWeap_Tomahawk(W) != None && !class'VRWeap_Tomahawk'.static.CanWield(W, P)) return false;
    GRI = KFGameReplicationInfo(P.WorldInfo.GRI);
    if (GRI != None && GRI.bIsEndlessPaused) return false;
    Manager = KFInventoryManager(P.InvManager);
    Dual = KFWeap_DualBase(W);
    foreach Manager.InventoryActors(class'KFWeapon', Existing)
    {
        ExistingPair = class'VRWeaponPair'.static.ForMember(Existing);
        if (ExistingPair != None && ExistingPair.IsMember(Existing) && ExistingPair.StockItem != None)
            if (W.Class == ExistingPair.StockItem.Class || W.Class == ExistingPair.StockItem.SingleClass
                || (SecondaryPistol(W.Class) && SecondaryPistol(ExistingPair.StockItem.Class))) return false;
        // Stock pickup permits some of these by creating/merging a dual. This
        // exact-actor transaction refuses all such destructive merge cases.
        if (Existing == W || Existing.Class == W.Class
            || (W.DualClass != None && Existing.Class == W.DualClass)
            || (Dual != None && Existing.Class == Dual.SingleClass)
            || (SecondaryPistol(W.Class) && SecondaryPistol(Existing.Class))) return false;
    }
    return Manager.CanCarryWeapon(W.Class, W.CurrentWeaponUpgradeIndex);
}

function Cancel()
{
    if (!bComponentsInstalled)
    {
        if (PreparedMedic != None)
        {
            if (bReuseMedic) PreparedMedic.SetTickIsDisabled(bMedicTickDisabled);
            else PreparedMedic.Destroy();
        }
        if (PreparedTargeting != None)
        {
            if (bReuseTargeting) PreparedTargeting.SetTickIsDisabled(bTargetingTickDisabled);
            else PreparedTargeting.Destroy();
        }
    }
    PreparedMedic = None; PreparedTargeting = None;
    bPrepared = false;
    bReuseMedic = false; bReuseTargeting = false;
}

// Allocation failure and every preflight rejection preserve original ownership.
// Use one helper per transfer attempt; Cancel frees an abandoned preparation.
function bool Prepare(KFPawn_Human OriginalOwner, KFPawn_Human Catcher, KFWeapon W)
{
    local int I;
    local KFWeapon Metadata;
    if (bMutationStarted) return false;
    Cancel();
    if (OriginalOwner == Catcher || !SourceCurrent(OriginalOwner, W) || !CanReceive(Catcher, W)
        || class'VRWeaponPair'.static.ForMember(W) != None
        || class'VRWeaponPair'.static.IsMemberClass(W.Class)) return false;
    Original = OriginalOwner; Recipient = Catcher; Weapon = W;
    OriginalController = Original != None ? Original.Controller : None;
    RecipientController = Recipient.Controller;
    OriginalInventory = Original != None ? KFInventoryManager(Original.InvManager) : None;
    RecipientInventory = KFInventoryManager(Recipient.InvManager);
    MedicClass = W.MedicCompClass; TargetingClass = W.TargetingCompClass;
    PreparedUpgrade = W.CurrentWeaponUpgradeIndex;
    for (I = 0; I < 2; ++I)
    { PreparedAmmo[I] = W.AmmoCount[I]; PreparedReserve[I] = W.SpareAmmoCount[I]; }
    PreparedReserve[1] = class'VRSecondaryAmmoPools'.static.Reserve(W, bRemoteStockSecondary);
    if (class'VRSecondaryAmmoPools'.static.HasTotal(W)
        && (PreparedAmmo[1] < 0 || PreparedReserve[1] < 0 || PreparedAmmo[1] > MaxInt - PreparedReserve[1]))
    { Cancel(); return false; }
    if (MedicClass != None)
    {
        if (W.MedicComp != None) PreparedMedicAmmoCost = W.MedicComp.AmmoCost;
        else if (PublicProp != None) PreparedMedicAmmoCost = PublicProp.PublicMedicAmmoCost;
        else if (StockPickup != None)
        {
            // Stock dropping destroyed the original component. A disposable
            // authored instance exposes its public cost without protected SDK
            // access; no inventory or source pickup is changed by this sample.
            Metadata = RecipientInventory.Spawn(W.Class, Recipient);
            if (Metadata == None || Metadata.MedicComp == None)
            {
                if (Metadata != None)
                {
                    if (Metadata.TargetingComp != None) Metadata.TargetingComp.Destroy();
                    Metadata.SetOwner(None); Metadata.Instigator = None; Metadata.Destroy();
                }
                Cancel(); return false;
            }
            PreparedMedicAmmoCost = Metadata.MedicComp.AmmoCost;
            Metadata.MedicComp.Destroy(); Metadata.MedicComp = None;
            if (Metadata.TargetingComp != None) Metadata.TargetingComp.Destroy();
            Metadata.TargetingComp = None; Metadata.SetOwner(None); Metadata.Instigator = None;
            Metadata.Destroy();
        }
        else { Cancel(); return false; }
        // Ownerless until commit: preparation must not replicate an unbound
        // component to the recipient before Weapon.MedicCompRepActor is set.
        bReuseMedic = OriginalInventory == None && W.MedicComp != None;
        PreparedMedic = bReuseMedic ? W.MedicComp : Recipient.Spawn(MedicClass);
        if (PreparedMedic == None) { Cancel(); return false; }
        bMedicTickDisabled = PreparedMedic.bTickIsDisabled;
        PreparedMedic.SetTickIsDisabled(true);
    }
    if (TargetingClass != None)
    {
        bReuseTargeting = OriginalInventory == None && W.TargetingComp != None;
        PreparedTargeting = bReuseTargeting ? W.TargetingComp : Recipient.Spawn(TargetingClass);
        if (PreparedTargeting == None) { Cancel(); return false; }
        bTargetingTickDisabled = PreparedTargeting.bTickIsDisabled;
        PreparedTargeting.SetTickIsDisabled(true);
    }
    bPrepared = true;
    return true;
}

private function bool SourceCurrent(KFPawn_Human OriginalOwner, KFWeapon W)
{
    if (StockPickup != None) return OriginalOwner == None && StockCurrent(W);
    if (PublicProp != None)
        return OriginalOwner == None && PublicProp.SourceRegistry != None
            && PublicProp.SourceRegistry.HasPublicWeapon(PublicProp, W);
    return Owns(OriginalOwner, W);
}

function bool StillPrepared()
{
    local int I;
    if (!bPrepared || bMutationStarted || !SourceCurrent(Original, Weapon) || !CanReceive(Recipient, Weapon)
        || (Original != None && (Original.Controller != OriginalController || Original.InvManager != OriginalInventory))
        || Recipient.Controller != RecipientController || Recipient.InvManager != RecipientInventory
        || Weapon.CurrentWeaponUpgradeIndex != PreparedUpgrade
        || Weapon.MedicCompClass != MedicClass || Weapon.TargetingCompClass != TargetingClass
        || (MedicClass != None && (PreparedMedic == None || PreparedMedic.bDeleteMe))
        || (TargetingClass != None && (PreparedTargeting == None || PreparedTargeting.bDeleteMe))) return false;
    for (I = 0; I < 2; ++I)
        if (Weapon.AmmoCount[I] != PreparedAmmo[I]) return false;
    if (Weapon.SpareAmmoCount[0] != PreparedReserve[0]
        || class'VRSecondaryAmmoPools'.static.Reserve(Weapon, bRemoteStockSecondary) != PreparedReserve[1]) return false;
    return true;
}

// Rejected guarantees no inventory mutation. OwnershipFault is an unexpected
// post-boundary failure: the caller must reconcile actual ownership, not retry
// or recreate the source prop. All ordinary failure-prone allocations precede it.
function byte Commit(optional bool bDoNotActivate=true)
{
    local int I;
    if (!StillPrepared()) { Cancel(); return Rejected; }
    bMutationStarted = true;
    if (OriginalInventory != None) OriginalInventory.RemoveFromInventory(Weapon);
    if (Weapon == None || Weapon.bDeleteMe || Owns(Original, Weapon))
    { Cancel(); return OwnershipFault; }
    // ItemRemovedFromInvManager destroyed the former owner's components. Match
    // KFWeapon.PreBeginPlay's initialization before GivenTo starts medic recharge.
    Weapon.SetOwner(Recipient);
    Weapon.Instigator = Recipient; Weapon.InvManager = RecipientInventory;
    Weapon.CacheKFPlayerController();
    Weapon.InitializeAmmoCapacity();
    if (OriginalInventory == None)
    {
        if (Weapon.MedicComp != None && Weapon.MedicComp != PreparedMedic) Weapon.MedicComp.Destroy();
        if (Weapon.TargetingComp != None && Weapon.TargetingComp != PreparedTargeting) Weapon.TargetingComp.Destroy();
    }
    Weapon.MedicComp = PreparedMedic; Weapon.MedicCompRepActor = PreparedMedic;
    Weapon.TargetingComp = PreparedTargeting; Weapon.TargetingCompRepActor = PreparedTargeting;
    bComponentsInstalled = true;
    if (PreparedMedic != None)
    {
        PreparedMedic.SetOwner(Recipient);
        PreparedMedic.Init(Weapon, PreparedMedicAmmoCost);
        // Its default initial replication is 100. Seed the actual charge so a
        // later component-channel update cannot undo the weapon ammo receipt.
        PreparedMedic.HealingDartAmmo = byte(Clamp(Weapon.AmmoCount[1], 0, 255));
        PreparedMedic.SetTickIsDisabled(bMedicTickDisabled);
    }
    if (PreparedTargeting != None)
    {
        PreparedTargeting.SetOwner(Recipient);
        PreparedTargeting.Init(Weapon);
        PreparedTargeting.SetTickIsDisabled(bTargetingTickDisabled);
    }
    // Stock AddInventory sets Owner/Instigator/InvManager, links the group,
    // accounts weight and sends ClientGivenTo to the new owning connection.
    // true keeps either hand mode's currently equipped weapon unchanged.
    RecipientInventory.AddInventory(Weapon, bDoNotActivate);
    if (!Owns(Recipient, Weapon)) { Cancel(); return OwnershipFault; }
    // Capacity follows the recipient's perk, but the transfer moves the full
    // paid pools even above that capacity. Never route them through AddAmmo,
    // pickup copy/merge or perk reinitialization, which may clamp reserve.
    for (I = 0; I < 2; ++I)
    { Weapon.AmmoCount[I] = PreparedAmmo[I]; Weapon.SpareAmmoCount[I] = PreparedReserve[I]; }
    class'VRSecondaryAmmoPools'.static.Write(Weapon, PreparedAmmo[1], PreparedReserve[1]);
    if (PreparedMedic != None)
        PreparedMedic.HealingDartAmmo = byte(Clamp(Weapon.AmmoCount[1], 0, 255));
    Weapon.bForceNetUpdate = true;
    Weapon.ClientForceAmmoUpdate(Weapon.AmmoCount[0], Weapon.SpareAmmoCount[0]);
    Weapon.ClientForceSecondaryAmmoUpdate(Weapon.AmmoCount[1]);
    Weapon.NotifyPickedUp();
    RecipientInventory.UpdateHUD();
    Cancel();
    return Transferred;
}
