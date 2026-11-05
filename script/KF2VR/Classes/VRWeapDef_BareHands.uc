// Kill and damage identity for unarmed VR melee: fists, boxing gloves, the
// palm shove and held-body slams. Every one of those damage types points
// here so stock match stats and last-hit attribution credit one weapon.
// Never sold: it has no weapon class and is not in VRTraderCatalog.
class VRWeapDef_BareHands extends KFWeaponDefinition abstract;

static function string GetItemName() { return "Bare hands"; }
static function string GetItemDescription() { return "Punches, shoves and swinging one Zed into another."; }
static function string GetItemCategory() { return "Melee"; }

// No WeaponClassPath to localize from, so the stock lookup would index an
// empty path; answer every key from the script package (as the Tomahawk does).
static function string GetItemLocalization(string KeyName)
{
    if (KeyName ~= "ItemName") return GetItemName();
    if (KeyName ~= "ItemDescription") return GetItemDescription();
    if (KeyName ~= "ItemCategory") return GetItemCategory();
    return "";
}

defaultproperties
{
    ImagePath="UI_PerkIcons_TEX.UI_PerkIcon_Berserker"
    BuyPrice=0
    AmmoPricePerMag=0
    EffectiveRange=1
}
