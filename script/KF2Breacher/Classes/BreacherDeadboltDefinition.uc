class BreacherDeadboltDefinition extends KFWeaponDefinition abstract;

static function string GetItemName() { return "Deadbolt"; }
static function string GetItemDescription()
{
    return "Breacher prototype. Align living Zeds: each distinct enemy increases the next hit's damage and width. Stock model and reload; balance provisional.";
}
static function string GetItemCategory() { return "Projectile"; }

defaultproperties
{
    WeaponClassPath="KF2Breacher.BreacherDeadbolt"
    ImagePath="WEP_UI_HRG_Nailgun_PDW_TEX.UI_WeaponSelect_HRG_Nailgun_PDW"
    // Temporary purchase/ammo values, not approved progression.
    BuyPrice=200
    AmmoPricePerMag=20
    EffectiveRange=50
}
