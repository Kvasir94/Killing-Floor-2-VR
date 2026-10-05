// Construction PDA selects a blueprint. It never directly creates a building.
class VREngineerPDA extends VREngineerWeapon;

var bool bKitGrantFailed, bKitRefunded;

function GivenTo(Pawn ThisPawn, optional bool bDoNotActivate)
{
    Super.GivenTo(ThisPawn, bDoNotActivate);
    Engineer = class'VREngineerKit'.static.Grant(self, KFPlayerController(ThisPawn.Controller));
    if (Engineer == None)
    {
        bKitGrantFailed = true;
        RefundFailedTraderGrant(KFInventoryManager(ThisPawn.InvManager));
        Destroy();
    }
}

function RefundFailedTraderGrant(KFInventoryManager Manager)
{
    local KFGameReplicationInfo GRI;
    local KFPlayerReplicationInfo PRI;
    local KFGFxObject_TraderItems.STraderItem ShopItem;
    local int I, Price;
    local VREngineerPurchaseReceipt Receipt;
    if (bKitRefunded || Manager == None || Manager.GetTransactionItemIndex(Class.Name) == INDEX_NONE) return;
    foreach WorldInfo.AllActors(class'VREngineerPurchaseReceipt', Receipt)
        if (Receipt.Manager == Manager && !Receipt.bDeleteMe)
        { Receipt.Refund(); bKitRefunded = true; return; }
    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    PRI = KFPlayerReplicationInfo(Instigator.PlayerReplicationInfo);
    if (GRI == None || GRI.TraderItems == None || PRI == None) return;
    for (I = 0; I < GRI.TraderItems.SaleItems.Length; ++I)
        if (GRI.TraderItems.SaleItems[I].ClassName == Class.Name)
        {
            ShopItem = GRI.TraderItems.SaleItems[I];
            Price = Manager.GetAdjustedBuyPriceFor(ShopItem);
            PRI.AddDosh(Price);
            bKitRefunded = true;
            `log("KF2VR_ENGINEER action=kit-grant-rolled-back refund=" $ Price);
            return;
        }
}

simulated function StartFire(byte FireModeNum)
{
    if (!CanStartSourceAction()) return;
    if (FireModeNum == 0 && !bPrimaryHeld)
    {
        bPrimaryHeld = true;
        if (!Engineer.SelectBlueprint(EBS_Sentry)) PlaySourceSound('wrench_hit_build_fail');
    }
}

function int AddAmmo(int Amount)
{
    if (Engineer == None || Amount <= 0) return 0;
    return Engineer.AddMetal(Amount);
}

simulated function bool AmmoMaxed(optional byte AmmoType)
{
    return Engineer == None || Engineer.Metal >= 200;
}

defaultproperties
{
    FirstPersonMeshName="KF2VREngineer.ConstructionPDA"
    PickupMeshName=""
    GroupPriority=203
    InventorySize=6
    // KF2 boxes grant half the resource capacity: one TF2 medium ammo pack.
    SpareAmmoCapacity(0)=200
    AmmoPickupScale(0)=0.5
}
