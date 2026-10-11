class BreacherDeadboltDefinition extends KFWeaponDefinition abstract;

static function string GetItemName() { return "Deadbolt"; }
static function string GetItemDescription()
{
    return "Forearm-mounted spike forge. Each distinct living enemy increases the next hit's damage and width. Reload forges and seats fresh ammunition.";
}
static function string GetItemCategory() { return "Projectile"; }

defaultproperties
{
    WeaponClassPath="KF2Breacher.BreacherDeadbolt"
    ImagePath="KF2VRHands.VRDeadboltIcon"
    // Temporary purchase/ammo values, not approved progression.
    BuyPrice=200
    AmmoPricePerMag=20
    EffectiveRange=50
}
