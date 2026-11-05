// A deliberate tracked catch of an existing stock pickup. Desktop touch/Use
// remains stock; no source actor or factory is consumed during preflight.
class VRStockWorldPickup extends Object;

static simulated function bool IsPickup(Actor Pickup)
{
    local KFDroppedPickup Dropped;
    local KFPickupFactory_Item Factory;
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || Pickup == None || Pickup.bDeleteMe || Pickup.bHidden) return false;
    Dropped = KFDroppedPickup(Pickup);
    if (Dropped != None)
        return VRWorldDropGun(Dropped) == None && class<KFWeapon>(Dropped.InventoryClass) != None;
    Factory = KFPickupFactory_Item(Pickup);
    return Factory != None && !Factory.bPickupHidden && Factory.PickupIndex < Factory.ItemPickups.Length
        && class<KFWeapon>(Factory.ItemPickups[Factory.PickupIndex].ItemClass) != None;
}

static simulated function vector GrabPosition(Actor Pickup)
{
    local KFDroppedPickup Dropped;
    local KFPickupFactory_Item Factory;
    if (Pickup == None) return vect(0,0,0);
    Dropped = KFDroppedPickup(Pickup);
    if (Dropped != None && Dropped.MyMeshComp != None) return Dropped.MyMeshComp.Bounds.Origin;
    Factory = KFPickupFactory_Item(Pickup);
    if (Factory != None && Factory.PickupMesh != None) return Factory.PickupMesh.Bounds.Origin;
    return Pickup.Location;
}

static simulated function bool NearHand(Actor Pickup, vector Palm, int Hand)
{
    local vector At, Extent, Offset;
    local KFDroppedPickup Dropped;
    local KFPickupFactory_Item Factory;
    if (Hand < 0 || Hand > 1 || !IsPickup(Pickup)
        || !class'VRReloadMotionGuard'.static.ValidPosition(Palm)) return false;
    At = GrabPosition(Pickup);
    Dropped = KFDroppedPickup(Pickup);
    Factory = KFPickupFactory_Item(Pickup);
    if (Dropped != None && Dropped.MyMeshComp != None) Extent = Dropped.MyMeshComp.Bounds.BoxExtent;
    else if (Factory != None && Factory.PickupMesh != None) Extent = Factory.PickupMesh.Bounds.BoxExtent;
    // Any visible part may establish a primary grip. Keep the world bounds
    // bounded, and trace the exact contact rather than reaching through a wall.
    Offset = Palm - At;
    At.X += FClamp(Offset.X, -FClamp(Extent.X, 0, 100), FClamp(Extent.X, 0, 100));
    At.Y += FClamp(Offset.Y, -FClamp(Extent.Y, 0, 100), FClamp(Extent.Y, 0, 100));
    At.Z += FClamp(Offset.Z, -FClamp(Extent.Z, 0, 100), FClamp(Extent.Z, 0, 100));
    return VSizeSq(Palm - At) <= Square(20.0) && Pickup.FastTrace(At, Palm);
}

private function DiscardPrepared(KFWeapon W)
{
    if (W == None || W.bDeleteMe) return;
    if (W.MedicComp != None) W.MedicComp.Destroy();
    if (W.TargetingComp != None) W.TargetingComp.Destroy();
    W.MedicComp = None; W.TargetingComp = None;
    W.SetOwner(None); W.Instigator = None; W.InvManager = None;
    W.Destroy();
}

