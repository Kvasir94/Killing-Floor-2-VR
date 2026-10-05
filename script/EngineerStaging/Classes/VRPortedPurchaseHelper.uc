// Stock buying/selling with a kit preflight and a receipt for the exact
// authority-side debit. Handles allocation failure at trader close as well.
class VRPortedPurchaseHelper extends KFAutoPurchaseHelper;

var VREngineerPurchaseReceipt KitReceipt;

function bool bCanPurchase(STraderItem SelectedItem, optional bool bReturnError = true)
{
    if (class'VRPortedTraderRegistry'.static.IsPortedDefinition(SelectedItem.WeaponDef)
        && !class'VRPortedTraderRegistry'.static.DependenciesReady(SelectedItem.WeaponDef)) return false;
    return Super.bCanPurchase(SelectedItem, bReturnError);
}

function PurchaseWeapon(STraderItem ShopItem)
{
    local int BeforeDosh;
    local KFPlayerController PC;
    if (ShopItem.WeaponDef != class'VRWeapDef_EngineerKit') { Super.PurchaseWeapon(ShopItem); return; }
    if (!bCanPurchase(ShopItem, true)) return;
    PC = Outer;
    if (PC == None || MyKFPRI == None || MyKFIM == None || PC.WorldInfo.NetMode != NM_Standalone) return;
    KitReceipt = PC.Spawn(class'VREngineerPurchaseReceipt', PC);
    if (KitReceipt == None) return;
    KitReceipt.PC = PC; KitReceipt.Builder = KFPawn_Human(PC.Pawn);
    KitReceipt.Manager = MyKFIM;
    BeforeDosh = int(MyKFPRI.Score);
    Super.PurchaseWeapon(ShopItem);
    KitReceipt.PaidDosh = Max(0, BeforeDosh - int(MyKFPRI.Score));
    if (KitReceipt.PaidDosh <= 0 || MyKFIM.GetTransactionItemIndex('VREngineerPDA') == INDEX_NONE)
    { KitReceipt.Destroy(); KitReceipt = None; }
}

function SellWeapon(SItemInformation ItemInfo, optional int SelectedItemIndex = -1)
{
    if (ItemInfo.DefaultItem.ClassName == 'VREngineerPDA' && KitReceipt != None)
    { KitReceipt.Destroy(); KitReceipt = None; }
    Super.SellWeapon(ItemInfo, SelectedItemIndex);
}
