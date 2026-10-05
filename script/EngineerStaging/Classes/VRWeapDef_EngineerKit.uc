class VRWeapDef_EngineerKit extends KFWeaponDefinition abstract;

static function string GetItemName() { return Localize("VREngineerKit", "ItemName", "KF2VR"); }
static function string GetItemDescription() { return Localize("VREngineerKit", "ItemDescription", "KF2VR"); }

defaultproperties
{
    WeaponClassPath="KF2VR.VREngineerPDA"
    BuyPrice=1000
    AmmoPricePerMag=0
    ImagePath="KF2VREngineer.Mat_df75e763e29a5ccaTexture"
    EffectiveRange=35
}
