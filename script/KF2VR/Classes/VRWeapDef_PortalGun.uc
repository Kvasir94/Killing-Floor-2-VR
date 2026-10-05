// Experimental branch only. Sold by the trader in standalone games
// (VRTraderCatalog), since portals are local-only.
class VRWeapDef_PortalGun extends KFWeaponDefinition abstract;

static function string GetItemName() { return "Portal Gun"; }
static function string GetItemDescription() { return "Trigger: blue portal. Grip: orange portal. Walk, shoot and throw through them."; }
static function string GetItemCategory() { return "Equipment"; }

defaultproperties
{
    WeaponClassPath="KF2VR.VRWeap_PortalGun"
    ImagePath="ui_weaponselect_tex.UI_WeaponSelect_9mm"
    BuyPrice=1
    AmmoPricePerMag=0
    EffectiveRange=0
}
