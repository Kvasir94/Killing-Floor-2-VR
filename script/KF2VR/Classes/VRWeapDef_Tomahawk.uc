// Sold by the trader under Berserker (VRTraderCatalog), VR sessions only.
class VRWeapDef_Tomahawk extends KFWeaponDefinition abstract;

static function string GetItemName() { return "RAVEN-7 Tomahawk"; }
static function string GetItemDescription() { return "Swing to strike. Hold the trigger to prepare, then release mid-swing to throw. Hold again in flight to suspend, release to recall. A resting axe recalls on press; grip also recalls."; }
static function string GetItemCategory() { return "Melee"; }

// The trader's owned-inventory pane queries localization directly, bypassing
// GetItemName. These fields must work from the script package itself because
// the current playable package does not ship an external KF2VR.int catalog.
static function string GetItemLocalization(string KeyName)
{
    if (KeyName ~= "ItemName") return GetItemName();
    if (KeyName ~= "ItemDescription") return GetItemDescription();
    if (KeyName ~= "ItemCategory") return GetItemCategory();
    return Super.GetItemLocalization(KeyName);
}

defaultproperties
{
    WeaponClassPath="KF2VR.VRWeap_Tomahawk"
    ImagePath="KF2VRHands.VRTomahawkIcon"
    BuyPrice=750
    AmmoPricePerMag=0
    EffectiveRange=2
    UpgradePrice[0]=600
    UpgradePrice[1]=700
    UpgradeSellPrice[0]=450
    UpgradeSellPrice[1]=975
}
