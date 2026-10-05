// Separate stock trader transaction for one additional axe, never a grant
// or same-class duplicate purchase. Price, weight and upgrades match one axe.
class VRWeapDef_TomahawkSecond extends VRWeapDef_Tomahawk abstract;

static function string GetItemName() { return "RAVEN-7 Additional Axe"; }
static function string GetItemLocalization(string KeyName)
{
    if (KeyName ~= "ItemName") return GetItemName();
    return Super.GetItemLocalization(KeyName);
}

defaultproperties
{
    WeaponClassPath="KF2VR.VRWeap_TomahawkSecond"
}
