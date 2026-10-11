class BreacherRipcordDefinition extends KFWeaponDefinition abstract;

static function string GetItemName() { return "Ripcord"; }
static function string GetItemDescription()
{
    return "Breacher prototype. Forearm winch harpoon: reels an eligible Zed to grab range. Its cabled hook returns after release or a miss; no magazine reload. Balance provisional.";
}
static function string GetItemCategory() { return "Projectile"; }

defaultproperties
{
    WeaponClassPath="KF2Breacher.BreacherRipcord"
    ImagePath="WEP_UI_Crossbow_TEX.UI_WeaponSelect_Crossbow"
    // Temporary purchase/ammo values, not approved progression.
    BuyPrice=650
    AmmoPricePerMag=0
    EffectiveRange=60
}
