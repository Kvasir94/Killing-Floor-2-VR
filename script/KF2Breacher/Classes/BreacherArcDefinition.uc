class BreacherArcDefinition extends KFWeaponDefinition abstract;

static function string GetItemName() { return "ArcFence"; }
static function string GetItemDescription() { return "Place linked pins, then Collapse toward the highlighted destination."; }

defaultproperties
{
    WeaponClassPath="KF2Breacher.BreacherArcGrenade"
    ImagePath="ui_weaponselect_tex.UI_WeaponSelect_EMPGrenade"
}