function KFWeapon Catch(Actor Pickup, KFPawn_Human Catcher, vector Palm, int Hand)
{
    local KFDroppedPickup Dropped;
    local KFPickupFactory_Item Factory;
    local KFWeapon Original, Incoming, ResultWeapon;
    local class<KFWeapon> WeaponClass;
    local KFInventoryManager Manager;
    local VRWorldDropTransfer Transfer;
    local VRWorldDropSingleMerge Merge;
    local VRWorldDropHandoff Handoff;
    local byte Outcome;
    local int I;
    local bool bGenerated;
    if (!class'VRWorldDropTransfer'.static.ValidBody(Catcher)
        || !class'VRPhysicalInteraction'.static.Allowed(Catcher) || !Catcher.bCanPickupInventory
        || Pickup == None || Pickup.Role != ROLE_Authority || Pickup.WorldInfo != Catcher.WorldInfo
        || !NearHand(Pickup, Palm, Hand)) return None;
    Dropped = KFDroppedPickup(Pickup);
    Factory = KFPickupFactory_Item(Pickup);
    Manager = KFInventoryManager(Catcher.InvManager);
    if (Dropped != None)
    {
        if (!Dropped.ValidTouch(Catcher)) return None;
        Original = KFWeapon(Dropped.Inventory);
        WeaponClass = class<KFWeapon>(Dropped.InventoryClass);
        if (Original == None || Original.bDeleteMe || WeaponClass == None) return None;
        if (Original.Class == WeaponClass) Incoming = Original;
        else if (KFWeap_DualBase(Original) == None || KFWeap_DualBase(Original).SingleClass != WeaponClass)
            return None;
    }
    else if (Factory != None)
    {
        if (!Factory.ReadyToPickup(0) || !Factory.CanUsePickup()
            || !Factory.FastTrace(Catcher.Location, Factory.Location)) return None;
        WeaponClass = class<KFWeapon>(Factory.ItemPickups[Factory.PickupIndex].ItemClass);
        if (Catcher.WorldInfo.Game == None || !Catcher.WorldInfo.Game.PickupQuery(Catcher, WeaponClass, Factory)) return None;
    }
    else return None;
    if (Incoming == None)
    {
        // This is the same spawn context/owner as stock CreateInventory.
        // PreBeginPlay initializes legitimate map ammo exactly once. A dual
        // drop instead replaces those initial pools with its exact paid single.
        Incoming = Manager.Spawn(WeaponClass, Catcher);
        if (Incoming == None) return None;
        bGenerated = true;
        if (Original != None)
        {
            Incoming.SetWeaponUpgradeLevel(Original.CurrentWeaponUpgradeIndex);
            for (I = 0; I < 2; ++I)
            { Incoming.AmmoCount[I] = Original.AmmoCount[I]; Incoming.SpareAmmoCount[I] = Original.SpareAmmoCount[I]; }
            Incoming.bGivenAtStart = Original.bGivenAtStart;
        }
        else Incoming.bGivenAtStart = true;
        Incoming.SetOwner(None); Incoming.Instigator = None; Incoming.InvManager = None; Incoming.Inventory = None;
        Incoming.CacheKFPlayerController(); Incoming.GotoState('Inactive');
    }
    Transfer = new(self) class'VRWorldDropTransfer';
    if (Transfer.PrepareStock(Pickup, Catcher, Incoming))
    {
        Outcome = Transfer.Commit(true);
        if (Outcome == class'VRWorldDropTransfer'.const.Transferred
            || (Transfer.bMutationStarted && class'VRWorldDropTransfer'.static.Owns(Catcher, Incoming)))
            ResultWeapon = Incoming;
    }
    else
    {
        Merge = new(self) class'VRWorldDropSingleMerge';
        Handoff = new(self) class'VRWorldDropHandoff';
        if (Merge.PrepareStock(Pickup, Catcher, Incoming, true)
            && Handoff.PrepareRecipient(Catcher, Merge.RecipientSingle, Hand))
        {
            Outcome = Merge.Commit();
            Handoff.FinishRecipient(Merge);
            if (Outcome == class'VRWorldDropSingleMerge'.const.Transferred
                || (Merge.bMutationStarted && class'VRWorldDropTransfer'.static.Owns(Catcher, Merge.ResultWeapon)))
                ResultWeapon = Merge.ResultWeapon;
        }
        Merge.Cancel();
    }
    Transfer.Cancel();
    if (!class'VRWorldDropTransfer'.static.Owns(Catcher, ResultWeapon))
    {
        if (bGenerated && Outcome == 0) DiscardPrepared(Incoming);
        return None;
    }
    if (Dropped != None)
    {
        // Stock Destroyed destroys its Inventory. The actual adopted actor
        // must be unlinked first; a dual receipt's obsolete original is retired.
        Dropped.Inventory = None;
        if (Original != None && Original != Incoming && !Original.bDeleteMe) Original.Destroy();
        Dropped.Destroy();
    }
    else
    {
        Factory.ActivateNewPickup(Catcher);
        Factory.PickedUpBy(Catcher);
    }
    return ResultWeapon;
}
